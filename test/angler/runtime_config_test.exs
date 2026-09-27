defmodule Angler.RuntimeConfigTest do
  # Evaluates config/runtime.exs the way a production release does at boot. It
  # reads OS environment variables, which are global to the VM, so not async.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @external_resource @runtime

  # Every variable runtime.exs reads, so nothing from the developer's shell leaks in.
  @vars ~r/"([A-Z][A-Z0-9_]+)"/
        |> Regex.scan(File.read!(@runtime), capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

  @required %{
    "TELEGRAM_BOT_TOKEN" => "123456:TEST-TOKEN",
    "DATABASE_URL" => "ecto://angler:secret@db/angler",
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "DASHBOARD_PASSWORD" => "correct horse battery staple"
  }

  @local_api %{
    "TELEGRAM_API_BASE_URL" => "http://telegram-bot-api:8081",
    "TELEGRAM_WEBHOOK_URL" => "http://app:4000/telegram/webhook"
  }

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp prod_config(env \\ %{}) do
    Enum.each(@vars, &System.delete_env/1)
    System.put_env(Map.merge(@required, env))
    Config.Reader.read!(@runtime, env: :prod, target: :host)[:angler]
  end

  test "reads every variable it uses" do
    assert "PUBLIC_URL" in @vars and "ALLOW_PRIVATE_NETWORK_DOWNLOADS" in @vars
  end

  describe "PUBLIC_URL" do
    test "a full URL sets the endpoint URL, the allowed origin and the webhook" do
      config = prod_config(%{"PUBLIC_URL" => "https://Angler.example.com/"})

      assert config[AnglerWeb.Endpoint][:url] ==
               [host: "Angler.example.com", port: 443, scheme: "https"]

      assert config[AnglerWeb.OriginCheck][:hosts] == ["Angler.example.com"]
      assert config[Angler.Telegram][:mode] == :webhook

      assert config[Angler.Telegram][:webhook_url] ==
               "https://Angler.example.com/telegram/webhook"
    end

    test "defaults to localhost and polling when unset" do
      config = prod_config(%{"ALLOWED_ORIGINS" => "nas.example.net, other.example.net"})

      assert config[AnglerWeb.OriginCheck][:hosts] ==
               ["localhost", "nas.example.net", "other.example.net"]

      assert config[Angler.Telegram][:mode] == :polling
      assert config[Angler.Telegram][:webhook_url] == nil
    end

    test "a bare host name is rejected at boot instead of breaking every dashboard connection" do
      assert_raise RuntimeError, ~r/PUBLIC_URL must be a full URL.*"angler.example.com"/s, fn ->
        prod_config(%{"PUBLIC_URL" => "angler.example.com"})
      end
    end

    test "other URL variables must be full http(s) URLs too" do
      for {name, value} <- [
            {"TELEGRAM_WEBHOOK_URL", "angler.example.com/telegram/webhook"},
            {"TELEGRAM_API_BASE_URL", "telegram-bot-api:8081"},
            {"PUBLIC_URL", "ftp://angler.example.com"},
            {"PUBLIC_URL", "https://"}
          ] do
        assert_raise RuntimeError, ~r/#{name} must be a full URL/, fn ->
          prod_config(%{name => value})
        end
      end
    end
  end

  describe "boolean variables" do
    test "accept true/false, 1/0, yes/no and on/off in any case" do
      for {value, expected} <- [
            {"True", true},
            {"YES", true},
            {" on ", true},
            {"1", true},
            {"FALSE", false},
            {"No", false},
            {"off", false},
            {"0", false}
          ] do
        assert prod_config(%{"PIPELINE_ENABLED" => value})[Angler.Pipeline][:enabled] ==
                 expected,
               "PIPELINE_ENABLED=#{inspect(value)}"
      end

      assert prod_config(%{"ECTO_IPV6" => "yes"})[Angler.Repo][:socket_options] == [:inet6]
      assert prod_config(%{"ECTO_IPV6" => "false"})[Angler.Repo][:socket_options] == []

      config = prod_config(Map.put(@local_api, "TELEGRAM_LOCAL_MODE", "TRUE"))
      assert config[Angler.Telegram][:local_mode] == true
    end

    test "fall back to their default when unset" do
      config = prod_config()

      assert config[Angler.Pipeline][:enabled] == true
      assert config[Angler.Telegram][:local_mode] == false
      assert config[Angler.Repo][:socket_options] == []
    end

    test "reject anything else instead of silently reading it as false" do
      assert_raise RuntimeError, ~r/PIPELINE_ENABLED must be true or false.*"enabled"/s, fn ->
        prod_config(%{"PIPELINE_ENABLED" => "enabled"})
      end
    end
  end

  describe "integer variables" do
    test "are parsed, with their default when unset" do
      config = prod_config(%{"DOWNLOAD_CONCURRENCY" => " 4 "})

      assert config[Angler.Pipeline][:download_concurrency] == 4
      assert config[Angler.Pipeline][:upload_concurrency] == 2
    end

    test "reject anything else with an error naming the variable" do
      assert_raise RuntimeError, ~r/MAX_ATTEMPTS must be a whole number.*"3x"/s, fn ->
        prod_config(%{"MAX_ATTEMPTS" => "3x"})
      end
    end
  end

  describe "Telegram Bot API server" do
    test "local mode with a local server and an internal HTTP webhook is accepted" do
      telegram = prod_config(Map.put(@local_api, "TELEGRAM_LOCAL_MODE", "true"))[Angler.Telegram]

      assert telegram[:local_mode] == true
      assert telegram[:api_base_url] == "http://telegram-bot-api:8081"
      assert telegram[:mode] == :webhook
      assert telegram[:webhook_url] == "http://app:4000/telegram/webhook"
    end

    test "TELEGRAM_LOCAL_MODE=true against the cloud API is rejected" do
      for cloud_env <- [%{}, %{"TELEGRAM_API_BASE_URL" => "https://API.telegram.org/"}] do
        assert_raise RuntimeError, ~r/TELEGRAM_LOCAL_MODE=true.*TELEGRAM_API_BASE_URL/s, fn ->
          prod_config(Map.put(cloud_env, "TELEGRAM_LOCAL_MODE", "true"))
        end
      end
    end

    test "a plain HTTP webhook URL with the cloud API is rejected" do
      assert_raise RuntimeError, ~r/only delivers webhooks to https:\/\/ URLs/, fn ->
        prod_config(%{"TELEGRAM_WEBHOOK_URL" => "http://app:4000/telegram/webhook"})
      end

      assert_raise RuntimeError, ~r/only delivers webhooks to https:\/\/ URLs/, fn ->
        prod_config(%{"PUBLIC_URL" => "http://nas.lan:4000"})
      end
    end

    test "a plain HTTP PUBLIC_URL is fine with polling (dashboard address only)" do
      config = prod_config(%{"PUBLIC_URL" => "http://nas.lan:4000", "TELEGRAM_MODE" => "polling"})

      assert config[Angler.Telegram][:mode] == :polling
      assert config[AnglerWeb.OriginCheck][:hosts] == ["nas.lan"]
    end
  end

  describe "ALLOW_PRIVATE_NETWORK_DOWNLOADS" do
    test "is off by default and can be enabled" do
      assert prod_config()[Angler.Media][:allow_private_networks] == false

      assert prod_config(%{"ALLOW_PRIVATE_NETWORK_DOWNLOADS" => "true"})[Angler.Media][
               :allow_private_networks
             ] == true
    end
  end
end
