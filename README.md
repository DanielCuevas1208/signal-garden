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
- Four network hazards: delay, message loss, partitions, and cut links.
- Node crash and restart. A crashed node forgets its state and stops the spread.
- Five gossip payloads: a rumor, a grow-only counter, a grow-only set, a register, and an LWW map.
- A grow-only counter (G-Counter) that converges across the network.
- A grow-only set (G-Set) that spreads a collection across the network.
- A last-writer-wins register (LWW register) where the newest write wins.
- A last-writer-wins map (LWW map) where every key converges on its own.
- Deterministic scenarios with fixed seeds and fault schedules.
- A live SVG graph, a convergence chart, and an event feed.
- A headless replay tool that reproduces any run from the CLI.

## Architecture

Signal Garden separates the deterministic core from the live interface.

```
lib/signal_garden/
  sim/
    core.ex           # Pure, side-effect-free state machine. Owns the event queue.
    engine.ex         # GenServer that drives the core and broadcasts snapshots.
    replay.ex         # Headless runner. Drives scenarios and summarizes results.
    scenario.ex       # Data shape for one run: topology, seed, faults, conditions.
    scenario_codec.ex # JSON import and export for scenarios.
    topology.ex       # Builds line, ring, grid, complete, and random graphs.
  scenarios.ex        # The built-in catalog of scenarios.
  sim.ex              # Thin facade the LiveView calls.
```

The `Core` module advances logical time in discrete steps. Each step pops one
event from a priority queue. A gossip event makes a node send a message to one
neighbour. The engine applies delay, loss, partition, and cut-link checks, then
schedules a delivery event in the future. Two runs with the same seed walk the
same path.

The `Engine` GenServer owns a `Core` struct. On each animation frame it advances
the core by a burst of events and broadcasts a snapshot over Phoenix PubSub.
The LiveView subscribes to that topic and re-renders the graph. The core never
touches the network, so tests stay fast and deterministic.

The `Replay` module drives the same core with no engine and no browser. It runs
a scenario to completion and returns a summary. The `mix signal_garden.replay`
task wraps it for the command line. See the "Headless replay" section below.

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
events. Click a node to toggle its partition group. Click an edge to cut or
heal that link. Drag the sliders to change delay, loss rate, and speed. Pick a
scenario from the list to load a new run.

Use the **Node fault** box to crash a node or restart it. In counter mode, use
the box to write to a node. In set mode, use the box to add a member. In
register mode, use the box to post a notice. In map mode, use the box to set
a service status. Use **Export JSON** to download
the active scenario. Use **Import JSON** to paste a file and load it into the
control room. Sample files ship at `priv/scenarios/ring.json`,
`priv/scenarios/counter.json`, `priv/scenarios/set.json`,
`priv/scenarios/register.json`, and `priv/scenarios/service_board.json`.

## Scenario files

A scenario file is versioned JSON. It carries the topology, the seed, the fault
schedule, the payload mode, and every network parameter. It also carries the
`link_cuts` list, so a broken link round-trips through a file. Two machines can
share one file and replay the same run.

Export a scenario from the control room, or build a file by hand. The format
requires `format: 1` and a `topology` block with `nodes`, `edges`, and
`layout`. Load a file in the browser or decode it in tests:

```
alias SignalGarden.Sim.ScenarioCodec
{:ok, scenario} = File.read!("priv/scenarios/ring.json") |> ScenarioCodec.decode()
```

## Built-in scenarios

The scenario catalog ships with thirteen runs. Each one fixes a topology, a
seed, and a set of network conditions.

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
| Broken link | 12 | two links are cut, then healed |
| Grow-only counter | 12 | five writes climb a G-Counter on a schedule |
| Guest list | 12 | five names join a G-Set on a schedule |
| Bulletin board | 12 | five notices overwrite an LWW register on a schedule |
| Service board | 12 | five statuses update an LWW map on a schedule |

## Link cuts

A link cut is an edge-level partition. It breaks one link in both directions.
Every message across that link is dropped until you heal it. A group partition
splits the whole network. A cut link breaks one edge.

Cut links to slow a path or to isolate part of the network. Click an edge on
the graph to toggle its cut. Use the **Link cut** box to cut or heal a specific
edge.

The **Broken link** scenario demonstrates the flow. It cuts two ring links
early, isolating most nodes. Healing them lets gossip cross and convergence
completes.

A cut link records a `dropped (cut link)` event. The edge turns rose and shows
a cut marker. The **heal** button repairs every cut link and merges every
partition group.

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

## Sets and CRDTs

The **Guest list** scenario swaps the rumor for a G-Set CRDT. This is the
classic grow-only set from the CRDT family. It shows how a collection
converges while the network keeps losing and reordering messages.

Each node holds a set of elements. An add action puts one element into the set
of the writing node. A gossip message carries the sender's whole set. On
delivery, the receiver merges the sets with union. Every node converges to the
same collection, even when the network splits or drops messages.

The control room shows the set contents as chips in the Telemetry card. It
shows the element count above each node. The **Add** box in the Node fault
panel writes a member to the selected node. The convergence chart tracks how
many nodes hold the full set.

Convergence needs every scheduled add to be issued. The run re-arms when you
add after it converged, so you can watch the new member spread. A manual add
survives only the current run. A duplicate add leaves the set unchanged.

## Registers and CRDTs

The **Bulletin board** scenario swaps the rumor for an LWW register. This is
the classic last-writer-wins register from the CRDT family. It shows how one
value converges while the network keeps losing and reordering messages.

Each node holds one value and the version of the write that produced it. A
write action puts a new value on the writing node with a new version. A gossip
message carries the sender's value and version. On delivery the receiver keeps
the value with the higher version, so the newest write wins everywhere. Every
node converges to the same value, even when the network splits or drops
messages.

The control room shows the write version above each node. The **Current
notice** card shows the latest value text. The **Publish** box in the Node
fault panel writes a notice to the selected node. The convergence chart tracks
how many nodes hold the latest version.

Convergence needs every scheduled write to be issued. The run re-arms when you
post after it converged, so you can watch the new notice spread. A manual
write survives only the current run. A write with the same text still moves
the version forward, because the version, not the text, decides the winner.

## Maps and CRDTs

The **Service board** scenario swaps the rumor for an LWW map. This is a map
of independent LWW registers, one per key. It shows how a set of values
converges while the network keeps losing and reordering messages.

Each node holds a map of keys. Every key stores one value and the version of
the write that produced it. A put action writes one key on the writing node
with a new version. A gossip message carries the sender's whole map. On
delivery, the receiver merges the maps per key. It keeps the higher version
for each key, so the newest write wins for that key. Every node converges to
the same map, even when the network splits or drops messages.

The control room shows each service and its current status in the Telemetry
card. It shows the number of keys a node holds above the node. The **Set**
box in the Node fault panel writes a status to the selected key. The
convergence chart tracks how many nodes hold the full map.

Convergence needs every scheduled write to be issued. The run re-arms when
you set a key after it converged, so you can watch the new status spread. A
manual write survives only the current run. A write to a key that already
changed still moves that key forward, because the version, not the status
text, decides the winner.

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
Broken link         12     converged    2822      382    45        809
Grow-only counter   12     converged    3832      617    44        1281
Guest list          12     converged    3638      603    21        1228
Bulletin board      12     converged    3688      601    36        1239
Service board       12     converged    3860      631    37        1298
```

The determinism check confirms the core is reproducible:

```
ring determinism: convergence_time equal = true
ring determinism: history equal          = true
ring determinism: event_log equal        = true
crash determinism: convergence_time equal = true
crash determinism: event_log equal        = true
cut determinism: convergence_time equal  = true
cut determinism: event_log equal         = true
counter determinism: convergence_time equal = true
counter determinism: counter_total equal  = true
counter determinism: event_log equal      = true
guest determinism: convergence_time equal = true
guest determinism: elements equal        = true
guest determinism: event_log equal        = true
bulletin determinism: convergence_time equal = true
bulletin determinism: register value equal = true
bulletin determinism: event_log equal       = true
board determinism: convergence_time equal  = true
board determinism: map_fields equal        = true
board determinism: event_log equal         = true
```

Reproduce this output from a checkout with:

```
mix signal_garden.replay
```

The legacy script `mix run --no-start priv/sample.exs` prints the same table
and the same determinism checks.

## Headless replay

Run any scenario from the command line. The replay tool drives the pure core
with no browser and no animation loop. It prints the outcome table above. Two
runs always produce identical output, which makes the tool a reproducibility
check for scripts and CI.

```
mix signal_garden.replay
mix signal_garden.replay ring
mix signal_garden.replay priv/scenarios/ring.json
```

The first command runs every built-in scenario. Pass a scenario id or a file
path to run a single scenario. Add an option to change the output:

| Option | Output |
| --- | --- |
| `--json` | One JSON document with a summary per scenario |
| `--trace` | The recent event trace as JSON |
| `--check` | A determinism check for one scenario |
| `--check-all` | A determinism check for every scenario |
| `--help` | Usage text |

A determinism check runs the scenario twice and compares the outcomes. It
prints one line per scenario. It exits non-zero when a run is not
reproducible. The CI workflow runs `--check-all` on every push.

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

In register mode, **Converged** means every node holds the latest write. The
run cannot converge before every scheduled notice is posted.

In map mode, **Converged** means every node holds the latest write of every
key. The run cannot converge before every scheduled status is set.

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

The suite has 168 tests. It covers the deterministic core, the counter CRDT,
the set CRDT, the register CRDT, the map CRDT, the topology builder, the
scenario codec, and the scenario catalog. It also covers link cuts, the
engine GenServer, the LiveView, and the headless replay tool. Tests never
sleep and never read the wall clock. Each core test replays a scenario and
asserts on the resulting state.

Run the precommit alias before you finish a change. It compiles, formats, and
tests the project in one pass:

```
mix precommit
```

## Limitations

- Logical time is synthetic, so convergence times compare runs, not real hosts.
- Partitions are modelled as group labels. Link cuts cover the per-edge case.
- Crashes lose all node state. There is no disk or persistent memory model.
- The engine runs one scenario at a time inside a single GenServer.
- The counter payload is a G-Counter. It only grows; it cannot be decremented.
- The set payload is a G-Set. Elements join; they cannot leave.
- The register payload is an LWW register. The newest write wins; history is not kept.
- The map payload is an LWW map. Keys only appear; they cannot be removed.
- The interface uses one SVG canvas, so very large graphs stay modest by design.
- Persistence is out of scope: a restart reloads the default scenario.
- Imported scenarios use a custom topology. They do not appear in the catalog list.
- The event trace is a rolling window of the 80 most recent events, not the full run.

## Roadmap

Later releases can build on this core without changing the model.

- **Scenario import and export.** Done. JSON files round-trip through the codec and the control room.
- **Crash and restart.** Done. Nodes crash, drop state, and recover through the control room.
- **Counters and CRDTs.** Done. The rumor now has a G-Counter sibling with scheduled and manual writes.
- **Sets and CRDTs.** Done. A G-Set spreads a collection through the network with scheduled and manual adds.
- **Headless replay tool.** Done. The `mix signal_garden.replay` task prints summaries, traces, and determinism checks from the CLI.
- **Edge-level partitions.** Done. Cut and heal single links from the graph, the fault box, or a scenario file.
- **Registers and CRDTs.** Done. The rumor now has an LWW register sibling with scheduled and manual writes.
- **Maps and CRDTs.** Done. The rumor now has an LWW map sibling with scheduled and manual writes per key.
- **More CRDTs.** Add an OR-set so elements can join and leave the collection.

## License

See `LICENSE` for the terms of use.
