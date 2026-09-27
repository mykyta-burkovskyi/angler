defmodule AnglerWeb.CoreComponents do
  @moduledoc """
  Provides core UI components: flash notices, buttons, form inputs, headers,
  tables, data lists and icons.

  Everything is styled with plain Tailwind CSS utilities on top of the design
  tokens defined in `assets/css/app.css` (`bg-surface`, `text-ink`, `border-line`,
  `bg-brand`, `text-danger`, ...). The tokens switch values in the dark theme, so
  components rarely need `dark:` variants.

    * [Tailwind CSS](https://tailwindcss.com) - utilities for layout, spacing and color.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="pointer-events-auto w-full cursor-pointer overflow-hidden rounded-xl border border-line bg-surface/95 shadow-lg shadow-ink/5 backdrop-blur motion-safe:animate-fade-in"
      {@rest}
    >
      <div class="flex items-start gap-3 p-3.5">
        <span class={[
          "mt-px flex size-6 shrink-0 items-center justify-center rounded-full",
          @kind == :info && "bg-success/12 text-success",
          @kind == :error && "bg-danger/12 text-danger"
        ]}>
          <.icon :if={@kind == :info} name="hero-check-mini" class="size-4" />
          <.icon :if={@kind == :error} name="hero-exclamation-triangle-mini" class="size-4" />
        </span>
        <div class="min-w-0 flex-1 pt-0.5 text-sm">
          <p :if={@title} class="font-semibold text-ink">{@title}</p>
          <p class="break-words text-ink-muted">{msg}</p>
        </div>
        <button
          type="button"
          class="-m-1 rounded-md p-1 text-ink-faint transition hover:bg-subtle hover:text-ink"
          aria-label="close"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  Variants: `primary` (solid brand color), `secondary` (the default, outlined),
  `ghost` (no chrome until hovered) and `danger` (destructive actions).

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
      <.button variant="danger" size="sm" data-confirm="Sure?">Delete</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form)

  attr :class, :any, default: nil, doc: "extra classes, appended to the variant classes"
  attr :variant, :string, values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "md", values: ~w(sm md)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :classes, [
        "inline-flex cursor-pointer select-none items-center justify-center gap-1.5 whitespace-nowrap rounded-lg font-medium transition duration-150",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand active:translate-y-px",
        "disabled:pointer-events-none disabled:opacity-50",
        "phx-click-loading:cursor-wait phx-click-loading:opacity-70 phx-submit-loading:cursor-wait phx-submit-loading:opacity-70",
        button_size(assigns.size),
        button_variant(assigns[:variant]),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp button_size("sm"), do: "h-8 px-2.5 text-xs"
  defp button_size("md"), do: "h-9 px-3.5 text-sm"

  defp button_variant("primary"),
    do: "bg-brand text-brand-ink shadow-xs hover:bg-brand-strong"

  defp button_variant("ghost"), do: "text-ink-muted hover:bg-subtle hover:text-ink"

  defp button_variant("danger"),
    do: "bg-danger/10 text-danger ring-1 ring-inset ring-danger/25 hover:bg-danger/15"

  defp button_variant(_secondary),
    do:
      "border border-line-strong bg-surface text-ink shadow-xs hover:border-ink-faint/50 hover:bg-subtle"

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  Besides the label, an input may show a `hint` below it and a `suffix` (a unit
  such as "MB") inside it.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  <.input field={@form[:limit]} type="number" suffix="MB" hint="Larger files are refused." />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :hint, :string, default: nil, doc: "help text shown below the input"
  attr :suffix, :string, default: nil, doc: "a unit shown inside the end of text inputs"

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assigns
      |> assign_new(:checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)
      |> assign_description()

    ~H"""
    <div>
      <label for={@id} class="flex cursor-pointer items-start gap-3">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors_id}
          class={
            @class ||
              "mt-0.5 size-4 shrink-0 cursor-pointer rounded border-line-strong accent-brand focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand"
          }
          {@rest}
        />
        <span class="text-sm">
          <span class="font-medium text-ink">{@label}</span>
          <span :if={@hint} class="mt-0.5 block text-xs text-ink-faint">{@hint}</span>
        </span>
      </label>
      <.errors id={@errors_id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    assigns = assign_description(assigns)

    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <div class="relative">
        <select
          id={@id}
          name={@name}
          class={[
            @class || [field_classes(), "cursor-pointer appearance-none pr-9"],
            @errors != [] && (@error_class || field_error_classes())
          ]}
          multiple={@multiple}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={described_by(@hint_id, @errors_id)}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
        <.icon
          :if={!@multiple}
          name="hero-chevron-up-down-mini"
          class="pointer-events-none absolute top-1/2 right-2.5 size-4 -translate-y-1/2 text-ink-faint"
        />
      </div>
      <.hint :if={@hint} id={@hint_id}>{@hint}</.hint>
      <.errors id={@errors_id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    assigns = assign_description(assigns)

    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          @class || [field_classes(), "min-h-24 resize-y leading-relaxed"],
          @errors != [] && (@error_class || field_error_classes())
        ]}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={described_by(@hint_id, @errors_id)}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.hint :if={@hint} id={@hint_id}>{@hint}</.hint>
      <.errors id={@errors_id} errors={@errors} />
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    assigns = assign_description(assigns)

    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <div class="relative">
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || [field_classes(), @suffix && "pr-20"],
            @errors != [] && (@error_class || field_error_classes())
          ]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={described_by(@hint_id, @errors_id)}
          {@rest}
        />
        <span
          :if={@suffix}
          class="pointer-events-none absolute inset-y-0 right-3 flex items-center text-sm text-ink-faint"
        >
          {@suffix}
        </span>
      </div>
      <.hint :if={@hint} id={@hint_id}>{@hint}</.hint>
      <.errors id={@errors_id} errors={@errors} />
    </div>
    """
  end

  defp field_classes do
    "block w-full rounded-lg border border-line-strong bg-surface px-3 py-2 text-sm text-ink shadow-xs transition placeholder:text-ink-faint focus:border-brand focus:ring-3 focus:ring-brand/20 focus:outline-none disabled:opacity-60"
  end

  defp field_error_classes, do: "border-danger focus:border-danger focus:ring-danger/20"

  # Ids that link the hint and the errors to the input (`aria-describedby`), so
  # screen readers announce them with it.
  defp assign_description(%{id: id} = assigns) do
    assign(assigns,
      hint_id: if(id && assigns.hint, do: "#{id}-hint"),
      errors_id: if(id && assigns.errors != [], do: "#{id}-errors")
    )
  end

  defp described_by(nil, nil), do: nil
  defp described_by(hint_id, errors_id), do: Enum.join([hint_id, errors_id] -- [nil], " ")

  attr :for, :string, default: nil
  slot :inner_block, required: true

  defp label(assigns) do
    ~H"""
    <label for={@for} class="mb-1.5 block text-sm font-medium text-ink">
      {render_slot(@inner_block)}
    </label>
    """
  end

  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp hint(assigns) do
    ~H"""
    <p id={@id} class="mt-1.5 text-xs text-ink-faint">{render_slot(@inner_block)}</p>
    """
  end

  # Helper used by inputs to render their form errors
  attr :id, :string, default: nil
  attr :errors, :list, required: true

  defp errors(assigns) do
    ~H"""
    <div :if={@errors != []} id={@id}>
      <p :for={msg <- @errors} class="mt-1.5 flex items-center gap-1.5 text-sm text-danger">
        <.icon name="hero-exclamation-circle-mini" class="size-4 shrink-0" />
        {msg}
      </p>
    </div>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="flex flex-col gap-4 pb-6 sm:flex-row sm:items-end sm:justify-between">
      <div class="min-w-0">
        <h1 class="text-2xl font-semibold tracking-tight text-balance text-ink">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-ink-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc ~S"""
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-left text-sm">
        <thead class="border-b border-line text-xs text-ink-faint">
          <tr>
            <th :for={col <- @col} class="px-3 py-2 font-medium first:pl-0 last:pr-0">
              {col[:label]}
            </th>
            <th :if={@action != []} class="py-2">
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
          class="divide-y divide-line"
        >
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="transition-colors hover:bg-subtle/60"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={["px-3 py-2.5 text-ink first:pl-0 last:pr-0", @row_click && "cursor-pointer"]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 py-2.5 pl-3 font-medium">
              <div class="flex gap-3">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl id={@id} class={["divide-y divide-line text-sm", @class]}>
      <div :for={item <- @item} class="grid grid-cols-5 gap-3 py-2.5 first:pt-0 last:pb-0">
        <dt class="col-span-2 text-ink-muted">{item.title}</dt>
        <dd class="col-span-3 min-w-0 break-words text-ink">{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  ## JS Commands

  @doc "Shows the element matching `selector` with a fade and slide-in transition."
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  @doc "Hides the element matching `selector` with a fade and slide-out transition."
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # You can make use of gettext to translate error messages by
    # uncommenting and adjusting the following code:

    # if count = opts[:count] do
    #   Gettext.dngettext(AnglerWeb.Gettext, "errors", msg, msg, count, opts)
    # else
    #   Gettext.dgettext(AnglerWeb.Gettext, "errors", msg, opts)
    # end

    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
