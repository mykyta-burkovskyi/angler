defmodule Angler.Media.Download do
  @moduledoc """
  The result of downloading a link with yt-dlp, or the images and sound of a
  TikTok slideshow (`Angler.Media.Slideshow`).

    * `:path` - absolute path of the downloaded media file
    * `:size` - bytes on disk
    * `:title`, `:extractor`, `:webpage_url` - from yt-dlp metadata (may be nil)
    * `:duration` - seconds (float) if known
    * `:width`, `:height`, `:video_codec`, `:audio_codec` - from yt-dlp metadata if known
    * `:kind` - `:video`, or `:slideshow` for a TikTok photo post; then `:path` is the
      directory holding `:images` (paths, in display order) and `:audio_path` (the
      sound or nil), `:duration` is the sound's and `:max_duration` the longest
      video to assemble (seconds, the download's `:max_duration` option, or nil)
  """
  @enforce_keys [:path, :size]
  defstruct [
    :path,
    :size,
    :title,
    :extractor,
    :webpage_url,
    :duration,
    :width,
    :height,
    :video_codec,
    :audio_codec,
    :audio_path,
    :max_duration,
    kind: :video,
    images: []
  ]

  @type t :: %__MODULE__{}
end
