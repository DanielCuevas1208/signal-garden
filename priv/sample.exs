# Signal Garden deterministic sample run.
#
# Run with:
#
#     mix run --no-start priv/sample.exs
#
# The script drives the pure Core with no animation loop and no browser.
# Two runs of the same scenario always produce identical output.

alias SignalGarden.{Scenarios, Sim.Core}

header =
  String.pad_trailing("scenario", 20) <>
    String.pad_trailing("nodes", 7) <>
    String.pad_trailing("status", 13) <>
    String.pad_trailing("t(ms)", 10) <>
    String.pad_trailing("hops", 7) <>
    String.pad_trailing("dropped", 10) <>
    "steps"

IO.puts(header)

rows =
  Enum.map(Scenarios.catalog(), fn scenario ->
    state = Core.new(scenario) |> Core.command({:set_status, :running})

    final =
      Enum.reduce_while(1..10_000, state, fn _, acc ->
        {acc, _} = Core.step(acc, 200)

        if acc.status in [:converged, :exhausted] do
          {:halt, acc}
        else
          {:cont, acc}
        end
      end)

    {scenario.name, map_size(final.nodes), final.status,
     final.convergence_time, final.hops, final.dropped, final.steps}
  end)

for {name, nodes, status, t, hops, dropped, steps} <- rows do
  IO.puts(
    String.pad_trailing(name, 20) <>
      String.pad_trailing("#{nodes}", 7) <>
      String.pad_trailing("#{status}", 13) <>
      String.pad_trailing("#{t}", 10) <>
      String.pad_trailing("#{hops}", 7) <>
      String.pad_trailing("#{dropped}", 10) <>
      "#{steps}"
  )
end

# Determinism check: the ring scenario must replay to the same state.
ring = fn ->
  Scenarios.fetch(:ring)
  |> Core.new()
  |> Core.command({:set_status, :running})
  |> then(fn state ->
    Enum.reduce_while(1..10_000, state, fn _, acc ->
      {acc, _} = Core.step(acc, 200)

      if acc.status in [:converged, :exhausted] do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end)
end

a = ring.()
b = ring.()

IO.puts("")
IO.puts("ring determinism: convergence_time equal = #{a.convergence_time == b.convergence_time}")
IO.puts("ring determinism: history equal          = #{a.history == b.history}")
IO.puts("ring determinism: event_log equal        = #{a.event_log == b.event_log}")