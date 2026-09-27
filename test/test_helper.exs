# Tests tagged :external shell out to ffmpeg/ffprobe/yt-dlp and only run when those
# tools exist. Tests tagged :network reach the internet; run them with
# `mix test --include network`.
external_tools? = Enum.all?(~w(ffmpeg ffprobe), &System.find_executable/1)

exclude = [:network] ++ if(external_tools?, do: [], else: [:external])

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(Angler.Repo, :manual)
