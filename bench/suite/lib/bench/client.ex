defmodule Bench.Client do
  @moduledoc false

  @callback id() :: atom()
  @callback setup(Bench.Config.t()) :: {:ok, term()} | {:error, term()}
  @callback request(term(), Bench.Scenario.t()) :: :ok | {:error, term()}
  @callback teardown(term()) :: :ok
end
