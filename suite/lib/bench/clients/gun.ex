defmodule Bench.Clients.Gun do
  @moduledoc false

  @behaviour Bench.Client

  alias Bench.Config
  alias Bench.Scenario

  @impl true
  def id, do: :gun

  @impl true
  def setup(%Config{} = config) do
    host = String.to_charlist(config.server_host)
    port = config.server_port
    conn_count = max(config.gun_conns, 1)

    conns =
      1..conn_count
      |> Enum.map(fn _ ->
        {:ok, pid} = :gun.open(host, port, %{protocols: [:http]})
        {:ok, _} = :gun.await_up(pid, config.request_timeout_ms)
        pid
      end)

    counter = :atomics.new(1, [])
    :atomics.put(counter, 1, 0)

    {:ok, %{conns: conns, counter: counter, config: config}}
  rescue
    error -> {:error, error}
  end

  @impl true
  def request(state, %Scenario{} = scenario) do
    conn = pick_conn(state)
    method = normalize_method(scenario.method)
    headers = scenario.headers
    body = scenario.body || ""

    stream_ref = :gun.request(conn, method, scenario.path, headers, body)
    await_response(conn, stream_ref, state.config.request_timeout_ms)
  end

  @impl true
  def teardown(state) do
    Enum.each(state.conns, fn conn ->
      _ = :gun.close(conn)
    end)

    :ok
  end

  defp pick_conn(state) do
    idx = :atomics.add_get(state.counter, 1, 1)
    Enum.at(state.conns, rem(idx - 1, length(state.conns)))
  end

  defp await_response(conn, stream_ref, timeout_ms) do
    receive do
      {:gun_response, ^conn, ^stream_ref, :fin, _status, _headers} ->
        :ok

      {:gun_response, ^conn, ^stream_ref, :nofin, _status, _headers} ->
        await_data(conn, stream_ref, timeout_ms)

      {:gun_error, ^conn, ^stream_ref, reason} ->
        {:error, reason}

      {:gun_down, ^conn, _protocol, reason, _} ->
        {:error, reason}
    after
      timeout_ms ->
        {:error, :timeout}
    end
  end

  defp await_data(conn, stream_ref, timeout_ms) do
    receive do
      {:gun_data, ^conn, ^stream_ref, :fin, _data} ->
        :ok

      {:gun_data, ^conn, ^stream_ref, :nofin, _data} ->
        await_data(conn, stream_ref, timeout_ms)

      {:gun_error, ^conn, ^stream_ref, reason} ->
        {:error, reason}

      {:gun_down, ^conn, _protocol, reason, _} ->
        {:error, reason}
    after
      timeout_ms ->
        {:error, :timeout}
    end
  end

  defp normalize_method(method) when is_atom(method) do
    method |> Atom.to_string() |> String.upcase()
  end

  defp normalize_method(method) when is_binary(method) do
    String.upcase(method)
  end

  defp normalize_method(method) when is_list(method) do
    method |> List.to_string() |> String.upcase()
  end
end
