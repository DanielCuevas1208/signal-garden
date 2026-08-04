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
- A headless CLI that replays any scenario and prints a full event trace.

## Architecture

Signal Garden separates the deterministic core from the live interface.

```
lib/signal_garden/
  replay.ex           # Headless replay: full trace, determinism check, CLI text.
  sim/
    core.ex           # Pure, side-effect-free state machine. Owns the event queue.
    engine.ex         # GenServer that drives the core and broadcasts snapshots.
    scenario.ex       # Data shape for one run: topology, seed, faults, conditions.
    scenario_codec.ex # JSON import and export for scenarios.
    topology.ex       # Builds line, ring, grid, complete, and random graphs.
  scenarios.ex        # The built-in catalog of scenarios.
  sim.ex              # Thin facade the LiveView calls.
lib/mix/tasks/
  signal_garden.replay.ex # The `mix signal_garden.replay` command.
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
`layout`. Load a file in the browser, decode it in tests, or replay it from
the CLI:

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
was produced with the `Core` module only, with no animation loop and no
browser. Reproduce it with the command below.

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
Grow-only counter   12     converged    3832      617    44        1281
```

The determinism check confirms the core is reproducible:

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

Reproduce this output from a checkout with:

```
mix run --no-start priv/sample.exs
```

## Headless replay

The `mix signal_garden.replay` command runs a scenario without a browser. It
drives the pure core, prints a summary, and dumps the full event trace. It
accepts a catalog id or a JSON scenario file:

```
mix signal_garden.replay ring
mix signal_garden.replay priv/scenarios/counter.json
```

A single run prints the summary:

```
Scenario: Ring  (12 nodes, seed 2, rumor)
Status: converged   Converged at 750 ms
Hops: 120   Delivered: 115   Dropped: 0   Steps: 236
Fingerprint: 930fc7ea1766b00cbe83a01612e46ad0ebb6dd1c93a862ebbbb669e439cbdd8e
```

The event trace follows the summary. Each line records one send at its
logical time:

```
Event trace (120 entries)
t=     1  send       5 -> 6
t=     2  send       1 -> 2
t=    86  send       7 -> 6
```

Faults appear as their own lines. The crash scenario adds crashed and
restarted entries, and counter mode adds write entries:

```
t=   500  crashed    4
t=  1500  restarted  4
t=   400  write      1 +1
```

The fingerprint is a SHA-256 digest of the trace. Two machines that replay
the same scenario produce the same digest.

Use `--check` to confirm a scenario is reproducible. The command runs it
twice and compares every field:

```
mix signal_garden.replay crash --check
```

```
Crash and recover: deterministic. Two runs produced identical traces.
  Converged at: 1815 ms   Events: 273   Steps: 540
  Fingerprint: 1d133cfafe64b2636d84b7623f965edaec5ec8f08031c4e8b95867ddd0f72390
```

Without an argument, the command replays every built-in scenario and prints
the summary table shown above. Add `--check` to verify the whole catalog:

```
mix signal_garden.replay --check
```

```
scenario            deterministic  t(ms)     events  fingerprint
Line                yes            772       72      b18a083848f24c6770e7bcb10478a2b3e89e03b4da6e828b245f7f9ecbc2917f
Ring                yes            750       120     930fc7ea1766b00cbe83a01612e46ad0ebb6dd1c93a862ebbbb669e439cbdd8e
Grid                yes            1295      564     d9496f640565db5634a5c1e4b735874637409e6eb7c332b7d8c2414f45f10ff0
Random graph        yes            715       160     67c3cee2bf966ec763c719895cf4ec28baf2aa92c54f3fa95fc14dd950a34e93
Healing partition   yes            1397      249     44791f84c91d11ba9d448c02e4ea9f8cf74ac40db0c1ffbe77fca611e9fe8342
Churn               yes            731       156     68571bf1408322983e6eb2ee43091f1aea953a80be03f97f832a1cbbda22ce5f
Lossy link          yes            594       126     cb05fdf3bbf446a9955eb7538378e19bda4d2867c7d26aa30ac0f0f30bfd4554
Crash and recover   yes            1815      273     1d133cfafe64b2636d84b7623f965edaec5ec8f08031c4e8b95867ddd0f72390
Grow-only counter   yes            3832      666     ec4200cb887bf0682ee5a78fe212c133bcc10c13127d4bad6ec50dfae9a5ae4a
```

Other flags: `--json` emits machine-readable JSON, and `--no-trace` prints
the summary only.

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

The suite has 92 tests. It covers the deterministic core, the counter CRDT,
the topology builder, the scenario codec, the scenario catalog, the headless
replay tool, and the CLI. It also covers the engine GenServer and the
LiveView. Tests never sleep and never read the wall clock. Each core test
replays a scenario and asserts on the resulting state.

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
- **Headless replay tool.** Done. The CLI prints a full trace, a fingerprint, and a determinism check.
- **Edge-level partitions.** Cut a single link instead of a node group.
- **More CRDTs.** Add a grow-only set or an LWW register on top of the counter model.
- **Trace export.** Write a replay trace to a file for byte-for-byte comparison.

## License

See `LICENSE` for the terms of use.
