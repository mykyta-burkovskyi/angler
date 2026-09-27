defmodule Angler.Media.Egress do
  @moduledoc """
  Decides which network addresses downloads may reach (see `Angler.Media.EgressProxy`).

  Only public internet addresses are allowed. Blocked are loopback, "this network",
  private (RFC 1918, where Docker networks and compose services live), carrier-grade
  NAT, link-local (cloud metadata endpoints), documentation, benchmarking, multicast
  and reserved IPv4 ranges, and every IPv6 address outside global unicast `2000::/3`
  (loopback, unique local, link-local, multicast, ...) plus the special-purpose,
  documentation and 6to4 blocks inside it. IPv4-mapped (`::ffff:a.b.c.d`) and NAT64
  (`64:ff9b::a.b.c.d`) addresses are judged by their IPv4 address.

  Setting `config :angler, Angler.Media, allow_private_networks: true` turns the
  check off (`ALLOW_PRIVATE_NETWORK_DOWNLOADS=true`).
  """

  import Bitwise

  @blocked_ipv4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  # Inside global unicast 2000::/3: IETF special purpose (incl. Teredo),
  # documentation, 6to4 and the newer documentation block.
  @blocked_ipv6 [
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    {{0x3FFF, 0, 0, 0, 0, 0, 0, 0}, 20}
  ]

  @resolve_timeout :timer.seconds(10)

  @doc "Whether private network addresses are allowed (`:allow_private_networks`)."
  @spec private_networks_allowed?() :: boolean()
  def private_networks_allowed?, do: Angler.Media.config(:allow_private_networks, false) == true

  @doc "Whether `address` is a public internet address that downloads may reach."
  @spec public?(:inet.ip_address()) :: boolean()
  def public?({a, b, c, d} = address)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
      do: not Enum.any?(@blocked_ipv4, &in_range?(address, &1))

  def public?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: public?(ipv4(high, low))
  def public?({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: public?(ipv4(high, low))

  def public?({a, _, _, _, _, _, _, _} = address) when a in 0x2000..0x3FFF,
    do: not Enum.any?(@blocked_ipv6, &in_range?(address, &1))

  def public?(_address), do: false

  defp ipv4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp in_range?(address, {network, prefix_length}) do
    <<prefix::bitstring-size(^prefix_length), _::bitstring>> = to_bits(address)
    <<network_prefix::bitstring-size(^prefix_length), _::bitstring>> = to_bits(network)
    prefix == network_prefix
  end

  defp to_bits({a, b, c, d}), do: <<a, b, c, d>>

  defp to_bits({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  @doc """
  Resolves `host` (a name or an IPv4/IPv6 literal, without brackets) to all of its
  IPv4 and IPv6 addresses.
  """
  @spec resolve(String.t()) :: {:ok, [:inet.ip_address(), ...]} | {:error, :nxdomain}
  def resolve(host) do
    host = String.to_charlist(host)

    case :inet.parse_address(host) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _reason} ->
        addresses =
          for family <- [:inet, :inet6],
              {:ok, addresses} <- [:inet.getaddrs(host, family, @resolve_timeout)],
              address <- addresses,
              uniq: true,
              do: address

        if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
    end
  end

  @doc """
  Resolves `host` and returns its addresses when every one of them is public, so
  the caller connects to exactly the addresses that were checked (a second lookup
  could return different ones).
  """
  @spec check(String.t()) ::
          {:ok, [:inet.ip_address(), ...]} | {:error, :blocked | :nxdomain}
  def check(host) do
    with {:ok, addresses} <- resolve(host) do
      if Enum.all?(addresses, &public?/1), do: {:ok, addresses}, else: {:error, :blocked}
    end
  end
end
