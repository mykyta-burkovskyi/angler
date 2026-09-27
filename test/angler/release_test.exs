defmodule Angler.ReleaseTest do
  use Angler.DataCase, async: true

  alias Angler.Release

  @overlays Path.expand("../../rel/overlays/bin", __DIR__)

  describe "migrate/0" do
    test "applies every migration and is a no-op once the database is up to date" do
      assert [{:ok, [], _apps}] = Release.migrate()

      assert [_ | _] = migrations = Ecto.Migrator.migrations(Repo)
      assert Enum.all?(migrations, &match?({:up, _version, _name}, &1))
    end
  end

  describe "release overlay scripts" do
    for {script, command} <- [{"server", "./angler start"}, {"migrate", "Angler.Release.migrate"}] do
      test "bin/#{script} is executable and runs #{command}" do
        path = Path.join(@overlays, unquote(script))

        assert File.read!(path) =~ unquote(command)
        assert Bitwise.band(File.stat!(path).mode, 0o111) == 0o111
      end
    end
  end
end
