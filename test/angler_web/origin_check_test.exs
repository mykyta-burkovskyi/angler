defmodule AnglerWeb.OriginCheckTest do
  # Changes the AnglerWeb.OriginCheck application environment.
  use ExUnit.Case, async: false

  alias AnglerWeb.OriginCheck

  setup do
    original = Application.get_env(:angler, OriginCheck)
    Application.put_env(:angler, OriginCheck, hosts: ["angler.example.com", "Tunnel.Example.org"])

    on_exit(fn ->
      if original,
        do: Application.put_env(:angler, OriginCheck, original),
        else: Application.delete_env(:angler, OriginCheck)
    end)
  end

  defp allowed?(origin), do: OriginCheck.allowed?(URI.parse(origin))

  test "accepts the configured hosts" do
    assert allowed?("https://angler.example.com")
    assert allowed?("https://tunnel.example.org:8443")
    refute allowed?("https://evil.example.com")
  end

  test "accepts local names and addresses" do
    for origin <- [
          "http://localhost:4000",
          "http://nas:4000",
          "http://nas.local",
          "http://angler.lan",
          "http://box.home.arpa",
          "http://app.internal",
          "http://app.localhost",
          "http://127.0.0.1:4000",
          "http://192.168.1.20:4000",
          "http://10.0.0.5",
          "http://172.20.0.1",
          "http://169.254.1.1",
          "http://100.100.1.1",
          "http://[::1]:4000",
          "http://[fd12:3456:789a::1]:4000",
          "http://[fe80::1]"
        ] do
      assert allowed?(origin), origin
    end
  end

  test "rejects public names and addresses, including IPv6 literals" do
    for origin <- [
          "https://example.com",
          "http://93.184.215.14",
          "http://8.8.8.8:4000",
          "http://[2001:4860:4860::8888]",
          "http://[2606:4700:4700::1111]:4000",
          "http://[2001:db8::1]",
          "null",
          ""
        ] do
      refute allowed?(origin), origin
    end
  end
end
