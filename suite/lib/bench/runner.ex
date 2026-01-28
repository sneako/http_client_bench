defmodule Bench.Runner do
  @moduledoc false

  alias Bench.ClientRegistry
  alias Bench.Metrics
  alias Bench.Result
  require Logger

  def run(config) do
    client_modules = ClientRegistry.resolve(config.clients)

    results =
      Enum.flat_map(client_modules, fn client_module ->
        log_info("Starting client #{client_module.id()}")
        case client_module.setup(config) do
          {:ok, state} ->
            scenario_results =
              Enum.map(config.scenarios, fn scenario ->
                log_info("Running #{client_module.id()} scenario #{scenario.name}")
                run_scenario(client_module, state, config, scenario)
              end)

            _ = client_module.teardown(state)
            scenario_results

          {:error, _reason} ->
            [
              %Result{
                client: client_module.id(),
                scenario: "setup",
                errors: 1,
                duration_s: 0.0,
                rps: 0.0
              }
            ]
        end
      end)

    {:ok, results}
  end

  defp log_info(message), do: Logger.info(message)

  defp run_scenario(client_module, state, config, scenario) do
    warmup_ms = config.warmup_s * 1000
    duration_ms = config.duration_s * 1000

    if warmup_ms > 0 do
      run_phase(
        warmup_ms,
        config.request_timeout_ms,
        config.concurrency,
        client_module,
        state,
        scenario,
        nil
      )
    end

    metrics = Metrics.new(config)
    start_us = System.monotonic_time(:microsecond)

    run_phase(
      duration_ms,
      config.request_timeout_ms,
      config.concurrency,
      client_module,
      state,
      scenario,
      metrics
    )

    end_us = System.monotonic_time(:microsecond)
    elapsed_s = max(end_us - start_us, 0) / 1_000_000

    snapshot = Metrics.snapshot(metrics)
    rps = if elapsed_s > 0, do: snapshot.total / elapsed_s, else: 0.0

    %Result{
      client: client_module.id(),
      scenario: scenario.name,
      requests: snapshot.total,
      errors: snapshot.errors,
      duration_s: elapsed_s,
      rps: rps,
      min_us: snapshot.min,
      max_us: snapshot.max,
      mean_us: snapshot.mean,
      p50_us: snapshot.p50,
      p90_us: snapshot.p90,
      p99_us: snapshot.p99,
      error_reasons: snapshot.error_reasons
    }
  end

  defp run_phase(duration_ms, request_timeout_ms, concurrency, client_module, state, scenario, metrics) do
    deadline = System.monotonic_time(:millisecond) + duration_ms

    tasks =
      1..concurrency
      |> Enum.map(fn _ ->
        Task.async(fn ->
          seed_rand()
          worker_loop(deadline, client_module, state, scenario, metrics)
        end)
      end)

    await_timeout = duration_ms + request_timeout_ms + 10_000

    Enum.each(tasks, fn task ->
      _ = Task.await(task, await_timeout)
    end)
  end

  defp worker_loop(deadline, client_module, state, scenario, metrics) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      :ok
    else
      start_us = System.monotonic_time(:microsecond)

      scenario = materialize_scenario(scenario)

      result =
        try do
          client_module.request(state, scenario)
        catch
          kind, reason ->
            {:error, {kind, reason}}
        end

      end_us = System.monotonic_time(:microsecond)

      case {metrics, result} do
        {nil, _} ->
          :ok

        {metrics, :ok} ->
          Metrics.record_ok(metrics, end_us - start_us)

        {metrics, {:error, reason}} ->
          Metrics.record_error(metrics, reason)
      end

      worker_loop(deadline, client_module, state, scenario, metrics)
    end
  end

  defp materialize_scenario(%Bench.Scenario{delay_range_ms: {min_ms, max_ms}} = scenario)
       when is_integer(min_ms) and is_integer(max_ms) and max_ms >= min_ms do
    ms = min_ms + :rand.uniform(max_ms - min_ms + 1) - 1
    path =
      if String.contains?(scenario.path, "{ms}") do
        String.replace(scenario.path, "{ms}", Integer.to_string(ms))
      else
        "/delay/#{ms}"
      end

    %{scenario | path: path}
  end

  defp materialize_scenario(scenario), do: scenario

  defp seed_rand do
    :rand.seed(:exsplus, {
      :erlang.phash2({self(), System.monotonic_time(), System.unique_integer([:positive])}),
      :erlang.phash2({System.unique_integer([:positive]), self()}),
      :erlang.phash2({System.monotonic_time(), node()})
    })
  end
end
