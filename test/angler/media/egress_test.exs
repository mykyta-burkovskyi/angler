defmodule Angler.Media.EgressTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Egress

  defp parse(address) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(address))
    ip
  end

  describe "public?/1" do
    for address <- [
          "93.184.215.14",
          "8.8.8.8",
          "1.1.1.1",
          "172.15.255.255",
          "172.32.0.1",
          "100.63.255.255",
          "100.128.0.1",
          "192.169.0.1",
          "2606:4700:4700::1111",
          "2a00:1450:4001:80b::200e",
          "::ffff:8.8.8.8",
          "64:ff9b::808:808"
        ] do
      test "allows #{address}" do
        assert Egress.public?(parse(unquote(address)))
      end
    end

    for address <- [
          # loopback, "this network", private, CGNAT, link-local (cloud metadata)
          "127.0.0.1",
          "127.255.0.9",
          "0.0.0.0",
          "10.1.2.3",
          "172.16.0.1",
          "172.18.0.3",
          "172.31.255.255",
          "192.168.1.20",
          "100.64.0.1",
          "100.127.255.255",
          "169.254.169.254",
          # special purpose, documentation, benchmarking, multicast, reserved, broadcast
          "192.0.0.8",
          "192.0.2.1",
          "198.18.0.1",
          "198.51.100.7",
          "203.0.113.9",
          "224.0.0.251",
          "239.255.255.250",
          "240.0.0.1",
          "255.255.255.255",
          # IPv6 loopback, unspecified, unique local, link-local, multicast, site-local
          "::1",
          "::",
          "fd12:3456:789a::1",
          "fc00::1",
          "fe80::1",
          "ff02::1",
          "fec0::1",
          # IPv4-mapped, IPv4-compatible and NAT64 forms of private addresses
          "::ffff:127.0.0.1",
          "::ffff:192.168.1.20",
          "::127.0.0.1",
          "64:ff9b::a00:1",
          "64:ff9b:1::1",
          # special purpose blocks inside 2000::/3: Teredo, documentation, 6to4
          "2001::1",
          "2001:db8::1",
          "2002:c0a8:0114::1",
          "3fff::1",
          # outside global unicast
          "4000::1",
          "100::1"
        ] do
      test "blocks #{address}" do
        refute Egress.public?(parse(unquote(address)))
      end
    end
  end

  describe "resolve/1 and check/1" do
    test "take IP literals as they are, including short forms" do
      assert Egress.resolve("192.168.1.20") == {:ok, [{192, 168, 1, 20}]}
      assert Egress.resolve("::1") == {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}
      assert Egress.resolve("127.1") == {:ok, [{127, 0, 0, 1}]}
      assert Egress.resolve("2130706433") == {:ok, [{127, 0, 0, 1}]}

      assert Egress.check("8.8.8.8") == {:ok, [{8, 8, 8, 8}]}
      assert Egress.check("127.1") == {:error, :blocked}
      assert Egress.check("0x7f.0.0.1") == {:error, :blocked}
    end

    test "block names that resolve to private addresses" do
      assert {:ok, [_ | _] = addresses} = Egress.resolve("localhost")
      refute Enum.any?(addresses, &Egress.public?/1)
      assert Egress.check("localhost") == {:error, :blocked}
    end

    test "report names that do not resolve" do
      assert Egress.check("no-such-host.invalid") == {:error, :nxdomain}
    end
  end
end
