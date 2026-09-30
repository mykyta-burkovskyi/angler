defmodule AnglerWeb.MediaController do
  @moduledoc """
  Serves a delivered entry's video (with HTTP Range support, for seeking in the
  browser) and thumbnail from local storage, for previews on the dashboard, and
  the photos, videos and video thumbnails of an album entry.

  Only single byte ranges are supported (`bytes=first-last`, `bytes=first-` and the
  suffix form `bytes=-length`); a Range header this controller doesn't understand
  (another unit, several ranges, malformed) is ignored and the whole file is sent,
  as HTTP allows. Only files inside `Angler.Storage.root/0` are ever served, and
  paths never come from the request: an album item is picked by its index among
  the entry's stored items (`Angler.Storage.media_item_path/2`).
  """
  use AnglerWeb, :controller

  alias Angler.Entries
  alias Angler.Entries.Entry
  alias Angler.Storage

  # The photo formats an album may hold (see Angler.Storage.Album).
  @image_types %{".jpg" => "image/jpeg", ".png" => "image/png", ".webp" => "image/webp"}

  @doc "Sends an entry's final video, honouring a single-range `Range` header."
  def video(conn, %{"id" => id}) do
    case stored_file(id, &Storage.video_path/1) do
      {:ok, path, size} -> send_video(conn, path, size)
      :error -> not_found(conn)
    end
  end

  @doc "Sends an entry's thumbnail (cacheable by the browser for an hour)."
  def thumbnail(conn, %{"id" => id}) do
    case stored_file(id, &Storage.thumbnail_path/1) do
      {:ok, path, _size} -> send_image(conn, path, "image/jpeg")
      :error -> not_found(conn)
    end
  end

  @doc """
  Sends an item of an album entry, by its index (from 0): a video like `video/2`,
  a photo like `thumbnail/2`, each with the content type of its file.
  """
  def item(conn, %{"id" => id, "index" => index}) do
    with {:ok, index} <- parse_index(index),
         {:ok, path, size} <- stored_file(id, &Storage.media_item_path(&1, index)) do
      send_item(conn, path, size)
    else
      :error -> not_found(conn)
    end
  end

  @doc "Sends the thumbnail of an album entry's video item, like `thumbnail/2`."
  def item_thumbnail(conn, %{"id" => id, "index" => index}) do
    with {:ok, index} <- parse_index(index),
         {:ok, path, _size} <- stored_file(id, &Storage.media_item_thumbnail_path(&1, index)) do
      send_image(conn, path, "image/jpeg")
    else
      :error -> not_found(conn)
    end
  end

  # Plain digits only: no sign, space, fraction or anything else Integer.parse/1
  # would let through. An album has at most 20 items.
  defp parse_index(index) do
    if Regex.match?(~r/\A\d{1,2}\z/, index), do: {:ok, String.to_integer(index)}, else: :error
  end

  defp stored_file(id, path_fun) do
    with %Entry{} = entry <- Entries.get(id),
         path when is_binary(path) <- path_fun.(entry),
         true <- Storage.managed_path?(path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path) do
      {:ok, path, size}
    else
      _ -> :error
    end
  end

  # The content type follows the file's name, which Angler.Storage.Album checked.
  defp send_item(conn, path, size) do
    extension = Path.extname(path)

    cond do
      extension == ".mp4" -> send_video(conn, path, size)
      type = @image_types[extension] -> send_image(conn, path, type)
      true -> not_found(conn)
    end
  end

  defp send_video(conn, path, size) do
    conn
    |> put_resp_content_type("video/mp4", nil)
    |> put_resp_header("accept-ranges", "bytes")
    |> send_range(path, size, requested_range(conn, size))
  end

  defp send_image(conn, path, content_type) do
    conn
    |> put_resp_content_type(content_type, nil)
    |> put_resp_header("cache-control", "private, max-age=3600")
    |> send_file(200, path)
  end

  defp send_range(conn, path, _size, :all), do: send_file(conn, 200, path)

  defp send_range(conn, path, size, {first, last}) do
    conn
    |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
    |> send_file(206, path, first, last - first + 1)
  end

  defp send_range(conn, _path, size, :unsatisfiable) do
    conn
    |> put_resp_header("content-range", "bytes */#{size}")
    |> send_resp(416, "")
  end

  # Returns `:all`, `{first, last}` (inclusive, within the file) or `:unsatisfiable`.
  defp requested_range(conn, size) do
    with [header] <- get_req_header(conn, "range"),
         [unit, spec] <- String.split(header, "=", parts: 2),
         "bytes" <- unit |> String.trim() |> String.downcase(),
         [_match, first, last] <- Regex.run(~r/\A\s*(\d*)-(\d*)\s*\z/, spec) do
      resolve_range(parse_position(first), parse_position(last), size)
    else
      _ -> :all
    end
  end

  defp parse_position(""), do: nil
  defp parse_position(digits), do: String.to_integer(digits)

  # "bytes=-" is not a valid range: ignore it.
  defp resolve_range(nil, nil, _size), do: :all

  # Suffix range: the last `length` bytes.
  defp resolve_range(nil, length, size) when length > 0 and size > 0,
    do: {max(size - length, 0), size - 1}

  defp resolve_range(nil, _length, _size), do: :unsatisfiable

  defp resolve_range(first, nil, size) when first < size, do: {first, size - 1}

  defp resolve_range(first, last, size) when is_integer(last) and first <= last and first < size,
    do: {first, min(last, size - 1)}

  defp resolve_range(_first, _last, _size), do: :unsatisfiable

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not found")
  end
end
