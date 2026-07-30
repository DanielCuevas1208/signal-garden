# Signal Garden

Signal Garden is an interactive simulator for distributed systems. It makes
message delay, network partitions, retries, and eventual convergence visible
and reproducible in a browser. A deterministic gossip network runs in
Elixir, and a Phoenix LiveView control room draws the rumor as it spreads.

The same scenario always produces the same event trace, the same convergence
time, and the same history. Two runs that share a seed are byte-for-byte
identical, so a fault you see on one machine is a fault anyone can replay.

## What it shows

- An actor model gossip engine written in pure Elixir.
- Logical time that has no link to the wall clock.
- Three network hazards: delay, message loss, and partitions.
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

Use **Export JSON** to download the active scenario. Use **Import JSON** to
paste a file and load it into the control room. A sample file ships at
`priv/scenarios/ring.json`.

## Scenario files

A scenario file is versioned JSON. It carries the topology, the seed, the fault
schedule, and every network parameter. Two machines can share one file and
replay the same run.

Export a scenario from the control room, or build a file by hand. The format
requires `format: 1` and a `topology` block with `nodes`, `edges`, and
`layout`. Load a file in the browser or decode it in tests:

```
alias SignalGarden.Sim.ScenarioCodec
{:ok, scenario} = File.read!("priv/scenarios/ring.json") |> ScenarioCodec.decode()
```

## Built-in scenarios

The scenario catalog ships with seven runs. Each one fixes a topology, a seed,
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
```

The determinism check confirms the core is reproducible:

```
ring determinism: convergence_time equal = true
ring determinism: history equal          = true
ring determinism: event_log equal        = true
```

Reproduce this output from a checkout with:

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

## Testing

Run the full suite:

```
mix test
```

The suite has 40 tests. It covers the deterministic core, the topology
builder, the scenario codec, the scenario catalog, the engine GenServer, and
the LiveView.
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
- The engine runs one scenario at a time inside a single GenServer.
- The interface uses one SVG canvas, so very large graphs stay modest by design.
- Persistence is out of scope: a restart reloads the default scenario.
- Imported scenarios use a custom topology. They do not appear in the catalog list.

## Roadmap

Later releases can build on this core without changing the model.

- **Scenario import and export.** Done. JSON files round-trip through the codec and the control room.
- **Crash and restart.** Kill nodes mid-run and watch the network recover.
- **Counters and CRDTs.** Swap the rumor for a grow-only counter.
- **Headless replay tool.** Run a scenario from the CLI and print a trace.
- **Edge-level partitions.** Cut a single link instead of a node group.

## License

See `LICENSE` for the terms of use.