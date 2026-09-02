defmodule AshSandbox.EncryptedSecret do
  @moduledoc """
  A string that is encrypted before it reaches the data layer and decrypted on
  the way back (003 T036, data-model.md §SandboxCredential).

  ## Why this exists alongside `sensitive? true`

  The two are routinely conflated and protect against different readers.
  `sensitive? true` governs what Ash **prints** — inspect output, error
  messages, changeset dumps — and leaves the stored bytes untouched. This type
  governs what someone **reading the table** sees: a database backup, a replica,
  an operator with `SELECT`, or a support engineer running an ad-hoc query.

  A credential needs both, because neither implies the other. The resource
  therefore keeps `sensitive? true` on the attribute *and* uses this as its
  type.

  ## AES-256-GCM, from OTP's `:crypto`

  GCM is authenticated: tampering with stored ciphertext produces a decrypt
  failure rather than a silently different plaintext. That matters here because
  the value is fed into `CREATE ROLE ... PASSWORD` and a corrupted secret that
  decrypts to *something* would produce a sandbox nobody can connect to, with
  no indication why.

  A fresh 12-byte IV per write is generated for every encryption, so two
  sandboxes that happen to share a secret do not share ciphertext. Without it
  the scheme is deterministic and leaks equality across rows — an operator
  could see which sandboxes share a credential without decrypting anything.

  Stored as `iv <> tag <> ciphertext`, Base64-encoded so the column stays
  `text` and needs no migration.

  ## Key management

  The key comes from configuration and is **not** generated at runtime: a
  generated key would change on restart and strand every credential already
  written. Configure it as 32 raw bytes, Base64-encoded:

      config :ash_sandbox, AshSandbox.EncryptedSecret,
        key: System.fetch_env!("SANDBOX_CREDENTIAL_KEY")

  ## Why not `cloak`

  `cloak`/`cloak_ecto` is the conventional Elixir answer and was considered and
  rejected -- recorded in `003` data-model.md §Decision. The short form: this is
  a *published library* (`012-FR-015`), so every dependency it declares is
  inherited by every consumer, and imposing Cloak's vault configuration on
  consumers who may hold no credentials at all is not worth 136 lines. The
  accepted cost is the next paragraph.

  Revisit if a requirement appears for key rotation without downtime, or if a
  second encrypted attribute appears in these packages.

  This is deliberately not a key *rotation* mechanism. Rotating the encryption
  key means re-encrypting every row, which is a migration rather than a type
  concern — and distinct from `FR-020`'s credential rotation, which changes the
  secret itself and is handled by the resource's `:rotate` action.
  """
  use Ash.Type

  @cipher :aes_256_gcm
  @iv_bytes 12
  @tag_bytes 16

  @impl true
  def storage_type(_constraints), do: :text

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, _constraints) when is_binary(value), do: {:ok, value}

  def cast_input(_value, _constraints), do: :error

  # Values arriving from the data layer are ciphertext; values already in memory
  # (a freshly cast changeset attribute) are plaintext. `cast_stored/2` is only
  # called for the former, so decryption belongs there and nowhere else.
  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(value, _constraints) when is_binary(value), do: decrypt(value)

  def cast_stored(_value, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(value, _constraints) when is_binary(value), do: {:ok, encrypt(value)}

  def dump_to_native(_value, _constraints), do: :error

  defp encrypt(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(@cipher, key(), iv, plaintext, _aad = "", true)

    Base.encode64(iv <> tag <> ciphertext)
  end

  defp decrypt(stored) do
    with {:ok, raw} <- Base.decode64(stored),
         <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>> <- raw,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(@cipher, key(), iv, ciphertext, _aad = "", tag, false) do
      {:ok, plaintext}
    else
      # `:error` rather than a raise: a row whose ciphertext does not
      # authenticate is invalid data, and Ash reports it as such against the
      # attribute rather than crashing whatever happened to load the record.
      _ -> :error
    end
  end

  @doc """
  Derives the key now, so no later read has to.

  Called from `AshSandbox.Application.start/2`. A consumer that holds no
  credentials configures no key, so an unconfigured application is a no-op here
  rather than a boot failure — the raise belongs on the first *use* of a
  credential, where it names what the caller was trying to do.
  """
  @spec warm() :: :ok
  def warm do
    if configured(), do: _key = key()
    :ok
  end

  @doc false
  # ⚠️ Public for the test that asserts a read does not re-derive
  # (`encrypted_secret_test.exs`), and for no other caller. It returns the raw
  # key, which is why it is `@doc false`: `Application.get_env/2` already hands
  # the same secret to anything running in this VM, so this exposes nothing new,
  # but it should not read as part of the library's interface either.
  #
  # ## Cached in `persistent_term`, keyed by the configured value
  #
  # Base64-decoding and length-checking 32 bytes is not expensive, but it ran on
  # every encrypt *and* every decrypt -- so loading a page of credentials paid
  # for it once per row, allocating a fresh copy of the key each time. A
  # `persistent_term` read allocates nothing and copies nothing.
  #
  # The cache key includes the configured (encoded) value rather than being a
  # bare module name. A key that changed in configuration but not in the cache
  # would encrypt new rows with the old one and give no sign of it, and
  # `config/test.exs` sets a different key from `dev` -- so this is also what
  # keeps the cache honest across environments. Comparing the encoded string is
  # the cheap half; the decode is what is skipped.
  @spec key() :: binary()
  def key do
    encoded = configured() || raise missing_key_message()

    case :persistent_term.get({__MODULE__, :key, encoded}, :miss) do
      :miss ->
        derived = decode_key(encoded)
        :persistent_term.put({__MODULE__, :key, encoded}, derived)
        derived

      derived ->
        derived
    end
  end

  defp configured do
    Application.get_env(:ash_sandbox, __MODULE__, [])
    |> Keyword.get(:key)
  end

  defp missing_key_message do
    """
    #{inspect(__MODULE__)} requires an encryption key.

        config :ash_sandbox, #{inspect(__MODULE__)},
          key: System.fetch_env!("SANDBOX_CREDENTIAL_KEY")

    Generate one with: Base.encode64(:crypto.strong_rand_bytes(32))
    """
  end

  defp decode_key(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 ->
        key

      {:ok, key} ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} key must be 32 bytes for #{@cipher}, got #{byte_size(key)}"

      :error ->
        raise ArgumentError, "#{inspect(__MODULE__)} key must be Base64-encoded"
    end
  end
end
