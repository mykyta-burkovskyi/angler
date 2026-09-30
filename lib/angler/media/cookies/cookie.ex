defmodule Angler.Media.Cookies.Cookie do
  @moduledoc """
  One cookie of the cookies file (see `Angler.Media.Cookies`).

    * `:domain` - lowercased, without a leading dot
    * `:include_subdomains` - whether subdomains of `:domain` get the cookie too
      (otherwise only that exact host does)
    * `:path` - the path the cookie applies to (and below it)
    * `:secure` - whether it may only be sent over HTTPS
    * `:expires` - Unix time in seconds, or nil for a session cookie
    * `:name`, `:value` - checked to be valid in a `cookie` header

  The value is left out of `inspect/2`, so crash reports and logs can't show it.
  """

  @derive {Inspect, except: [:value]}
  @enforce_keys [:domain, :name, :value]
  defstruct [
    :domain,
    :name,
    :value,
    :expires,
    include_subdomains: false,
    path: "/",
    secure: false
  ]

  @type t :: %__MODULE__{
          domain: String.t(),
          include_subdomains: boolean(),
          path: String.t(),
          secure: boolean(),
          expires: integer() | nil,
          name: String.t(),
          value: String.t()
        }
end
