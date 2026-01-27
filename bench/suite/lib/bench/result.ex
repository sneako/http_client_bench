defmodule Bench.Result do
  @moduledoc false

  defstruct client: nil,
            scenario: nil,
            requests: 0,
            errors: 0,
            duration_s: 0.0,
            rps: 0.0,
            min_us: nil,
            max_us: nil,
            mean_us: nil,
            p50_us: nil,
            p90_us: nil,
            p99_us: nil
end
