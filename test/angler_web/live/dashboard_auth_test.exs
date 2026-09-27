defmodule AnglerWeb.DashboardAuthTest do
  # Not async: one test rotates the configured password.
  use AnglerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AnglerWeb.DashboardAuth

  defp authenticate(conn, password \\ "test-password") do
    put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth("admin", password))
  end

  test "challenges requests without credentials", %{conn: conn} do
    for path <- [~p"/", ~p"/settings", ~p"/entries/#{Ecto.UUID.generate()}"] do
      conn = get(conn, path)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Angler")]
    end
  end

  test "rejects a wrong password", %{conn: conn} do
    conn = conn |> authenticate("wrong") |> get(~p"/")
    assert conn.status == 401
  end

  test "serves the dashboard pages with valid credentials", %{conn: conn} do
    conn = authenticate(conn)

    assert html_response(get(conn, ~p"/"), 200) =~ "Entries"
    assert html_response(get(conn, ~p"/settings"), 200) =~ "Settings"
  end

  test "does not mount without the session marker" do
    socket = %Phoenix.LiveView.Socket{endpoint: AnglerWeb.Endpoint}

    assert {:halt, %{redirected: {:redirect, %{to: "/"}}}} =
             DashboardAuth.on_mount(:default, %{}, %{}, socket)

    assert {:halt, %{redirected: {:redirect, %{to: "/"}}}} =
             DashboardAuth.on_mount(:default, %{}, %{"dashboard_auth" => "forged"}, socket)
  end

  test "drops live sessions when the password changes", %{conn: conn} do
    conn = conn |> authenticate() |> get(~p"/")
    assert html_response(conn, 200)

    config = Application.get_env(:angler, DashboardAuth)
    on_exit(fn -> Application.put_env(:angler, DashboardAuth, config) end)
    Application.put_env(:angler, DashboardAuth, Keyword.put(config, :password, "rotated"))

    assert {:error, {:redirect, %{to: "/"}}} = live(conn)
  end
end
