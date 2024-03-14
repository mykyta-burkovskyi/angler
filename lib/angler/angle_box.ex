defmodule Angler.AngleBox do
  def choose_angle(url) do
    [Angler.Angles.Tiktok, Angler.Angles.Instagram]
    |> Enum.find(fn angle -> angle.is_matching_url?(url) end)
  end
end
