# Signal Garden

Signal Garden is an interactive distributed-systems simulator. It shows
message delay, network partitions, retries, and eventual convergence in a
browser. A deterministic gossip network runs in Elixir. A Phoenix LiveView
control room shows the message as it spreads.

The same scenario always produces the same event trace, convergence time, and
history. Two runs with the same seed produce the same bytes. Anyone can replay
the same fault on another machine.

## What it shows

- An actor model gossip engine written in pure Elixir.
- Logical time that has no link to the wall clock.
- Three network hazards: delay, message loss, and partitions.
- Node crash and restart. A crashed node forgets its state and stops the spread.
- Two gossip payloads: a rumor and a grow-only counter.
- A grow-only counter (G-Counter) that converges across the network.
- Deterministic scenarios with fixed seeds and fault schedules.
- A live SVG graph, a convergence chart, and an event feed.

## Architecture

Signal Garden separates the deterministic core from the live interface.

```
lib/signal_garden/
  sim/
    core.ex           # Pure, side-effect-free state machine. Owns the event queue.
    engine.ex         # GenServer that drives the core and broadcasts snapshots.
    scenario.ex       # Data shape for one run: topology, seed, faults, conditions.
    scenario_codec.ex # JSON import and export for scenarios.
    replay.ex         # Headless, deterministic replay. Backs the CLI and sample script.
    topology.ex       # Builds line, ring, grid, complete, and random graphs.
  scenarios.ex        # The built-in catalog of scenarios.
  sim.ex              # Thin facade the LiveView calls.
```

The `Core` module advances logical time in discrete steps. Each step pops one
event from a priority queue. A gossip event makes a node send a message to one
neighbour. The engine applies delay, loss, and partition checks, then schedules
a delivery event in the future. Two runs with the same seed walk the same path.

The `Engine` GenServer owns a `Core` struct. On each animation frame it advances
the core by a burst of events and broadcasts a snapshot over Phoenix PubSub.
The LiveView subscribes to that topic and re-renders the graph. The core never
touches the network, so tests stay fast and deterministic.

The web layer lives in `lib/signal_garden_web/`. A single LiveView renders the
control room. Plain HEEx templates use hand-written CSS classes, not a UI kit.

## Setup

Install Elixir 1.17 or later. Erlang/OTP 27 or later is required.

Run setup once to fetch dependencies and build the assets:

```
mix setup
```

Start the server:

```
mix phx.server
```

Open the control room in a browser:

```
http://localhost:4000
```

Press **Run** to start the loop. Press **Step** to advance a fixed number of
events. Click a node to toggle its partition group. Drag the sliders to change
delay, loss rate, and speed. Pick a scenario from the list to load a new run.

Use the **Node fault** box to crash a node or restart it. In counter mode, use
the box to write to a node. Use **Export JSON** to download the active
scenario. Use **Import JSON** to paste a file and load it into the control
room. Sample files ship at `priv/scenarios/ring.json` and
`priv/scenarios/counter.json`.

## Scenario files

A scenario file is versioned JSON. It carries the topology, the seed, the fault
schedule, the payload mode, and every network parameter. Two machines can share
one file and replay the same run.

Export a scenario from the control room, or build a file by hand. The format
requires `format: 1` and a `topology` block with `nodes`, `edges`, and
`layout`. Load a file in the browser or decode it in tests:

```
alias SignalGarden.Sim.ScenarioCodec
{:ok, scenario} = File.read!("priv/scenarios/ring.json") |> ScenarioCodec.decode()
```

## Built-in scenarios

The scenario catalog ships with nine runs. Each one fixes a topology, a seed,
and a set of network conditions.

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
| Grow-only counter | 12 | five writes climb a G-Counter on a schedule |

## Counters and CRDTs

The **Grow-only counter** scenario swaps the rumor for a G-Counter CRDT. This
is the classic counter from the CRDT family. It shows eventual convergence in
its purest form.

Each node keeps one cell per node id. A write adds to the cell of the writing
node. A gossip message carries the sender's whole cell map. On delivery, the
receiver merges the map with element-wise max. The counter total is the sum of
the cells. Every node converges to the same total, even when messages drop,
reorder, or split the network.

The control room shows the total above each node. The **+1** button in the
Node fault box writes to the selected node. The convergence chart tracks how
many nodes hold the latest total. A write moves the frontier, and the chart
re-climbs as the write spreads.

Convergence needs every scheduled write to be issued. The run re-arms when you
write after it converged, so you can watch the new total spread. A manual
write survives only the current run. Reset rebuilds the scenario from its seed.

## Sample output

The block below is real output from a deterministic run of every scenario. It
was produced with the `Replay` module only, with no animation loop and no
browser. Reproduce it with the command below.

```
scenario           nodes  status     t(ms)  hops  dropped  steps
Line               8      converged  772    72    0        142
Ring               12     converged  750    120   0        236
Grid               30     converged  1295   564   0        1112
Random graph       16     converged  715    160   0        312
Healing partition  14     converged  1397   198   51       446
Churn              15     converged  731    152   4        309
Lossy link         14     converged  594    120   6        237
Crash and recover  12     converged  1815   269   24       540
Grow-only counter  12     converged  3832   617   44       1281
```

The determinism check confirms the core is reproducible. Every scenario
replays to an identical result:

```
Line: deterministic = true (t=772ms, 142 steps, 72 events)
Ring: deterministic = true (t=750ms, 236 steps, 120 events)
Grid: deterministic = true (t=1295ms, 1112 steps, 564 events)
Random graph: deterministic = true (t=715ms, 312 steps, 160 events)
Healing partition: deterministic = true (t=1397ms, 446 steps, 249 events)
Churn: deterministic = true (t=731ms, 309 steps, 156 events)
Lossy link: deterministic = true (t=594ms, 237 steps, 126 events)
Crash and recover: deterministic = true (t=1815ms, 540 steps, 273 events)
Grow-only counter: deterministic = true (t=3832ms, 1281 steps, 666 events)
```

Reproduce this output from a checkout with:

```
mix run --no-start priv/sample.exs
```

## Headless replay

The `mix garden.replay` task runs the same core from the command line. It
prints a report without starting the server. The output is deterministic, so
it is safe to diff and safe to record in a changelog.

Run every catalog scenario:

```
mix garden.replay
```

Run one scenario by id:

```
mix garden.replay ring
```

Run a scenario file:

```
mix garden.replay priv/scenarios/counter.json
```

Print the full event trace:

```
mix garden.replay lossy --trace
```

The trace lists every delivery, drop, crash, restart, and counter write in
chronological order. Two runs produce the same trace.

Confirm determinism:

```
mix garden.replay --verify
```

Emit machine-readable JSON for a script or a diff:

```
mix garden.replay counter --json
```

The `SignalGarden.Sim.Replay` module backs the task. It runs a scenario to
completion and returns the summary numbers plus the full trace. Tests drive
this module directly, so the CLI has the same coverage as the core.

## Status model

The control room shows a status pill. The status drives the run loop.

- **Ready**: a scenario is loaded and idle.
- **Running**: the loop advances logical time.
- **Paused**: the loop stopped and can resume.
- **Converged**: every node knows the latest value.
- **Stalled**: the event queue emptied before convergence.

A stalled run is a fault condition. It usually means a permanent partition
separated the origin from the rest of the network.

In counter mode, **Converged** means every node holds the final counter total.
The run cannot converge before every scheduled write is issued.

## Crash and restart

A crash takes a node out of service. The node stops gossiping and forgets what
it knew. In-flight messages to it are dropped. The network cannot converge
while any node is down.

A restart returns the node to service. The node starts empty and re-joins the
gossip loop. It re-learns the latest state from its neighbours. Convergence
returns once every node is back up and informed.

The **Crash and recover** scenario demonstrates this flow. It crashes two nodes
mid-run and restarts them later. The convergence chart shows the informed count
dip while the nodes are down, then climb back to full coverage.

You can also crash and restart nodes by hand from the control room. Use the
**Node fault** box to pick a node, then crash or restart it while the run is
active. Replay a scenario file to reproduce the exact fault schedule on another
machine.

## Testing

Run the full suite:

```
mix test
```

The suite has 87 tests. It covers the deterministic core, the counter CRDT,
the topology builder, the scenario codec, the scenario catalog, and the
headless replay tool. It also covers the engine GenServer and the LiveView.
Tests never sleep and never read the wall clock. Each core test replays a
scenario and asserts on the resulting state.

Run the precommit alias before you finish a change. It compiles, formats, and
tests the project in one pass:

```
mix precommit
```

## Limitations

- Logical time is synthetic, so convergence times compare runs, not real hosts.
- Partitions are modelled as group labels, not as link failures per edge.
- Crashes lose all node state. There is no disk or persistent memory model.
- The engine runs one scenario at a time inside a single GenServer.
- The counter payload is a G-Counter. It only grows; it cannot be decremented.
- The interface uses one SVG canvas, so very large graphs stay modest by design.
- Persistence is out of scope: a restart reloads the default scenario.
- Imported scenarios use a custom topology. They do not appear in the catalog list.

## Roadmap

Later releases can build on this core without changing the model.

- **Scenario import and export.** Done. JSON files round-trip through the codec and the control room.
- **Crash and restart.** Done. Nodes crash, drop state, and recover through the control room.
- **Counters and CRDTs.** Done. The rumor now has a G-Counter sibling with scheduled and manual writes.
- **Headless replay tool.** Done. `mix garden.replay` prints a table, a trace, or JSON from the CLI.
- **Edge-level partitions.** Cut a single link instead of a node group.
- **More CRDTs.** Add a grow-only set or an LWW register on top of the counter model.

## License

See `LICENSE` for the terms of use.
