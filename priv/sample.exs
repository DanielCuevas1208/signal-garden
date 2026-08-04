# Signal Garden deterministic sample run.
#
# Run with:
#
#     mix run --no-start priv/sample.exs
#
# The script drives the pure Core with no animation loop and no browser.
# Two runs of the same scenario always produce identical output.
#
# The same reports are available from the CLI:
#
#     mix signal_garden.replay --check

alias SignalGarden.{Scenarios, Sim.Replay}

reports = Enum.map(Scenarios.catalog(), &Replay.run/1)

IO.puts(Replay.table_header())
Enum.each(reports, &IO.puts(Replay.summary_line(&1)))

IO.puts("")
IO.puts("Determinism check: each scenario must replay to the same report.")

Enum.each(Scenarios.catalog(), fn scenario ->
  status = if Replay.deterministic?(scenario), do: "true", else: "false"
  IO.puts("#{String.pad_trailing(scenario.name, 20)} deterministic = #{status}")
end)
