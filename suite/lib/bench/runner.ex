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
        log_info("Setting up client #{client_module.id()}")

        case client_module.setup(config) do
          {:ok, state} ->
            scenario_concurrency =
              scenario_concurrency_map(client_module, state, config, config.scenarios)

            log_info(
              "Computed concurrency for #{client_module.id()}: " <>
                format_concurrency_map(scenario_concurrency)
            )

            scenario_results =
              Enum.map(config.scenarios, fn scenario ->
                concurrency = Map.get(scenario_concurrency, scenario.name, config.concurrency)

                log_info(
                  "Running #{client_module.id()} scenario #{scenario.name} (concurrency=#{concurrency})"
                )

                run_scenario(client_module, state, config, scenario, concurrency)
              end)

            log_info("Tearing down client #{client_module.id()}")
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

  defp run_scenario(client_module, state, config, scenario, scenario_concurrency) do
    warmup_ms = config.warmup_s * 1000
    duration_ms = config.duration_s * 1000

    if warmup_ms > 0 do
      warmup_metrics = Metrics.new(config)

      run_phase(
        warmup_ms,
        config.request_timeout_ms,
        scenario_concurrency,
        client_module,
        state,
        scenario,
        warmup_metrics
      )

      warmup_snapshot = Metrics.snapshot(warmup_metrics)
      warmup_requests = warmup_snapshot.total + warmup_snapshot.errors

      warmup_error_suffix =
        format_error_reason_suffix(warmup_snapshot.errors, warmup_snapshot.error_reasons)

      log_info(
        "Warmup #{client_module.id()} scenario #{scenario.name}: " <>
          "requests=#{warmup_requests} errors=#{warmup_snapshot.errors}#{warmup_error_suffix}"
      )
    end

    metrics = Metrics.new(config)
    start_us = System.monotonic_time(:microsecond)

    run_phase(
      duration_ms,
      config.request_timeout_ms,
      scenario_concurrency,
      client_module,
      state,
      scenario,
      metrics
    )

    end_us = System.monotonic_time(:microsecond)
    elapsed_s = max(end_us - start_us, 0) / 1_000_000

    snapshot = Metrics.snapshot(metrics)
    rps = if elapsed_s > 0, do: snapshot.total / elapsed_s, else: 0.0

    result = %Result{
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

    log_result(result)
    result
  end

  defp run_phase(
         duration_ms,
         request_timeout_ms,
         concurrency,
         client_module,
         state,
         scenario,
         metrics
       ) do
    deadline = System.monotonic_time(:millisecond) + duration_ms

    tasks =
      1..concurrency
      |> Enum.map(fn _ ->
        Task.async(fn ->
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

  defp log_result(%Result{} = result) do
    error_suffix = format_error_reason_suffix(result.errors, result.error_reasons)

    log_info(
      "Completed #{result.client} scenario #{result.scenario}: " <>
        "requests=#{result.requests} " <>
        "rps=#{format_float(result.rps)} " <>
        "errors=#{result.errors} " <>
        "p50_ms=#{format_us(result.p50_us)} " <>
        "p99_ms=#{format_us(result.p99_us)}#{error_suffix}"
    )
  end

  defp format_us(nil), do: "n/a"
  defp format_us(value), do: format_float(value / 1000)

  defp format_float(value) when is_float(value) do
    :io_lib.format("~.2f", [value]) |> IO.iodata_to_binary()
  end

  defp format_float(value) when is_integer(value), do: Integer.to_string(value)

  defp scenario_concurrency_map(client_module, state, config, scenarios) do
    cond do
      config.target_rps ->
        Enum.into(scenarios, %{}, fn scenario ->
          {scenario.name, compute_concurrency(config, scenario, config.target_rps, nil, false)}
        end)

      config.dynamic_concurrency ->
        preflight = preflight_scenarios(client_module, state, config, scenarios)

        Enum.into(scenarios, %{}, fn scenario ->
          case Map.get(preflight, scenario.name) do
            %{concurrency: concurrency} ->
              {scenario.name, cap_concurrency(config, concurrency)}

            _ ->
              {scenario.name, config.concurrency}
          end
        end)

      true ->
        Enum.into(scenarios, %{}, fn scenario -> {scenario.name, config.concurrency} end)
    end
  end

  defp format_concurrency_map(map) do
    map
    |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp compute_concurrency(config, scenario, target_rps, preflight, only_increase) do
    latency_ms =
      case preflight do
        nil ->
          scenario.expected_latency_ms

        preflight_map ->
          case Map.get(preflight_map, scenario.name) do
            %{mean_us: mean_us} when is_number(mean_us) and mean_us > 0 ->
              mean_us / 1000

            _ ->
              scenario.expected_latency_ms
          end
      end

    concurrency =
      if is_number(target_rps) and target_rps > 0 and is_number(latency_ms) and latency_ms > 0 do
        value = Float.ceil(target_rps * latency_ms / 1000)
        max(1, trunc(value))
      else
        config.concurrency
      end

    concurrency =
      if only_increase do
        max(config.concurrency, concurrency)
      else
        concurrency
      end

    cap_concurrency(config, concurrency)
  end

  defp preflight_scenarios(client_module, state, config, scenarios) do
    preflight_ms = max(config.preflight_s, 1) * 1000
    warmup_ms = max(config.preflight_warmup_s, 0) * 1000

    concurrencies =
      case config.preflight_concurrencies do
        [] -> [max(config.preflight_concurrency, 1)]
        list -> list
      end

    Enum.reduce(scenarios, %{}, fn scenario, acc ->
      best =
        Enum.reduce(concurrencies, nil, fn concurrency, best ->
          log_info(
            "Preflight #{client_module.id()} scenario #{scenario.name} (concurrency=#{concurrency})"
          )

          if warmup_ms > 0 do
            warmup_metrics = Metrics.new(config)

            run_phase(
              warmup_ms,
              config.request_timeout_ms,
              concurrency,
              client_module,
              state,
              scenario,
              warmup_metrics
            )

            warmup_snapshot = Metrics.snapshot(warmup_metrics)
            warmup_requests = warmup_snapshot.total + warmup_snapshot.errors

            warmup_error_suffix =
              format_error_reason_suffix(warmup_snapshot.errors, warmup_snapshot.error_reasons)

            log_info(
              "Preflight warmup #{client_module.id()} scenario #{scenario.name} " <>
                "concurrency=#{concurrency} requests=#{warmup_requests} " <>
                "errors=#{warmup_snapshot.errors}#{warmup_error_suffix}"
            )
          end

          metrics = Metrics.new(config)
          start_us = System.monotonic_time(:microsecond)

          run_phase(
            preflight_ms,
            config.request_timeout_ms,
            concurrency,
            client_module,
            state,
            scenario,
            metrics
          )

          end_us = System.monotonic_time(:microsecond)
          elapsed_s = max(end_us - start_us, 0) / 1_000_000
          snapshot = Metrics.snapshot(metrics)
          requests = snapshot.total + snapshot.errors
          rps = if elapsed_s > 0, do: snapshot.total / elapsed_s, else: 0.0
          error_suffix = format_error_reason_suffix(snapshot.errors, snapshot.error_reasons)

          candidate = %{
            concurrency: concurrency,
            rps: rps,
            mean_us: snapshot.mean,
            errors: snapshot.errors
          }

          log_info(
            "Preflight result #{client_module.id()} scenario #{scenario.name} " <>
              "concurrency=#{concurrency} requests=#{requests} " <>
              "rps=#{format_float(rps)} errors=#{snapshot.errors}#{error_suffix}"
          )

          choose_best(candidate, best)
        end)

      if best do
        log_info(
          "Preflight selected #{client_module.id()} scenario #{scenario.name} " <>
            "concurrency=#{best.concurrency} rps=#{format_float(best.rps)} errors=#{best.errors}"
        )
      end

      Map.put(acc, scenario.name, best)
    end)
  end

  defp choose_best(candidate, nil), do: candidate

  defp choose_best(candidate, best) do
    cond do
      best.errors == 0 and candidate.errors == 0 ->
        if candidate.rps >= best.rps, do: candidate, else: best

      best.errors == 0 ->
        best

      candidate.errors == 0 ->
        candidate

      candidate.errors < best.errors ->
        candidate

      candidate.errors > best.errors ->
        best

      candidate.rps >= best.rps ->
        candidate

      true ->
        best
    end
  end

  defp cap_concurrency(config, concurrency) do
    case config.max_concurrency do
      max_concurrency when is_integer(max_concurrency) and max_concurrency > 0 ->
        min(concurrency, max_concurrency)

      _ ->
        concurrency
    end
  end

  defp format_error_reason_suffix(errors, _error_reasons) when errors <= 0, do: ""

  defp format_error_reason_suffix(_errors, error_reasons) do
    formatted =
      error_reasons
      |> Enum.sort_by(fn {_reason, count} -> -count end)
      |> Enum.take(3)
      |> Enum.map(fn {reason, count} -> "#{inspect(reason)}=#{count}" end)
      |> Enum.join(", ")

    if formatted == "" do
      ""
    else
      " top_errors=[#{formatted}]"
    end
  end
end
