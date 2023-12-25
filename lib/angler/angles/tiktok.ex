defmodule Angler.Angles.Tiktok do
  def fish_out(url) do
    url |> process_redirect |> get_video_id |> get_video_details |> get_video_url
  end

  defp process_redirect(url) do
    Tesla.client([Tesla.Middleware.FollowRedirects]) |> Tesla.get!(url) |> Map.fetch!(:url)
  end

  defp get_video_id(url) do
    url |> URI.parse() |> Map.get(:path) |> String.split("/") |> List.last()
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

  defp get_video_url(
         {video_id,
          %{
            "aweme_list" => [
              %{
                "aweme_id" => aweme_id,
                "video" => %{"download_addr" => %{"url_list" => [video_url | _]}}
              }
              | _
            ]
          }}
       )
       when aweme_id == video_id do
    video_url
  end
end
