defmodule AnglerWeb.OriginCheck do
  @moduledoc """
  Websocket origin policy for the dashboard (`check_origin` MFA).

  The app usually sits behind a TLS-terminating proxy for Telegram's webhook, while
  the dashboard may also be opened directly on the LAN (`http://nas:4000`). A single
  configured host (Phoenix's default) or `:conn` (which compares scheme and port)
  cannot express that, so an origin is accepted when its host is:

    * the host of `PUBLIC_URL`,
    * listed in `ALLOWED_ORIGINS` (comma separated hosts),
    * `localhost`, a loopback/private/link-local IP address, a single-label name
      (`nas`) or a `.local`/`.lan`/`.home.arpa`/`.internal` name.

  Cross-site websocket hijacking needs a malicious page served from one of those
  origins, which a remote attacker does not control.
  """

  @local_suffixes ~w(.local .lan .home.arpa .internal .localhost)

  @spec allowed?(URI.t()) :: boolean()
  def allowed?(%URI{host: host}) when is_binary(host) and host != "" do
    host = String.downcase(host)

    host in configured_hosts() or host == "localhost" or local_ip?(host) or
      single_label?(host) or String.ends_with?(host, @local_suffixes)
  end

  def allowed?(_origin), do: false

  defp configured_hosts do
    Application.get_env(:angler, __MODULE__, [])
    |> Keyword.get(:hosts, [])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&String.downcase/1)
  end

  # IPv6 literals have no dots either; they pass only as local addresses.
  defp single_label?(host), do: not String.contains?(host, [".", ":"])

  defp local_ip?(host) do
    case :inet.parse_address(String.to_charlist(String.trim(host, "[") |> String.trim("]"))) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, b, _, _}} when b in 16..31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {169, 254, _, _}} -> true
      {:ok, {100, b, _, _}} when b in 64..127 -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {a, _, _, _, _, _, _, _}} when a in 0xFC00..0xFDFF or a in 0xFE80..0xFEBF -> true
      _ -> false
    end
  end
end
