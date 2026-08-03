# Signal Garden deterministic sample run.
#
# Run with:
#
#     mix run --no-start priv/sample.exs
#
# The script replays every built-in scenario with the pure core. No
# animation loop and no browser are involved. Two runs always produce
# identical output. The same report is available from the command line
# with `mix garden.replay`.

alias SignalGarden.Sim.Replay

outcomes = Replay.run_all()

IO.puts(Replay.format_table(outcomes))
IO.puts("")
IO.puts("Determinism check: every scenario replays to an identical result.")
IO.puts("")

for report <- Replay.verify_all() do
  IO.puts(
    "#{report.name}: deterministic = #{report.deterministic} " <>
      "(t=#{report.convergence_time}ms, #{report.steps} steps, #{report.events} events)"
  )
end
