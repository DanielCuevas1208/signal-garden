# Signal Garden

Signal Garden is an interactive distributed-systems simulator.
It shows message delay, network partitions, retries, and eventual
convergence in a browser.
A deterministic gossip network runs in Elixir.
A Phoenix LiveView control room shows the signal as it spreads.

The same scenario always produces the same event trace.
Two runs with the same seed produce the same bytes.
Anyone can replay the same fault on another machine.

## What it shows

- An actor model gossip engine written in pure Elixir.
- Logical time that has no link to the wall clock.
- Three network hazards: delay, message loss, and partitions.
- Node crash and restart. A crashed node forgets its state.
- Deterministic scenarios with fixed seeds and fault schedules.
- A live SVG graph, a convergence chart, and an event feed.
- A grow-only counter. Nodes merge counts without losing updates.

## Payload modes

A scenario runs in one of two payload modes.

**Rumor.** One origin seeds a single value.
Nodes spread the value until every node knows it.

**G-Counter.** Every node owns one slot of a grow-only counter.
Gossip merges slots with element-wise max.
The counter value is the sum of the vector.
The network converges on the total count of increments.

The counter mode is a CRDT.
A merge never deletes an increment.
A node keeps a count it already received, even if the source node crashes.
This is the key difference from the rumor mode.

## Architecture

Signal Garden separates the deterministic core from the live interface.

```
lib/signal_garden/
  sim/
    core.ex           # Pure, side-effect-free state machine.
    engine.ex         # GenServer that drives the core and broadcasts snapshots.
    scenario.ex       # Data shape for one run.
    scenario_codec.ex # JSON import and export for scenarios.
    topology.ex       # Builds line, ring, grid, complete, and random graphs.
  scenarios.ex        # The built-in catalog of scenarios.
  sim.ex              # Thin facade the LiveView calls.
```

The `Core` module advances logical time in discrete steps.
Each step pops one event from a priority queue.
A gossip event makes a node send a message to one neighbour.
The engine applies delay, loss, and partition checks.
It then schedules a delivery event in the future.
Two runs with the same seed walk the same path.

The `Engine` GenServer owns a `Core` struct.
On each animation frame it advances the core by a burst of events.
It broadcasts a snapshot over Phoenix PubSub.
The LiveView subscribes to that topic and re-renders the graph.
The core never touches the network, so tests stay fast.

The web layer lives in `lib/signal_garden_web/`.
A single LiveView renders the control room.
Plain HEEx templates use hand-written CSS classes.

## Setup

Install Elixir 1.17 or later.
Erlang/OTP 27 or later is required.

Run setup once to fetch dependencies and build the assets.

```
mix setup
```

Start the server.

```
mix phx.server
```

Open the control room in a browser.

```
http://localhost:4000
```

Press **Run** to start the loop.
Press **Step** to advance a fixed number of events.
Click a node to toggle its partition group.
Drag the sliders to change delay, loss rate, and speed.
Pick a scenario from the list to load a new run.

Use the **Node fault** box to crash, restart, or count a node.
Use **Export JSON** to download the active scenario.
Use **Import JSON** to paste a file and load it.
A sample file ships at `priv/scenarios/ring.json`.

## Scenario files

A scenario file is versioned JSON.
It carries the topology, the seed, the fault schedule, and every network parameter.
Two machines can share one file and replay the same run.

Export a scenario from the control room, or build a file by hand.
The format requires `format: 1` and a `topology` block.
Load a file in the browser or decode it in tests.

```
alias SignalGarden.Sim.ScenarioCodec
{:ok, scenario} = File.read!("priv/scenarios/ring.json") |> ScenarioCodec.decode()
```

## Built-in scenarios

The catalog ships with ten runs.
Each one fixes a topology, a seed, and a set of network conditions.

| Scenario | Nodes | Faults |
| --- | --- | --- |
| Line | 8 | none |
| Ring | 12 | none |
| Grid | 30 | none |
| Random graph | 16 | none |
| Healing partition | 14 | a split forms, then heals |
| Churn | 15 | partitions toggle on a schedule |
| Lossy link | 14 | five percent of messages lost |
| Crash and recover | 12 | two nodes crash, then restart |
| Counter ring | 10 | counter mode, one count per node |
| Counter split | 12 | a split, two counts, then a heal |

## Sample output

The block below is real output from a deterministic run of every scenario.
It uses the `Core` module only.
There is no animation loop and no browser.
Reproduce it with the command below.

```
scenario            nodes  status       t(ms)     hops   dropped   steps
Line                8      converged    772       72     0         142
Ring                12     converged    750       120    0         236
Grid                30     converged    1295      564    0         1112
Random graph        16     converged    715       160    0         312
Healing partition   14     converged    1397      198    51        446
Churn               15     converged    731       152    4         309
Lossy link          14     converged    594       120    6         237
Crash and recover   12     converged    1815      269    24        540
Counter ring        10     converged    842       111    0         219
Counter split       12     converged    2417      299    92        692
```

The determinism check confirms the core is reproducible.

```
ring determinism: convergence_time equal = true
ring determinism: history equal          = true
ring determinism: event_log equal        = true
crash determinism: convergence_time equal = true
crash determinism: event_log equal        = true
counter determinism: convergence_time equal = true
counter determinism: event_log equal        = true
```

Reproduce this output from a checkout.

```
mix run --no-start priv/sample.exs
```

## Status model

The control room shows a status pill.
The status drives the run loop.

- **Ready**: a scenario is loaded and idle.
- **Running**: the loop advances logical time.
- **Paused**: the loop stopped and can resume.
- **Converged**: every node knows the latest value.
- **Stalled**: the event queue emptied before convergence.

A stalled run is a fault condition.
It usually means a permanent partition separated the origin from the rest.

## Crash and restart

A crash takes a node out of service.
The node stops gossiping and forgets what it knew.
In-flight messages to it are dropped.
The network cannot converge while any node is down.

A restart returns the node to service.
The node starts empty and re-joins the gossip loop.
It re-learns the latest value from its neighbours.

The **Crash and recover** scenario demonstrates this flow.
You can also crash and restart nodes by hand from the control room.

## Counters and CRDTs

The counter mode uses a grow-only counter.
Each node owns one slot of the counter vector.
Gossip merges slots with element-wise max.

The **Counter split** scenario shows the CRDT guarantee.
Three nodes split into their own group.
They count again while isolated.
The heal merges both sides.
The total reaches fourteen.
The counts made during the split are never lost.

Use the **Count** button to add an increment to any node.
The per-node count appears below each node in the graph.
The **Value** stat shows the best count seen so far.

## Testing

Run the full suite.

```
mix test
```

The suite has 62 tests.
It covers the deterministic core, the topology builder, the scenario codec,
the scenario catalog, the engine GenServer, and the LiveView.
Tests never sleep and never read the wall clock.
Each core test replays a scenario and asserts on the resulting state.

Run the precommit alias before you finish a change.

```
mix precommit
```

## Limitations

- Logical time is synthetic, so convergence times compare runs, not real hosts.
- Partitions are modelled as group labels, not as link failures per edge.
- Crashes lose all node state. There is no disk or persistent memory model.
- A counter increment held only by a crashed node is lost forever.
- The engine runs one scenario at a time inside a single GenServer.
- The interface uses one SVG canvas, so very large graphs stay modest by design.
- Persistence is out of scope: a restart reloads the default scenario.
- Imported scenarios use a custom topology. They do not appear in the catalog list.

## Roadmap

- **Scenario import and export.** Done. JSON files round-trip through the codec and the control room.
- **Crash and restart.** Done. Nodes crash, drop state, and recover through the control room.
- **Counters and CRDTs.** Done. A grow-only counter merges through partitions without loss.
- **Headless replay tool.** Run a scenario from the CLI and print a trace.
- **Edge-level partitions.** Cut a single link instead of a node group.

## License

See `LICENSE` for the terms of use.
