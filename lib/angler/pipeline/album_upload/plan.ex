defmodule Angler.Pipeline.AlbumUpload.Plan do
  @moduledoc """
  Splits an album into the parts `Angler.Pipeline.AlbumUpload` sends, one request
  each, in display order (pure).

  Telegram takes 2 to 10 items per `sendMediaGroup`. When the files are uploaded
  (the cloud Bot API), one request's files must also stay within the Bot API's
  upload limit: the items' files and thumbnails, plus 64 KiB per file for the
  multipart overhead. An item too large for that on its own is a part of its own.

  The album is split into the fewest parts that keep both rules, and of those
  splits the one with the fewest parts of a single item, then the most even part
  sizes, larger parts first: 11 items are sent as 6 + 5, 20 as 10 + 10, and six
  videos of 9 MB with a 50 MB limit as 3 + 3 (not 5 + 1). A part of one item is
  sent with `sendPhoto` or `sendVideo`.
  """

  @max_items 10
  @part_overhead 65_536

  @typedoc """
  An album item: `:bytes` is the size of its file and thumbnail (0 when unknown),
  `:media` and `:thumbnail` tell which files a request uploads.
  """
  @type item :: %{
          required(:media) => {:path, Path.t()} | {:file_id, String.t()},
          optional(:thumbnail) => Path.t() | nil,
          optional(:bytes) => non_neg_integer() | nil,
          optional(atom()) => term()
        }

  @doc """
  The parts to send `items` in. `max_request_bytes` is the most one request may
  upload, or nil when files aren't uploaded (a local Bot API server reads them
  from disk): then only the number of items counts.
  """
  @spec groups([item], pos_integer() | nil) :: [[item]] when item: item()
  def groups([], _max_request_bytes), do: []

  def groups(items, max_request_bytes) when is_list(items) do
    {groups, []} =
      items
      |> part_sizes(max_request_bytes)
      |> Enum.map_reduce(items, fn size, rest -> Enum.split(rest, size) end)

    groups
  end

  @doc "The bytes a request uploads for `item`: its files and their multipart overhead."
  @spec request_bytes(item()) :: non_neg_integer()
  def request_bytes(item) do
    parts = Enum.count([uploaded?(item.media), is_binary(Map.get(item, :thumbnail))], & &1)
    (Map.get(item, :bytes) || 0) + parts * @part_overhead
  end

  defp uploaded?({:path, _path}), do: true
  defp uploaded?(_media), do: false

  # The sizes of the best split (see the moduledoc), an exact search over the
  # splits of the items from each position on, from the last item back: a
  # split's cost is {parts, parts of one item, sum of squared part sizes, part
  # sizes negated}, compared in that order. Every part of the best split of all
  # items is followed by the best split of the items after it, since a cost adds
  # up over the parts (and the sizes compare in order).
  defp part_sizes(items, max_request_bytes) do
    bytes = items |> Enum.map(&request_bytes/1) |> List.to_tuple()
    count = tuple_size(bytes)

    best =
      Enum.reduce((count - 1)..0//-1, %{count => {0, 0, 0, []}}, fn start, best ->
        cost =
          start
          |> part_sizes_from(bytes, max_request_bytes)
          |> Enum.map(fn size ->
            {parts, lone, squares, sizes} = Map.fetch!(best, start + size)

            {parts + 1, lone + if(size == 1, do: 1, else: 0), squares + size * size,
             [-size | sizes]}
          end)
          |> Enum.min()

        Map.put(best, start, cost)
      end)

    {_parts, _lone, _squares, sizes} = Map.fetch!(best, 0)
    Enum.map(sizes, &(-&1))
  end

  # The sizes a part starting at `start` may have: up to 10 items within the
  # byte limit, and always 1 (an item too large on its own is sent alone).
  defp part_sizes_from(start, bytes, max_request_bytes) do
    last = min(start + @max_items, tuple_size(bytes)) - 1

    start..last
    |> Enum.scan(0, &(elem(bytes, &1) + &2))
    |> Enum.with_index(1)
    |> Enum.take_while(fn {total, size} ->
      size == 1 or max_request_bytes == nil or total <= max_request_bytes
    end)
    |> Enum.map(fn {_total, size} -> size end)
  end
end
