defmodule AnglerWeb.StatusComponentsTest do
  use ExUnit.Case, async: true

  import AnglerWeb.ComponentTestHelpers
  import AnglerWeb.StatusComponents

  alias Angler.Entries.Entry

  describe "status_badge/1" do
    test "labels every status" do
      for status <- Entry.statuses() do
        html = render_html(&status_badge/1, status: status)
        assert exists?(html, "span[data-status=#{status}]")
        assert text(html, "span") =~ status_label(status)
      end
    end

    test "pulses only for work in progress" do
      assert exists?(
               render_html(&status_badge/1, status: :downloading),
               ".motion-safe\\:animate-pulse"
             )

      refute exists?(render_html(&status_badge/1, status: :done), ".motion-safe\\:animate-pulse")
    end
  end

  describe "progress_bar/1" do
    test "shows a known percentage" do
      html = render_html(&progress_bar/1, percent: 42.4, stage: :downloading)

      assert attribute(html, "[role=progressbar]", "aria-valuenow") == "42"
      assert attribute(html, "[role=progressbar] > div", "style") =~ "width: 42.4%"
    end

    test "animates when the percentage is unknown" do
      html = render_html(&progress_bar/1, percent: nil, stage: :processing)

      assert attribute(html, "[role=progressbar]", "aria-valuenow") == nil
      assert exists?(html, ".motion-safe\\:animate-indeterminate")
    end
  end

  describe "stage_steps/1" do
    defp states(status) do
      html = render_html(&stage_steps/1, id: "steps", status: status)
      html |> LazyHTML.query("li") |> LazyHTML.attribute("data-state")
    end

    test "marks earlier stages complete and the current one" do
      assert states(:queued) == ~w(current pending pending pending pending)
      assert states(:processing) == ~w(complete complete current pending pending)
      assert states(:done) == ~w(complete complete complete complete complete)
    end
  end

  test "labels and helpers" do
    assert error_kind_label(:too_large) == "Too large"
    assert error_kind_label(nil) == "Error"

    active = entry(status: :uploading)

    assert current_progress(active, %{stage: :uploading, percent: 5.0}) == %{
             stage: :uploading,
             percent: 5.0
           }

    assert current_progress(active, %{stage: :processing, percent: 5.0}) == nil
    assert progress_text(active, nil) == "Uploading"
  end
end
