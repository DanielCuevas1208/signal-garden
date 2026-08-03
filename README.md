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
- A headless replay tool. The CLI runs a scenario and prints a trace.
- A live SVG graph, a convergence chart, and an event feed.

## Architecture

Signal Garden separates the deterministic core from the live interface.

```
lib/signal_garden/
  sim/
    core.ex           # Pure, side-effect-free state machine. Owns the event queue.
    engine.ex         # GenServer that drives the core and broadcasts snapshots.
    replay.ex         # Headless replay: full trace plus a determinism check.
    scenario.ex       # Data shape for one run: topology, seed, faults, conditions.
    scenario_codec.ex # JSON import and export for scenarios.
    topology.ex       # Builds line, ring, grid, complete, and random graphs.
  scenarios.ex        # The built-in catalog of scenarios.
  sim.ex              # Thin facade the LiveView calls.
lib/mix/tasks/
  signal_garden.replay.ex # CLI entry point for the headless replay tool.
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

## Headless replay tool

Run a scenario without a browser. The tool drives the pure core to a
terminal state and prints a trace.

    mix signal_garden.replay counter

Pick a scenario by id, or pass a JSON file:

    mix signal_garden.replay ring
    mix signal_garden.replay priv/scenarios/ring.json

Run every built-in scenario as a table:

    mix signal_garden.replay all

Print the whole trace with `--full`. Print JSON with `--json`:

    mix signal_garden.replay counter --json

Use `--list` to see the catalog. Use `--events N` to limit trace lines.
The tool runs each scenario twice. Equal traces prove determinism.
The exit code is 0 on success, 1 on error, and 2 when a run does not converge.

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

The block below is real output from a headless replay of every scenario.
It uses the pure `Core` module only, with no animation loop and no browser.
Reproduce it with the command below.

    mix signal_garden.replay all

```
scenario           mode     nodes  status     t(ms)  hops  dropped  steps  det
Line               rumor    8      converged  772    72    0        142    true
Ring               rumor    12     converged  750    120   0        236    true
Grid               rumor    30     converged  1295   564   0        1112   true
Random graph       rumor    16     converged  715    160   0        312    true
Healing partition  rumor    14     converged  1397   198   51       446    true
Churn              rumor    15     converged  731    152   4        309    true
Lossy link         rumor    14     converged  594    120   6        237    true
Crash and recover  rumor    12     converged  1815   269   24       540    true
Grow-only counter  counter  12     converged  3832   617   44       1281   true
```

The replay tool also verifies reproducibility. Each scenario runs twice,
and the two traces must match. The `priv/sample.exs` script prints the
same checks:

```
ring determinism: convergence_time equal = true
ring determinism: history equal          = true
ring determinism: event_log equal        = true
crash determinism: convergence_time equal = true
crash determinism: event_log equal        = true
counter determinism: convergence_time equal = true
counter determinism: counter_total equal  = true
counter determinism: event_log equal      = true
```

Reproduce the checks from a checkout with:

```
mix run --no-start priv/sample.exs
```

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

The suite has 90 tests. It covers the deterministic core, the counter CRDT,
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
- The replay tool stops a run that never converges at a fixed event budget.
- The counter payload is a G-Counter. It only grows; it cannot be decremented.
- The interface uses one SVG canvas, so very large graphs stay modest by design.
- Persistence is out of scope: a restart reloads the default scenario.
- Imported scenarios use a custom topology. They do not appear in the catalog list.

## Roadmap

Later releases can build on this core without changing the model.

- **Scenario import and export.** Done. JSON files round-trip through the codec and the control room.
- **Crash and restart.** Done. Nodes crash, drop state, and recover through the control room.
- **Counters and CRDTs.** Done. The rumor now has a G-Counter sibling with scheduled and manual writes.
- **Headless replay tool.** Done. The CLI replays a scenario and prints a deterministic trace.
- **Edge-level partitions.** Cut a single link instead of a node group.
- **More CRDTs.** Add a grow-only set or an LWW register on top of the counter model.

## License

See `LICENSE` for the terms of use.
