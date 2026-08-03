# Signal Garden deterministic sample run.
#
# Run with:
#
#     mix run --no-start priv/sample.exs
#
# The script delegates to SignalGarden.Sim.Replay. It drives the pure core
# with no animation loop and no browser. Two runs of the same scenario
# always produce identical output.

alias SignalGarden.Sim.Replay

IO.puts(Replay.format_summary_table(Replay.run_all()))

IO.puts("")

IO.puts(Replay.format_verify(Replay.verify()))
