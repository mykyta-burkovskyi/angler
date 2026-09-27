defmodule Angler.TelegramFixtures do
  @moduledoc """
  Builders for Telegram updates and messages as they arrive from the Bot API
  (decoded JSON, string keys), and a `Req.Test` stub for `Angler.Telegram`.

  Attribute maps passed to the builders use string keys and are merged into the
  defaults.
  """

  @doc "A unique positive integer, e.g. for update, message and chat ids."
  def unique_id, do: System.unique_integer([:positive])

  @doc "A Telegram user."
  def user(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => unique_id(),
        "is_bot" => false,
        "first_name" => "Ann",
        "last_name" => "Angler",
        "username" => "ann"
      },
      attrs
    )
  end

  @doc "A private chat with `user` (private chat ids equal the user id)."
  def private_chat(user \\ user()) do
    Map.merge(
      %{"id" => user["id"], "type" => "private"},
      Map.take(user, ["first_name", "last_name", "username"])
    )
  end

  @doc "A supergroup (negative id)."
  def group_chat(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => -1_000_000_000_000 - unique_id(),
        "type" => "supergroup",
        "title" => "Fishing club"
      },
      attrs
    )
  end

  @doc "A channel (negative id)."
  def channel_chat(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => -1_000_000_000_000 - unique_id(),
        "type" => "channel",
        "title" => "Catch of the day"
      },
      attrs
    )
  end

  @doc """
  A text message. Every `http(s)://` URL in `text` gets a `url` entity with
  UTF-16 offsets, the way Telegram sends them. Defaults to a private chat.
  """
  def text_message(text, attrs \\ %{}) do
    from = Map.get(attrs, "from", user())

    Map.merge(
      %{
        "message_id" => unique_id(),
        "date" => System.os_time(:second),
        "from" => from,
        "chat" => private_chat(from),
        "text" => text,
        "entities" => url_entities(text)
      },
      attrs
    )
  end

  @doc "A video message with a `caption` (URLs get `caption_entities`)."
  def caption_message(caption, attrs \\ %{}) do
    caption
    |> text_message(attrs)
    |> Map.drop(["text", "entities"])
    |> Map.merge(%{
      "caption" => caption,
      "caption_entities" => url_entities(caption),
      "video" => %{"file_id" => "BAAC#{unique_id()}", "file_unique_id" => "AgAD#{unique_id()}"}
    })
  end

  @doc "A text message posted in `chat` (see `group_chat/1`)."
  def group_message(text, chat \\ group_chat(), attrs \\ %{}),
    do: text_message(text, Map.put(attrs, "chat", chat))

  @doc """
  A group message with a link that can never be stored: its malformed topic id
  makes `Angler.Entries.enqueue/1` raise. For testing how poison updates are handled.
  """
  def poison_message do
    group_message("https://youtu.be/poison", group_chat(), %{
      "is_topic_message" => true,
      "message_thread_id" => "not a number"
    })
  end

  @doc """
  A YouTube link of exactly `bytes` bytes ending in random characters, which
  Postgres can't compress: from about 2.7 kB on it doesn't fit a btree index row
  (a repetitive link of that length would).
  """
  def long_link(bytes) do
    prefix = "https://www.youtube.com/watch?v=x&p="
    size = bytes - byte_size(prefix)
    token = size |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    prefix <> binary_part(token, 0, size)
  end

  @doc "A channel post (no `from`, `sender_chat` is the channel)."
  def channel_post(text, chat \\ channel_chat(), attrs \\ %{}) do
    text
    |> text_message(Map.merge(%{"chat" => chat, "sender_chat" => chat}, attrs))
    |> Map.delete("from")
  end

  @doc """
  Wraps a message into an update of `type` ("message", "channel_post", ...).
  (Not named `update` because DataCase imports `Ecto.Query.update/3`.)
  """
  def build_update(message, type \\ "message"),
    do: %{"update_id" => unique_id(), type => message}

  @doc "`url` entities (UTF-16 offsets) for the `http(s)://` URLs in `text`."
  def url_entities(text) do
    ~r{https?://\S+}
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{start, length}] ->
      %{
        "type" => "url",
        "offset" => utf16_length(binary_part(text, 0, start)),
        "length" => utf16_length(binary_part(text, start, length))
      }
    end)
  end

  @doc "Length of `string` in UTF-16 code units, as Telegram counts entity offsets."
  def utf16_length(string),
    do: byte_size(:unicode.characters_to_binary(string, :utf8, {:utf16, :little})) |> div(2)

  @doc "A successful Bot API response body."
  def api_ok(result), do: %{"ok" => true, "result" => result}

  @doc "A failed Bot API response body."
  def api_error(code, description, parameters \\ nil) do
    %{"ok" => false, "error_code" => code, "description" => description}
    |> then(&if parameters, do: Map.put(&1, "parameters", parameters), else: &1)
  end

  @doc "The Message Telegram returns for a sent video."
  def sent_video(chat_id, attrs \\ %{}) do
    Map.merge(
      %{
        "message_id" => unique_id(),
        "date" => System.os_time(:second),
        "chat" => %{"id" => chat_id, "type" => "private"},
        "video" => %{
          "file_id" => "BAACAgIAAxkBAAI#{unique_id()}",
          "file_unique_id" => "AgAD#{unique_id()}",
          "duration" => 12,
          "width" => 720,
          "height" => 1280,
          "mime_type" => "video/mp4",
          "file_size" => 1_234_567
        }
      },
      attrs
    )
  end

  @doc """
  Stubs the Bot API (`Req.Test` under the name `Angler.Telegram`). Every request is
  reported to `test_pid` as `{:bot_api, method, params}` (params are the decoded
  JSON or multipart fields), and answered from `responses`, a map of method name to:

    * a `fun(conn)` returning the response conn
    * `{:error, code, description}` or `{:error, code, description, parameters}`
    * any other term, returned as the `result` of a successful response

  Methods missing from `responses` return `true`.
  """
  def stub_bot_api(responses \\ %{}, test_pid \\ self()) do
    Req.Test.stub(Angler.Telegram, fn conn ->
      method = List.last(conn.path_info)
      send(test_pid, {:bot_api, method, conn.body_params})

      case Map.get(responses, method, true) do
        fun when is_function(fun, 1) ->
          fun.(conn)

        {:error, code, description} ->
          error_response(conn, code, description, nil)

        {:error, code, description, parameters} ->
          error_response(conn, code, description, parameters)

        result ->
          Req.Test.json(conn, api_ok(result))
      end
    end)
  end

  defp error_response(conn, code, description, parameters) do
    conn
    |> Plug.Conn.put_status(code)
    |> Req.Test.json(api_error(code, description, parameters))
  end
end
