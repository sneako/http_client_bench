defmodule Bench.Metrics do
  @moduledoc false

  alias Bench.Config

  defstruct sketch: nil, error_counter: nil

  def new(%Config{} = config) do
    sketch = :ddskerl_counters.new(Config.ddskerl_opts(config))
    errors = :counters.new(1, [:write_concurrency])
    %__MODULE__{sketch: sketch, error_counter: errors}
  end

  def record_ok(%__MODULE__{sketch: sketch}, latency_us) do
    _ = :ddskerl_counters.insert(sketch, latency_us)
    :ok
  end

  def record_error(%__MODULE__{error_counter: errors}) do
    :counters.add(errors, 1, 1)
    :ok
  end

  def snapshot(%__MODULE__{sketch: sketch, error_counter: errors}) do
    total = :ddskerl_counters.total(sketch)
    sum = :ddskerl_counters.sum(sketch)
    mean = if total > 0, do: sum / total, else: 0.0

    %{
      total: total,
      errors: :counters.get(errors, 1),
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
end
