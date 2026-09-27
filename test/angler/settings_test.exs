defmodule Angler.SettingsTest do
  # Settings updates are broadcast to every subscriber (e.g. dashboard tests).
  use Angler.DataCase, async: false

  alias Angler.Settings
  alias Angler.Settings.Setting

  describe "update/1" do
    test "saves valid settings" do
      assert {:ok, %Setting{storage_limit_mb: 500, history_days: 30}} =
               Settings.update(%{"storage_limit_mb" => "500", "history_days" => "30"})

      assert %Setting{storage_limit_mb: 500, history_days: 30} = Settings.get()
    end

    test "stores internationalized allowed hosts in their ASCII form, as links are matched" do
      assert {:ok, %Setting{allowed_hosts: hosts} = setting} =
               Settings.update(%{"allowed_hosts" => "Пример.РФ\nwww.TikTok.com"})

      assert hosts == ["xn--e1afmkfd.xn--p1ai", "tiktok.com"]
      assert Settings.host_allowed?(setting, Angler.Links.host("https://пример.рф/video"))
    end

    test "keeps the entry history for 90 days by default, and forever with 0" do
      assert Settings.get().history_days == 90
      assert {:ok, %Setting{history_days: 0}} = Settings.update(%{"history_days" => "0"})
    end

    test "posts titles as captions by default, until turned off" do
      assert %Setting{title_captions: true} = Settings.get()

      assert {:ok, %Setting{title_captions: false}} =
               Settings.update(%{"title_captions" => "false"})

      assert %Setting{title_captions: false} = Settings.get()

      assert {:ok, %Setting{title_captions: true}} =
               Settings.update(%{"title_captions" => "true"})
    end

    test "rejects a title captions value that isn't a boolean" do
      assert {:error, changeset} = Settings.update(%{"title_captions" => "sometimes"})
      assert %{title_captions: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} = Settings.update(%{"title_captions" => nil})
      assert %{title_captions: ["can't be blank"]} = errors_on(changeset)
      assert Settings.get().title_captions
    end

    # Settings saved before the column existed.
    test "posts titles as captions for a settings row that doesn't mention them" do
      Angler.Repo.query!(
        "INSERT INTO settings (id, inserted_at, updated_at) VALUES (1, now(), now())"
      )

      assert %Setting{title_captions: true, inserted_at: %DateTime{}} = Settings.get()
    end

    test "rejects an invalid history period" do
      assert {:error, changeset} = Settings.update(%{"history_days" => "-1"})
      assert %{history_days: [_message]} = errors_on(changeset)

      assert {:error, changeset} = Settings.update(%{"history_days" => "100000"})
      assert %{history_days: [_message]} = errors_on(changeset)
    end

    # The column is a 4-byte integer: a value this big made the save raise.
    test "rejects a storage limit too big to store instead of raising" do
      assert {:error, changeset} = Settings.update(%{"storage_limit_mb" => "10000000000"})
      assert %{storage_limit_mb: [_message]} = errors_on(changeset)
    end

    test "rejects chat ids too big to be Telegram chat ids instead of raising" do
      assert {:error, changeset} =
               Settings.update(%{"allowed_chat_ids" => "-1001234567890, 99999999999999999999"})

      assert %{allowed_chat_ids: [message]} = errors_on(changeset)
      assert message =~ "99999999999999999999"

      assert {:ok, %Setting{allowed_chat_ids: [-1_001_234_567_890]}} =
               Settings.update(%{"allowed_chat_ids" => "-1001234567890"})
    end
  end
end
