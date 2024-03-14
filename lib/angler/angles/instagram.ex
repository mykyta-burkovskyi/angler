defmodule Angler.Angles.Instagram do
  @behaviour Angler.Angles.Angle

  def is_matching_url?(url) do
    is_instagram_host = url |> Map.get(:host) |> String.contains?("instagram.com")

    path = url |> Map.get(:path)

    has_valid_path =
      Regex.match?(~r/^\/p\/([a-zA-Z0-9_-]+)\/?/, path) or
        Regex.match?(~r/^\/reels?\/([a-zA-Z0-9_-]+)\/?/, path)

    is_instagram_host and has_valid_path
  end

  def fish_out(url) do
    url
    |> get_video_id
    |> get_video_url
  end

  defp get_video_id(url) do
    url |> Map.get(:path) |> String.split("/", trim: true) |> List.last()
  end

  defp get_video_url(video_id) do
    headers =
      Application.fetch_env!(:angler, :instagram_api_headers) |> Jason.decode!() |> Map.to_list()

    raw_body =
      Application.fetch_env!(:angler, :instagram_api_body_template)
      |> Jason.decode!()

    body =
      %{
        raw_body
        | "variables" => Map.put(raw_body["variables"], "shortcode", video_id) |> Jason.encode!()
      }
      |> URI.encode_query()

    result =
      Finch.build(
        :post,
        Application.fetch_env!(:angler, :instagram_api_url),
        headers,
        body
      )
      |> Finch.request!(Angler.Finch)

    video_url =
      result.body
      |> Jason.decode!()
      |> Map.get("data")
      |> Map.get("xdt_shortcode_media")
      |> Map.get("video_url")

    [video_url]
  end
end
