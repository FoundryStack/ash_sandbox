defmodule AshSandbox.Application do
  # Private (FR-014). An OTP application callback is started by the runtime, not
  # called by a consumer, so it is not part of AshSandbox's interface -- see that
  # module's moduledoc for the public list.
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Derived once here rather than on every encrypt and every decrypt. A
    # consumer with no credentials has no key configured, and this is a no-op
    # for it -- see `AshSandbox.EncryptedSecret.warm/0`.
    :ok = AshSandbox.EncryptedSecret.warm()

    children = [
      # Starts a worker by calling: AshSandbox.Worker.start_link(arg)
      # {AshSandbox.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AshSandbox.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
