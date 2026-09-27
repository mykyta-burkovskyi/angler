defmodule Angler.Repo.Migrations.AddMediaKindToEntries do
  use Ecto.Migration

  def change do
    alter table(:entries) do
      # "video" or "slideshow" (a TikTok photo post assembled into a video), see
      # Angler.Entries.Entry; nil until the download finished.
      add :media_kind, :string
    end
  end
end
