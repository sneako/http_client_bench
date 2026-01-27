defmodule Bench.Scenario do
  @moduledoc false

  defstruct name: nil,
            method: :get,
            path: "/",
            headers: [],
            body: nil,
            response_bytes: 0
end
