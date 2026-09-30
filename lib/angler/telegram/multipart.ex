defmodule Angler.Telegram.Multipart do
  @moduledoc """
  Building blocks for Bot API request bodies that carry files (see
  `Angler.Telegram.VideoBody` and `Angler.Telegram.MediaBody`): multipart text
  values, file parts, and the `file://` URIs a local Bot API server in `--local`
  mode reads from its own disk.
  """

  @chunk_size 65_536

  @content_types %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp",
    ".mp4" => "video/mp4"
  }

  @doc """
  The `file://` URI of `path`. A local Bot API server in `--local` mode reads it
  from its own disk, which shares the media volume at the same absolute path.
  """
  @spec file_uri(Path.t()) :: String.t()
  def file_uri(path), do: "file://" <> URI.encode(Path.expand(path))

  @doc "A value as a multipart text field: maps and lists (e.g. `media`) as JSON."
  @spec value(String.t() | integer() | boolean() | map() | list()) :: String.t()
  def value(value) when is_binary(value), do: value
  def value(value) when is_integer(value), do: Integer.to_string(value)
  def value(value) when is_boolean(value), do: Atom.to_string(value)
  def value(value) when is_map(value) or is_list(value), do: Jason.encode!(value)

  @doc "Turns the values of `fields` (a keyword list without nils) into text fields."
  @spec text_fields(keyword()) :: [{atom(), String.t()}]
  def text_fields(fields), do: Enum.map(fields, fn {name, value} -> {name, value(value)} end)

  @doc """
  A file part for `path`, sent as `filename` with the content type of its
  extension (see `content_type/1`).

  The file is streamed in chunks (never the default `:line` mode of
  `File.stream!/2`, which rewrites CRLF), which also lets Req compute the
  content length from the file size without reading the file into memory.
  """
  @spec file_part(Path.t(), String.t()) :: {File.Stream.t(), keyword()}
  def file_part(path, filename) do
    {File.stream!(path, @chunk_size), filename: filename, content_type: content_type(filename)}
  end

  @doc """
  The content type for a file name's extension (JPEG, PNG, WebP or MP4), else
  `application/octet-stream`.
  """
  @spec content_type(Path.t()) :: String.t()
  def content_type(filename) do
    extension = filename |> Path.extname() |> String.downcase()
    Map.get(@content_types, extension, "application/octet-stream")
  end
end
