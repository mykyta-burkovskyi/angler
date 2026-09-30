defmodule Angler.Entries.MediaItem do
  @moduledoc """
  One photo or video of an album entry (`media_kind: :album`), embedded in
  `entries.media_items` in display order.

    * `:type` - `:photo` or `:video`
    * `:path` - the item's file relative to the entry's directory, e.g.
      `album/01/photo.jpg` (see `Angler.Storage.Album`)
    * `:thumbnail` - a video's thumbnail, relative like `:path`, or nil
    * `:bytes` - size of the file
    * `:width`, `:height` - dimensions, if known
    * `:duration` - a video's seconds, if known
    * `:file_id`, `:file_unique_id` - the Telegram file once the item was delivered

  `Angler.Entries.update!/2` doesn't cast, so items must be built with `new/1`: it
  normalizes values Ecto would refuse to store (e.g. an integer duration).
  """
  use Ecto.Schema

  @types [:photo, :video]
  @fields ~w(type path thumbnail bytes width height duration file_id file_unique_id)a

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: @types
    field :path, :string
    field :thumbnail, :string
    field :bytes, :integer
    field :width, :integer
    field :height, :integer
    field :duration, :float
    field :file_id, :string
    field :file_unique_id, :string
  end

  @type t :: %__MODULE__{
          type: :photo | :video | nil,
          path: String.t() | nil,
          thumbnail: String.t() | nil,
          bytes: non_neg_integer() | nil,
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          duration: float() | nil,
          file_id: String.t() | nil,
          file_unique_id: String.t() | nil
        }

  @doc """
  Builds an item from a map (or another item) with atom or string keys.

  Unknown keys are dropped and values of the wrong type become nil, so it never
  raises: `:type` accepts `:photo`/`:video` or their names, numbers are
  accepted for the integer fields (floats are rounded) and for `:duration`
  (integers become floats), and strings for the others.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    values = for field <- @fields, do: {field, normalize(field, fetch(attrs, field))}
    struct!(__MODULE__, values)
  end

  @doc "Whether the item was delivered to Telegram (it has a file id)."
  @spec delivered?(t()) :: boolean()
  def delivered?(%__MODULE__{file_id: file_id}), do: is_binary(file_id)

  defp fetch(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(field))
    end
  end

  defp normalize(:type, type) when type in @types, do: type
  defp normalize(:type, "photo"), do: :photo
  defp normalize(:type, "video"), do: :video
  defp normalize(:type, _type), do: nil

  defp normalize(:duration, value) when is_integer(value), do: value * 1.0
  defp normalize(:duration, value) when is_float(value), do: value
  defp normalize(:duration, _value), do: nil

  defp normalize(field, value) when field in [:bytes, :width, :height] do
    cond do
      is_integer(value) -> value
      is_float(value) -> round(value)
      true -> nil
    end
  end

  defp normalize(_field, value) when is_binary(value), do: value
  defp normalize(_field, _value), do: nil
end
