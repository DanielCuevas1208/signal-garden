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

  test ~S(timeline marks concurrent writes as resolved by a later observed write) do
    left = MultiValueRegister.write(MultiValueRegister.new(), {1, 1}, ~S(blue))
    right = MultiValueRegister.write(MultiValueRegister.new(), {2, 1}, ~S(green))
    observed = MultiValueRegister.merge(left, right)
    later = MultiValueRegister.write(observed, {3, 1}, ~S(violet))

    assert MultiValueRegister.timeline(later) == [
             %{
               node: 1,
               sequence: 1,
               value: ~S(blue),
               observed: [],
               observed_by: [{3, 1}],
               visible: false
             },
             %{
               node: 2,
               sequence: 1,
               value: ~S(green),
               observed: [],
               observed_by: [{3, 1}],
               visible: false
             },
             %{
               node: 3,
               sequence: 1,
               value: ~S(violet),
               observed: [{1, 1}, {2, 1}],
               observed_by: [],
               visible: true
             }
           ]
  end

  test ~S(legacy register state remains readable without a history field) do
    state = %{entries: %{}, context: MapSet.new()}
    written = MultiValueRegister.write(state, {4, 1}, ~S(yellow))

    assert written.entries == %{{4, 1} => ~S(yellow)}
    assert written.history == %{{4, 1} => %{value: ~S(yellow), observed: MapSet.new()}}
  end

  test "compaction removes resolved history and preserves causal context" do
    left = MultiValueRegister.write(MultiValueRegister.new(), {1, 1}, "blue")
    right = MultiValueRegister.write(MultiValueRegister.new(), {2, 1}, "green")
    observed = MultiValueRegister.merge(left, right)
    later = MultiValueRegister.write(observed, {3, 1}, "violet")

    compacted = MultiValueRegister.compact(later)

    assert MultiValueRegister.values(compacted) == ["violet"]
    assert MultiValueRegister.retained_history_count(compacted) == 1
    assert MultiValueRegister.compacted_count(compacted) == 2
    assert MapSet.size(compacted.context) == 3
    assert Enum.map(MultiValueRegister.timeline(compacted), & &1.value) == ["violet"]
    assert MultiValueRegister.equivalent?(later, compacted)
    assert MultiValueRegister.values(MultiValueRegister.merge(compacted, left)) == ["violet"]
  end

  test "a compacted register keeps later concurrent writes separate" do
    first = MultiValueRegister.write(MultiValueRegister.new(), {1, 1}, "blue")
    resolved = MultiValueRegister.write(first, {2, 1}, "violet")
    compacted = MultiValueRegister.compact(resolved)
    concurrent = MultiValueRegister.write(MultiValueRegister.new(), {3, 1}, "green")

    merged = MultiValueRegister.merge(compacted, concurrent)

    assert MultiValueRegister.values(merged) == ["green", "violet"]
    assert MultiValueRegister.compacted_count(merged) == 1
    assert MapSet.size(merged.context) == 3
  end
end
