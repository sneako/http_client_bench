defmodule Bench.Tuner do
  @moduledoc false

  alias Bench.{Config, ResultWriter, Runner}
  alias NimbleCSV.RFC4180, as: CSV
  require Logger

  def enabled? do
    env_truthy?("BENCH_TUNE")
  end

  def run(%Config{} = config) do
    if config.clients != [:finch] do
      Logger.info("BENCH_TUNE enabled; forcing clients to finch")
    end

    config = %{config | clients: [:finch]}
    tune_dir = Path.join(config.result_dir, "tune")
    File.mkdir_p!(tune_dir)

    pool_sizes = tune_pool_sizes()
    pool_counts = tune_pool_counts()
    scenario_names = Enum.map(config.scenarios, & &1.name)

    rows =
      for pool_size <- pool_sizes, pool_count <- pool_counts, reduce: [] do
        acc ->
          Logger.info("Tuning finch pool_size=#{pool_size} pool_count=#{pool_count}")

          combo_dir = Path.join(tune_dir, "ps#{pool_size}_pc#{pool_count}")

          combo_config = %{
            config
            | pool_size: pool_size,
              pool_count: pool_count,
              result_dir: combo_dir
          }

          {:ok, results} = Runner.run(combo_config)
          :ok = ResultWriter.write(results, combo_config)

          acc ++ rows_for_results(results, pool_size, pool_count)
      end

    winners = winners(rows, scenario_names)

    File.write!(Path.join(tune_dir, "tune.csv"), tune_csv(rows))
    File.write!(Path.join(tune_dir, "tune_winners.csv"), winners_csv(winners))

    {:ok, %{result_dir: config.result_dir, tune_dir: tune_dir}}
  end

  defp tune_pool_sizes do
    env_list_int("BENCH_TUNE_POOL_SIZES", [50, 100, 200])
  end

  defp tune_pool_counts do
    case env_list_int("BENCH_TUNE_POOL_COUNTS", []) do
      [] ->
        cpu = cpu_count()

        [
          div(cpu, 4),
          div(cpu, 2),
          cpu,
          cpu * 2,
          cpu * 4
        ]
        |> Enum.map(&max(1, &1))
        |> uniq_preserve_order()

      counts ->
        counts
    end
  end

  defp cpu_count do
    case :erlang.system_info(:logical_processors_available) do
      count when is_integer(count) and count > 0 ->
        count

      _ ->
        case :erlang.system_info(:schedulers_online) do
          count when is_integer(count) and count > 0 -> count
          _ -> System.schedulers_online()
        end
    end
  end

  defp rows_for_results(results, pool_size, pool_count) do
    Enum.map(results, fn result ->
      %{
        pool_size: pool_size,
        pool_count: pool_count,
        scenario: result.scenario,
        rps: result.rps,
        errors: result.errors,
        qualified: result.errors == 0
      }
    end)
  end

  defp winners(rows, scenario_names) do
    by_scenario =
      rows
      |> Enum.group_by(& &1.scenario)

    Enum.map(scenario_names, fn scenario ->
      candidates =
        by_scenario
        |> Map.get(scenario, [])
        |> Enum.filter(& &1.qualified)

      case Enum.max_by(candidates, & &1.rps, fn -> nil end) do
        nil ->
          %{
            scenario: scenario,
            pool_size: nil,
            pool_count: nil,
            rps: nil,
            errors: nil,
            qualified: false
          }

        winner ->
          %{
            scenario: scenario,
            pool_size: winner.pool_size,
            pool_count: winner.pool_count,
            rps: winner.rps,
            errors: winner.errors,
            qualified: true
          }
      end
    end)
  end

  defp tune_csv(rows) do
    header = ["pool_size", "pool_count", "scenario", "rps", "errors", "qualified"]
    data = Enum.map(rows, &row_to_list/1)
    CSV.dump_to_iodata([header | data])
  end

  defp winners_csv(rows) do
    header = ["scenario", "pool_size", "pool_count", "rps", "errors", "qualified"]
    data = Enum.map(rows, &winner_to_list/1)
    CSV.dump_to_iodata([header | data])
  end

  defp row_to_list(row) do
    [
      format_field(row.pool_size),
      format_field(row.pool_count),
      format_field(row.scenario),
      format_field(row.rps),
      format_field(row.errors),
      format_field(row.qualified)
    ]
  end

  defp winner_to_list(row) do
    [
      format_field(row.scenario),
      format_field(row.pool_size),
      format_field(row.pool_count),
      format_field(row.rps),
      format_field(row.errors),
      format_field(row.qualified)
    ]
  end

  defp env_truthy?(key) do
    case System.get_env(key) do
      nil -> false
      "" -> false
      value -> value in ["1", "true", "TRUE", "yes", "YES"]
    end
  end

  defp env_list_int(key, default) do
    case System.get_env(key) do
      nil ->
        default

      "" ->
        default

      value ->
        values =
          value
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&parse_int/1)
          |> Enum.filter(&(&1 > 0))
          |> uniq_preserve_order()

        if values == [], do: default, else: values
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp uniq_preserve_order(list) do
    Enum.reduce(list, [], fn item, acc ->
      if item in acc, do: acc, else: acc ++ [item]
    end)
  end

  defp format_field(nil), do: ""
  defp format_field(value) when is_binary(value), do: value
  defp format_field(value) when is_atom(value), do: Atom.to_string(value)
  defp format_field(value) when is_integer(value), do: Integer.to_string(value)

  defp format_field(value) when is_float(value),
    do: :io_lib.format("~.4f", [value]) |> IO.iodata_to_binary()

  defp format_field(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp format_field(value), do: to_string(value)
end
