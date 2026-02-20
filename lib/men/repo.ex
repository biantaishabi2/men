defmodule Men.Repo do
  use Ecto.Repo,
    otp_app: :men,
    adapter: Ecto.Adapters.Postgres
end
