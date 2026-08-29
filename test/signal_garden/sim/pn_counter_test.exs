defmodule SignalGarden.Sim.PNCounterTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Sim.PNCounter

  test ~S(a signed adjustment grows the matching cell) do
    state = PNCounter.new()
    state = PNCounter.adjust(state, 1, 5)
    state = PNCounter.adjust(state, 1, -2)

    assert state.positive == %{1 => 5}
    assert state.negative == %{1 => 2}
    assert PNCounter.value(state) == 3
  end

  test ~S(merge keeps independent positive and negative cells) do
    left = PNCounter.new() |> PNCounter.adjust(1, 5) |> PNCounter.adjust(2, -3)
    right = PNCounter.new() |> PNCounter.adjust(1, -2) |> PNCounter.adjust(3, 4)

    merged = PNCounter.merge(left, right)

    assert merged == %{positive: %{1 => 5, 3 => 4}, negative: %{1 => 2, 2 => 3}}
    assert PNCounter.value(merged) == 4
    assert PNCounter.equivalent?(merged, PNCounter.merge(right, left))
  end
end
