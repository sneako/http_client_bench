defmodule Bench.ClientRegistry do
  @moduledoc false

  @clients [
    {:finch, Bench.Clients.Finch},
    {:hackney, Bench.Clients.Hackney},
    {:gun, Bench.Clients.Gun}
  ]

  def all_ids do
    Enum.map(@clients, &elem(&1, 0))
  end

  def resolve(ids) do
    client_map = Map.new(@clients)
    Enum.map(ids, fn id -> Map.fetch!(client_map, id) end)
  end
end
