defmodule Angler.Media.Error do
  @moduledoc """
  A media step (download, probe, transcode) failed.

  `:kind` is one of `Angler.Entries.Entry.error_kinds/0` and drives retry decisions
  and what is shown to users; `:message` is a short human readable explanation
  (e.g. the relevant `ERROR:` line from yt-dlp); `:output` optionally holds the tail
  of the tool output for the dashboard.
  """
  defexception [:kind, :message, :output]

  @type t :: %__MODULE__{
          kind: Angler.Entries.Entry.error_kind(),
          message: String.t(),
          output: String.t() | nil
        }

  @doc "Builds an error; `output` is the relevant tail of the tool output, if any."
  @spec new(Angler.Entries.Entry.error_kind(), String.t(), String.t() | nil) :: t()
  def new(kind, message, output \\ nil),
    do: %__MODULE__{kind: kind, message: message, output: output}
end
