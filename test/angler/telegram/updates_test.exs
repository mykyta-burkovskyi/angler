defmodule Angler.Telegram.UpdatesTest do
  use Angler.DataCase, async: true

  import Angler.TelegramFixtures
  import ExUnit.CaptureLog

  alias Angler.Entries.Entry
  alias Angler.Settings
  alias Angler.Telegram.Updates

  @tiktok "https://www.tiktok.com/@fisher/video/7301?_r=1&is_from_webapp=1"

  # Replies are sent from tasks started by handle/1, which find this stub through $callers.
  setup do
    stub_bot_api(%{"sendMessage" => %{"message_id" => 1}})
    :ok
  end

  describe "handle/1 with links" do
    test "queues links of a private message" do
      user = user(%{"id" => unique_id(), "username" => "fisher"})
      message = text_message("look 🎣 #{@tiktok} and https://youtu.be/abc?si=x", %{"from" => user})
      update = build_update(message)

      assert {:ok, [tiktok, youtube]} = Updates.handle(update)

      assert %Entry{
               status: :queued,
               url: "https://www.tiktok.com/@fisher/video/7301",
               source_host: "tiktok.com",
               chat_type: "private",
               chat_title: "Ann Angler",
               message_thread_id: nil,
               from_name: "@fisher",
               max_attempts: 3
             } = tiktok

      assert tiktok.update_id == update["update_id"]
      assert tiktok.chat_id == user["id"]
      assert tiktok.message_id == message["message_id"]
      assert tiktok.from_id == user["id"]
      assert youtube.url == "https://youtu.be/abc"
      assert youtube.source_host == "youtu.be"

      assert Repo.aggregate(Entry, :count) == 2
      refute_receive {:bot_api, _, _}, 50
    end

    test "queues links of group messages, keeping forum topics only" do
      chat = group_chat(%{"title" => "Anglers", "is_forum" => true})
      from = user(%{"username" => nil, "first_name" => "Bob", "last_name" => nil})

      topic =
        group_message(@tiktok, chat, %{
          "from" => from,
          "is_topic_message" => true,
          "message_thread_id" => 12
        })

      assert {:ok, [entry]} = Updates.handle(build_update(topic))

      assert %Entry{
               chat_type: "supergroup",
               chat_title: "Anglers",
               message_thread_id: 12,
               from_name: "Bob"
             } =
               entry

      assert entry.chat_id == chat["id"]

      # In groups without topics message_thread_id may name a reply thread.
      reply = group_message(@tiktok, group_chat(), %{"message_thread_id" => 99})
      assert {:ok, [%Entry{message_thread_id: nil}]} = Updates.handle(build_update(reply))
    end

    test "queues channel posts, named after the signature or the channel" do
      chat = channel_chat(%{"title" => "Catch of the day"})

      post = channel_post(@tiktok, chat, %{"author_signature" => "Captain"})
      assert {:ok, [entry]} = Updates.handle(build_update(post, "channel_post"))

      assert %Entry{chat_type: "channel", chat_title: "Catch of the day", from_name: "Captain"} =
               entry

      assert entry.from_id == chat["id"]

      edited = channel_post("https://youtu.be/xyz", chat)
      assert {:ok, [entry]} = Updates.handle(build_update(edited, "edited_channel_post"))
      assert entry.from_name == "Catch of the day"
    end

    test "queues links added by an edit, without duplicating earlier ones" do
      message = group_message(@tiktok)
      assert {:ok, [_]} = Updates.handle(build_update(message))

      edited =
        Map.merge(message, %{"text" => "#{@tiktok} https://youtu.be/new", "edit_date" => 1})

      edited = Map.put(edited, "entities", url_entities(edited["text"]))

      assert {:ok, [%Entry{url: "https://youtu.be/new"}]} =
               Updates.handle(build_update(edited, "edited_message"))

      assert Repo.aggregate(Entry, :count) == 2
    end

    test "skips redelivered updates" do
      update = build_update(group_message(@tiktok))

      assert {:ok, [_]} = Updates.handle(update)
      assert {:ok, []} = Updates.handle(update)
      assert Repo.aggregate(Entry, :count) == 1
    end

    test "reads links from captions" do
      message = caption_message("#{@tiktok} 🎣", %{"chat" => group_chat()})

      assert {:ok, [%Entry{url: "https://www.tiktok.com/@fisher/video/7301"}]} =
               Updates.handle(build_update(message))
    end

    test "skips links too long to store and queues the message's other links" do
      message = group_message("#{long_link(3_000)} https://youtu.be/good")

      assert {:ok, [%Entry{url: "https://youtu.be/good"}]} =
               Updates.handle(build_update(message))
    end

    test "uses the configured max_attempts" do
      config = Application.get_env(:angler, Angler.Pipeline)
      assert {:ok, [entry]} = Updates.handle(build_update(group_message(@tiktok)))
      assert entry.max_attempts == config[:max_attempts]
    end
  end

  describe "handle/1 filters" do
    test "ignores messages from bots but not from anonymous admins" do
      bot = user(%{"is_bot" => true, "username" => "other_bot"})
      chat = group_chat()

      assert {:ok, []} =
               Updates.handle(build_update(group_message(@tiktok, chat, %{"from" => bot})))

      anonymous =
        group_message(@tiktok, chat, %{
          "from" =>
            user(%{"id" => 1_087_968_824, "is_bot" => true, "username" => "GroupAnonymousBot"}),
          "sender_chat" => chat,
          "author_signature" => "Admin"
        })

      assert {:ok, [%Entry{from_name: "Admin"}]} = Updates.handle(build_update(anonymous))
    end

    test "ignores channel posts forwarded to the discussion group, unless only the group is allowed" do
      channel = channel_chat()
      group = group_chat()
      telegram = user(%{"id" => 777_000, "first_name" => "Telegram", "username" => nil})

      forward =
        group_message(@tiktok, group, %{
          "from" => telegram,
          "sender_chat" => channel,
          "is_automatic_forward" => true,
          "forward_origin" => %{
            "type" => "channel",
            "chat" => channel,
            "message_id" => 7,
            "date" => 1
          }
        })

      # The channel_post update of the original already queues its links.
      assert {:ok, []} = Updates.handle(build_update(forward))

      {:ok, _} = Settings.update(%{"allowed_chat_ids" => Integer.to_string(group["id"])})
      assert {:ok, [%Entry{chat_id: chat_id}]} = Updates.handle(build_update(forward))
      assert chat_id == group["id"]
    end

    test "ignores service messages and malformed messages" do
      joined =
        group_message("")
        |> Map.drop(["text", "entities"])
        |> Map.put("new_chat_members", [user()])

      assert {:ok, []} = Updates.handle(build_update(joined))
      assert {:ok, []} = Updates.handle(build_update(Map.delete(group_message(@tiktok), "chat")))
      assert {:ok, []} = Updates.handle(%{"update_id" => 1, "message" => "nonsense"})
      assert Repo.aggregate(Entry, :count) == 0
    end

    test "ignores other update types" do
      assert {:ok, []} = Updates.handle(%{"update_id" => 1, "callback_query" => %{"id" => "1"}})
      assert {:ok, []} = Updates.handle(%{"update_id" => 2})
    end

    test "logs membership changes without failing" do
      for {type, status} <- [
            {"private", "kicked"},
            {"supergroup", "left"},
            {"group", "administrator"}
          ] do
        chat = if type == "private", do: private_chat(), else: group_chat(%{"type" => type})

        change = %{
          "chat" => chat,
          "from" => user(),
          "date" => 1,
          "old_chat_member" => %{"status" => "member"},
          "new_chat_member" => %{"status" => status, "user" => user(%{"is_bot" => true})}
        }

        assert {:ok, []} =
                 Updates.handle(%{"update_id" => unique_id(), "my_chat_member" => change})
      end

      assert {:ok, []} = Updates.handle(%{"update_id" => 1, "my_chat_member" => %{}})
    end

    test "only processes allowed chats" do
      allowed = group_chat()
      {:ok, _} = Settings.update(%{"allowed_chat_ids" => Integer.to_string(allowed["id"])})

      assert {:ok, []} = Updates.handle(build_update(group_message(@tiktok)))
      assert {:ok, [_]} = Updates.handle(build_update(group_message(@tiktok, allowed)))

      # Not even commands are answered in other chats.
      assert {:ok, []} = Updates.handle(build_update(text_message("/help")))
      refute_receive {:bot_api, _, _}, 50
    end

    test "only queues links to allowed hosts" do
      {:ok, _} = Settings.update(%{"allowed_hosts" => "youtube.com"})

      message = group_message("#{@tiktok} https://m.youtube.com/watch?v=1 https://example.com/v")

      assert {:ok, [%Entry{url: "https://m.youtube.com/watch?v=1"}]} =
               Updates.handle(build_update(message))
    end

    test "queues links to any host when the host list is empty" do
      Repo.insert!(%Settings.Setting{id: 1, allowed_hosts: []})

      assert {:ok, [%Entry{source_host: "example.com"}]} =
               Updates.handle(build_update(group_message("https://www.example.com/v")))
    end
  end

  describe "handle/1 replies in private chats" do
    test "answers /start and /help with the help text" do
      for text <- ["/start", "/help", "/help@AnglerBot", "/START payload"] do
        message = text_message(text)
        assert {:ok, []} = Updates.handle(build_update(message))

        # Replies are sent from tasks through the app-wide rate limiter.
        assert_receive {:bot_api, "sendMessage", params}, 2_000
        assert params["chat_id"] == message["chat"]["id"]
        assert params["text"] == Updates.help_text()
        assert params["reply_parameters"]["message_id"] == message["message_id"]
        assert params["link_preview_options"] == %{"is_disabled" => true}
      end

      assert Updates.help_text() =~ "privacy mode"
    end

    test "hints how to use the bot when a message has no link" do
      assert {:ok, []} = Updates.handle(build_update(text_message("hello")))

      assert_receive {:bot_api, "sendMessage", %{"text" => "Send me a link to a video" <> _}},
                     2_000
    end

    test "says which sites are not supported" do
      assert {:ok, []} = Updates.handle(build_update(text_message("https://www.example.com/v")))

      assert_receive {:bot_api, "sendMessage",
                      %{"text" => "Sorry, I don't download videos from example.com."}},
                     2_000
    end

    test "stays quiet for edits, other commands, groups and messages with links" do
      assert {:ok, []} = Updates.handle(build_update(text_message("hello"), "edited_message"))
      assert {:ok, []} = Updates.handle(build_update(text_message("/settings")))
      assert {:ok, []} = Updates.handle(build_update(group_message("/help")))
      assert {:ok, []} = Updates.handle(build_update(group_message("hello")))
      assert {:ok, [_]} = Updates.handle(build_update(text_message(@tiktok)))

      refute_receive {:bot_api, _, _}, 100
    end

    test "logs failed replies" do
      test = self()

      Req.Test.stub(Angler.Telegram, fn conn ->
        send(test, {:reply_task, self()})

        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(api_error(403, "Forbidden: bot was blocked by the user"))
      end)

      log =
        capture_log(fn ->
          assert {:ok, []} = Updates.handle(build_update(text_message("/start")))
          assert_receive {:reply_task, task}, 2_000
          ref = Process.monitor(task)
          # The task may already have finished (:noproc) by the time it is monitored.
          assert_receive {:DOWN, ^ref, :process, ^task, reason} when reason in [:normal, :noproc],
                         2_000
        end)

      assert log =~ "Could not reply"
      assert log =~ "bot was blocked by the user"
    end
  end

  describe "handle_safely/1" do
    test "returns :ok for handled updates" do
      assert Updates.handle_safely(build_update(group_message(@tiktok))) == :ok
      assert Repo.aggregate(Entry, :count) == 1
    end

    test "logs and acknowledges updates that can't be processed" do
      poison = build_update(poison_message())
      assert_raise Ecto.ChangeError, fn -> Updates.handle(poison) end

      log = capture_log(fn -> assert Updates.handle_safely(poison) == :ok end)

      assert log =~ "Dropping Telegram update #{poison["update_id"]}"
      assert log =~ "Ecto.ChangeError"
    end
  end

  describe "storage_error?/1" do
    test "recognizes temporary storage failures" do
      assert Updates.storage_error?(%DBConnection.ConnectionError{message: "down"})
      assert Updates.storage_error?(DBConnection.OwnershipError.exception("no owner"))
      assert Updates.storage_error?(%Postgrex.Error{message: "closed"})

      for code <- ~w(08006 40001 40P01 53100 53300 55P03 25006 57P01 57014 58030) do
        assert Updates.storage_error?(%Postgrex.Error{postgres: %{pg_code: code}}), code
      end
    end

    test "treats errors that fail the same way every time as permanent" do
      for code <- ~w(22021 23502 42P01 54000 55000 P0001 XX000) do
        refute Updates.storage_error?(%Postgrex.Error{postgres: %{pg_code: code}}), code
      end

      refute Updates.storage_error?(%ArgumentError{})
    end

    test "treats an index row that is too big as permanent" do
      attrs = %{url: long_link(3_000), chat_id: 1, chat_type: "private", message_id: 1}
      error = assert_raise Postgrex.Error, fn -> Angler.Entries.enqueue([attrs]) end

      assert error.postgres.code == :program_limit_exceeded
      refute Updates.storage_error?(error)
    end
  end
end
