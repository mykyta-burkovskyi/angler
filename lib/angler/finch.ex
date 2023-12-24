defmodule Angler.Finch do
  use Tesla

  adapter(Tesla.Adapter.Finch, name: __MODULE__, receive_timeout: 40_000)
end
