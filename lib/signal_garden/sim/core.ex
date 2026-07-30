defmodule SignalGarden.Sim.Core do
  @moduledoc """
  The deterministic, side-effect-free simulation core.

  The core advances a gossip network in discrete logical time. Logical time
  is measured in milliseconds and has no link to wall clock time. Two runs
  that share the same scenario and the same command sequence produce the
  same history, the same event trace, and the same convergence time.

  ## Model

  Each node holds what it knows about the origin value: a version number and
  the value seen at that version. A node knows nothing at first, except the
  origin, which seeds itself with version one.

  On a gossip tick a node chooses one neighbour, copies its own knowledge to
  that neighbour through a message, and reschedules the next tick. The
  network applies three hazards between send and deliver:

    * delay - the message lands later in logical time
    * partition - a message that crosses a partition boundary is dropped
    * loss - a fair die roll drops a fixed fraction of messages

  The engine records every cross-hazard send in an event log so the
  interface can show what the network did to the signal.

  ## Status

  The status field drives the visible state machine:

    * `:idle` - scenario loaded, nothing has run yet
    * `:running` - the loop is advancing logical time
    * `:paused` - stopped, ready to resume
    * `:converged` - every informed node knows the latest value
    * `:exhausted` - the event queue is empty before convergence

  `:exhausted` is a fault condition. It means a scenario can never converge,
  usually because a permanent partition separated the origin from the rest.
  """

  @type status :: :idle | :running | :paused | :converged | :exhausted

  @type event ::
          {:gossip, pos_integer()}
          | {:deliver, pos_integer(), %{version: non_neg_integer(), value: number()}}
          | {:fault, term()}

  @type state :: %__MODULE__{}

  @type snapshot :: map()

  @enforce_keys [:scenario]

  @derive {Inspect, except: [:rng]}
  defstruct(
    scenario: nil,
    topology: nil,
    nodes: %{},
    queue: [],
    seq: 0,
    clock: 0,
    partitions: %{},
    delay_ms: {35, 70},
    drop_prob: 0.0,
    gossip_interval_ms: 90,
    origin: 1,
    latest: %{value: 100, version: 1},
    rng: nil,
    informed: MapSet.new(),
    history: [],
    event_log: [],
    edge_activity: %{},
    status: :idle,
    steps: 0,
    convergence_time: nil,
    hops: 0,
    dropped: 0,
    delivered: 0,
    log_size: 80
  )

  # ---------------------------------------------------------------------------
  # construction
  # ---------------------------------------------------------------------------

  @doc "Build a fresh core state from a scenario struct."
  def new(%SignalGarden.Sim.Scenario{} = scenario) do
    topology = scenario.topology
    nodes = build_nodes(topology, scenario)
    rng = :rand.seed_s(:exsss, scenario.seed)

    state = %__MODULE__{
      scenario: scenario,
      topology: topology,
      nodes: nodes,
      rng: rng,
      origin: scenario.origin,
      latest: %{value: scenario.latest_value, version: 1},
      delay_ms: scenario.delay_ms,
      drop_prob: scenario.drop_prob,
      gossip_interval_ms: scenario.gossip_interval_ms,
      partitions: Map.new(scenario.partitions),
      informed: MapSet.new([scenario.origin]),
      log_size: 80
    }

    state
    |> schedule_gossip()
    |> schedule_faults()
    |> record_history()
  end

  defp build_nodes(topology, scenario) do
    origin = scenario.origin

    Enum.reduce(topology.nodes, %{}, fn id, acc ->
      known =
        if id == origin do
          %{origin => %{version: 1, value: scenario.latest_value}}
        else
          %{origin => %{version: 0, value: nil}}
        end

      Map.put(acc, id, %{
        id: id,
        known: known,
        neighbors: Map.get(topology.adjacency, id, []),
        informed: id == origin
      })
    end)
  end

  defp schedule_gossip(%__MODULE__{topology: topology} = state) do
    Enum.reduce(topology.nodes, state, fn id, acc ->
      offset = 1 + rem(id, 5)
      push_event(acc, offset, {:gossip, id})
    end)
  end

  defp schedule_faults(%__MODULE__{} = state) do
    Enum.reduce(state.scenario.fault_schedule, state, fn fault, acc ->
      push_event(acc, fault.at, {:fault, fault.action})
    end)
  end

  # ---------------------------------------------------------------------------
  # commands
  # ---------------------------------------------------------------------------

  @doc "Apply a runtime command and return the new state."
  def command(%__MODULE__{} = state, {:set_status, status}), do: %{state | status: status}

  def command(%__MODULE__{} = state, {:set_delay, delay}) when is_integer(delay) and delay >= 0 do
    %{state | delay_ms: {delay, delay}}
  end

  def command(%__MODULE__{} = state, {:set_delay, {lo, hi}})
      when is_integer(lo) and is_integer(hi) and lo >= 0 and hi >= lo do
    %{state | delay_ms: {lo, hi}}
  end

  def command(%__MODULE__{} = state, {:set_drop, drop})
      when is_float(drop) and drop >= 0.0 and drop <= 1.0 do
    %{state | drop_prob: drop}
  end

  def command(%__MODULE__{} = state, {:set_interval, interval})
      when is_integer(interval) and interval > 0 do
    %{state | gossip_interval_ms: interval}
  end

  def command(%__MODULE__{} = state, {:assign, node, group})
      when is_integer(group) do
    %{state | partitions: Map.put(state.partitions, node, group)}
  end

  def command(%__MODULE__{} = state, {:assign_partition, node, group})
      when is_integer(group) do
    %{state | partitions: Map.put(state.partitions, node, group)}
  end

  def command(%__MODULE__{} = state, {:merge, :all}) do
    %{state | partitions: %{}}
  end

  def command(%__MODULE__{} = state, {:toggle_partition, node}) do
    current = Map.get(state.partitions, node, 0)
    next = if current == 0, do: 1, else: 0

    partitions =
      if next == 0,
        do: Map.delete(state.partitions, node),
        else: Map.put(state.partitions, node, next)

    %{state | partitions: partitions}
  end

  def command(%__MODULE__{} = state, {:set_partitions, map}) when is_map(map) do
    %{state | partitions: Map.new(map, fn {k, v} -> {k, v} end)}
  end

  def command(%__MODULE__{} = state, _unknown), do: state

  # ---------------------------------------------------------------------------
  # stepping
  # ---------------------------------------------------------------------------

  @doc """
  Advance the simulation by up to `count` events.

  Returns `{state, processed}` where `processed` is the number of events
  applied. Counting zero events sets the status to `:exhausted` when the
  queue is empty.
  """
  def step(%__MODULE__{} = state, count) when is_integer(count) and count > 0 do
    step_loop(state, count, 0)
  end

  defp step_loop(state, _remaining, processed) when state.status in [:converged, :exhausted] do
    {state, processed}
  end

  defp step_loop(%__MODULE__{queue: []} = state, _remaining, processed) do
    {%{state | status: :exhausted}, processed}
  end

  defp step_loop(state, 0, processed), do: {state, processed}

  defp step_loop(state, remaining, processed) do
    {{time, _seq, event}, rest} = pop_event(state)
    state = %{state | queue: rest, clock: time}
    state = handle_event(state, event)
    state = record_history(state)
    state = maybe_converge(state)
    step_loop(state, remaining - 1, processed + 1)
  end

  # ---------------------------------------------------------------------------
  # event handling
  # ---------------------------------------------------------------------------

  defp handle_event(%__MODULE__{} = state, {:gossip, id}) do
    node = state.nodes[id]

    state
    |> forward_rumor(node)
    |> reschedule_gossip(id)
  end

  defp handle_event(%__MODULE__{} = state, {:deliver, to, payload}) do
    node = state.nodes[to]
    current = Map.get(node.known, state.origin, %{version: 0, value: nil})

    state =
      if payload.version > current.version do
        nodes =
          put_in(state.nodes, [to, :known], Map.put(node.known, state.origin, payload))

        nodes =
          put_in(nodes, [to, :informed], payload.version == state.latest.version)

        informed =
          if payload.version == state.latest.version do
            MapSet.put(state.informed, to)
          else
            state.informed
          end

        %{state | nodes: nodes, informed: informed, delivered: state.delivered + 1}
      else
        %{state | delivered: state.delivered + 1}
      end

    state
  end

  defp handle_event(%__MODULE__{} = state, {:fault, action}) do
    command(state, action)
  end

  defp forward_rumor(%__MODULE__{} = state, node) do
    case pick_neighbour(node, state.rng) do
      {nil, _rng} ->
        state

      {to, rng} ->
        forward(%{state | rng: rng}, node.id, to)
    end
  end

  defp forward(state, from, to) do
    payload = get_in(state.nodes, [from, :known, state.origin])
    key = edge_key(from, to)
    same_partition = same_partition?(state.partitions, from, to)

    {survives, rng} =
      if state.drop_prob > 0.0 do
        roll_drop(state.rng, state.drop_prob)
      else
        {true, state.rng}
      end

    state = %{state | rng: rng}

    cond do
      not same_partition ->
        state
        |> Map.put(:dropped, state.dropped + 1)
        |> log_event(:dropped_partition, from, to)
        |> tap_edge(key, :partition)

      not survives ->
        state
        |> Map.put(:dropped, state.dropped + 1)
        |> log_event(:dropped_loss, from, to)
        |> tap_edge(key, :loss)

      true ->
        {delay, rng1} = sample_delay(state.delay_ms, state.rng)
        deliver_at = state.clock + delay
        state = %{state | rng: rng1, hops: state.hops + 1}
        state = push_event_with(state, deliver_at, {:deliver, to, payload})

        state
        |> log_event(:deliver, from, to)
        |> tap_edge(key, :deliver)
    end
  end

  defp reschedule_gossip(state, id) do
    {jitter, rng} = uniform(state.rng, 0.85, 1.15)
    state = %{state | rng: rng}
    next = state.clock + round(state.gossip_interval_ms * jitter)
    push_event(state, next, {:gossip, id})
  end

  defp maybe_converge(state) do
    total = map_size(state.nodes)
    reached = MapSet.size(state.informed)

    cond do
      state.convergence_time != nil ->
        state

      reached >= total and total > 0 ->
        %{state | status: :converged, convergence_time: state.clock}

      true ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # history / logging
  # ---------------------------------------------------------------------------

  defp record_history(%__MODULE__{} = state) do
    point = %{
      t: state.clock,
      informed: MapSet.size(state.informed),
      total: map_size(state.nodes),
      steps: state.steps
    }

    history = state.history ++ [point]

    history =
      if length(history) > state.log_size do
        Enum.take(history, -state.log_size)
      else
        history
      end

    %{state | history: history, steps: state.steps + 1}
  end

  defp log_event(%__MODULE__{} = state, kind, from, to) do
    entry = %{
      t: state.clock,
      kind: kind,
      from: from,
      to: to,
      partition: Map.get(state.partitions, from, 0) != Map.get(state.partitions, to, 0)
    }

    log = [entry | state.event_log]
    log = Enum.take(log, state.log_size)
    %{state | event_log: log}
  end

  defp tap_edge(%__MODULE__{} = state, key, kind) do
    %{state | edge_activity: Map.put(state.edge_activity, key, {state.clock, kind})}
  end

  # ---------------------------------------------------------------------------
  # queue helpers
  # ---------------------------------------------------------------------------

  defp push_event(%__MODULE__{} = state, time, event) do
    push_event_with(state, time, event)
  end

  defp push_event_with(%__MODULE__{} = state, time, event) do
    seq = state.seq + 1
    queue = insert_event(state.queue, {time, seq, event})
    %{state | queue: queue, seq: seq}
  end

  defp pop_event(%__MODULE__{queue: [head | tail]}), do: {head, tail}

  defp insert_event(queue, entry) do
    {time, _, _} = entry
    insert_at(queue, entry, time, [])
  end

  defp insert_at([], entry, _time, acc), do: Enum.reverse(acc) ++ [entry]

  defp insert_at([{t, _, _} = head | rest], entry, time, acc) when t <= time do
    insert_at(rest, entry, time, [head | acc])
  end

  defp insert_at(rest, entry, _time, acc), do: Enum.reverse(acc) ++ [entry | rest]

  # ---------------------------------------------------------------------------
  # randomness helpers
  # ---------------------------------------------------------------------------

  defp pick_neighbour(%{neighbors: []}, rng), do: {nil, rng}

  defp pick_neighbour(%{neighbors: neighbors}, rng) do
    {idx, rng} = :rand.uniform_s(length(neighbors), rng)
    {Enum.at(neighbors, idx - 1), rng}
  end

  defp roll_drop(rng, prob) do
    {x, rng} = :rand.uniform_s(rng)
    {x > prob, rng}
  end

  defp sample_delay({lo, hi}, rng) when lo == hi, do: {lo, rng}

  defp sample_delay({lo, hi}, rng) do
    {x, rng} = :rand.uniform_s(rng)
    {lo + round((hi - lo) * x), rng}
  end

  defp sample_delay(value, rng) when is_integer(value), do: {value, rng}

  defp uniform(rng, lo, hi) do
    {x, rng} = :rand.uniform_s(rng)
    {lo + (hi - lo) * x, rng}
  end

  # ---------------------------------------------------------------------------
  # partition helpers
  # ---------------------------------------------------------------------------

  defp same_partition?(partitions, a, b) do
    Map.get(partitions, a, 0) == Map.get(partitions, b, 0)
  end

  # ---------------------------------------------------------------------------
  # snapshot
  # ---------------------------------------------------------------------------

  @doc "Return a view-friendly map for the LiveView."
  def snapshot(%__MODULE__{} = state) do
    %{
      scenario: scenario_brief(state.scenario),
      status: state.status,
      clock: state.clock,
      steps: state.steps,
      hops: state.hops,
      delivered: state.delivered,
      dropped: state.dropped,
      convergence_time: state.convergence_time,
      origin: state.origin,
      latest: state.latest,
      delay_ms: state.delay_ms,
      drop_prob: state.drop_prob,
      gossip_interval_ms: state.gossip_interval_ms,
      partitions: state.partitions,
      nodes: snapshot_nodes(state),
      edges: snapshot_edges(state),
      history: state.history,
      event_log: Enum.reverse(state.event_log),
      reached: MapSet.size(state.informed),
      total: map_size(state.nodes)
    }
  end

  defp snapshot_nodes(%__MODULE__{} = state) do
    Enum.map(state.topology.nodes, fn id ->
      node = state.nodes[id]
      {x, y} = Map.fetch!(state.topology.layout, id)

      %{
        id: id,
        x: x,
        y: y,
        informed: node.informed,
        is_origin: id == state.origin,
        partition: Map.get(state.partitions, id, 0),
        value: get_in(node, [Access.key(:known), state.origin, Access.key(:value)]),
        version: get_in(node, [Access.key(:known), state.origin, Access.key(:version)])
      }
    end)
  end

  defp snapshot_edges(%__MODULE__{} = state) do
    Enum.map(state.topology.edges, fn {a, b} = _pair ->
      key = edge_key(a, b)
      {t, kind} = Map.get(state.edge_activity, key, {nil, nil})

      %{
        a: a,
        b: b,
        key: key,
        last_time: t,
        last_kind: kind,
        partitioned: Map.get(state.partitions, a, 0) != Map.get(state.partitions, b, 0)
      }
    end)
  end

  defp scenario_brief(nil), do: nil

  defp scenario_brief(scenario) do
    %{
      id: scenario.id,
      name: scenario.name,
      description: scenario.description,
      seed: scenario.seed
    }
  end

  defp edge_key(a, b), do: if(a <= b, do: {a, b}, else: {b, a})
end
