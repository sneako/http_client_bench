defmodule Bench.MixProject do
  use Mix.Project

  def project do
    [
      app: :bench_suite,
      version: "0.1.0",
      elixir: ">= 1.14.0",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Bench.Application, []}
    ]
  end

  defp deps do
    [
      finch_dep(),
      {:hackney, "~> 1.20"},
      {:gun, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:ddskerl, "~> 0.2"},
      {:nimble_csv, "~> 1.2"}
    ]
  end

  defp finch_dep do
    case System.get_env("BENCH_FINCH_SOURCE") do
      "git" ->
        git = System.get_env("BENCH_FINCH_GIT") || "https://github.com/sneako/finch.git"
        ref = System.get_env("BENCH_FINCH_REF") || "main"
        opts = [git: git]
        opts = if ref, do: Keyword.put(opts, :ref, ref), else: opts
        {:finch, opts}

      "hex" ->
        version = System.get_env("BENCH_FINCH_VERSION") || "~> 0.19"
        {:finch, version}

      "path" ->
        path = System.get_env("BENCH_FINCH_PATH") || "../../finch"
        {:finch, path: path}

      nil ->
        {:finch, git: "https://github.com/sneako/finch.git", ref: "main"}

      other ->
        raise "Unsupported BENCH_FINCH_SOURCE=#{other}"
    end
  end
end
