defmodule Angler.Media.Instagram.GraphQLTest do
  use ExUnit.Case, async: true

  import Angler.InstagramFixtures

  alias Angler.Media.Instagram.GraphQL

  @moduletag :capture_log

  test "asks for the post by media id, with the headers Instagram requires and no cookies" do
    stub_instagram(fn conn ->
      {params, conn} = form(conn)
      send(self(), {:form, params})
      javascript(conn, graphql("DdwalmrkTSK"))
    end)

    assert {:ok, %{"code" => "DdwalmrkTSK", "carousel_media" => [_, _, _]}} =
             GraphQL.fetch("DdwalmrkTSK", [])

    assert_received {:instagram_request, "POST", "www.instagram.com/api/graphql", conn}
    assert_received {:form, params}

    assert %{
             "doc_id" => "27130156389949648",
             "variables" => variables,
             "lsd" => lsd,
             "fb_api_caller_class" => "RelayModern",
             "fb_api_req_friendly_name" => "PolarisLoggedOutDesktopWWWPostRootContentQuery",
             "server_timestamps" => "true"
           } = params

    assert Jason.decode!(variables) == %{"media_id" => "3994809802840683658"}
    assert lsd != ""

    header = &Plug.Conn.get_req_header(conn, &1)
    assert header.("x-fb-lsd") == [lsd]
    assert header.("sec-fetch-site") == ["same-origin"]
    assert header.("x-ig-app-id") == ["936619743392459"]
    assert header.("referer") == ["https://www.instagram.com/p/DdwalmrkTSK/"]
    assert header.("content-type") == ["application/x-www-form-urlencoded"]
    assert header.("cookie") == []
  end

  test "classifies missing and gated posts" do
    stub_graphql(%{
      "DdwalmrkTSX" => graphql("DdwalmrkTSX"),
      "B7" => recorded("graphql_gated_pk123.json")
    })

    assert GraphQL.fetch("DdwalmrkTSX", [0, 0]) == :missing
    assert GraphQL.fetch("B7", [0, 0]) == {:gated, "Not available in your region"}

    # One request each: these answers are not retried.
    for _request <- 1..2, do: assert_received({:instagram_request, "POST", _path, _conn})
    refute_received {:instagram_request, _method, _path, _conn}
  end

  test "retries unexpected answers and failures, then gives up" do
    for {response, reason} <- [
          {&Req.Test.html(&1, "<!DOCTYPE html><html>Instagram</html>"), "the answer is not JSON"},
          {&javascript(&1, ~s({"errors":[{"message":"doc_id changed"}]})),
           "the answer has errors"},
          {&javascript(&1, ~s({"data":{"xig_polaris_media":null},"errors":[{}]})),
           "the answer has errors"},
          {&javascript(&1, ~s({"data":{"renamed":{}}})), "unexpected answer"},
          {&javascript(&1, ~s({"data":{"xig_polaris_media":{"if_not_gated_logged_out":null}}})),
           "no post in the answer"},
          {&Plug.Conn.send_resp(&1, 503, ""), "HTTP 503"},
          {&Plug.Conn.send_resp(&1, 401, "{}"), "HTTP 401"},
          {&redirect(&1, "https://www.instagram.com/"), "redirected with HTTP 302"},
          {&Req.Test.transport_error(&1, :econnrefused), "network error (econnrefused)"}
        ] do
      stub_instagram(response)
      assert GraphQL.fetch("DdwalmrkTSK", [0, 0]) == {:gave_up, reason}

      for _attempt <- 1..3, do: assert_received({:instagram_request, "POST", _path, _conn})
      refute_received {:instagram_request, _method, _path, _conn}
    end
  end

  test "stops at the first sign of rate limiting" do
    for {response, reason} <- [
          {&Plug.Conn.send_resp(&1, 429, ""), "HTTP 429"},
          {&javascript(&1, recorded_401(), 401), "HTTP 401, login required"},
          {&redirect(&1, "https://www.instagram.com/accounts/login/?next=%2Fapi%2Fgraphql"),
           "redirected to the login page"}
        ] do
      stub_instagram(response)
      assert GraphQL.fetch("DdwalmrkTSK", [0, 0]) == {:rate_limited, reason}

      assert_received {:instagram_request, "POST", _path, _conn}
      refute_received {:instagram_request, _method, _path, _conn}
    end
  end

  defp recorded_401 do
    ~s({"message":"Please wait a few minutes before you try again.","require_login":true,) <>
      ~s("igweb_rollout":true,"status":"fail"})
  end

  test "recovers when a later attempt works" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    stub_instagram(fn conn ->
      case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
        1 -> Req.Test.html(conn, "<html></html>")
        _later -> javascript(conn, graphql("Ddwoj5kBk9X"))
      end
    end)

    assert {:ok, %{"code" => "Ddwoj5kBk9X"}} = GraphQL.fetch("Ddwoj5kBk9X", [0])
    assert Agent.get(attempts, & &1) == 2
  end

  describe "classify/1" do
    test "a post, a gate (checked before the errors that come with it), a missing post" do
      assert {:ok, %{"code" => "x"}} =
               GraphQL.classify(%{
                 "data" => %{
                   "xig_polaris_media" => %{"if_not_gated_logged_out" => %{"code" => "x"}}
                 }
               })

      assert recorded("graphql_gated_pk123.json") |> Jason.decode!() |> GraphQL.classify() ==
               {:gated, "Not available in your region"}

      gate = %{"title" => "", "description" => "It can't be seen by certain audiences."}

      assert GraphQL.classify(%{"data" => %{"xig_polaris_media" => %{"gating_ruling" => gate}}}) ==
               {:gated, "It can't be seen by certain audiences."}

      assert GraphQL.classify(%{"data" => %{"xig_polaris_media" => %{"gating_ruling" => %{}}}}) ==
               {:gated, nil}

      assert GraphQL.classify(%{"data" => %{"xig_polaris_media" => nil}, "errors" => []}) ==
               :missing
    end

    test "anything else is retried" do
      for answer <- [%{"data" => nil}, %{"data" => %{}}, %{}, [], "text", nil] do
        assert {:retry, _reason} = GraphQL.classify(answer)
      end
    end
  end
end
