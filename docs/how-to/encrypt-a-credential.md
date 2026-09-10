# Encrypt a credential

`AshSandbox.SandboxCredentialTemplate` stores the credential a sandbox uses to reach its own data
store. The secret is encrypted before it reaches the data layer and decrypted on the way back, by
`AshSandbox.EncryptedSecret`.

## 1. Generate and configure a key

```elixir
Base.encode64(:crypto.strong_rand_bytes(32))
```

```elixir
config :ash_sandbox, AshSandbox.EncryptedSecret,
  key: System.fetch_env!("SANDBOX_CREDENTIAL_KEY")
```

32 raw bytes, Base64-encoded. Anything else raises with the reason — wrong length, or not Base64 —
rather than silently producing unreadable rows.

⚠️ **Do not generate the key at runtime.** A generated key changes on restart and strands every
credential already written. It comes from configuration, and this is why key *rotation* is out of
scope for the type: rotating the encryption key means re-encrypting every row, which is a
migration. That is distinct from rotating a *credential*, which is the `:rotate` action below.

**A host that holds no credentials configures no key**, and that is a supported state. The library
derives the key at application start when one is configured and does nothing when none is; the
raise lands on the first *use* of a credential, where it names what the caller was trying to do.

## 2. Declare the resource

```elixir
defmodule MyApp.SandboxCredential do
  use AshSandbox.SandboxCredentialTemplate,
    data_layer: AshPostgres.DataLayer,
    domain: MyApp.Sandboxes,
    repo: MyApp.Repo,
    table: "sandbox_credentials",
    sandbox_resource: MyApp.Sandbox
end
```

## 3. Issue one

```elixir
{:ok, credential} =
  MyApp.SandboxCredential
  |> Ash.Changeset.for_create(:issue, %{
    sandbox_id: sandbox.id,
    role_name: "sbx_01_app",
    secret: generated_password,
    data_store_ref: "sbx_01_db"
  })
  |> Ash.create(authorize?: false)
```

`role_name` is unique across the table. Two sandboxes sharing a role share its grants, which is
the containment failure in one line.

`data_store_ref` records *which* logical database the credential is granted on, so a later rotation
or revoke knows where to act without re-deriving it.

## 4. Rotate it

```elixir
{:ok, credential} =
  credential
  |> Ash.Changeset.for_update(:rotate, %{secret: new_password})
  |> Ash.update(authorize?: false)

credential.version
# => 2
```

Rotation replaces the secret **in place**. The row survives, the role survives, and `version`
increments atomically — a second row would leave two live credentials for one sandbox and no
statement of which is current.

## What this protects against, and what it does not

Two mechanisms are in play and they defend against different readers. Neither implies the other,
which is why the template uses both:

* **The type** governs what someone reading the *table* sees — a backup, a replica, an operator
  with `SELECT`, a support engineer running an ad-hoc query. AES-256-GCM, a fresh 12-byte IV per
  write so two sandboxes with the same secret do not share ciphertext, stored as
  `iv <> tag <> ciphertext` and Base64-encoded so the column stays `text`.
* **`sensitive? true`** governs what Ash *prints* — inspect output, error messages, changeset
  dumps — and leaves the stored bytes untouched. That is where credentials actually leak: a
  crashed changeset in a log, an `{:error, changeset}` inspected by a failing test, a struct
  dumped by an observer.

GCM is authenticated, so tampered ciphertext produces a decrypt failure rather than a silently
different plaintext. A row that fails to authenticate is reported as invalid data against the
attribute; it does not crash whatever loaded the record.

⚠️ **The tenant can read its own credential, and that is not a leak.** The sandbox has to connect
to its own database, so the value is necessarily readable by tenant code. Containment does not come
from concealment — it comes from the credential granting nothing anywhere else: one `LOGIN` role
per sandbox, with privileges only on that sandbox's own logical database. A test asserting that
reading the credential *fails* would be testing the wrong guarantee and would fail a correct
implementation.

The `secret` attribute is deliberately **not** `public?`, so it cannot be read through an
owner-facing action; the provisioning path reads it with `authorize?: false` when injecting it at
sandbox start.

## Why not `cloak`

`cloak`/`cloak_ecto` is the conventional Elixir answer and was considered and rejected. This is a
published library, so every dependency it declares is inherited by every consumer, and imposing a
vault configuration on consumers who may hold no credentials at all is not worth 136 lines. Revisit
if key rotation without downtime becomes a requirement, or if a second encrypted attribute appears
in these packages.
