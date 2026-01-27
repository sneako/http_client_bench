defmodule Mix.Tasks.Bench.Run do
  @moduledoc """
  Run the Finch benchmark suite.
  """

  use Mix.Task

  @shortdoc "Run the Finch benchmark suite"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    ensure_started([:finch, :hackney, :gun, :ddskerl])

    config = Bench.Config.load()

    {:ok, results} = Bench.Runner.run(config)
    :ok = Bench.ResultWriter.write(results, config)
    Mix.shell().info("Results written to #{config.result_dir}")
  end

  defp ensure_started(apps) do
    Enum.each(apps, fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
      end
    end)
  end
end
