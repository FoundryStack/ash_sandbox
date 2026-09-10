# Changelog

## 0.1.0 — 2026-09-10

Extracted from the Axonn umbrella (`apps/ash_sandbox`) into a standalone package, carrying its
full commit history via `git subtree split`. No behavior changed by the extraction itself.

Public interface at extraction: `AshSandbox.RegistryTemplate`, `AshSandbox.ProjectTemplate`,
`AshSandbox.EnvironmentTemplate`, `AshSandbox.TemplateTemplate`,
`AshSandbox.OperationRecordTemplate`, `AshSandbox.SandboxCredentialTemplate`, and
`AshSandbox.EncryptedSecret` (public by consequence). See `priv/boundary.md` for the full contract.

`AshSandbox.RunPolicy`, the `AshSandbox.Resource` DSL extension, and `AshSandbox.Plug` were
withdrawn from the umbrella before extraction (R-12) and do not exist in this package.
