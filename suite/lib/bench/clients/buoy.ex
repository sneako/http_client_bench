defmodule Bench.Clients.Buoy do
  @moduledoc false

  @behaviour Bench.Client

  require Record

  Record.defrecord(
    :shackle_cast,
    :cast,
    Record.extract(:cast, from_lib: "shackle/include/shackle.hrl")
  )

  alias Bench.Config
  alias Bench.Scenario

  @impl true
  def id, do: :buoy

  @impl true
  def setup(%Config{} = config) do
    if config.http_version == "http2" do
      {:error, :http2_not_supported}
    else
      with :ok <- ensure_started(),
           {:ok, url} <- parse_base_url(config),
           :ok <- start_pool(url, config) do
        {:ok, %{url: url, config: config}}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def request(state, %Scenario{} = scenario) do
    url = put_path(state.url, scenario.path)
    body = scenario.body || :undefined
    headers = scenario.headers || []

    opts = %{
      headers: headers,
      body: body,
      pid: self(),
      timeout: state.config.request_timeout_ms
    }

    try do
      case :buoy.async_request(scenario.method, url, opts) do
        {:ok, request_id} ->
          await_response(request_id, state.config.request_timeout_ms)

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      exception -> {:error, exception}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @impl true
  def teardown(state) do
    _ = :buoy_pool.stop(state.url)
    _ = :buoy_app.stop()
    :ok
  end

  defp ensure_started do
    case :buoy_app.start() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      other -> other
    end
  end

  defp parse_base_url(%Config{} = config) do
    url = "#{config.scheme}://#{config.server_host}:#{config.server_port}/"

    case :buoy_utils.parse_url(url) do
      {:error, reason} -> {:error, reason}
      url_rec -> {:ok, url_rec}
    end
  end

  defp start_pool(url, %Config{} = config) do
    pool_size = max(config.pool_size, 1)
    backlog_size = max(pool_size * 4, 1024)

    pool_opts = [
      {:pool_size, pool_size},
      {:backlog_size, backlog_size},
      {:pool_strategy, :round_robin},
      {:socket_options, socket_options(config)},
      {:reconnect_time_min, 500},
      {:reconnect_time_max, 120_000}
    ]

    case :buoy_pool.start(url, pool_opts) do
      :ok -> :ok
      {:error, :pool_already_started} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp socket_options(%Config{scheme: "https", tls_verify: false}) do
    default_socket_options() ++
      [
        nodelay: true,
        verify: :verify_none
      ]
  end

  defp socket_options(_config) do
    default_socket_options() ++ [nodelay: true]
  end

  defp default_socket_options do
    [
      :binary,
      {:packet, :raw},
      {:send_timeout, 5_000},
      {:send_timeout_close, true}
    ]
  end

  defp put_path({:buoy_url, host, hostname, _path, port, protocol}, path) do
    {:buoy_url, host, hostname, path, port, protocol}
  end

  defp await_response(request_id, timeout_ms) do
    receive do
      {shackle_cast(request_id: ^request_id), reply} ->
        case reply do
          {:ok, _resp} -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    after
      timeout_ms ->
        flush_reply(request_id)
        {:error, :timeout}
    end
  end

  defp flush_reply(request_id) do
    receive do
      {shackle_cast(request_id: ^request_id), _reply} -> :ok
    after
      0 -> :ok
    end
  end
end
