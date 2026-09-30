defmodule AnglerWeb.SettingsLive.FormComponents do
  @moduledoc """
  Pieces of the settings form (`AnglerWeb.SettingsLive`): its titled sections, the
  sticky save bar, and the helpers that turn setting values into field values and
  hints.
  """
  use AnglerWeb, :html

  alias AnglerWeb.Format

  @failure_reply_options [
    {"Don't reply", :none},
    {"In private chats only", :private},
    {"In all chats", :all}
  ]

  @doc "Renders a group of fields with its title and description beside it."
  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :inner_block, required: true

  def form_section(assigns) do
    ~H"""
    <section class="grid gap-x-8 gap-y-4 border-b border-line px-5 py-6 md:grid-cols-3">
      <div>
        <h2 class="text-sm font-semibold text-ink">{@title}</h2>
        <p class="mt-1 text-xs leading-relaxed text-ink-muted">{@description}</p>
      </div>
      <div class="space-y-5 md:col-span-2">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc "Renders the sticky bar at the bottom of the form: whether it's saved, and its buttons."
  attr :dirty?, :boolean, required: true, doc: "whether the form has unsaved edits"

  def save_bar(assigns) do
    ~H"""
    <div class="sticky bottom-0 z-10 -mt-px flex items-center justify-between gap-3 rounded-b-xl border-t border-line bg-surface/90 px-5 py-3 backdrop-blur">
      <p id="form-status" class="flex items-center gap-2 text-xs text-ink-muted">
        <span class={["size-2 rounded-full", if(@dirty?, do: "bg-warning", else: "bg-success")]} />
        {if @dirty?, do: "Unsaved changes", else: "All changes saved"}
      </p>
      <div class="flex gap-2">
        <.button
          :if={@dirty?}
          id="discard-changes"
          type="button"
          variant="ghost"
          phx-click="discard"
        >
          Discard
        </.button>
        <.button id="save-settings" type="submit" variant="primary" phx-disable-with="Saving…">
          Save changes
        </.button>
      </div>
    </div>
    """
  end

  @doc "The options of the failure replies select, as `{label, value}`."
  @spec failure_reply_options() :: [{String.t(), atom()}]
  def failure_reply_options, do: @failure_reply_options

  @doc "A list setting as edited in a textarea: one item per line."
  @spec list_text([String.t() | integer()] | String.t() | nil) :: String.t()
  def list_text(items) when is_list(items), do: Enum.join(items, "\n")
  def list_text(text) when is_binary(text), do: text
  def list_text(nil), do: ""

  @doc "The hint of the storage limit field for the value entered (in MB)."
  @spec storage_hint(term()) :: String.t()
  def storage_hint(value) do
    case to_integer(value) do
      mb when is_integer(mb) and mb > 0 ->
        "#{Format.bytes(mb * 1_000_000)}. When kept files exceed it, the oldest are removed first."

      _ ->
        "When kept files exceed it, the oldest are removed first."
    end
  end

  @doc "The hint of the retention field for the value entered (in hours)."
  @spec retention_hint(term()) :: String.t()
  def retention_hint(value) do
    case to_integer(value) do
      0 ->
        "Delivered media is deleted right after sending."

      hours when is_integer(hours) and hours > 0 ->
        "About #{Format.elapsed(hours * 3600)}. 0 deletes files right after sending."

      _ ->
        "0 deletes files right after sending."
    end
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp to_integer(_value), do: nil
end
