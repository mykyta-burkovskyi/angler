defmodule Angler.Pipeline.AlbumUpload.PlanTest do
  use ExUnit.Case, async: true

  alias Angler.Pipeline.AlbumUpload.Plan

  @mb 1_000_000
  @overhead 65_536

  describe "groups/2" do
    test "sends up to 10 items in one request" do
      for count <- [1, 2, 10] do
        items = items(count)
        assert Plan.groups(items, nil) == [items]
        assert Plan.groups(items, 50 * @mb) == [items]
      end

      assert Plan.groups([], nil) == []
    end

    test "splits more items into requests of about the same size, in order" do
      for {count, sizes} <- [
            {11, [6, 5]},
            {12, [6, 6]},
            {19, [10, 9]},
            {20, [10, 10]},
            {21, [7, 7, 7]},
            {23, [8, 8, 7]}
          ] do
        items = items(count)
        groups = Plan.groups(items, nil)

        assert Enum.map(groups, &length/1) == sizes
        assert Enum.concat(groups) == items
      end
    end

    test "keeps the files of one upload within the limit, with their multipart overhead" do
      # 5 videos of 12.5 MB with their thumbnails (2 parts each): 4 would need 50.5 MB.
      videos = for n <- 1..5, do: item(n, 12_500_000, thumbnail: "thumb#{n}.jpg")
      assert Plan.request_bytes(hd(videos)) == 12_500_000 + 2 * @overhead

      groups = Plan.groups(videos, 50 * @mb)

      assert Enum.map(groups, &length/1) == [3, 2]
      assert Enum.concat(groups) == videos

      for group <- groups do
        assert group |> Enum.map(&Plan.request_bytes/1) |> Enum.sum() <= 50 * @mb
      end
    end

    test "counts the overhead: items filling the limit exactly don't fit together" do
      items = [item(1, 25 * @mb), item(2, 25 * @mb)]
      assert Plan.groups(items, 50 * @mb) == [[hd(items)], tl(items)]

      items = [item(1, 25 * @mb - @overhead), item(2, 25 * @mb - @overhead)]
      assert Plan.groups(items, 50 * @mb) == [items]
    end

    test "sends an item too large for the limit on its own" do
      [small, huge, other] = items = [item(1, @mb), item(2, 60 * @mb), item(3, @mb)]

      assert Plan.groups(items, 50 * @mb) == [[small], [huge], [other]]
    end

    test "splits by size into the fewest requests, as even as they fit, without lone items" do
      # 9 MB videos with the 50 MB limit: 5 fit in one request.
      for {count, sizes} <- [
            {6, [3, 3]},
            {10, [5, 5]},
            {11, [4, 4, 3]},
            {12, [4, 4, 4]},
            {20, [5, 5, 5, 5]}
          ] do
        items = for n <- 1..count, do: item(n, 9 * @mb)
        groups = Plan.groups(items, 50 * @mb)

        assert Enum.map(groups, &length/1) == sizes
        assert Enum.concat(groups) == items
      end
    end

    test "sends an item alone only when no split into as many requests avoids it" do
      # 40 + 15 + 15 MB: 40 + 15 would be too large, so the first item goes alone.
      items = [item(1, 40 * @mb), item(2, 15 * @mb), item(3, 15 * @mb)]
      assert items |> Plan.groups(50 * @mb) |> Enum.map(&length/1) == [1, 2]

      # 10 + 30 + 30 MB: the last two don't fit together.
      items = [item(1, 10 * @mb), item(2, 30 * @mb), item(3, 30 * @mb)]
      assert items |> Plan.groups(50 * @mb) |> Enum.map(&length/1) == [2, 1]

      # 5 x 12 MB: 4 fit in one request, but 3 + 2 needs no more requests than 4 + 1.
      items = for n <- 1..5, do: item(n, 12 * @mb)
      assert items |> Plan.groups(50 * @mb) |> Enum.map(&length/1) == [3, 2]
    end

    test "agrees with an exhaustive search on random albums" do
      for _ <- 1..300 do
        count = Enum.random(1..12)
        items = for n <- 1..count, do: item(n, Enum.random([1, 5, 9, 12, 20, 30, 55]) * @mb)
        limit = Enum.random([nil, 20 * @mb, 50 * @mb])
        groups = Plan.groups(items, limit)

        assert Enum.concat(groups) == items
        assert Enum.all?(groups, &valid_part?(&1, limit))

        best =
          count
          |> compositions()
          |> Enum.filter(fn sizes ->
            sizes |> split(items) |> Enum.all?(&valid_part?(&1, limit))
          end)
          |> Enum.map(&cost/1)
          |> Enum.min()

        assert groups |> Enum.map(&length/1) |> cost() == best
      end
    end

    test "only counts the items when files aren't uploaded" do
      items = for n <- 1..10, do: item(n, 100 * @mb)
      assert Plan.groups(items, nil) == [items]
    end

    test "counts no upload for files sent by file_id" do
      item = %{media: {:file_id, "AgAC"}, thumbnail: nil}
      assert Plan.request_bytes(item) == 0
      assert Plan.request_bytes(%{media: {:path, "/a.jpg"}}) == @overhead
    end
  end

  defp items(count), do: for(n <- 1..count, do: item(n, 100_000))

  defp valid_part?([_item], _limit), do: true

  defp valid_part?(part, limit) do
    length(part) <= 10 and
      (limit == nil or part |> Enum.map(&Plan.request_bytes/1) |> Enum.sum() <= limit)
  end

  # Every way to write `count` as a sum of part sizes, in order.
  defp compositions(0), do: [[]]

  defp compositions(count) do
    for size <- 1..count, rest <- compositions(count - size), do: [size | rest]
  end

  defp split(sizes, items) do
    {parts, []} = Enum.map_reduce(sizes, items, &Enum.split(&2, &1))
    parts
  end

  # Fewest requests, then fewest lone items, then the most even sizes.
  defp cost(sizes) do
    {length(sizes), Enum.count(sizes, &(&1 == 1)), sizes |> Enum.map(&(&1 * &1)) |> Enum.sum()}
  end

  defp item(n, bytes, opts \\ []) do
    %{
      index: n - 1,
      type: :photo,
      media: {:path, "/album/#{n}.jpg"},
      thumbnail: opts[:thumbnail],
      bytes: bytes
    }
  end
end
