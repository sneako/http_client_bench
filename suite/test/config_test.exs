defmodule Bench.ConfigTest do
  use ExUnit.Case, async: false

  setup do
    keys = [
      "BENCH_CLIENTS",
      "BENCH_SCENARIOS",
      "BENCH_RESULTS_DIR",
      "BENCH_SERVER_HOST",
      "BENCH_SERVER_PORT"
    ]

    original = for key <- keys, into: %{}, do: {key, System.get_env(key)}

    on_exit(fn ->
      Enum.each(original, fn {key, value} ->
        case value do
          nil -> System.delete_env(key)
          _ -> System.put_env(key, value)
        end
      end)
    end)

    :ok
  end

  test "defaults include known clients" do
    System.delete_env("BENCH_CLIENTS")
    config = Bench.Config.load()

    assert :finch in config.clients
    assert :hackney in config.clients
    assert :gun in config.clients
  end

  test "filters scenarios by name" do
    System.put_env("BENCH_SCENARIOS", "health,small")
    config = Bench.Config.load()

    assert Enum.map(config.scenarios, & &1.name) == ["health", "small"]
  end
end
