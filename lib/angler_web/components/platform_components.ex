defmodule AnglerWeb.PlatformComponents do
  @moduledoc """
  The platforms the dashboard recognizes by host: their names, and the colored
  monogram tile that stands in for a missing thumbnail.

  All components are styled with the design tokens from `assets/css/app.css`.
  """
  use Phoenix.Component

  import AnglerWeb.CoreComponents, only: [icon: 1]

  # {domains, name, monogram, tile classes}
  @platforms [
    {~w(tiktok.com), "TikTok", "TT", "bg-zinc-900 text-white dark:bg-zinc-700"},
    {~w(instagram.com instagr.am), "Instagram", "IG",
     "bg-linear-to-br from-amber-400 via-pink-500 to-purple-600 text-white"},
    {~w(youtube.com youtu.be), "YouTube", "YT", "bg-red-600 text-white"},
    {~w(x.com twitter.com), "X", "X", "bg-zinc-900 text-white dark:bg-zinc-700"},
    {~w(reddit.com redd.it), "Reddit", "R", "bg-orange-500 text-white"},
    {~w(facebook.com fb.watch), "Facebook", "f", "bg-blue-600 text-white"},
    {~w(vimeo.com), "Vimeo", "V", "bg-sky-500 text-white"},
    {~w(twitch.tv), "Twitch", "Tw", "bg-violet-600 text-white"},
    {~w(threads.net threads.com), "Threads", "@", "bg-zinc-900 text-white dark:bg-zinc-700"},
    {~w(bsky.app), "Bluesky", "B", "bg-sky-600 text-white"},
    {~w(pinterest.com pin.it), "Pinterest", "P", "bg-red-700 text-white"},
    {~w(streamable.com), "Streamable", "S", "bg-blue-500 text-white"},
    {~w(dailymotion.com), "Dailymotion", "D", "bg-slate-800 text-white dark:bg-slate-600"},
    {~w(snapchat.com), "Snapchat", "S", "bg-yellow-300 text-zinc-900"}
  ]

  @doc "The platform name of a host (\"TikTok\"), or nil for unknown hosts."
  @spec platform_name(String.t() | nil) :: String.t() | nil
  def platform_name(host) do
    case platform(host) do
      {name, _monogram, _classes} -> name
      nil -> nil
    end
  end

  defp platform(nil), do: nil

  defp platform(host) do
    Enum.find_value(@platforms, fn {domains, name, monogram, classes} ->
      if Enum.any?(domains, &(host == &1 or String.ends_with?(host, "." <> &1))),
        do: {name, monogram, classes}
    end)
  end

  @doc """
  Renders a tile for a platform: a colored monogram for known hosts and a film
  icon otherwise. Fills its container.
  """
  attr :host, :string, default: nil
  attr :class, :any, default: nil

  def platform_tile(assigns) do
    assigns = assign(assigns, :platform, platform(assigns.host))

    ~H"""
    <div
      :if={@platform}
      title={elem(@platform, 0)}
      class={[
        "flex size-full items-center justify-center text-sm font-bold tracking-tight select-none",
        elem(@platform, 2),
        @class
      ]}
    >
      {elem(@platform, 1)}
    </div>
    <div
      :if={!@platform}
      class={["flex size-full items-center justify-center bg-subtle text-ink-faint", @class]}
    >
      <.icon name="hero-film" class="size-5" />
    </div>
    """
  end
end
