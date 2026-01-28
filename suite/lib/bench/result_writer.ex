defmodule Bench.ResultWriter do
  @moduledoc false

  alias Bench.Result
  alias NimbleCSV.RFC4180, as: CSV

  def write(results, config) do
    File.mkdir_p!(config.result_dir)

    summary = Enum.map(results, &summary_row/1)
    metadata = metadata(config)

    File.write!(Path.join(config.result_dir, "summary.csv"), summary_csv(summary))
    File.write!(Path.join(config.result_dir, "metadata.csv"), metadata_csv(metadata))
    File.write!(Path.join(config.result_dir, "errors.csv"), errors_csv(results))

    :ok
  end

  defp summary_row(%Result{} = result) do
    %{
      client: result.client,
      scenario: result.scenario,
      requests: result.requests,
      errors: result.errors,
      duration_seconds: result.duration_s,
      rps: result.rps,
      latency_ms_min: to_ms(result.min_us),
      latency_ms_max: to_ms(result.max_us),
      latency_ms_mean: to_ms(result.mean_us),
      latency_ms_p50: to_ms(result.p50_us),
      latency_ms_p90: to_ms(result.p90_us),
      latency_ms_p99: to_ms(result.p99_us)
    }
  end

  defp metadata(config) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      bench: %{
        server_host: config.server_host,
        server_port: config.server_port,
        scheme: config.scheme,
        http_version: config.http_version,
        duration_s: config.duration_s,
        warmup_s: config.warmup_s,
        concurrency: config.concurrency,
        clients: config.clients,
        scenarios: Enum.map(config.scenarios, & &1.name),
        pool_size: config.pool_size,
        pool_count: config.pool_count,
        gun_conns: config.gun_conns,
        request_timeout_ms: config.request_timeout_ms,
        tls_verify: config.tls_verify,
        ddskerl_error: config.ddskerl_error,
        ddskerl_bound: config.ddskerl_bound
      },
      finch: %{
        source: System.get_env("BENCH_FINCH_SOURCE") || "git",
        ref: System.get_env("BENCH_FINCH_REF"),
        version: System.get_env("BENCH_FINCH_VERSION"),
        app_version: app_version(:finch)
      },
      system: %{
        elixir: System.version(),
        otp_release: to_string(:erlang.system_info(:otp_release)),
        system_architecture: to_string(:erlang.system_info(:system_architecture)),
        os_type: format_os_type(:os.type()),
        git_sha: System.get_env("BENCH_GIT_SHA")
      }
    }
  end

  defp app_version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp format_os_type({family, name}), do: "#{family}/#{name}"
  defp format_os_type(other), do: inspect(other)

  defp summary_csv(rows) do
    header = [
      "client",
      "scenario",
      "requests",
      "errors",
      "duration_seconds",
      "rps",
      "latency_ms_min",
      "latency_ms_max",
      "latency_ms_mean",
      "latency_ms_p50",
      "latency_ms_p90",
      "latency_ms_p99"
    ]

    data = Enum.map(rows, &summary_row_to_list/1)

    CSV.dump_to_iodata([header | data])
  end

  defp summary_row_to_list(row) do
    [
      row.client,
      row.scenario,
      row.requests,
      row.errors,
      row.duration_seconds,
      row.rps,
      row.latency_ms_min,
      row.latency_ms_max,
      row.latency_ms_mean,
      row.latency_ms_p50,
      row.latency_ms_p90,
      row.latency_ms_p99
    ]
    |> Enum.map(&format_field/1)
  end

  defp to_ms(nil), do: nil
  defp to_ms(value), do: value / 1000

  defp metadata_csv(metadata) do
    rows =
      metadata
      |> flatten_metadata([])
      |> Enum.map(fn {key, value} -> [format_field(key), format_metadata_value(value)] end)

    CSV.dump_to_iodata([["key", "value"] | rows])
  end

  defp flatten_metadata(map, prefix) when is_map(map) do
    map
    |> Enum.flat_map(fn {key, value} ->
      key = key |> to_string() |> String.replace(~r/\s+/, "_")
      new_prefix = prefix ++ [key]

      if is_map(value) do
        flatten_metadata(value, new_prefix)
      else
        [{Enum.join(new_prefix, "."), value}]
      end
    end)
  end

  defp format_metadata_value(value) when is_list(value) do
    if Enum.all?(value, &(&1 == nil or is_binary(&1) or is_atom(&1) or is_number(&1))) do
      value
      |> Enum.map(&format_field/1)
      |> Enum.join(",")
    else
      inspect(value)
    end
  end

  defp format_metadata_value(value), do: format_field(value)

  defp format_field(nil), do: ""
  defp format_field(value) when is_binary(value), do: value
  defp format_field(value) when is_atom(value), do: Atom.to_string(value)
  defp format_field(value) when is_integer(value), do: Integer.to_string(value)

  defp format_field(value) when is_float(value),
    do: :io_lib.format("~.4f", [value]) |> IO.iodata_to_binary()

  defp format_field(value), do: to_string(value)

  defp errors_csv(results) do
    header = ["client", "scenario", "reason", "count"]

    rows =
      results
      |> Enum.flat_map(fn result ->
        Enum.map(result.error_reasons, fn {reason, count} ->
          [format_field(result.client), format_field(result.scenario), format_field(reason), count]
        end)
      end)

    CSV.dump_to_iodata([header | rows])
  end
end
