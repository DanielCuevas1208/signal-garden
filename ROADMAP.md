# Signal Garden roadmap

This roadmap keeps milestone IDs stable. Each milestone names a user-visible outcome and local verification.

Status values: Complete, In progress, Planned, and Blocked.

## Completed releases

- `scenario-import-export` — Complete.
  - Outcome: Shareable JSON scenarios load in the control room.
  - Acceptance: Codec round-trips topology, faults, and network settings.
  - Verify: `mix test test/signal_garden/sim/scenario_codec_test.exs`

- `crash-restart` — Complete.
  - Outcome: Users can reproduce node outages and recovery.
  - Acceptance: Crashes clear node state; restarts rejoin gossip.
  - Verify: `mix test test/signal_garden/sim/core_test.exs`

- `counter-crdt` — Complete.
  - Outcome: A G-Counter shows monotonic replica convergence.
  - Acceptance: Scheduled and manual increments converge after faults.
  - Verify: `mix test test/signal_garden/sim/counter_test.exs`

- `set-crdt` — Complete.
  - Outcome: A G-Set shows collection convergence.
  - Acceptance: Scheduled and manual additions reach every replica.
  - Verify: `mix test test/signal_garden/sim/set_test.exs`

- `headless-replay` — Complete.
  - Outcome: Scripts can replay scenarios without the browser.
  - Acceptance: CLI summaries and determinism checks use the pure core.
  - Verify: `mix test test/mix/tasks/signal_garden_replay_test.exs`

- `edge-partitions` — Complete.
  - Outcome: Users can cut one network link.
  - Acceptance: Cut messages drop; healing restores convergence.
  - Verify: `mix test test/signal_garden/sim/core_test.exs`

- `register-crdt` — Complete.
  - Outcome: An LWW register shows ordered writes.
  - Acceptance: The newest version converges across replicas.
  - Verify: `mix test test/signal_garden/sim/register_test.exs`

- `map-crdt` — Complete.
  - Outcome: An LWW map shows per-key convergence.
  - Acceptance: Each key keeps its newest version.
  - Verify: `mix test test/signal_garden/sim/service_board_test.exs`

- `observed-remove-set` — Complete.
  - Outcome: A roster demonstrates observed-remove semantics.
  - Acceptance: Unseen concurrent additions survive removal.
  - Verify: `mix test test/signal_garden/sim/orset_test.exs`

- `multi-value-register` — Complete.
  - Outcome: Concurrent writes remain visible.
  - Acceptance: Causal dots preserve concurrent branches.
  - Verify: `mix test test/signal_garden/sim/mv_register_test.exs`

- `conflict-timeline` — Complete.
  - Outcome: Users can inspect active and resolved MV-register history.
  - Acceptance: Timeline entries expose dots and observations.
  - Verify: `mix test test/signal_garden_web/live/garden_live_test.exs`

- `causal-history-compaction` — Complete.
  - Outcome: Resolved history can leave the interactive view.
  - Acceptance: Compaction preserves values and causal context.
  - Verify: `mix test test/signal_garden/sim/mv_register_test.exs`

- `pn-counter` — Complete.
  - Outcome: A ledger shows signed replica updates.
  - Acceptance: Credits and debits merge independently.
  - Verify: `mix test test/signal_garden/sim/pn_counter_core_test.exs`

- `scenario-comparison` — Complete.
  - Outcome: Users can compare two deterministic runs.
  - Acceptance: The UI and CLI show summaries, deltas, and traces.
  - Verify: `mix test test/signal_garden/sim/replay_test.exs`

- `scriptable-comparison` — Complete.
  - Outcome: Automation can consume paired JSON evidence.
  - Acceptance: `--compare` emits stable machine-readable output.
  - Verify: `mix test test/mix/tasks/signal_garden_replay_test.exs`

### `full-trace-export` — Complete.
  - Outcome: Scripts can save every replay event beyond the UI window.
  - Acceptance: Ordered events, metadata, and summary values survive export.
  - Verify: `mix test test/signal_garden/sim/core_test.exs test/signal_garden/sim/replay_test.exs`
  - Demo: `mix signal_garden.replay --export-trace tmp/grid-trace.json grid`

## Current release

### `convergence-counterexample` — Complete

The replay task explains a permanent barrier that blocks convergence.

Acceptance:

- The evidence identifies nodes unreachable from the origin.
- The evidence lists partition or link-cut barriers.
- The evidence records deterministic blocking events.
- Replaying the same scenario produces identical evidence.

Verification:

```text
mix test test/signal_garden/sim/replay_test.exs
mix test test/mix/tasks/signal_garden_replay_test.exs
mix signal_garden.replay --export-counterexample tmp/stalled.json priv/scenarios/stalled.json
```

The README includes sample counterexample output.

## Future releases

### `trace-verifier` — Planned

Outcome: Verify a trace artifact against a fresh deterministic replay.

Bounded deliverable: Add a `--verify-trace PATH` command.

Acceptance:

- Check artifact format and event order.
- Compare the stored summary with replay output.
- Return a non-zero status for altered evidence.

Verify: `mix test test/mix/tasks/signal_garden_replay_test.exs`

### `streaming-trace-export` — Planned

Outcome: Export very long traces without retaining the full list.

Bounded deliverable: Stream JSON events to a file during replay.

Acceptance:

- Keep the interactive window bounded.
- Bound export memory independently from trace length.
- Preserve deterministic event order.

Verify: `mix test test/signal_garden/sim/replay_test.exs`

Blocked milestones: None.
