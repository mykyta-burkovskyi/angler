defmodule Angler.Angle do
  require Logger

  def fish_out(url) do
    Logger.info("Fishing out video from #{url}")

    id = UUID.uuid4(:hex)

    {output, 0} =
      System.cmd(
        "yt-dlp",
        ["-o", "/tmp/angler/produce/#{id}.%(ext)s", url, "--remux-video", "mp4"],
        stderr_to_stdout: true
      )

    Logger.debug("yt-dlp output: #{output}")
    Logger.info("Fished out video from #{url}")

    "/tmp/angler/produce/#{id}.mp4"
  end
end
