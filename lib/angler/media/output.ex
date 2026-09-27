defmodule Angler.Media.Output do
  @moduledoc """
  A video ready to be sent with `sendVideo`: MP4 (H.264/AAC when transcoded) that
  fits the upload limit, plus metadata Telegram needs to render it properly.

    * `:path` - absolute path of the MP4 file
    * `:size` - bytes on disk (always <= the requested target)
    * `:thumbnail_path` - JPEG thumbnail (<= 320px, < 200 kB) or nil
    * `:duration` - whole seconds
    * `:width`, `:height` - display dimensions (rotation applied)
    * `:video_codec` - codec of the output video stream, e.g. "h264"
    * `:transcoded` - whether ffmpeg re-encoded the video
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
    transcoded: false
  ]

  @type t :: %__MODULE__{}
end
