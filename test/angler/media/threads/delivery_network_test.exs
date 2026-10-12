defmodule Angler.Media.Threads.DeliveryNetworkTest do
  # Live Threads posts through Angler.Media.download/3 and prepare/3 (real Threads,
  # Instagram's CDN, ffmpeg and ffprobe). Excluded by default; run with:
  #
  #   mix test test/angler/media/threads/delivery_network_test.exs --include network --include external
  #
  # Not async: talks to Threads and the CDN without the Req.Test stubs of the test
  # configuration.
  use ExUnit.Case, async: false

  alias Angler.Media
  alias Angler.Media.{Download, Instagram, Output, Probe, Threads}

  @moduletag :external
  @moduletag :network
  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag timeout: :timer.minutes(10)

  @target 50_000_000

  setup do
    for module <- [Threads, Instagram] do
      original = Application.get_env(:angler, module)
      on_exit(fn -> Application.put_env(:angler, module, original) end)
      Application.put_env(:angler, module, [])
    end

    :ok
  end

  # Downloads and prepares `url` like the pipeline does, retrying transient
  # failures a few times (only the last attempt may leave out refused files).
  defp deliver(url, dir, attempts \\ 3) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    opts = [
      target_bytes: @target,
      max_source_bytes: 1_024_000_000,
      max_duration: 1_800,
      final_attempt: attempts == 1
    ]

    with {:ok, download} <- Media.download(url, dir, opts),
         {:ok, output} <- Media.prepare(download, dir, target_bytes: @target) do
      {download, output}
    else
      {:error, %Media.Error{kind: :transient}} when attempts > 1 ->
        deliver(url, dir, attempts - 1)

      {:error, error} ->
        flunk("#{url}: #{inspect(error)}")
    end
  end

  defp assert_telegram_video(%Output{} = output, audio?) do
    assert %Output{video_codec: "h264"} = output
    assert output.size <= @target
    assert {:ok, probe} = Probe.run(output.path)

    assert %Probe{video_codec: "h264", faststart?: true, has_audio?: ^audio?} = probe
    assert {probe.width, probe.height} == {output.width, output.height}
    assert File.exists?(output.thumbnail_path)
    probe
  end

  test "a photo post with music becomes a slideshow video", %{tmp_dir: tmp_dir} do
    {download, output} = deliver("https://www.threads.com/@nasa/post/DePPcDfkc_a", tmp_dir)

    assert %Download{kind: :slideshow, extractor: "Threads", images: [_photo]} = download
    assert Path.basename(download.audio_path) == "clip.flac"
    # The post's 30 s clip of the song.
    assert_in_delta download.duration, 30.0, 0.5

    probe = assert_telegram_video(output, true)
    assert_in_delta probe.duration, 30.0, 0.5
  end

  test "a video post", %{tmp_dir: tmp_dir} do
    {download, output} = deliver("https://www.threads.com/@nasa/post/DeMqtuYgkaL", tmp_dir)

    assert %Download{kind: :video, extractor: "Threads"} = download
    assert download.title =~ "Artemis II"

    probe = assert_telegram_video(output, true)
    assert_in_delta probe.duration, 89.4, 1.0
  end

  test "a carousel of photos and videos", %{tmp_dir: tmp_dir} do
    {download, output} = deliver("https://www.threads.com/@zuck/post/Ddt7cL5EfUG", tmp_dir)

    assert %Download{kind: :album, extractor: "Threads", items: items} = download
    assert length(items) == 9

    assert %Output{kind: :album, items: prepared} = output

    assert Enum.map(prepared, & &1.type) ==
             ~w(photo photo photo photo photo video photo photo video)a

    assert Enum.all?(prepared, &(&1.size <= @target))
  end
end
