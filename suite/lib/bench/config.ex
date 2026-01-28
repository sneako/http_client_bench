defmodule Bench.Config do
  @moduledoc false

  alias Bench.ClientRegistry
  alias Bench.Scenario

  @static_dir Path.expand("../../../infra/server/static", __DIR__)

  @json_32k Path.join(@static_dir, "json_32k.json")
            |> File.read!()

  @echo_payloads %{
    1024 => Path.join(@static_dir, "echo_1024.bin") |> File.read!(),
    4096 => Path.join(@static_dir, "small.bin") |> File.read!(),
    131_072 => Path.join(@static_dir, "medium.bin") |> File.read!(),
    1_048_576 => Path.join(@static_dir, "large.bin") |> File.read!()
  }

  defstruct server_host: "localhost",
            server_port: 8080,
            scheme: "http",
            http_version: "http1",
            duration_s: 30,
            warmup_s: 5,
            concurrency: 100,
            clients: [],
            scenarios: [],
            result_dir: nil,
            pool_size: 200,
            pool_count: 32,
            gun_conns: 4,
            request_timeout_ms: 30_000,
            tls_verify: false,
            ddskerl_error: 0.01,
            ddskerl_bound: 2048,
            echo_bytes: 1024,
            delay_ms: 100,
            target_rps: nil,
            scenario_latency_ms: %{},
            dynamic_concurrency: false,
            preflight_s: 5,
            preflight_concurrency: 25,
            max_concurrency: nil

  def load do
    http_version = normalize_http_version(env("BENCH_HTTP_VERSION", "http1"))
    scheme_default = if http_version == "http2", do: "https", else: "http"
    scheme = env("BENCH_SCHEME", scheme_default)
    tls_verify = env_bool("BENCH_TLS_VERIFY", false)

    if http_version == "http2" and scheme != "https" do
      raise "HTTP/2 requires https; set BENCH_SCHEME=https"
    end

    config = %__MODULE__{
      server_host: env("BENCH_SERVER_HOST", "localhost"),
      server_port: env_int("BENCH_SERVER_PORT", 8080),
      scheme: scheme,
      http_version: http_version,
      duration_s: env_int("BENCH_DURATION", 30),
      warmup_s: env_int("BENCH_WARMUP", 5),
      concurrency: env_int("BENCH_CONCURRENCY", 25),
      pool_size: env_int("BENCH_POOL_SIZE", 200),
      pool_count: env_int("BENCH_POOL_COUNT", 32),
      gun_conns: env_int("BENCH_GUN_CONNS", 4),
      request_timeout_ms: env_int("BENCH_REQUEST_TIMEOUT_MS", 30_000),
      tls_verify: tls_verify,
      ddskerl_error: env_float("BENCH_DDSKERL_ERROR", 0.01),
      ddskerl_bound: env_int("BENCH_DDSKERL_BOUND", 2048),
      echo_bytes: env_int("BENCH_ECHO_BYTES", 1024),
      delay_ms: env_int("BENCH_DELAY_MS", 100),
      target_rps: env_float_optional("BENCH_TARGET_RPS"),
      scenario_latency_ms: env_latency_map("BENCH_SCENARIO_LATENCY_MS"),
      dynamic_concurrency: env_bool("BENCH_DYNAMIC_CONCURRENCY", false),
      preflight_s: env_int("BENCH_PREFLIGHT_S", 5),
      preflight_concurrency: env_int("BENCH_PREFLIGHT_CONCURRENCY", 25),
      max_concurrency: env_int_optional("BENCH_MAX_CONCURRENCY")
    }

    scenario_names = env_list("BENCH_SCENARIOS")
    client_names = env_list("BENCH_CLIENTS")

    scenarios =
      config
      |> default_scenarios()
      |> apply_latency_overrides(config)
      |> filter_scenarios(scenario_names)

    client_ids =
      case client_names do
        [] -> ClientRegistry.all_ids()
        ["all"] -> ClientRegistry.all_ids()
        names -> Enum.map(names, &String.to_atom/1)
      end

    config = %__MODULE__{
      config
      | scenarios: scenarios,
        clients: client_ids,
        result_dir: env("BENCH_RESULTS_DIR", default_results_dir())
    }

    config
  end

  def ddskerl_opts(%__MODULE__{ddskerl_error: error, ddskerl_bound: bound}) do
    %{error: error, bound: bound}
  end

  defp default_scenarios(%__MODULE__{echo_bytes: echo_bytes, delay_ms: delay_ms}) do
    body = echo_payload(echo_bytes)

    [
      %Scenario{name: "health", method: :get, path: "/health", response_bytes: 2},
      %Scenario{name: "small", method: :get, path: "/small", response_bytes: 4096},
      %Scenario{name: "medium", method: :get, path: "/medium", response_bytes: 131_072},
      %Scenario{name: "large", method: :get, path: "/large", response_bytes: 1_048_576},
      %Scenario{name: "json", method: :get, path: "/json", response_bytes: 0},
      %Scenario{
        name: "echo",
        method: :post,
        path: "/echo",
        body: body,
        response_bytes: byte_size(body)
      },
      %Scenario{name: "stream", method: :get, path: "/stream", response_bytes: 1_048_576},
      %Scenario{
        name: "delay",
        method: :get,
        path: "/delay/#{delay_ms}",
        response_bytes: 0,
        expected_latency_ms: delay_ms
      },
      %Scenario{
        name: "delay_var",
        method: :get,
        path: "/delay_var",
        response_bytes: 0,
        expected_latency_ms: 110
      },
      %Scenario{
        name: "delay_post",
        method: :post,
        path: "/delay_post",
        headers: [{"content-type", "application/json"}],
        body: @json_32k,
        response_bytes: byte_size(@json_32k),
        expected_latency_ms: 110
      }
    ]
  end

  defp apply_latency_overrides(scenarios, %__MODULE__{scenario_latency_ms: overrides}) do
    if overrides == %{} do
      scenarios
    else
      Enum.map(scenarios, fn scenario ->
        case Map.fetch(overrides, scenario.name) do
          {:ok, latency} -> %{scenario | expected_latency_ms: latency}
          :error -> scenario
        end
      end)
    end
  end

  defp filter_scenarios(scenarios, []), do: scenarios
  defp filter_scenarios(scenarios, ["all"]), do: scenarios

  defp filter_scenarios(scenarios, names) do
    Enum.filter(scenarios, fn scenario -> scenario.name in names end)
  end

  defp env(key, default) do
    case System.get_env(key) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> default
        end
    end
  end

  defp env_float(key, default) do
    case System.get_env(key) do
      nil ->
        default

      "" ->
        default

      value ->
        case Float.parse(value) do
          {float, _} -> float
          :error -> default
        end
    end
  end

  defp env_float_optional(key) do
    case System.get_env(key) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case Float.parse(value) do
          {float, _} when float > 0 -> float
          _ -> nil
        end
    end
  end

  defp env_int_optional(key) do
    case System.get_env(key) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case Integer.parse(value) do
          {int, _} when int > 0 -> int
          _ -> nil
        end
    end
  end

  defp env_list(key) do
    case System.get_env(key) do
      nil ->
        []

      "" ->
        []

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
    end
  end

  defp env_bool(key, default) do
    case System.get_env(key) do
      nil -> default
      "" -> default
      value -> value in ["1", "true", "TRUE", "yes", "YES"]
    end
  end

  defp env_latency_map(key) do
    case System.get_env(key) do
      nil ->
        %{}

      "" ->
        %{}

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.reduce(%{}, fn entry, acc ->
          case String.split(entry, ":", parts: 2) do
            [name, latency_raw] ->
              latency = parse_latency(latency_raw)

              if latency > 0 do
                Map.put(acc, String.trim(name), latency)
              else
                acc
              end

            _ ->
              acc
          end
        end)
    end
  end

  defp parse_latency(value) do
    value = String.trim(value)

    case Float.parse(value) do
      {latency, _} -> latency
      :error -> 0.0
    end
  end

  defp normalize_http_version(value) do
    case String.downcase(value) do
      "h2" -> "http2"
      "http2" -> "http2"
      "http/2" -> "http2"
      "http1" -> "http1"
      "http/1" -> "http1"
      other -> other
    end
  end

  defp default_results_dir do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H%M%SZ")
    Path.expand("../results/#{timestamp}", File.cwd!())
  end

  defp echo_payload(size) do
    case Map.fetch(@echo_payloads, size) do
      {:ok, payload} ->
        payload

      :error ->
        raise "Unsupported BENCH_ECHO_BYTES=#{size}. Add a static payload under infra/server/static."
    end
  end

end
