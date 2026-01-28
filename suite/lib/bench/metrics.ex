defmodule Bench.Metrics do
  @moduledoc false

  alias Bench.Config

  defstruct sketch: nil, error_counter: nil, error_table: nil

  def new(%Config{} = config) do
    sketch = :ddskerl_counters.new(Config.ddskerl_opts(config))
    errors = :counters.new(1, [:write_concurrency])
    error_table = :ets.new(:bench_error_reasons, [:set, :public, {:write_concurrency, true}])
    %__MODULE__{sketch: sketch, error_counter: errors, error_table: error_table}
  end

  def record_ok(%__MODULE__{sketch: sketch}, latency_us) do
    _ = :ddskerl_counters.insert(sketch, latency_us)
    :ok
  end

  def record_error(%__MODULE__{error_counter: errors, error_table: error_table}, reason) do
    :counters.add(errors, 1, 1)
    key = normalize_reason(reason)
    _ = :ets.update_counter(error_table, key, {2, 1}, {key, 0})
    :ok
  end

  def snapshot(%__MODULE__{sketch: sketch, error_counter: errors, error_table: error_table}) do
    total = :ddskerl_counters.total(sketch)
    sum = :ddskerl_counters.sum(sketch)
    mean = if total > 0, do: sum / total, else: 0.0
    error_reasons = :ets.tab2list(error_table)

    %{
      total: total,
      errors: :counters.get(errors, 1),
      error_reasons: error_reasons,
      min: quantile(sketch, total, 0.0),
      max: quantile(sketch, total, 1.0),
      mean: mean,
      p50: quantile(sketch, total, 0.50),
      p90: quantile(sketch, total, 0.90),
      p99: quantile(sketch, total, 0.99)
    }
  end

  defp quantile(_sketch, 0, _q), do: nil

  defp quantile(sketch, _total, q) do
    case :ddskerl_counters.quantile(sketch, q) do
      :undefined -> nil
      value -> value
    end
  end

  defp normalize_reason({:error, reason}), do: normalize_reason(reason)
  defp normalize_reason({kind, reason}) when is_atom(kind), do: {kind, normalize_reason(reason)}
  defp normalize_reason(reason), do: reason
end
