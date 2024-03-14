defmodule Angler.Angles.Angle do
  @callback is_matching_url?(URI.t()) :: boolean()
  @callback fish_out(URI.t()) :: [String.t()]
end
