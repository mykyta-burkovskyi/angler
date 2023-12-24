defmodule Angler.UrlExtractor do
  def extract(message_entities, message_text) do
    extract_url = message_text |> get_extractor

    message_entities
    |> Enum.filter(&(&1["type"] == "url"))
    |> Enum.map(extract_url)
  end

  defp get_extractor(message_text) do
    message_text_utf16 =
      message_text |> :unicode.characters_to_binary(:utf8, :utf16)

    fn %{"length" => length, "offset" => offset} ->
      message_text_utf16
      |> binary_slice(offset * 2, length * 2)
      |> :unicode.characters_to_binary(:utf16, :utf8)
    end
  end
end
