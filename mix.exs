defmodule Angler.MixProject do
  use Mix.Project

  def project do
    [
      app: :angler,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :wx, :observer, :runtime_tools],
      mod: {Angler.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telegram, github: "visciang/telegram", tag: "1.2.1"},
      {:bandit, "~> 1.3"},
      {:finch, "~> 0.18"},
      {:uuid, "~> 1.1"}
    ]
  end
end
