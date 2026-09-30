defmodule Angler.Media.Instagram.RequestTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Instagram

  test "has bounded timeouts and no automatic retries" do
    request = Instagram.request(url: "https://www.instagram.com/")

    assert %{
             retry: false,
             redirect: false,
             receive_timeout: 15_000,
             request_timeout: 30_000,
             connect_options: [timeout: 15_000]
           } = request.options

    # The test configuration's :req_options apply too.
    assert request.options.plug == {Req.Test, Instagram}
  end

  test "never follows redirects, whatever the options say" do
    Req.Test.stub(Instagram, fn conn ->
      case conn.request_path do
        "/moved" ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://www.instagram.com/elsewhere")
          |> Plug.Conn.send_resp(302, "")

        "/elsewhere" ->
          Plug.Conn.send_resp(conn, 200, "followed")
      end
    end)

    request = Instagram.request(url: "https://www.instagram.com/moved", redirect: true)

    assert request.options.redirect == false
    assert {:ok, %Req.Response{status: 302}} = Req.request(request)
  end
end
