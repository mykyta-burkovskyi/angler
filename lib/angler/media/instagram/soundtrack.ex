defmodule Angler.Media.Instagram.Soundtrack do
  @moduledoc """
  Whether an Instagram photo post (`Angler.Media.Instagram.Post.photos?/1`) has
  music, which makes it a slideshow video instead of an album.

  Instagram shows a post's music only to logged-in visitors. So `find/2` looks it
  up only when a cookies file is configured (`Angler.Media.Cookies`), with one
  request to the logged-in media info API (`Angler.Media.Instagram.MediaInfo`,
  made only when the file holds an Instagram session), and reads the music from
  the answer (`Angler.Media.Instagram.Music`).

  Anything but usable music gives `:none`, and the post goes out as an album: no
  cookies file or no Instagram session in it, no music, muted music, a post the
  logged-in lookup did not find, and answers showing that Instagram did not
  accept the login, rate limits the account or changed its API. None of these is
  retried: that would only delay the album and ask again with the same account.
  Only a lookup that could not reach Instagram (a network error, HTTP 408 or a
  server error) is retried (`:transient`), unless this is the final attempt.

  Every outcome but music is logged (at info level or above, so the production
  log tells why a post went out as an album), naming the post and the reason,
  never cookies, answers or URLs. Only a lookup that will be retried logs at
  debug level.
  """
  require Logger

  alias Angler.Media.{Cookies, Error}
  alias Angler.Media.Instagram.{MediaInfo, Music, Post}

  @doc """
  Looks up the music of the photo post `post`: `{:ok, music}`, `:none` (send it
  as an album), or `{:error, error}` (`:transient`) when Instagram could not be
  reached and the job is tried again.

  Option `:final_attempt` (default true): on the final attempt, a lookup that
  could not reach Instagram gives `:none` instead of an error.
  """
  @spec find(Post.t(), keyword()) :: {:ok, Music.t()} | :none | {:error, Error.t()}
  def find(%Post{code: code}, opts \\ []) do
    if Cookies.configured?() do
      code
      |> MediaInfo.fetch(Cookies.load())
      |> outcome(code, Keyword.get(opts, :final_attempt, true))
    else
      :none
    end
  end

  defp outcome({:ok, media}, code, _final?) do
    case Music.from_media(media) do
      {:ok, music} ->
        {:ok, music}

      {:none, reason} ->
        Logger.info("Instagram post #{code}: no usable music (#{reason}), sending it as an album")
        :none
    end
  end

  # Info, not debug: prod logs at :info, and the admin needs to see why photo posts
  # with music arrive as albums (e.g. the session in the file has expired).
  defp outcome({:error, :no_session}, code, _final?) do
    Logger.info(
      "Instagram post #{code}: no Instagram login in the cookies file (or it has " <>
        "expired), sending it as an album"
    )

    :none
  end

  defp outcome({:error, :missing}, code, _final?) do
    Logger.info(
      "Instagram post #{code}: the logged-in lookup did not find it, sending it as an album"
    )

    :none
  end

  defp outcome({:error, {:login_rejected, reason}}, code, _final?) do
    Logger.warning(
      "Instagram did not accept the login in the cookies file (#{reason}): photo posts " <>
        "are sent as albums until the cookies are exported again (post #{code})"
    )

    :none
  end

  defp outcome({:error, {:rate_limited, reason}}, code, _final?) do
    Logger.warning(
      "Instagram post #{code}: Instagram is rate limiting the logged-in account " <>
        "(#{reason}), sending it as an album"
    )

    :none
  end

  defp outcome({:error, {:unexpected, reason}}, code, _final?) do
    Logger.warning(
      "Instagram post #{code}: could not read its music (#{reason}), sending it as an album"
    )

    :none
  end

  defp outcome({:error, {:unreachable, reason}}, code, final?) do
    if final? do
      Logger.warning(
        "Instagram post #{code}: could not look up its music (#{reason}), sending it as an album"
      )

      :none
    else
      Logger.debug("Instagram post #{code}: could not look up its music (#{reason}), retrying")

      {:error,
       Error.new(:transient, "Could not look up the music of the Instagram post (#{reason})")}
    end
  end
end
