defmodule AnglerWeb.HealthController do
  use AnglerWeb, :controller

  @doc "Returns 200 when the database is reachable, 503 otherwise."
  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(Angler.Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> json(conn, %{status: "ok"})
      {:error, _} -> conn |> put_status(503) |> json(%{status: "database unavailable"})
    end
  end
end
