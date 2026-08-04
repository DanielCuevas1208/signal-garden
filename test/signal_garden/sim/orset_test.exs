defmodule SignalGarden.Sim.OrsetTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario}

  # ---------------------------------------------------------------------------
  # determinism and convergence
  # ---------------------------------------------------------------------------

  test "an observed-remove set scenario converges to the expected roster" do
    state = run_to_completion(:roster)

    assert state.status == :converged
    assert state.orset_ops_issued == 6
    assert state.orset_adds_issued == 4
    assert state.orset_removes_issued == 2
    assert state.orset_elements == MapSet.new(["Alan", "Edsger"])

    memberships =
      Enum.map(state.topology.nodes, fn id ->
        store = get_in(state.nodes, [id, :known, state.origin]).store
        orset_membership(store)
      end)

    assert Enum.all?(memberships, &(&1 == state.orset_elements))
  end

  test "two orset runs converge at the same logical clock" do
    a = run_to_completion(:roster)
    b = run_to_completion(:roster)

    assert a.convergence_time == b.convergence_time
    assert a.history == b.history
    assert a.event_log == b.event_log
    assert a.orset_elements == b.orset_elements
  end

  test "the run does not converge before all scheduled operations are issued" do
    state = Scenarios.fetch(:roster) |> Core.new()
    {state, _} = Core.step(state, 500)

    refute state.status == :converged
    assert MapSet.size(state.informed) == 0
  end

  # ---------------------------------------------------------------------------
  # add and remove commands
  # ---------------------------------------------------------------------------

  test "a manual add puts a fresh tag into the writing node's store" do
    state = Scenarios.fetch(:roster) |> Core.new()
    state = Core.command(state, {:add, 3, "Linus"})

    assert state.orset_ops_issued == 1
    assert state.orset_adds_issued == 1
    assert MapSet.member?(state.orset_elements, "Linus")

    tags = get_in(state.nodes, [3, :known, state.origin]).store["Linus"]
    assert MapSet.member?(tags.adds, {3, 1})
  end

  test "a manual remove takes the element out of the writing node's store" do
    state = Scenarios.fetch(:roster) |> Core.new()
    state = state |> Core.command({:add, 3, "Linus"}) |> Core.command({:remove, 3, "Linus"})

    assert state.orset_ops_issued == 2
    assert state.orset_removes_issued == 1
    refute MapSet.member?(state.orset_elements, "Linus")

    tags = get_in(state.nodes, [3, :known, state.origin]).store["Linus"]
    assert MapSet.member?(tags.removes, {3, 1})
    assert MapSet.size(tags.adds) == 0
  end

  test "add and remove commands are ignored in rumor mode" do
    state = Scenarios.fetch(:ring) |> Core.new()
    state = Core.command(state, {:add, 2, "Linus"})
    state = Core.command(state, {:remove, 2, "Linus"})

    assert state.orset_ops_issued == 0
    assert state.orset_elements == MapSet.new()
  end

  test "a manual add after convergence re-arms the run" do
    state = run_to_completion(:roster)
    assert state.status == :converged

    state = Core.command(state, {:add, 2, "Grace"})
    assert state.status == :idle
    assert state.orset_ops_issued == 7
    assert MapSet.member?(state.orset_elements, "Grace")

    state = run_to_converge(state)
    assert state.status == :converged

    memberships =
      Enum.map(state.topology.nodes, fn id ->
        store = get_in(state.nodes, [id, :known, state.origin]).store
        orset_membership(store)
      end)

    assert Enum.all?(memberships, &(&1 == state.orset_elements))
  end

  test "a manual remove after convergence re-arms the run" do
    state = run_to_completion(:roster)
    assert state.status == :converged

    state = Core.command(state, {:remove, 2, "Alan"})
    assert state.status == :idle
    assert state.orset_ops_issued == 7
    refute MapSet.member?(state.orset_elements, "Alan")

    state = run_to_converge(state)
    assert state.status == :converged

    memberships =
      Enum.map(state.topology.nodes, fn id ->
        store = get_in(state.nodes, [id, :known, state.origin]).store
        orset_membership(store)
      end)

    assert Enum.all?(memberships, &(&1 == state.orset_elements))
  end

  test "a scheduled remove does not move the convergence target" do
    scenario = %Scenario{
      Scenarios.roster()
      | fault_schedule: [
          %{at: 10, action: {:add, 2, "Ada"}, label: "add"},
          %{at: 20, action: {:remove, 2, "Ada"}, label: "remove"}
        ]
    }

    state = Core.new(scenario)
    state = step_n(state, 30)

    assert state.orset_ops_issued == 2
    assert state.orset_ops_target == 2
    refute MapSet.member?(state.orset_elements, "Ada")
  end

  # ---------------------------------------------------------------------------
  # observed-remove merge semantics
  # ---------------------------------------------------------------------------

  test "delivering a message merges the tag sets of both replicas" do
    state = Scenarios.fetch(:roster) |> Core.new()

    # Node 1 adds Ada, node 2 adds Grace; hand node 1's store to node 2.
    state = state |> Core.command({:add, 1, "Ada"})
    payload = get_in(state.nodes, [1, :known, state.origin])
    queue = [{1, state.seq + 1, {:deliver, 2, payload}}]
    state = %{state | queue: queue}
    {state, _} = Core.step(state, 1)

    state = Core.command(state, {:add, 2, "Grace"})
    store = get_in(state.nodes, [2, :known, state.origin]).store

    assert orset_membership(store) == MapSet.new(["Ada", "Grace"])
  end

  test "a remove blocks a stale add message from resurrecting a member" do
    state = Scenarios.fetch(:roster) |> Core.new()

    # Node 1 adds Ada, then a gossip message carries that add to node 2.
    state = Core.command(state, {:add, 1, "Ada"})
    state = deliver_payload(state, 1, 2)

    # A stale pre-remove copy of node 1's store is still in flight.
    stale = get_in(state.nodes, [1, :known, state.origin])

    # Node 1 removes Ada and the removal spreads to node 2.
    state = Core.command(state, {:remove, 1, "Ada"})
    state = deliver_payload(state, 1, 2)

    # The stale add lands after the removal was observed. The tag is already
    # in the removed set, so the member stays gone.
    state = deliver_payload(state, 1, 2, stale)

    store = get_in(state.nodes, [2, :known, state.origin]).store
    assert orset_membership(store) == MapSet.new()
  end

  test "a duplicate add does not change membership but keeps its own tag" do
    state = Scenarios.fetch(:roster) |> Core.new()
    state = state |> Core.command({:add, 1, "Ada"}) |> Core.command({:add, 1, "Ada"})

    assert state.orset_ops_issued == 2
    assert MapSet.member?(state.orset_elements, "Ada")

    tags = get_in(state.nodes, [1, :known, state.origin]).store["Ada"]
    assert tags.adds == MapSet.new([{1, 1}, {1, 2}])
  end

  test "removing an absent element records the op but leaves membership alone" do
    state = Scenarios.fetch(:roster) |> Core.new()
    state = Core.command(state, {:remove, 2, "Nobody"})

    assert state.orset_ops_issued == 1
    assert state.orset_removes_issued == 1
    assert state.orset_elements == MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # faults and orset state
  # ---------------------------------------------------------------------------

  test "crashing an orset node drops its store" do
    state = Scenarios.fetch(:roster) |> Core.new()

    state = %{state | queue: []}
    state = Core.command(state, {:add, 7, "Ada"})
    assert map_size(get_in(state.nodes, [7, :known, state.origin]).store) == 1

    state = Core.command(state, {:crash, 7})
    assert get_in(state.nodes, [7, :known, state.origin]).store == %{}
    refute state.nodes[7].up
  end

  test "a permanently crashed orset node blocks convergence" do
    scenario = %Scenario{
      Scenarios.roster()
      | topology: SignalGarden.Sim.Topology.line(6),
        seed: 5,
        origin: 1,
        fault_schedule: [
          %{at: 100, action: {:add, 1, "Ada"}, label: "add"},
          %{at: 200, action: {:remove, 1, "Ada"}, label: "remove"}
        ]
    }

    state = Core.new(scenario)
    state = Core.command(state, {:crash, 6})
    state = run_to_converge(state)

    refute state.status == :converged
    assert state.nodes[6].up == false
  end

  test "restarting an orset node lets it re-learn the roster" do
    state = run_to_completion(:roster)
    state = Core.command(state, {:crash, 5})
    state = Core.command(state, {:restart, 5})

    assert get_in(state.nodes, [5, :known, state.origin]).store == %{}

    state = run_to_converge(state)
    store = get_in(state.nodes, [5, :known, state.origin]).store
    assert orset_membership(store) == state.orset_elements
  end

  test "add and remove faults appear in the event log" do
    state = Scenarios.fetch(:roster) |> Core.new()
    state = state |> Core.command({:add, 3, "Ada"}) |> Core.command({:remove, 3, "Ada"})

    kinds = Enum.map(state.event_log, & &1.kind)
    assert :added in kinds
    assert :removed in kinds
    assert Enum.any?(state.event_log, &(&1.kind == :removed and &1.element == "Ada"))
  end

  # ---------------------------------------------------------------------------
  # snapshot shape
  # ---------------------------------------------------------------------------

  test "the snapshot exposes orset fields" do
    state = Scenarios.fetch(:roster) |> Core.new()
    state = state |> Core.command({:add, 1, "Ada"})
    snap = Core.snapshot(state)

    assert snap.mode == :orset
    assert snap.orset_ops == 1
    assert snap.orset_adds == 1
    assert snap.orset_removes == 0
    assert snap.orset_size == 1
    assert snap.orset_elements == ["Ada"]

    node = Enum.find(snap.nodes, &(&1.id == 1))
    assert node.value == 1
    assert node.version == 1

    fresh = Enum.find(snap.nodes, &(&1.id == 2))
    assert fresh.value == 0
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp orset_membership(store) do
    store
    |> Enum.filter(fn {_element, %{adds: adds, removes: removes}} ->
      MapSet.difference(adds, removes) != MapSet.new()
    end)
    |> Enum.map(fn {element, _tags} -> element end)
    |> MapSet.new()
  end

  # Hand a node's current store to another node as an in-flight message.
  defp deliver_payload(state, from, to) do
    deliver_payload(state, from, to, get_in(state.nodes, [from, :known, state.origin]))
  end

  defp deliver_payload(state, _from, to, payload) do
    queue = [{1, state.seq + 1, {:deliver, to, payload}}]
    state = %{state | queue: queue}
    {state, _} = Core.step(state, 1)
    state
  end

  defp run_to_completion(id) do
    Scenarios.fetch(id) |> Core.new() |> run_to_converge()
  end

  defp run_to_converge(%Core{} = state), do: await(state, :converged, 200_000)

  defp step_n(%Core{} = state, events) do
    {state, _} = Core.step(state, events)
    state
  end

  defp await(%Core{} = state, target, budget) do
    state = Core.command(state, {:set_status, :running})

    Enum.reduce_while(1..div(budget, 50)//1, state, fn _, acc ->
      acc = step_n(acc, 50)
      if acc.status == target, do: {:halt, acc}, else: {:cont, acc}
    end)
  end
end
