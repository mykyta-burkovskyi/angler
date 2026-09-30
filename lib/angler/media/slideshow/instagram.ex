defmodule Angler.Media.Slideshow.Instagram do
  @moduledoc """
  An Instagram photo post with music as a slideshow (`Angler.Media.Slideshow`):
  the post's photos, played with the post's clip of its song.

  `download/4`:

    1. downloads the photos like an album (`Angler.Media.Album.download/3`: into
       `<dir>/album/NN/source.jpg`, with the album's rules for refused photos and
       the size limit)
    2. downloads the song into `<dir>/album/sound/` and cuts the post's clip out of
       it (`Angler.Media.Slideshow.Sound`: `clip.flac`, see
       `Angler.Media.Slideshow.Clip`), from Instagram's CDN only
       (`Angler.Media.Instagram.Cdn`: no cookies, no redirects) and within what
       the photos left of `:max_source_bytes`
    3. returns a `%Angler.Media.Download{kind: :slideshow}` whose `:path` is the
       `album` directory, which `Angler.Media.Slideshow.prepare/3` renders into a
       video and then deletes

  When the music can't be used, the post goes out as the album it would have been
  without music, from the photos already on disk: a song over the size limit
  (or over 50 MB), and on the final attempt a song the CDN refused or could not
  deliver, that is not media or has no audio, that can't be cut, or that ffprobe
  or ffmpeg took too long on. Before the final attempt those fail with
  `:transient` (or `:timeout`), so the pipeline tries again with freshly signed
  URLs. It never degrades to a silent video: albums are never re-sent by file id,
  so the next request of the link tries again, while a silent slideshow would be
  re-sent for every later request of it. A missing ffmpeg or ffprobe, another
  ffprobe failure and a failed write are `:internal` errors, retried and then
  failed like any other.
  """
  require Logger

  alias Angler.Media.{Album, Download, Error}
  alias Angler.Media.Instagram.{Cdn, Music, Post}
  alias Angler.Media.Slideshow.Sound

  @doc """
  Downloads the photos of `post` and the clip of `music` into `<dir>/album`, see
  the module documentation: a slideshow, or the album when the music can't be
  used.

  Options as for `Angler.Media.Album.download/3`: `:max_source_bytes`,
  `:max_duration`, `:final_attempt` and `:on_progress` (`"Downloading 3/12"`,
  then `"Downloading sound"` and `"Preparing sound"`).
  """
  @spec download(Post.t(), Music.t(), Path.t(), keyword()) ::
          {:ok, Download.t()} | {:error, Error.t()}
  def download(%Post{} = post, %Music{} = music, dir, opts) do
    final? = Keyword.get(opts, :final_attempt, true)
    budget = Keyword.get(opts, :max_source_bytes)

    with {:ok, album} <- Album.download(post, dir, opts),
         sound_dir = Path.join(album.path, "sound"),
         # Sound writes into an existing directory.
         :ok <- make_dir(sound_dir) do
      %{url: music.url, duration: music.duration, window: {music.start, music.clip_duration}}
      |> Sound.download(sound_dir,
        fetch: &Cdn.fetch/3,
        budget: budget && budget - album.size,
        final_attempt: final?,
        on_progress: Keyword.get(opts, :on_progress)
      )
      |> case do
        {:ok, %{path: path} = audio} when is_binary(path) ->
          {:ok, slideshow(album, audio)}

        {:ok, _silent} ->
          as_album(album, sound_dir, post, "its music could not be used")

        {:error, %Error{kind: :too_large}} ->
          as_album(album, sound_dir, post, "its music does not fit the size limit")

        {:error, %Error{kind: kind} = error} when final? and kind in [:transient, :timeout] ->
          as_album(album, sound_dir, post, error.message)

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # Render works in the album directory and deletes it (photos, sound, canvases).
  defp slideshow(%Download{} = album, audio) do
    %Download{
      album
      | kind: :slideshow,
        items: [],
        images: Enum.map(album.items, & &1.path),
        audio_path: audio.path,
        duration: audio.duration,
        size: album.size + audio.bytes
    }
  end

  defp as_album(album, sound_dir, post, reason) do
    File.rm_rf(sound_dir)
    Logger.warning("Instagram post #{post.code}: #{reason}, sending its photos as an album")
    {:ok, album}
  end

  defp make_dir(path) do
    case File.mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Error.new(:internal, "Could not create #{path}: #{:file.format_error(reason)}")}
    end
  end
end
