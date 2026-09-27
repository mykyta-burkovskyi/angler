defmodule AnglerWeb.DashboardAuth do
  @moduledoc """
  HTTP basic auth for the dashboard.

  As a plug it challenges the browser and, on success, stores a fingerprint of the
  configured credentials in the session. As an `on_mount` hook it re-checks that
  fingerprint, because the LiveView websocket and live navigation within a
  `live_session` never pass through the router pipeline. Changing the password
  invalidates existing sessions.

  Configured with `config :angler, AnglerWeb.DashboardAuth, username: ..., password: ...`.
  """
  @behaviour Plug

  import Plug.Conn

  @session_key "dashboard_auth"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {username, password} = credentials()

    conn =
      Plug.BasicAuth.basic_auth(conn, username: username, password: password, realm: "Angler")

    if conn.halted do
      conn
    else
      put_session(conn, @session_key, fingerprint(username, password))
    end
  end

  def on_mount(:default, _params, session, socket) do
    {username, password} = credentials()
    expected = fingerprint(username, password)

    case session do
      %{@session_key => value} when is_binary(value) ->
        if Plug.Crypto.secure_compare(value, expected),
          do: {:cont, socket},
          else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  defp credentials do
    config = Application.get_env(:angler, __MODULE__, [])

    case {config[:username], config[:password]} do
      {username, password} when is_binary(username) and is_binary(password) and password != "" ->
        {username, password}

      _ ->
        raise "dashboard credentials are not configured (DASHBOARD_USERNAME / DASHBOARD_PASSWORD)"
    end
  end

  defp fingerprint(username, password) do
    secret = AnglerWeb.Endpoint.config(:secret_key_base)

    :crypto.mac(:hmac, :sha256, secret, "dashboard:" <> username <> ":" <> password)
    |> Base.url_encode64(padding: false)
  end
end
