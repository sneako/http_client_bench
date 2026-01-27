defmodule Bench.MetricsTest do
  use ExUnit.Case, async: true

  test "records counts and percentiles" do
    config = %Bench.Config{}
    metrics = Bench.Metrics.new(config)

    Bench.Metrics.record_ok(metrics, 1000)
    Bench.Metrics.record_ok(metrics, 2000)
    Bench.Metrics.record_error(metrics)

    snapshot = Bench.Metrics.snapshot(metrics)

    assert snapshot.total == 2
    assert snapshot.errors == 1
    assert snapshot.min <= snapshot.max
    assert snapshot.p50
  end
end
