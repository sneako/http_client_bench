defmodule Bench.Clients.Finch do
  @moduledoc false

  @behaviour Bench.Client

  alias Bench.Config
  alias Bench.Scenario

  @impl true
  def id, do: :finch

  @impl true
  def setup(%Config{} = config) do
    name = BenchFinch
    pool_opts = [size: config.pool_size, count: config.pool_count]
    pool_opts = maybe_set_protocols(pool_opts, config)
    pool_opts = maybe_set_conn_opts(pool_opts, config)
    pools = %{default: pool_opts}

    case Finch.start_link(name: name, pools: pools) do
      {:ok, pid} ->
        {:ok, %{name: name, pid: pid, config: config}}

      {:error, {:already_started, pid}} ->
        {:ok, %{name: name, pid: pid, config: config}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def request(state, %Scenario{} = scenario) do
    url = build_url(state.config, scenario)
    req = Finch.build(scenario.method, url, scenario.headers, scenario.body)

    case Finch.request(req, state.name, receive_timeout: state.config.request_timeout_ms) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def teardown(state) do
    if Process.alive?(state.pid) do
      Process.unlink(state.pid)
      Process.exit(state.pid, :shutdown)
    end

    :ok
  end

  defp build_url(config, scenario) do
    "#{config.scheme}://#{config.server_host}:#{config.server_port}#{scenario.path}"
  end

  defp maybe_set_protocols(pool_opts, %Config{http_version: "http2"}) do
    Keyword.put(pool_opts, :protocols, [:http2])
  end

  defp maybe_set_protocols(pool_opts, _config), do: pool_opts

  defp maybe_set_conn_opts(pool_opts, %Config{scheme: "https", tls_verify: false}) do
    conn_opts = [transport_opts: [verify: :verify_none]]
    Keyword.put(pool_opts, :conn_opts, conn_opts)
  end

  defp maybe_set_conn_opts(pool_opts, _config), do: pool_opts
end
