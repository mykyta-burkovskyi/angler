defmodule Angler.Repo.Migrations.ForgetInstagramFileIds do
  use Ecto.Migration

  # Instagram carousels delivered before albums were supported were sent as their
  # first video only: forget those Telegram files so the next post of such a link
  # is downloaded again (and sent completely) instead of re-sending that video.
  # Reels are downloaded once more too, which is harmless.
  def up do
    execute """
    UPDATE entries
    SET telegram_file_id = NULL, telegram_file_unique_id = NULL
    WHERE telegram_file_id IS NOT NULL
      AND (media_kind IS NULL OR media_kind = 'video')
      AND (source_host LIKE '%instagram.com' OR source_host LIKE '%instagr.am')
    """
  end

  # The forgotten file ids can't be restored (and aren't needed).
  def down, do: :ok
end
