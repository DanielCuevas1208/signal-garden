defmodule SignalGarden.Sim.MultiValueRegisterTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Sim.MultiValueRegister

  test "concurrent writes remain visible after merge" do
    left = MultiValueRegister.write(MultiValueRegister.new(), {1, 1}, "blue")
    right = MultiValueRegister.write(MultiValueRegister.new(), {2, 1}, "green")
    merged = MultiValueRegister.merge(left, right)

    assert MultiValueRegister.values(merged) == ["blue", "green"]
    assert MultiValueRegister.conflict_count(merged) == 2
  end

  test "a later write removes values its writer has observed" do
    left = MultiValueRegister.write(MultiValueRegister.new(), {1, 1}, "blue")
    right = MultiValueRegister.write(MultiValueRegister.new(), {2, 1}, "green")
    observed = MultiValueRegister.merge(left, right)
    later = MultiValueRegister.write(observed, {3, 1}, "violet")

    assert MultiValueRegister.values(later) == ["violet"]
    assert MapSet.size(later.context) == 3
  end

  test "an unseen concurrent value survives a later write" do
    left = MultiValueRegister.write(MultiValueRegister.new(), {1, 1}, "blue")
    right = MultiValueRegister.write(MultiValueRegister.new(), {2, 1}, "green")
    later = MultiValueRegister.write(left, {3, 1}, "violet")
    merged = MultiValueRegister.merge(later, right)

    assert MultiValueRegister.values(merged) == ["green", "violet"]
  end

  test "merge is commutative and idempotent" do
    left = MultiValueRegister.write(MultiValueRegister.new(), {1, 1}, "blue")
    right = MultiValueRegister.write(MultiValueRegister.new(), {2, 1}, "green")
    merged = MultiValueRegister.merge(left, right)

    assert MultiValueRegister.merge(left, right) == MultiValueRegister.merge(right, left)
    assert MultiValueRegister.merge(merged, merged) == merged
  end
end
