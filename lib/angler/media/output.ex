defmodule Angler.Media.Output do
  @moduledoc """
  Media ready to be sent to Telegram, plus the metadata Telegram needs to render
  it properly.

  For `kind: :video`, a video for `sendVideo`: MP4 (H.264/AAC when transcoded) that
  fits the upload limit.

    * `:path` - absolute path of the MP4 file
    * `:size` - bytes on disk (always <= the requested target)
    * `:thumbnail_path` - JPEG thumbnail (<= 320px, < 200 kB) or nil
    * `:duration` - whole seconds
    * `:width`, `:height` - display dimensions (rotation applied)
    * `:video_codec` - codec of the output video stream, e.g. "h264"
    * `:transcoded` - whether ffmpeg re-encoded the video

  For `kind: :album`, the photos and videos of a post, each file within the
  upload limit (see `Angler.Storage.Album` for the layout):

    * `:path` - the `<dir>/album` directory
    * `:size` - bytes of all final item files
    * `:thumbnail_path` - cover thumbnail (`Angler.Storage.output_paths/1`) or nil
    * `:width`, `:height` - of the first item
    * `:duration`, `:video_codec` - nil
    * `:transcoded` - whether any video was re-encoded
    * `:items` - in display order, see `t:item/0`: `:path` is `photo.<jpg|png|webp>`
      or `video.mp4` in the item's directory `<dir>/album/NN/`, `:thumbnail_path`
      a video's `thumbnail.jpg` there (nil for photos), `:duration` a video's
      seconds (a number, or nil) and `:video_codec`/`:transcoded` as above (nil and
      false for photos)
  """
  @enforce_keys [:path, :size]
  defstruct [
    :path,
    :size,
    :thumbnail_path,
    :duration,
    :width,
    :height,
    :video_codec,
    kind: :video,
    transcoded: false,
    items: []
  ]

  @typedoc "An item of an album, see the module documentation."
  @type item :: %{
          type: :photo | :video,
          path: Path.t(),
          size: non_neg_integer(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          duration: number() | nil,
          thumbnail_path: Path.t() | nil,
          video_codec: String.t() | nil,
          transcoded: boolean()
        }

  @type t :: %__MODULE__{}
end
