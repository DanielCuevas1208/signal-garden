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

# Determinism check: the crash scenario must replay to the same state.
crash = fn ->
  Scenarios.fetch(:crash)
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

c = crash.()
d = crash.()

IO.puts("crash determinism: convergence_time equal = #{c.convergence_time == d.convergence_time}")
IO.puts("crash determinism: event_log equal        = #{c.event_log == d.event_log}")

# Determinism check: the broken link scenario must replay to the same state.
cut = fn ->
  Scenarios.fetch(:cut)
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

g = cut.()
h = cut.()

IO.puts("cut determinism: convergence_time equal  = #{g.convergence_time == h.convergence_time}")
IO.puts("cut determinism: event_log equal         = #{g.event_log == h.event_log}")

# Determinism check: the counter scenario must converge to the same total.
counter = fn ->
  Scenarios.fetch(:counter)
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

e = counter.()
f = counter.()

IO.puts(
  "counter determinism: convergence_time equal = #{e.convergence_time == f.convergence_time}"
)

IO.puts("counter determinism: counter_total equal  = #{e.increments_total == f.increments_total}")
IO.puts("counter determinism: event_log equal      = #{e.event_log == f.event_log}")

# Determinism check: the set scenario must converge to the same collection.
guest = fn ->
  Scenarios.fetch(:guest_list)
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

g = guest.()
h = guest.()

IO.puts("guest determinism: convergence_time equal = #{g.convergence_time == h.convergence_time}")
IO.puts("guest determinism: elements equal        = #{g.elements == h.elements}")
IO.puts("guest determinism: event_log equal        = #{g.event_log == h.event_log}")