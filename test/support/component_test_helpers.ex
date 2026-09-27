defmodule AnglerWeb.ComponentTestHelpers do
  @moduledoc """
  Rendering and querying function components in tests of the dashboard components
  (`AnglerWeb.CommonComponents`, `AnglerWeb.EntryComponents`, ...).
  """

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Angler.Entries.Entry

  @doc "Renders a function component with `assigns`, parsed for querying."
  def render_html(component, assigns) do
    component |> render_component(assigns) |> LazyHTML.from_fragment()
  end

  @doc "The text of the nodes matching `selector`, with whitespace collapsed."
  def text(html, selector) do
    html
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc "Whether any node matches `selector`."
  def exists?(html, selector), do: html |> LazyHTML.query(selector) |> Enum.count() > 0

  @doc "The attribute `name` of the first node matching `selector`."
  def attribute(html, selector, name) do
    html |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  @doc "A queued entry that is never saved, with `attrs` set."
  def entry(attrs \\ %{}) do
    struct!(
      %Entry{
        id: Ecto.UUID.generate(),
        status: :queued,
        url: "https://www.tiktok.com/@user/video/1",
        source_host: "tiktok.com",
        chat_id: -1001,
        chat_type: "supergroup",
        chat_title: "Video club",
        message_id: 7,
        from_name: "Ann",
        inserted_at: DateTime.utc_now(),
        available_at: DateTime.utc_now()
      },
      attrs
    )
  end
end
