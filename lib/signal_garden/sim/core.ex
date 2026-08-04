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
    * cut link - a broken edge drops every message that crosses it
    * partition - a message that crosses a partition boundary is dropped
    * loss - a fair die roll drops a fixed fraction of messages

  A link cut is an edge-level fault. It breaks one link between two nodes in
  both directions, while a group partition splits the whole network. Cut a
  link to isolate a node or to slow a path. Heal it to restore the edge.

  A node can also crash. A crashed node stops gossiping, forgets what it
  knew, and drops the deliveries that arrive while it is down. Restarting
  the node brings it back with empty state so it must re-learn the value
  from its neighbours.

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

  ## Modes

  A scenario runs in one of two modes.

  The `:rumor` mode (the default) gossips one value with a version. The origin
  node seeds the value, and a node becomes informed when it holds that exact
  version.

  The `:counter` mode gossips a grow-only counter. Each node keeps one cell per
  node id. An increment action adds to the cell of the writing node, and a
  message carries the sender's whole cell map. On delivery the receiver merges
  with element-wise max, so every node converges to the same total. A node is
  informed when its own total equals the total of all increments issued so far.
  Convergence requires that every scheduled increment has been issued.

  The `:set` mode gossips a grow-only set. Each node holds a set of elements.
  An add action puts one element into the set of the writing node, and a
  message carries the sender's whole set. On delivery the receiver merges with
  set union, so every node converges to the same collection. A node is
  informed when its set contains every element added so far. Convergence
  requires that every scheduled add has been issued.

  The `:register` mode gossips a last-writer-wins register. Each node holds
  one value and the version of the write that produced it. A write action
  puts a new value on the writing node with a new version. On delivery the
  receiver keeps the value with the higher version, so the newest write wins
  everywhere. A node is informed when it holds the latest write. Convergence
  requires that every scheduled write has been issued.
  """

  @type status :: :idle | :running | :paused | :converged | :exhausted
  @type mode :: :rumor | :counter | :set | :register

  @type event ::
          {:gossip, pos_integer()}
          | {:deliver, pos_integer(), map()}
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
    link_cuts: MapSet.new(),
    delay_ms: {35, 70},
    drop_prob: 0.0,
    gossip_interval_ms: 90,
    origin: 1,
    latest: %{value: 100, version: 1},
    mode: :rumor,
    increments_issued: 0,
    increments_total: 0,
    increment_target: 0,
    adds_issued: 0,
    adds_total: 0,
    adds_target: 0,
    elements: MapSet.new(),
    writes_issued: 0,
    writes_target: 0,
    register_value: nil,
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
      latest: latest_for(scenario),
      mode: scenario.mode,
      increments_issued: 0,
      increments_total: 0,
      increment_target: scheduled_increments(scenario),
      adds_issued: 0,
      adds_total: 0,
      adds_target: scheduled_adds(scenario),
      elements: MapSet.new(),
      writes_issued: 0,
      writes_target: scheduled_writes(scenario),
      register_value: nil,
      delay_ms: scenario.delay_ms,
      drop_prob: scenario.drop_prob,
      gossip_interval_ms: scenario.gossip_interval_ms,
      partitions: Map.new(scenario.partitions),
      link_cuts: MapSet.new(scenario.link_cuts, &edge_key/1),
      informed: initial_informed(scenario),
      log_size: 80
    }

    state
    |> schedule_gossip()
    |> schedule_faults()
    |> record_history()
  end

  defp latest_for(%SignalGarden.Sim.Scenario{mode: mode})
       when mode in [:counter, :set, :register],
       do: %{value: 0, version: 0}

  defp latest_for(%SignalGarden.Sim.Scenario{latest_value: value}),
    do: %{value: value, version: 1}

  defp scheduled_increments(%SignalGarden.Sim.Scenario{mode: :counter} = scenario) do
    Enum.count(scenario.fault_schedule, fn fault ->
      match?({:increment, _, _}, fault.action)
    end)
  end

  defp scheduled_increments(_scenario), do: 0

  defp scheduled_adds(%SignalGarden.Sim.Scenario{mode: :set} = scenario) do
    Enum.count(scenario.fault_schedule, fn fault ->
      match?({:add, _, _}, fault.action)
    end)
  end

  defp scheduled_adds(_scenario), do: 0

  defp scheduled_writes(%SignalGarden.Sim.Scenario{mode: :register} = scenario) do
    Enum.count(scenario.fault_schedule, fn fault ->
      match?({:write, _, _}, fault.action)
    end)
  end

  defp scheduled_writes(_scenario), do: 0

  defp initial_informed(%SignalGarden.Sim.Scenario{mode: mode})
       when mode in [:counter, :set, :register],
       do: MapSet.new()

  defp initial_informed(%SignalGarden.Sim.Scenario{origin: origin}),
    do: MapSet.new([origin])

  defp build_nodes(topology, scenario) do
    origin = scenario.origin

    Enum.reduce(topology.nodes, %{}, fn id, acc ->
      known =
        case scenario.mode do
          :counter ->
            %{origin => %{cells: %{}}}

          :set ->
            %{origin => %{elements: MapSet.new()}}

          :register ->
            %{origin => %{value: nil, version: 0}}

          _ ->
            if id == origin do
              %{origin => %{version: 1, value: scenario.latest_value}}
            else
              %{origin => %{version: 0, value: nil}}
            end
        end

      Map.put(acc, id, %{
        id: id,
        up: true,
        known: known,
        neighbors: Map.get(topology.adjacency, id, []),
        informed: scenario.mode == :rumor and id == origin
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
    %{state | partitions: %{}, link_cuts: MapSet.new()}
  end

  def command(%__MODULE__{} = state, {:cut, {a, b}}) when is_integer(a) and is_integer(b) do
    %{state | link_cuts: MapSet.put(state.link_cuts, edge_key(a, b))}
  end

  def command(%__MODULE__{} = state, {:cut_link, {a, b}}) when is_integer(a) and is_integer(b) do
    command(state, {:cut, {a, b}})
  end

  def command(%__MODULE__{} = state, {:heal_link, {a, b}}) when is_integer(a) and is_integer(b) do
    %{state | link_cuts: MapSet.delete(state.link_cuts, edge_key(a, b))}
  end

  def command(%__MODULE__{} = state, {:toggle_link_cut, {a, b}})
      when is_integer(a) and is_integer(b) do
    key = edge_key(a, b)

    cuts =
      if MapSet.member?(state.link_cuts, key),
        do: MapSet.delete(state.link_cuts, key),
        else: MapSet.put(state.link_cuts, key)

    %{state | link_cuts: cuts}
  end

  def command(%__MODULE__{} = state, {:crash, node}) when is_integer(node) do
    crash_node(state, node)
  end

  def command(%__MODULE__{} = state, {:restart, node}) when is_integer(node) do
    restart_node(state, node)
  end

  def command(%__MODULE__{mode: :counter} = state, {:increment, node, amount})
      when is_integer(node) and is_integer(amount) and amount > 0 do
    apply_increment(state, node, amount, true)
  end

  def command(%__MODULE__{mode: :set} = state, {:add, node, element})
      when is_integer(node) and (is_binary(element) or is_number(element)) do
    apply_add(state, node, element, true)
  end

  def command(%__MODULE__{mode: :register} = state, {:write, node, value})
      when is_integer(node) and (is_binary(value) or is_number(value)) do
    apply_write(state, node, value, true)
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
  # crash / restart
  # ---------------------------------------------------------------------------

  defp crash_node(%__MODULE__{} = state, node) do
    nodes = put_in(state.nodes, [node, :up], false)
    nodes = put_in(nodes, [node, :informed], false)
    nodes = put_in(nodes, [node, :known], empty_known(state))

    state = %{
      state
      | nodes: nodes,
        informed: MapSet.delete(state.informed, node)
    }

    log_fault(state, :crashed, node)
  end

  defp restart_node(%__MODULE__{} = state, node) do
    nodes = put_in(state.nodes, [node, :up], true)
    nodes = put_in(nodes, [node, :informed], false)
    nodes = put_in(nodes, [node, :known], empty_known(state))

    state = %{state | nodes: nodes}

    state
    |> log_fault(:restarted, node)
    |> push_event(state.clock + 1, {:gossip, node})
  end

  defp empty_known(%__MODULE__{mode: :counter, origin: origin}),
    do: %{origin => %{cells: %{}}}

  defp empty_known(%__MODULE__{mode: :set, origin: origin}),
    do: %{origin => %{elements: MapSet.new()}}

  defp empty_known(%__MODULE__{mode: :register, origin: origin}),
    do: %{origin => %{value: nil, version: 0}}

  defp empty_known(%__MODULE__{origin: origin}),
    do: %{origin => %{version: 0, value: nil}}

  defp log_fault(%__MODULE__{} = state, kind, node) do
    entry = %{
      t: state.clock,
      kind: kind,
      from: node,
      to: nil,
      partition: false
    }

    log = [entry | state.event_log]
    log = Enum.take(log, state.log_size)
    %{state | event_log: log}
  end

  defp log_increment(%__MODULE__{} = state, node, amount) do
    entry = %{
      t: state.clock,
      kind: :increment,
      from: node,
      to: nil,
      amount: amount,
      partition: false
    }

    log = [entry | state.event_log]
    log = Enum.take(log, state.log_size)
    %{state | event_log: log}
  end

  defp log_add(%__MODULE__{} = state, node, element) do
    entry = %{
      t: state.clock,
      kind: :added,
      from: node,
      to: nil,
      element: element,
      partition: false
    }

    log = [entry | state.event_log]
    log = Enum.take(log, state.log_size)
    %{state | event_log: log}
  end

  defp log_write(%__MODULE__{} = state, node, value) do
    entry = %{
      t: state.clock,
      kind: :wrote,
      from: node,
      to: nil,
      value: value,
      partition: false
    }

    log = [entry | state.event_log]
    log = Enum.take(log, state.log_size)
    %{state | event_log: log}
  end

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

    if node.up do
      state
      |> forward_rumor(node)
      |> reschedule_gossip(id)
    else
      state
    end
  end

  defp handle_event(%__MODULE__{} = state, {:deliver, to, payload}) do
    case state.mode do
      :counter -> deliver_counter(state, to, payload)
      :set -> deliver_set(state, to, payload)
      :register -> deliver_register(state, to, payload)
      _ -> deliver_rumor(state, to, payload)
    end
  end

  defp handle_event(%__MODULE__{} = state, {:fault, {:increment, node, amount}}) do
    apply_increment(state, node, amount, false)
  end

  defp handle_event(%__MODULE__{} = state, {:fault, {:add, node, element}}) do
    apply_add(state, node, element, false)
  end

  defp handle_event(%__MODULE__{} = state, {:fault, {:write, node, value}}) do
    apply_write(state, node, value, false)
  end

  defp handle_event(%__MODULE__{} = state, {:fault, action}) do
    command(state, action)
  end

  defp deliver_rumor(%__MODULE__{} = state, to, payload) do
    node = state.nodes[to]

    if not node.up do
      %{state | dropped: state.dropped + 1}
    else
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
  end

  defp deliver_counter(%__MODULE__{} = state, to, payload) do
    node = state.nodes[to]

    if not node.up do
      %{state | dropped: state.dropped + 1}
    else
      current = get_in(node.known, [state.origin])
      cells = merge_counter(current.cells, payload.cells)

      nodes = put_in(state.nodes, [to, :known, state.origin], %{cells: cells})
      state = %{state | nodes: nodes, delivered: state.delivered + 1}
      refresh_node_informed(state, to)
    end
  end

  defp deliver_set(%__MODULE__{} = state, to, payload) do
    node = state.nodes[to]

    if not node.up do
      %{state | dropped: state.dropped + 1}
    else
      current = get_in(node.known, [state.origin])
      elements = MapSet.union(current.elements, payload.elements)

      nodes = put_in(state.nodes, [to, :known, state.origin], %{elements: elements})
      state = %{state | nodes: nodes, delivered: state.delivered + 1}
      refresh_node_informed(state, to)
    end
  end

  defp deliver_register(%__MODULE__{} = state, to, payload) do
    node = state.nodes[to]

    if not node.up do
      %{state | dropped: state.dropped + 1}
    else
      current = get_in(node.known, [state.origin])

      next =
        if payload.version > current.version do
          %{value: payload.value, version: payload.version}
        else
          current
        end

      nodes = put_in(state.nodes, [to, :known, state.origin], next)
      state = %{state | nodes: nodes, delivered: state.delivered + 1}
      refresh_node_informed(state, to)
    end
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
    cut = MapSet.member?(state.link_cuts, key)

    {survives, rng} =
      if state.drop_prob > 0.0 do
        roll_drop(state.rng, state.drop_prob)
      else
        {true, state.rng}
      end

    state = %{state | rng: rng}

    cond do
      cut ->
        state
        |> Map.put(:dropped, state.dropped + 1)
        |> log_event(:dropped_cut, from, to, cut: true)
        |> tap_edge(key, :cut)

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

      reached >= total and total > 0 and fault_target_met?(state) ->
        %{state | status: :converged, convergence_time: state.clock}

      true ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # counter mode (grow-only counter)
  # ---------------------------------------------------------------------------

  defp apply_increment(%__MODULE__{mode: :counter} = state, node, amount, bump_target?) do
    issued = state.increments_issued + 1
    total = state.increments_total + amount
    target = if bump_target?, do: state.increment_target + 1, else: state.increment_target

    {status, convergence_time} = rearm(state.status, state.convergence_time, bump_target?)

    cells =
      get_in(state.nodes, [node, :known, state.origin, :cells])
      |> Map.update(node, amount, &(&1 + amount))

    state = %{
      state
      | increments_issued: issued,
        increments_total: total,
        increment_target: target,
        latest: %{value: total, version: issued},
        status: status,
        convergence_time: convergence_time
    }

    nodes = put_in(state.nodes, [node, :known, state.origin], %{cells: cells})
    state = %{state | nodes: nodes}

    state
    |> refresh_all_informed()
    |> log_increment(node, amount)
  end

  # A manual increment after the run finished re-arms the run so the new write
  # can be watched. Clearing the convergence time lets the core converge again.
  # Scheduled increments leave the status untouched.
  defp rearm(status, _time, true) when status in [:converged, :exhausted], do: {:idle, nil}
  defp rearm(status, time, _), do: {status, time}

  defp merge_counter(cells_a, cells_b) do
    Map.merge(cells_a, cells_b, fn _node, a, b -> max(a, b) end)
  end

  defp counter_total(%{known: known}, origin) do
    known[origin].cells
    |> Map.values()
    |> Enum.sum()
  end

  defp counter_informed?(%__MODULE__{} = state, node_id) do
    node = state.nodes[node_id]

    node.up and
      state.increments_issued >= state.increment_target and
      counter_total(node, state.origin) == state.increments_total
  end

  # ---------------------------------------------------------------------------
  # set mode (grow-only set)
  # ---------------------------------------------------------------------------

  defp apply_add(%__MODULE__{mode: :set} = state, node, element, bump_target?) do
    issued = state.adds_issued + 1
    elements = MapSet.put(state.elements, element)
    target = if bump_target?, do: state.adds_target + 1, else: state.adds_target

    {status, convergence_time} = rearm(state.status, state.convergence_time, bump_target?)

    state = %{
      state
      | adds_issued: issued,
        adds_total: MapSet.size(elements),
        adds_target: target,
        elements: elements,
        latest: %{value: MapSet.size(elements), version: issued},
        status: status,
        convergence_time: convergence_time
    }

    nodes = put_in(state.nodes, [node, :known, state.origin], %{elements: elements})
    state = %{state | nodes: nodes}

    state
    |> refresh_all_informed()
    |> log_add(node, element)
  end

  defp set_informed?(%__MODULE__{} = state, node_id) do
    node = state.nodes[node_id]

    node.up and
      state.adds_issued >= state.adds_target and
      MapSet.size(node.known[state.origin].elements) == MapSet.size(state.elements)
  end

  # ---------------------------------------------------------------------------
  # register mode (last-writer-wins register)
  # ---------------------------------------------------------------------------

  defp apply_write(%__MODULE__{mode: :register} = state, node, value, bump_target?) do
    issued = state.writes_issued + 1
    target = if bump_target?, do: state.writes_target + 1, else: state.writes_target

    {status, convergence_time} = rearm(state.status, state.convergence_time, bump_target?)

    state = %{
      state
      | writes_issued: issued,
        writes_target: target,
        register_value: value,
        latest: %{value: value, version: issued},
        status: status,
        convergence_time: convergence_time
    }

    nodes = put_in(state.nodes, [node, :known, state.origin], %{value: value, version: issued})
    state = %{state | nodes: nodes}

    state
    |> refresh_all_informed()
    |> log_write(node, value)
  end

  defp register_informed?(%__MODULE__{} = state, node_id) do
    node = state.nodes[node_id]

    node.up and
      state.writes_issued >= state.writes_target and
      get_in(node.known, [state.origin]).version == state.writes_issued
  end

  # ---------------------------------------------------------------------------
  # convergence targets
  # ---------------------------------------------------------------------------

  defp fault_target_met?(%__MODULE__{mode: :counter} = state) do
    state.increments_issued >= state.increment_target
  end

  defp fault_target_met?(%__MODULE__{mode: :set} = state) do
    state.adds_issued >= state.adds_target
  end

  defp fault_target_met?(%__MODULE__{mode: :register} = state) do
    state.writes_issued >= state.writes_target
  end

  defp fault_target_met?(_state), do: true

  defp refresh_node_informed(%__MODULE__{} = state, node_id) do
    informed? = node_informed?(state, node_id)

    nodes = put_in(state.nodes, [node_id, :informed], informed?)

    informed =
      if informed?,
        do: MapSet.put(state.informed, node_id),
        else: MapSet.delete(state.informed, node_id)

    %{state | nodes: nodes, informed: informed}
  end

  defp node_informed?(%__MODULE__{mode: :counter} = state, node_id),
    do: counter_informed?(state, node_id)

  defp node_informed?(%__MODULE__{mode: :set} = state, node_id),
    do: set_informed?(state, node_id)

  defp node_informed?(%__MODULE__{mode: :register} = state, node_id),
    do: register_informed?(state, node_id)

  defp node_informed?(%__MODULE__{nodes: nodes}, node_id), do: nodes[node_id].informed

  defp refresh_all_informed(%__MODULE__{} = state) do
    Enum.reduce(state.topology.nodes, state, fn node_id, acc ->
      refresh_node_informed(acc, node_id)
    end)
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

  defp log_event(%__MODULE__{} = state, kind, from, to, extra \\ []) do
    entry = %{
      t: state.clock,
      kind: kind,
      from: from,
      to: to,
      partition: Map.get(state.partitions, from, 0) != Map.get(state.partitions, to, 0)
    }

    entry = Map.merge(entry, Map.new(extra))

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
      mode: state.mode,
      counter_total: state.increments_total,
      counter_writes: state.increments_issued,
      set_size: MapSet.size(state.elements),
      set_adds: state.adds_issued,
      set_elements: Enum.sort(MapSet.to_list(state.elements)),
      register_value: state.register_value,
      register_writes: state.writes_issued,
      delay_ms: state.delay_ms,
      drop_prob: state.drop_prob,
      gossip_interval_ms: state.gossip_interval_ms,
      partitions: state.partitions,
      link_cuts: MapSet.to_list(state.link_cuts),
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
        up: node.up,
        informed: node.informed,
        is_origin: id == state.origin,
        partition: Map.get(state.partitions, id, 0),
        value: node_value(state, node),
        version: node_version(state, node)
      }
    end)
  end

  defp node_value(%__MODULE__{mode: :counter, origin: origin}, node) do
    Enum.sum(Map.values(node.known[origin].cells))
  end

  defp node_value(%__MODULE__{mode: :set, origin: origin}, node) do
    MapSet.size(node.known[origin].elements)
  end

  defp node_value(%__MODULE__{mode: :register, origin: origin}, node) do
    node.known[origin].version
  end

  defp node_value(%__MODULE__{origin: origin}, node) do
    get_in(node, [Access.key(:known), origin, Access.key(:value)])
  end

  defp node_version(%__MODULE__{mode: :counter} = state, _node), do: state.increments_issued
  defp node_version(%__MODULE__{mode: :set} = state, _node), do: state.adds_issued

  defp node_version(%__MODULE__{mode: :register, origin: origin}, node) do
    node.known[origin].version
  end

  defp node_version(%__MODULE__{origin: origin}, node) do
    get_in(node, [Access.key(:known), origin, Access.key(:version)])
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
        cut: MapSet.member?(state.link_cuts, key),
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

  defp edge_key({a, b}), do: edge_key(a, b)

  defp edge_key(a, b), do: if(a <= b, do: {a, b}, else: {b, a})
end
