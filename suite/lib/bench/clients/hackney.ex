defmodule Bench.Clients.Hackney do
  @moduledoc false

  @behaviour Bench.Client

  alias Bench.Config
  alias Bench.Scenario

  @impl true
  def id, do: :hackney

  @impl true
  def setup(%Config{} = config) do
    pool = :bench_hackney
    options = [max_connections: config.pool_size, timeout: config.request_timeout_ms]

    case :hackney_pool.start_pool(pool, options) do
      :ok -> {:ok, %{pool: pool, config: config}}
      {:ok, _pid} -> {:ok, %{pool: pool, config: config}}
      {:error, reason} -> {:error, reason}
      other -> {:ok, %{pool: pool, config: config, info: other}}
    end
  end

  @impl true
  def request(state, %Scenario{} = scenario) do
    url = build_url(state.config, scenario)
    headers = scenario.headers
    body = scenario.body || ""

    opts = [
      pool: state.pool,
      recv_timeout: state.config.request_timeout_ms,
      max_per_host: state.config.pool_size
    ]

    opts = maybe_protocols(opts, state.config)
    opts = maybe_insecure(opts, state.config)

    case :hackney.request(scenario.method, url, headers, body, opts) do
      {:ok, _status, _resp_headers, client_ref} ->
        consume_body(client_ref)

      {:ok, _status, _resp_headers} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def teardown(state) do
    _ = :hackney_pool.stop_pool(state.pool)
    :ok
  end

  defp consume_body(client_ref) do
    case :hackney.body(client_ref) do
      {:ok, _body} ->
        :hackney.close(client_ref)
        :ok

      {:error, reason} ->
        :hackney.close(client_ref)
        {:error, reason}
    end
  end

  defp build_url(config, scenario) do
    "#{config.scheme}://#{config.server_host}:#{config.server_port}#{scenario.path}"
  end

  defp maybe_protocols(opts, %Config{http_version: "http2"}), do: Keyword.put(opts, :protocols, [:http2])
  defp maybe_protocols(opts, %Config{http_version: "http1"}), do: Keyword.put(opts, :protocols, [:http1])
  defp maybe_protocols(opts, _config), do: opts

  defp maybe_insecure(opts, %Config{scheme: "https", tls_verify: false}) do
    opts
    |> Keyword.put(:insecure, true)
    |> Keyword.put(:ssl_options, [verify: :verify_none])
  end

  defp maybe_insecure(opts, _config), do: opts
end
