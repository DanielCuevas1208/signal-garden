defmodule SignalGarden.Sim.ScenarioCodec do
  @moduledoc """
  Encode and decode simulation scenarios as JSON.

  The format is versioned and self-contained. A file carries the topology,
  the seed, the fault schedule, and every network parameter needed to replay
  the run in the browser or in the headless core.
  """

  alias SignalGarden.Sim.{Scenario, Topology}

  @format 1

  @catalog_ids ~w(line ring grid random split churn lossy crash counter counter_split imported)a

  @doc "Encode a scenario struct as pretty-printed JSON."
  @spec encode(Scenario.t()) :: String.t()
  def encode(%Scenario{} = scenario) do
    scenario
    |> to_map()
    |> Jason.encode!(pretty: true)
  end

  @doc "Decode JSON text into a scenario struct."
  @spec decode(String.t()) :: {:ok, Scenario.t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json),
         {:ok, scenario} <- from_map(map) do
      {:ok, scenario}
    else
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
      other -> other
    end
  end

  @doc "Decode a decoded JSON map into a scenario struct."
  @spec from_map(map()) :: {:ok, Scenario.t()} | {:error, term()}
  def from_map(%{"format" => @format} = map), do: build_scenario(map)
  def from_map(%{"format" => version}), do: {:error, {:unsupported_format, version}}
  def from_map(_), do: {:error, :missing_format}

  # ---------------------------------------------------------------------------
  # encode
  # ---------------------------------------------------------------------------

  defp to_map(%Scenario{} = scenario) do
    %{
      "format" => @format,
      "id" => Atom.to_string(scenario.id),
      "name" => scenario.name,
      "description" => scenario.description,
      "seed" => scenario.seed,
      "mode" => Atom.to_string(scenario.mode),
      "origin" => scenario.origin,
      "latest_value" => scenario.latest_value,
      "delay_ms" => encode_delay(scenario.delay_ms),
      "drop_prob" => scenario.drop_prob,
      "gossip_interval_ms" => scenario.gossip_interval_ms,
      "partitions" => encode_partitions(scenario.partitions),
      "fault_schedule" => Enum.map(scenario.fault_schedule, &encode_fault/1),
      "topology" => encode_topology(scenario.topology)
    }
  end

  defp encode_delay({lo, hi}), do: [lo, hi]
  defp encode_delay(value) when is_integer(value), do: value

  defp encode_partitions(partitions) do
    partitions
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Map.new(fn {k, v} -> {Integer.to_string(k), v} end)
  end

  defp encode_fault(%{at: at, action: {:merge, :all}, label: label}) do
    %{"at" => at, "action" => "merge", "label" => label}
  end

  defp encode_fault(%{at: at, action: {:assign, node, group}, label: label}) do
    %{
      "at" => at,
      "action" => "assign",
      "node" => node,
      "group" => group,
      "label" => label
    }
  end

  defp encode_fault(%{at: at, action: {:crash, node}, label: label}) do
    %{"at" => at, "action" => "crash", "node" => node, "label" => label}
  end

  defp encode_fault(%{at: at, action: {:restart, node}, label: label}) do
    %{"at" => at, "action" => "restart", "node" => node, "label" => label}
  end

  defp encode_fault(%{at: at, action: {:increment, node}, label: label}) do
    %{"at" => at, "action" => "increment", "node" => node, "label" => label}
  end

  defp encode_topology(%Topology{} = topology) do
    %{
      "id" => Atom.to_string(topology.id),
      "label" => topology.label,
      "nodes" => topology.nodes,
      "edges" => Enum.map(topology.edges, fn {a, b} -> [a, b] end),
      "layout" =>
        topology.layout
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Map.new(fn {k, {x, y}} -> {Integer.to_string(k), [x, y]} end)
    }
  end

  # ---------------------------------------------------------------------------
  # decode
  # ---------------------------------------------------------------------------

  defp build_scenario(map) do
    with {:ok, topology} <- decode_topology(map["topology"]),
         {:ok, origin} <- require_pos_int(map["origin"], "origin"),
         :ok <- validate_origin(topology, origin),
         {:ok, mode} <- require_mode(map["mode"]),
         {:ok, name} <- require_string(map["name"], "name"),
         {:ok, description} <- require_string(map["description"], "description"),
         {:ok, seed} <- require_int(map["seed"], "seed"),
         {:ok, latest_value} <- require_number(map["latest_value"], "latest_value"),
         {:ok, delay_ms} <- decode_delay_result(map["delay_ms"]),
         {:ok, drop_prob} <- require_float_range(map["drop_prob"], "drop_prob", 0.0, 1.0),
         {:ok, gossip_interval_ms} <-
           require_pos_int(map["gossip_interval_ms"], "gossip_interval_ms"),
         {:ok, partitions} <- decode_partitions_result(map["partitions"] || %{}),
         {:ok, fault_schedule} <- decode_fault_schedule(map["fault_schedule"] || []) do
      {:ok,
       %Scenario{
         id: parse_id(map["id"]),
         name: name,
         description: description,
         seed: seed,
         mode: mode,
         topology: topology,
         origin: origin,
         latest_value: latest_value,
         delay_ms: delay_ms,
         drop_prob: drop_prob,
         gossip_interval_ms: gossip_interval_ms,
         partitions: partitions,
         fault_schedule: fault_schedule
       }}
    end
  end

  defp decode_topology(nil), do: {:error, {:missing_field, "topology"}}
  defp decode_topology(map) when is_map(map), do: Topology.from_export(map)
  defp decode_topology(_), do: {:error, {:invalid_field, "topology"}}

  defp decode_delay([lo, hi]) when is_integer(lo) and is_integer(hi) and lo >= 0 and hi >= lo,
    do: {:ok, {lo, hi}}

  defp decode_delay(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp decode_delay(_), do: {:error, {:invalid_field, "delay_ms"}}

  defp decode_delay_result(value), do: decode_delay(value)

  defp decode_partitions_result(map) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case parse_key(k) do
        {:error, _} = err -> {:halt, err}
        key when is_integer(key) and is_integer(v) -> {:cont, {:ok, Map.put(acc, key, v)}}
        _ -> {:halt, {:error, {:invalid_field, "partitions"}}}
      end
    end)
  end

  defp decode_fault_schedule(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case decode_fault(item) do
        {:ok, fault} -> {:cont, {:ok, [fault | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, faults} -> {:ok, Enum.reverse(faults)}
      other -> other
    end
  end

  defp decode_fault(%{"at" => at, "action" => "merge", "label" => label}) when is_integer(at) do
    {:ok, %{at: at, action: {:merge, :all}, label: label}}
  end

  defp decode_fault(%{
         "at" => at,
         "action" => "assign",
         "node" => node,
         "group" => group,
         "label" => label
       })
       when is_integer(at) and is_integer(node) and is_integer(group) do
    {:ok, %{at: at, action: {:assign, node, group}, label: label}}
  end

  defp decode_fault(%{"at" => at, "action" => "crash", "node" => node, "label" => label})
       when is_integer(at) and is_integer(node) do
    {:ok, %{at: at, action: {:crash, node}, label: label}}
  end

  defp decode_fault(%{"at" => at, "action" => "restart", "node" => node, "label" => label})
       when is_integer(at) and is_integer(node) do
    {:ok, %{at: at, action: {:restart, node}, label: label}}
  end

  defp decode_fault(%{"at" => at, "action" => "increment", "node" => node, "label" => label})
       when is_integer(at) and is_integer(node) do
    {:ok, %{at: at, action: {:increment, node}, label: label}}
  end

  defp decode_fault(_), do: {:error, {:invalid_field, "fault_schedule"}}

  defp parse_id(nil), do: :imported

  defp parse_id(id) when is_binary(id) do
    case String.to_existing_atom(id) do
      atom when atom in @catalog_ids -> atom
      _ -> :imported
    end
  rescue
    ArgumentError -> :imported
  end

  # A missing mode means rumor, so files written before counters still load.
  defp require_mode(nil), do: {:ok, :rumor}
  defp require_mode("rumor"), do: {:ok, :rumor}
  defp require_mode("counter"), do: {:ok, :counter}
  defp require_mode(_), do: {:error, {:invalid_field, "mode"}}

  defp parse_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {n, ""} -> n
      _ -> {:error, {:invalid_field, "partitions"}}
    end
  end

  defp parse_key(key) when is_integer(key), do: key

  defp validate_origin(%Topology{nodes: nodes}, origin) do
    if origin in nodes, do: :ok, else: {:error, {:invalid_origin, origin}}
  end

  defp require_string(value, _field) when is_binary(value), do: {:ok, value}
  defp require_string(_, field), do: {:error, {:invalid_field, field}}

  defp require_int(value, _field) when is_integer(value), do: {:ok, value}
  defp require_int(_, field), do: {:error, {:invalid_field, field}}

  defp require_pos_int(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp require_pos_int(_, field), do: {:error, {:invalid_field, field}}

  defp require_number(value, _field) when is_number(value), do: {:ok, value}
  defp require_number(_, field), do: {:error, {:invalid_field, field}}

  defp require_float_range(value, _field, lo, hi)
       when is_number(value) and value >= lo and value <= hi,
       do: {:ok, value * 1.0}

  defp require_float_range(_, field, _, _), do: {:error, {:invalid_field, field}}
end
