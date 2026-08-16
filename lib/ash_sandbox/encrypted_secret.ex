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

  defp key do
    config = Application.get_env(:ash_sandbox, __MODULE__, [])

    case Keyword.get(config, :key) do
      nil ->
        raise """
        #{inspect(__MODULE__)} requires an encryption key.

            config :ash_sandbox, #{inspect(__MODULE__)},
              key: System.fetch_env!("SANDBOX_CREDENTIAL_KEY")

        Generate one with: Base.encode64(:crypto.strong_rand_bytes(32))
        """

      encoded ->
        decode_key(encoded)
    end
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
