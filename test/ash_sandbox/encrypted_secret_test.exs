defmodule AshSandbox.EncryptedSecretTest do
  @moduledoc """
  The key is derived once and read many times.

  ## What the derivation cost actually was

  Base64-decoding 32 bytes is cheap; doing it on every encrypt *and* every
  decrypt is not the same statement. `cast_stored/2` runs per row, so loading a
  page of credentials re-derived the same key once per credential and allocated
  a fresh copy of it each time. Reading a `persistent_term` allocates nothing
  and copies nothing, which is why identity is the assertion below rather than
  equality: two equal keys would pass while the derivation still ran.

  ## The cache must not outlive the configuration

  A cache under a bare module name would encrypt with a key the configuration
  no longer names, and give no sign of it — the failure would surface much
  later as rows that decrypt with nothing. So the last test here matters more
  than the first two: changing the configured key must change the derived key.
  """
  # ⚠️ `async: false`. Two of these tests rewrite the application's configured
  # key, which every other test that stores a credential reads.
  use ExUnit.Case, async: false

  alias AshSandbox.EncryptedSecret

  test "the key is derived once, and later reads return that same term" do
    # The read that derives returns the term it built rather than the copy
    # `:persistent_term.put/2` made of it, so the identity below is between two
    # reads of the cache. `warm/0` has normally already made this a no-op.
    _warm = EncryptedSecret.key()
    first = EncryptedSecret.key()

    # ⚠️ `same/2`, not `==`. A re-derivation produces an equal binary, so
    # equality is exactly the assertion that cannot tell the two apart.
    assert :erts_debug.same(first, EncryptedSecret.key())
    assert :erts_debug.same(first, EncryptedSecret.key())
  end

  test "a round trip through the type does not re-derive per value" do
    _warm = EncryptedSecret.key()
    key = EncryptedSecret.key()

    stored =
      for secret <- ["one", "two", "three"] do
        {:ok, encrypted} = EncryptedSecret.dump_to_native(secret, [])
        encrypted
      end

    plaintexts =
      Enum.map(stored, fn encrypted ->
        {:ok, plaintext} = EncryptedSecret.cast_stored(encrypted, [])
        plaintext
      end)

    assert plaintexts == ["one", "two", "three"]
    assert :erts_debug.same(key, EncryptedSecret.key())
  end

  test "a configured key that changes changes the derived key" do
    previous = Application.get_env(:ash_sandbox, EncryptedSecret, [])
    rotated = Base.encode64(:crypto.strong_rand_bytes(32))

    on_exit(fn -> Application.put_env(:ash_sandbox, EncryptedSecret, previous) end)

    before = EncryptedSecret.key()

    Application.put_env(
      :ash_sandbox,
      EncryptedSecret,
      Keyword.put(previous, :key, rotated)
    )

    assert EncryptedSecret.key() == Base.decode64!(rotated)
    refute EncryptedSecret.key() == before
  end

  test "an unconfigured key raises on use rather than at boot" do
    previous = Application.get_env(:ash_sandbox, EncryptedSecret, [])
    on_exit(fn -> Application.put_env(:ash_sandbox, EncryptedSecret, previous) end)

    Application.put_env(:ash_sandbox, EncryptedSecret, Keyword.delete(previous, :key))

    # `warm/0` is called from the application callback, and a consumer of this
    # library that holds no credentials configures no key. Refusing to boot it
    # would make an unused feature a startup failure.
    assert EncryptedSecret.warm() == :ok

    assert_raise RuntimeError, ~r/requires an encryption key/, fn ->
      EncryptedSecret.dump_to_native("secret", [])
    end
  end
end
