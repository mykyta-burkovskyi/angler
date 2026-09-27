defmodule AnglerWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 1]
  import Phoenix.LiveViewTest
  import AnglerWeb.CoreComponents

  defp render_html(component, assigns) do
    component |> render_component(assigns) |> LazyHTML.from_fragment()
  end

  defp text(html, selector) do
    html
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp exists?(html, selector), do: html |> LazyHTML.query(selector) |> Enum.count() > 0

  defp attribute(html, selector, name) do
    html |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp slot(content), do: [%{inner_block: fn _, _ -> content end}]

  describe "flash/1" do
    test "renders the message of its kind" do
      html = render_html(&flash/1, kind: :info, flash: %{"info" => "Saved"})

      assert text(html, "#flash-info[role=alert]") =~ "Saved"
      assert exists?(html, "#flash-info .hero-check-mini")
    end

    test "renders nothing without a message" do
      assert render_component(&flash/1, kind: :error, flash: %{}) =~ ~r/^\s*$/
    end

    test "renders a title and inner content" do
      html =
        render_html(&flash/1,
          kind: :error,
          id: "oops",
          title: "Oh no",
          inner_block: slot("Broken")
        )

      assert text(html, "#oops") =~ "Oh no"
      assert text(html, "#oops") =~ "Broken"
      assert exists?(html, "#oops .hero-exclamation-triangle-mini")
    end
  end

  describe "button/1" do
    test "renders a button styled by variant and size" do
      html =
        render_html(&button/1,
          variant: "primary",
          size: "sm",
          class: "w-full",
          inner_block: slot("Save")
        )

      assert text(html, "button") == "Save"
      class = attribute(html, "button", "class")
      assert class =~ "bg-brand"
      assert class =~ "h-8"
      assert class =~ "w-full"
    end

    test "defaults to the secondary style" do
      html = render_html(&button/1, inner_block: slot("Cancel"))
      assert attribute(html, "button", "class") =~ "border-line-strong"

      html = render_html(&button/1, variant: "danger", inner_block: slot("Delete"))
      assert attribute(html, "button", "class") =~ "text-danger"
    end

    test "renders a link when navigating" do
      html = render_html(&button/1, navigate: "/settings", inner_block: slot("Settings"))
      assert attribute(html, "a", "href") == "/settings"
    end
  end

  describe "input/1" do
    test "renders a labelled text input with hint, suffix and errors" do
      html =
        render_html(&input/1,
          id: "limit",
          name: "limit",
          label: "Limit",
          value: 50,
          type: "number",
          suffix: "MB",
          hint: "Upload size",
          errors: ["is too big"]
        )

      assert text(html, "label[for=limit]") == "Limit"
      assert attribute(html, "input#limit", "value") == "50"
      assert attribute(html, "input#limit", "class") =~ "border-danger"
      assert text(html, "div") =~ "MB"
      assert text(html, "div") =~ "Upload size"
      assert text(html, "p.text-danger") =~ "is too big"
    end

    test "takes name, id, value and used-input errors from a form field" do
      form = to_form(%{"email" => "a@b.c"})
      html = render_html(&input/1, field: form[:email], type: "email")

      assert attribute(html, "input#email", "name") == "email"
      assert attribute(html, "input#email", "value") == "a@b.c"
    end

    test "renders a checkbox with a hidden false value" do
      html =
        render_html(&input/1,
          id: "on",
          name: "on",
          type: "checkbox",
          value: true,
          label: "Enabled"
        )

      assert attribute(html, "input[type=hidden]", "value") == "false"
      assert attribute(html, "input#on", "checked") == ""
      assert text(html, "label") =~ "Enabled"
    end

    test "renders a select with the current option" do
      html =
        render_html(&input/1,
          id: "mode",
          name: "mode",
          type: "select",
          options: [{"None", :none}, {"All", :all}],
          value: :all,
          prompt: "Pick one"
        )

      assert attribute(html, "option[selected]", "value") == "all"
      assert text(html, "option[value='']") == "Pick one"
    end

    test "renders a textarea" do
      html =
        render_html(&input/1, id: "hosts", name: "hosts", type: "textarea", value: "a.com\nb.com")

      assert text(html, "textarea#hosts") == "a.com b.com"
    end

    test "links the hint and errors to the input for assistive technology" do
      for {type, tag, attrs} <- [
            {"number", "input", []},
            {"select", "select", [options: [{"All", :all}]]},
            {"textarea", "textarea", []}
          ] do
        base = [id: "field", name: "field", type: type, value: nil] ++ attrs

        html = render_html(&input/1, base ++ [hint: "Upload size", errors: ["is too big"]])

        assert attribute(html, "#{tag}#field", "aria-describedby") == "field-hint field-errors"
        assert attribute(html, "#{tag}#field", "aria-invalid") == "true"
        assert text(html, "#field-hint") == "Upload size"
        assert text(html, "#field-errors") == "is too big"

        html = render_html(&input/1, base ++ [hint: "Upload size"])
        assert attribute(html, "#{tag}#field", "aria-describedby") == "field-hint"
        assert attribute(html, "#{tag}#field", "aria-invalid") == nil

        html = render_html(&input/1, base)
        assert attribute(html, "#{tag}#field", "aria-describedby") == nil
      end

      html =
        render_html(&input/1,
          id: "on",
          name: "on",
          type: "checkbox",
          value: nil,
          errors: ["is invalid"]
        )

      assert attribute(html, "input#on", "aria-describedby") == "on-errors"
      assert attribute(html, "input#on", "aria-invalid") == "true"
      assert text(html, "#on-errors") == "is invalid"
    end

    test "renders a hidden input" do
      html = render_html(&input/1, id: "h", name: "h", type: "hidden", value: "1")
      assert attribute(html, "input[type=hidden]#h", "value") == "1"
    end
  end

  test "header/1 renders title, subtitle and actions" do
    html =
      render_html(&header/1,
        inner_block: slot("Settings"),
        subtitle: slot("All of them"),
        actions: slot("Save")
      )

    assert text(html, "h1") == "Settings"
    assert text(html, "p") == "All of them"
    assert text(html, "header") =~ "Save"
  end

  test "table/1 renders columns and actions" do
    html =
      render_html(&table/1,
        id: "tools",
        rows: [%{name: "ffmpeg"}, %{name: "yt-dlp"}],
        col: [%{label: "Tool", inner_block: fn _, row -> row.name end}],
        action: [%{inner_block: fn _, _ -> "Edit" end}]
      )

    assert text(html, "th") =~ "Tool"
    assert html |> LazyHTML.query("tbody#tools tr") |> Enum.count() == 2
    assert text(html, "tbody") =~ "yt-dlp"
    assert text(html, "tbody") =~ "Edit"
  end

  test "list/1 renders a description list" do
    html =
      render_html(&list/1,
        id: "details",
        item: [%{title: "Title", inner_block: fn _, _ -> "Cats" end}]
      )

    assert text(html, "#details dt") == "Title"
    assert text(html, "#details dd") == "Cats"
  end

  test "icon/1 renders a heroicon" do
    html = render_html(&icon/1, name: "hero-x-mark", class: "size-5")
    assert attribute(html, "span", "class") == "hero-x-mark size-5"
    assert attribute(html, "span", "aria-hidden") == "true"
  end

  test "translate_error/1 and translate_errors/2 interpolate options" do
    assert translate_error({"must be at least %{count}", count: 5}) == "must be at least 5"

    errors = [name: {"is invalid", []}, age: {"must be %{n}", n: 1}]
    assert translate_errors(errors, :age) == ["must be 1"]
  end
end
