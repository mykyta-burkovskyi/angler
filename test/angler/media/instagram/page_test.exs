defmodule Angler.Media.Instagram.PageTest do
  use ExUnit.Case, async: true

  import Angler.InstagramFixtures

  alias Angler.Media.Instagram.{GraphQL, Page}

  describe "read/1" do
    test "reads the post from the data blob of a recorded page" do
      assert {:ok, %{"code" => "DdwalmrkTSK", "carousel_media" => [_, _, _]} = media} =
               Page.read(recorded("page_carousel_DdwalmrkTSK.html"))

      assert get_in(media, ["caption", "text"]) =~ "we said yes"
    end

    test "reads Instagram's error page as a missing post" do
      assert Page.read(recorded("page_not_found_DdwalmrkTSX.html")) == :missing
    end

    test "classifies the data like a GraphQL answer" do
      gated =
        Jason.encode!(%{
          "require" => [
            [
              "RelayPrefetchedStreamCache",
              "next",
              [],
              [
                "adp_x",
                %{
                  "__bbox" => %{
                    "result" => %{
                      "data" => %{
                        "xig_polaris_media" => %{
                          "if_not_gated_logged_out" => nil,
                          "gating_ruling" => %{"title" => "Gated"}
                        }
                      }
                    }
                  }
                }
              ]
            ]
          ]
        })

      assert Page.read(page_with(gated)) == {:gated, "Gated"}
    end

    test "keeps the errors next to the data: a null post with errors is not missing" do
      result = %{
        "data" => %{"xig_polaris_media" => nil},
        "errors" => [%{"message" => "A server error field_exception occured."}]
      }

      assert GraphQL.classify(result) == {:retry, "the answer has errors"}

      assert Page.read(page_with(relay_blob(result))) ==
               {:gave_up, "the post page: the answer has errors"}

      # Without errors, the post is missing.
      assert Page.read(page_with(relay_blob(Map.delete(result, "errors")))) == :missing
    end

    test "gives up on pages without post data" do
      for html <- [
            "<!DOCTYPE html><html><body>Log in to Instagram</body></html>",
            page_with(~s({"require":[["qplTimingsServerJS",null,null,["1","htmlStart"]]]})),
            page_with(~s({"xig_polaris_media": not json})),
            page_with(~s({"data":{"xig_polaris_media":{"renamed":{}}}}))
          ] do
        assert {:gave_up, _reason} = Page.read(html)
      end
    end
  end

  # A RelayPrefetchedStreamCache blob embedding a GraphQL `result`.
  defp relay_blob(result) do
    Jason.encode!(%{
      "require" => [
        [
          "RelayPrefetchedStreamCache",
          "next",
          [],
          ["adp_x", %{"__bbox" => %{"complete" => true, "result" => result}}]
        ]
      ]
    })
  end

  defp page_with(blob) do
    ~s(<html><body><script type="application/json" data-content-len="1" data-sjs>) <>
      blob <> "</script></body></html>"
  end

  describe "fetch/1" do
    test "loads the post page like a browser navigation, without cookies" do
      stub_instagram(&Req.Test.html(&1, recorded("page_carousel_DdwalmrkTSK.html")))

      assert {:ok, %{"code" => "DdwalmrkTSK"}} = Page.fetch("DdwalmrkTSK")
      assert_received {:instagram_request, "GET", "www.instagram.com/p/DdwalmrkTSK/", conn}

      header = &Plug.Conn.get_req_header(conn, &1)
      assert header.("sec-fetch-mode") == ["navigate"]
      assert header.("sec-fetch-site") == ["none"]
      assert header.("sec-fetch-dest") == ["document"]
      assert ["text/html" <> _] = header.("accept")
      assert header.("cookie") == []
    end

    test "gives up when the page can't be loaded, without retrying" do
      for {response, reason} <- [
            {&redirect(&1, "https://www.instagram.com/accounts/login/?next=/p/x/"),
             "the post page redirected to the login page"},
            {&redirect(&1, "https://www.instagram.com/", 301),
             "the post page redirected with HTTP 301"},
            {&Plug.Conn.send_resp(&1, 500, ""), "the post page answered with HTTP 500"},
            {&Req.Test.transport_error(&1, :timeout), "the post page: network error (timeout)"}
          ] do
        stub_instagram(response)
        assert Page.fetch("DdwalmrkTSK") == {:gave_up, reason}
        assert_received {:instagram_request, "GET", _path, _conn}
        refute_received {:instagram_request, _method, _path, _conn}
      end
    end
  end
end
