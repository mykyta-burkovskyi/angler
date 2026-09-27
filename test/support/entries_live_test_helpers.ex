defmodule AnglerWeb.EntriesLiveTestHelpers do
  @moduledoc """
  Fixtures and queries shared by the tests of the entries list
  (`AnglerWeb.EntriesLive` and `AnglerWeb.EntriesLive.Rows`).
  """

  import Phoenix.LiveViewTest, only: [render: 1]

  alias Angler.Entries

  @doc """
  A queued TikTok entry, updated with `attrs` (all but `:url`, which is set on
  enqueue).
  """
  def entry_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, [entry]} =
      Entries.enqueue([
        %{
          url: Map.get(attrs, :url, "https://www.tiktok.com/@user/video/#{n}"),
          source_host: "tiktok.com",
          chat_id: -1_001_234,
          chat_type: "supergroup",
          chat_title: "Video club",
          message_id: n,
          from_id: 42,
          from_name: "Ann"
        }
      ])

    case Map.delete(attrs, :url) do
      attrs when attrs == %{} -> entry
      attrs -> Entries.update!(entry, attrs)
    end
  end

  @doc "The DOM ids of the rows the view lists, in order."
  def row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#entries > li")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))
  end

  @doc "The DOM id of an entry's row."
  def dom_id(entry), do: "entry-#{entry.id}"
end
