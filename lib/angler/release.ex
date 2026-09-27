defmodule Angler.Release do
  @moduledoc """
  Database tasks for the production release, where Mix is not available.

  Pending migrations also run automatically every time the release boots (see
  `Angler.Application`), so these are only needed by hand:

      docker compose exec app bin/migrate
      docker compose exec app bin/angler eval "Angler.Release.rollback(Angler.Repo, 20260926123605)"
  """
  @app :angler

  @doc "Runs all pending migrations of every repo. Returns the versions applied per repo."
  @spec migrate() :: [{:ok, [non_neg_integer()], [atom()]}]
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Reverts the migrations of `repo` down to and including `version`, e.g. before
  going back to an older image.
  """
  @spec rollback(module(), non_neg_integer()) :: {:ok, [non_neg_integer()], [atom()]}
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
