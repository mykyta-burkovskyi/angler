defmodule Angler.Media.YtdlpTest do
  use ExUnit.Case, async: true

  alias Angler.Media.{Error, Ytdlp}
  alias Angler.Media.Ytdlp.{Outcome, Progress}

  @dir "/data/media/0b0f6a6e-1d7e-4f0e-9d0f-6b1f4d8a2c11"
  @url "https://www.youtube.com/watch?v=jNQXAC9IVRw"

  defp value_after(args, flag) do
    args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)
  end

  defp values_after(args, flag) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(&(hd(&1) == flag))
    |> Enum.map(&List.last/1)
  end

  describe "args/3" do
    setup do
      opts = [
        target_bytes: 50_000_000,
        max_source_bytes: 1_024_000_000,
        max_duration: 1_800,
        cache_dir: "/data/cache"
      ]

      %{args: Ytdlp.args(@url, @dir, opts)}
    end

    test "passes the URL last, after --", %{args: args} do
      assert Enum.take(args, -2) == ["--", @url]
    end

    test "keeps option-like URLs after --" do
      args = Ytdlp.args("--exec=touch /tmp/pwned", @dir, [])
      assert Enum.take(args, -2) == ["--", "--exec=touch /tmp/pwned"]
      assert Enum.count(args, &(&1 == "--")) == 1
    end

    test "renders the limits as plain numbers", %{args: args} do
      assert value_after(args, "--max-filesize") == "1024000000"
      assert value_after(args, "--match-filters") == "!is_live & duration<?1800"

      assert value_after(args, "-f") ==
               "bv*[filesize<44000000]+ba/bv*[filesize_approx<44000000]+ba/" <>
                 "b[filesize<47500000]/b[filesize_approx<47500000]/bv*+ba/b"
    end

    test "prefers H.264/AAC MP4 up to 1080p", %{args: args} do
      assert value_after(args, "-S") ==
               "vcodec:h264,hdr:sdr,res:1080,fps:30,acodec:aac,ext:mp4:m4a,proto:https"

      assert value_after(args, "--merge-output-format") == "mp4/mkv"
    end

    test "writes into the entry directory", %{args: args} do
      assert values_after(args, "-P") == ["home:" <> @dir, "temp:" <> @dir <> "/tmp"]
      assert value_after(args, "-o") == "source.%(ext)s"
      assert value_after(args, "--cache-dir") == "/data/cache/yt-dlp"
    end

    test "prints metadata, progress and the result path", %{args: args} do
      assert "--no-quiet" in args
      assert "--ignore-config" in args
      assert ["1"] == values_after(args, "--max-downloads")

      assert values_after(args, "--print") == [
               "pre_process:[meta] %(.{is_live,duration})j",
               "after_move:[result] %(filepath)j"
             ]

      assert [download, postprocess] = values_after(args, "--progress-template")
      assert download =~ "download:[progress] %(progress.status)s"
      assert postprocess =~ "postprocess:[postprocess]"
      assert value_after(args, "--print-to-file") =~ "after_move:%(.{id,title,"

      assert args |> Enum.drop_while(&(&1 != "--print-to-file")) |> Enum.at(2) ==
               @dir <> "/info.jsonl"
    end

    test "escapes % in the info file path" do
      args = Ytdlp.args(@url, "/data/100%", [])

      assert args |> Enum.drop_while(&(&1 != "--print-to-file")) |> Enum.at(2) ==
               "/data/100%%/info.jsonl"
    end

    test "passes the per-run cookies copy only when there is one" do
      refute "--cookies" in Ytdlp.args(@url, @dir, [])

      assert value_after(Ytdlp.args(@url, @dir, cookies: @dir <> "/cookies.txt"), "--cookies") ==
               @dir <> "/cookies.txt"
    end

    test "points yt-dlp to the configured ffmpeg" do
      args = Ytdlp.args(@url, @dir, ffmpeg: "/opt/ffmpeg/bin/ffmpeg")
      assert value_after(args, "--ffmpeg-location") == "/opt/ffmpeg/bin/ffmpeg"
    end

    test "omits limits that are not given" do
      args = Ytdlp.args(@url, @dir, [])
      refute "--max-filesize" in args
      refute "--cache-dir" in args
      refute "--ffmpeg-location" in args
      assert value_after(args, "--match-filters") == "!is_live"
      assert value_after(args, "-f") == "bv*+ba/b"
    end
  end

  describe "parse_line/1" do
    test "parses progress lines" do
      assert Progress.parse_line("[progress] downloading 3072 433081 1766506.9766931725 0") ==
               {:progress,
                %{
                  status: "downloading",
                  downloaded: 3072,
                  total: 433_081,
                  speed: 1_766_506.9766931725,
                  eta: 0
                }}

      assert Progress.parse_line("[progress] downloading 1024 NA NA NA") ==
               {:progress,
                %{status: "downloading", downloaded: 1024, total: nil, speed: nil, eta: nil}}

      assert Progress.parse_line("[progress] downloading 1 2") == :other
    end

    test "parses postprocessor, metadata and result lines" do
      assert Progress.parse_line("[postprocess] started Merger") ==
               {:postprocess, "started", "Merger"}

      assert Progress.parse_line(~s([meta] {"is_live": false, "duration": 19})) ==
               {:meta, %{"is_live" => false, "duration" => 19}}

      assert Progress.parse_line(~s([result] "/data/x/source.mp4")) ==
               {:result, "/data/x/source.mp4"}

      assert Progress.parse_line(~s([result] "/data/\\"quoted\\" \\u00e9.mp4")) ==
               {:result, ~s(/data/"quoted" é.mp4)}
    end

    test "ignores everything else" do
      for line <- [
            "[youtube] abc: Downloading webpage",
            "[result] NA",
            "[meta] nope",
            "",
            "ERROR: x"
          ] do
        assert Progress.parse_line(line) == :other
      end
    end
  end

  describe "progress_update/1" do
    test "reports percent, sizes, speed and time left" do
      progress = %{
        status: "downloading",
        downloaded: 12_300_000,
        total: 45_000_000,
        speed: 2_100_000.0,
        eta: 12
      }

      assert Progress.progress_update(progress) == %{
               percent: 12_300_000 / 45_000_000 * 100,
               detail: "12.3 MB of 45.0 MB · 2.1 MB/s · 0:12 left"
             }
    end

    test "works without a total, speed or time left" do
      assert Progress.progress_update(%{
               status: "downloading",
               downloaded: 532_000,
               total: nil,
               speed: nil,
               eta: nil
             }) ==
               %{percent: nil, detail: "532 kB"}
    end

    test "formats long waits and finished downloads" do
      assert %{detail: "1.5 GB of 2.0 GB · 900 B/s · 1:02:03 left"} =
               Progress.progress_update(%{
                 status: "downloading",
                 downloaded: 1_500_000_000,
                 total: 2_000_000_000,
                 speed: 900,
                 eta: 3723
               })

      assert Progress.progress_update(%{
               status: "finished",
               downloaded: 433_081,
               total: 433_081,
               speed: 132_155.5,
               eta: nil
             }) ==
               %{percent: 100.0, detail: "433 kB of 433 kB · 132 kB/s"}
    end
  end

  describe "interpret/3" do
    @result ~s([result] "/data/x/source.mp4")

    test "succeeds with a result line on exit status 0 or 101" do
      lines = ["[postprocess] finished MoveFiles", @result]
      assert Outcome.interpret(0, lines) == {:ok, "/data/x/source.mp4"}

      assert Outcome.interpret(101, lines ++ ["[info] Maximum number of downloads reached"]) ==
               {:ok, "/data/x/source.mp4"}
    end

    test "rejects videos that are too long" do
      lines = [
        ~s([meta] {"is_live": false, "duration": 19}),
        "[download] Me at the zoo does not pass filter (!is_live & duration<?60), skipping .."
      ]

      assert {:error, %Error{kind: :too_large, message: "Video is longer than 1 minute"}} =
               Outcome.interpret(0, lines)

      lines = [
        "[download] Me at the zoo does not pass filter (!is_live & duration<?1800), skipping .."
      ]

      assert {:error, %Error{message: "Video is longer than 30 minutes"}} =
               Outcome.interpret(0, lines)

      lines = [
        "[download] Me at the zoo does not pass filter (!is_live & duration<?90), skipping .."
      ]

      assert {:error, %Error{message: "Video is longer than 90 seconds"}} =
               Outcome.interpret(0, lines)
    end

    test "rejects live streams" do
      lines = [
        ~s([meta] {"is_live": true}),
        "[download] Live now does not pass filter (!is_live & duration<?1800), skipping .."
      ]

      assert {:error, %Error{kind: :unsupported, message: "Live streams are not supported"}} =
               Outcome.interpret(0, lines)
    end

    test "rejects sources larger than --max-filesize" do
      lines = [
        "[download] File is larger than max-filesize (629172 bytes > 102400 bytes). Aborting.",
        "[info] Maximum number of downloads reached, stopping due to --max-downloads"
      ]

      assert {:error, %Error{kind: :too_large, message: "Source file is larger than 0.1 MB"}} =
               Outcome.interpret(101, lines)
    end

    test "treats a download that gave up on network errors as transient, even with status 101" do
      # --max-downloads still ends the run with 101 after the only download failed.
      lines = [
        "[info] 7449708266168274208: Downloading 1 format(s): h264_540p_552380-1",
        "[download] Got error: ('Unable to connect to proxy', OSError('Tunnel connection " <>
          "failed: 502 Bad Gateway')). Retrying (5/5)...",
        "ERROR: \r[download] Got error: ('Unable to connect to proxy', OSError('Tunnel " <>
          "connection failed: 502 Bad Gateway')). Giving up after 5 retries",
        "[info] Maximum number of downloads reached, stopping due to --max-downloads",
        "Aborting remaining downloads"
      ]

      assert {:error, %Error{kind: :transient, message: message}} = Outcome.interpret(101, lines)
      assert message =~ "Tunnel connection failed"
    end

    test "reports a skip without a reason as no video" do
      assert {:error, %Error{kind: :unsupported, message: "No video found at this link"}} =
               Outcome.interpret(0, ["WARNING: [Instagram] abc: No video formats found!"])

      assert {:error, %Error{kind: :unsupported}} = Outcome.interpret(0, [])
    end

    test "classifies ERROR lines and keeps the output" do
      lines = [
        "[generic] Extracting URL: https://example.com/",
        "WARNING: [generic] Falling back on generic information extractor",
        "ERROR: Unsupported URL: https://example.com/"
      ]

      assert {:error,
              %Error{
                kind: :unsupported,
                message: "Unsupported URL: https://example.com/",
                output: output
              }} =
               Outcome.interpret(1, lines)

      assert output == Enum.join(lines, "\n")
    end

    test "takes the reason from warnings when the error is the generic no formats" do
      # Real output for a removed YouTube video with --ignore-no-formats-error.
      lines = [
        "[youtube] aaaaaaaaaaa: Downloading webpage",
        "WARNING: [youtube] No supported JavaScript runtime could be found. Only deno is enabled by default",
        "WARNING: [youtube] This video is unavailable",
        "WARNING: No video formats found!",
        "WARNING: Requested format is not available",
        "ERROR: [youtube] aaaaaaaaaaa: No video formats found!"
      ]

      assert {:error, %Error{kind: :unavailable, message: "[youtube] This video is unavailable"}} =
               Outcome.interpret(1, lines)

      assert {:error, %Error{kind: :unsupported, message: "No video found at this link"}} =
               Outcome.interpret(1, ["ERROR: [Instagram] abc: No video formats found!"])
    end

    test "prefers a specific error over others" do
      lines = ["ERROR: 'url'", "ERROR: [Instagram] abc: HTTP Error 429: Too Many Requests"]

      assert {:error,
              %Error{
                kind: :transient,
                message: "[Instagram] abc: HTTP Error 429: Too Many Requests"
              }} = Outcome.interpret(1, lines)
    end

    test "reports broken extractors as internal, without the boilerplate" do
      lines = [
        "ERROR: [TikTok] 123: Unable to extract webpage video data; please report this issue on  https://github.com/yt-dlp/yt-dlp/issues?q= , filling out the appropriate issue template. Confirm you are on the latest version using  yt-dlp -U"
      ]

      assert {:error,
              %Error{
                kind: :internal,
                message: "[TikTok] 123: Unable to extract webpage video data"
              }} =
               Outcome.interpret(1, lines)
    end

    test "reports failures without ERROR lines with the exit status" do
      lines = ["Usage: yt-dlp [OPTIONS] URL [URL...]", "yt-dlp: error: no such option: --bogus"]

      assert {:error,
              %Error{
                kind: :internal,
                message: "yt-dlp exited with status 2: yt-dlp: error: no such option: --bogus"
              }} =
               Outcome.interpret(2, lines)

      assert {:error, %Error{kind: :internal, message: "yt-dlp exited with status 1"}} =
               Outcome.interpret(1, [])
    end
  end

  describe "classify/1" do
    for {message, kind} <- [
          # Real yt-dlp messages (without the "ERROR: " prefix)
          {"[youtube] aaaaaaaaaaa: This video is unavailable", :unavailable},
          {"[generic] nothing: Unable to download webpage: HTTP Error 404: Not Found (caused by <HTTPError 404: Not Found>)",
           :unavailable},
          {"[TikTok] 6748451240264420610: Your IP address is blocked from accessing this post",
           :unavailable},
          {"[Instagram] abc: The webpage request was redirected to the login page. You have exceeded the rate-limit for accessing posts anonymously",
           :transient},
          {"Unsupported URL: https://example.com/", :unsupported},
          {"[twitter:amplify] 123: HTTP Error 500: Domain Not Found", :transient},
          # Messages defined in the extractors
          {"[youtube] abc: Private video. Sign in if you've been granted access to this video",
           :unavailable},
          {"[youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.",
           :unavailable},
          {"[youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication.",
           :unavailable},
          {"[Instagram] abc: This content is only available for registered users who follow this account",
           :unavailable},
          {"[Instagram] abc: Restricted Video: You must be 18 years old or over to see this video.",
           :unavailable},
          {"[TikTok] 1: You do not have permission to view this post. Log into an account that has access",
           :unavailable},
          {"[TikTok] 1: TikTok is requiring login for access to this content", :unavailable},
          {"[youtube] abc: This video is not available from your location due to geo restriction",
           :unavailable},
          {"[youtube] abc: This video is DRM protected", :unavailable},
          {"[youtube] abc: This video has been removed for violating YouTube's Terms of Service",
           :unavailable},
          {"[youtube] abc: Video unavailable. This video contains content from X, who has blocked it on copyright grounds",
           :unavailable},
          {"[youtube] abc: Join this channel to get access to members-only content like this video",
           :unavailable},
          {"[youtube] abc: This live event will begin in 3 hours.", :unavailable},
          {"[Instagram] abc: No video formats found!", :unsupported},
          {"[twitter] 123: No video could be found in this tweet", :unsupported},
          {"[twitter] 123: Media #2 is not a video", :unsupported},
          {"[youtube] abc: Requested format is not available", :unsupported},
          {"[youtube] abc: HTTP Error 429: Too Many Requests", :transient},
          {"[generic] abc: Unable to download webpage: The read operation timed out", :transient},
          {"[generic] abc: Unable to download webpage: <urlopen error [Errno -3] Temporary failure in name resolution>",
           :transient},
          {"unable to download video data: HTTP Error 403: Forbidden", :transient},
          {"[Instagram] abc: Unable to download JSON metadata: HTTP Error 503: Service Unavailable",
           :transient},
          {"('Connection aborted.', RemoteDisconnected('Remote end closed connection without response'))",
           :transient},
          {"[download] Got error: [Errno 54] Connection reset by peer", :transient},
          {"[TikTok] 1: Unable to extract webpage video data; please report this issue on  https://github.com/yt-dlp/yt-dlp/issues",
           :internal},
          {"'url'", :internal},
          {"Postprocessing: Conversion failed!", :internal}
        ] do
      test "#{inspect(kind)}: #{message}" do
        assert Outcome.classify(unquote(message)) == unquote(kind)
      end
    end

    test "does not mistake words containing 'age' for age restrictions" do
      assert Outcome.classify("[generic] abc: Unable to extract page data") == :internal

      assert Outcome.classify(
               "[generic] abc: Unable to download webpage: HTTP Error 502: Bad Gateway"
             ) == :transient
    end
  end

  test "clean_message/1 strips the report boilerplate" do
    assert Outcome.clean_message(
             "[x] 1: Broken; please report this issue on  https://github.com/yt-dlp/yt-dlp/issues?q= , filling out"
           ) ==
             "[x] 1: Broken"

    assert Outcome.clean_message("[x] 1: Fine ") == "[x] 1: Fine"
  end
end
