defmodule Angler.Angles.Tiktok do
  @behaviour Angler.Angles.Angle

  def is_matching_url?(url) do
    url |> Map.get(:host) |> String.contains?("tiktok.com")
  end

  def fish_out(url) do
    url
    |> process_redirect
    |> get_video_id
    |> get_video_details
    |> get_video_urls
  end

  defp process_redirect(url) do
    IO.inspect(url |> URI.to_string(), label: "URL")

    Tesla.client([Tesla.Middleware.FollowRedirects])
    |> Tesla.get!(url |> URI.to_string())
    |> Map.fetch!(:url)
    |> URI.parse()
  end

  defp get_video_id(url) do
    url |> Map.get(:path) |> String.split("/", trim: true) |> List.last()
  end

  defp get_video_details(video_id) do
    details =
      Tesla.client([
        {Tesla.Middleware.Headers,
         [{"User-Agent", Application.fetch_env!(:angler, :tiktok_user_agent)}]},
        Tesla.Middleware.DecodeJson
      ])
      |> Tesla.get!("#{Application.fetch_env!(:angler, :tiktok_feed_url)}?aweme_id=#{video_id}")
      |> Map.fetch!(:body)

    {video_id, details}
  end

  defp get_video_urls(
         {video_id,
          %{
            "aweme_list" => [
              %{
                "aweme_id" => aweme_id,
                "video" => %{
                  "download_addr" => %{"url_list" => download_urls},
                  "play_addr" => %{"url_list" => play_urls}
                }
              }
              | _
            ]
          }}
       )
       when aweme_id == video_id do
    download_urls ++ play_urls
  end
end
