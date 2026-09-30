defmodule Angler.Repo.Migrations.ForgetInstagramFileIdsTest do
  use Angler.DataCase, async: true

  alias Angler.Entries
  alias Angler.Entries.Entry

  @migration Path.expand(
               "../../../priv/repo/migrations/20260929203614_forget_instagram_file_ids.exs",
               __DIR__
             )
  @module Angler.Repo.Migrations.ForgetInstagramFileIds

  test "forgets the Telegram files of Instagram posts delivered as a video" do
    forgotten = [
      delivered("https://www.instagram.com/p/A/", "instagram.com", :video),
      delivered("https://www.instagram.com/reel/B/", "instagram.com", nil),
      delivered("https://m.instagram.com/p/C/", "m.instagram.com", :video),
      delivered("https://instagr.am/p/D/", "instagr.am", :video)
    ]

    kept = [
      delivered("https://www.instagram.com/p/E/", "instagram.com", :album),
      delivered("https://www.tiktok.com/@a/video/1", "tiktok.com", :video),
      delivered("https://www.tiktok.com/@a/photo/2", "tiktok.com", :slideshow),
      delivered("https://notinstagram.com.example/v/3", "notinstagram.com.example", :video)
    ]

    migrate()

    for entry <- forgotten do
      assert %Entry{telegram_file_id: nil, telegram_file_unique_id: nil, status: :done} =
               Entries.get(entry.id)
    end

    for entry <- kept do
      assert %Entry{telegram_file_id: "FILE", telegram_file_unique_id: "UNIQUE"} =
               Entries.get(entry.id)
    end
  end

  # Runs the migration's `up/0` inside the test's transaction (rolled back like
  # everything else), under a version no real migration has. The migrator's table
  # lock would hold the sandbox connection that the migration itself needs.
  defp migrate do
    unless Code.ensure_loaded?(@module), do: Code.compile_file(@migration)

    assert :ok =
             Ecto.Migrator.up(Repo, 99_999_999_999_999, @module,
               log: false,
               migration_lock: false
             )
  end

  defp delivered(url, host, kind) do
    n = System.unique_integer([:positive])

    {:ok, [entry]} =
      Entries.enqueue([
        %{url: url, source_host: host, chat_id: 1, chat_type: "private", message_id: n}
      ])

    Entries.update!(entry, %{
      status: :done,
      media_kind: kind,
      telegram_file_id: "FILE",
      telegram_file_unique_id: "UNIQUE"
    })
  end
end
