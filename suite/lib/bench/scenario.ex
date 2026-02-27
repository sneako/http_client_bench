defmodule Bench.Scenario do
  @moduledoc false

  defstruct name: nil,
            method: :get,
            path: "/",
            headers: [],
            body: nil,
            response_bytes: 0,
            expected_latency_ms: nil
end
