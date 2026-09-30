defmodule Angler.Media.Download do
  @moduledoc """
  The result of downloading a link with yt-dlp, the images and sound of a
  slideshow (`Angler.Media.Slideshow`), or the photos and videos of an Instagram
  post (an album).

    * `:path` - absolute path of the downloaded media file
    * `:size` - bytes on disk
    * `:title`, `:extractor`, `:webpage_url` - from yt-dlp metadata (may be nil)
    * `:duration` - seconds (float) if known
    * `:width`, `:height`, `:video_codec`, `:audio_codec` - from yt-dlp metadata if known
    * `:kind` - `:video | :slideshow | :album`:
      * `:video` - a single media file at `:path`
      * `:slideshow` - photos with a sound: a TikTok photo post (`:path` is
        `slides/`), or an Instagram photo post with music (`:path` is `album/`,
        images at `album/NN/source.jpg`, the sound in `album/sound/`: the post's
        clip cut to `clip.flac`, or the downloaded song, `audio.m4a` or
        `audio.mp3`, when the clip is the whole song). `:path` is the directory
        holding `:images` (paths, in display order) and `:audio_path` (the sound or
        nil), `:duration` is the length of the sound that plays and
        `:max_duration` the longest video to assemble (seconds, the download's
        `:max_duration` option, or nil)
      * `:album` - the photos and videos of a post, sent as they are; `:path` is the
        `album` directory, `:size` the bytes of all items, `:title` the post text,
        `:items` the items in display order and `:max_duration` the longest video
        allowed (seconds or nil)
    * `:items` - album items, each `%{type: :photo | :video, path: path, size: bytes,
      width: w, height: h, duration: seconds}` (`path` is the item's source file,
      `<dir>/album/NN/source.<ext>`; dimensions and duration may be nil)
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
    images: [],
    items: []
  ]

  @typedoc "An item of an album download, see the module documentation."
  @type item :: %{
          type: :photo | :video,
          path: Path.t(),
          size: non_neg_integer(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          duration: number() | nil
        }

  @type t :: %__MODULE__{}
end
