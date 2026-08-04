defmodule SignalGarden.Sim.SetTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario}

  # ---------------------------------------------------------------------------
  # determinism and convergence
  # ---------------------------------------------------------------------------

  test "a grow-only set scenario converges to the expected collection" do
    state = run_to_completion(:guest_list)

    assert state.status == :converged
    assert state.adds_issued == 5
    assert MapSet.size(state.elements) == 5
    assert state.elements == MapSet.new(["Ada", "Grace", "Alan", "Edsger", "Barbara"])

    sets =
      Enum.map(state.topology.nodes, fn id ->
        get_in(state.nodes, [id, :known, state.origin]).elements
      end)

    assert Enum.all?(sets, &MapSet.equal?(&1, state.elements))
  end

  test "two set runs converge at the same logical clock" do
    a = run_to_completion(:guest_list)
    b = run_to_completion(:guest_list)

    assert a.convergence_time == b.convergence_time
    assert a.history == b.history
    assert a.event_log == b.event_log
  end

  test "the run does not converge before all scheduled adds are issued" do
    state = Scenarios.fetch(:guest_list) |> Core.new()
    {state, _} = Core.step(state, 500)

    refute state.status == :converged
    assert MapSet.size(state.informed) == 0
  end

  # ---------------------------------------------------------------------------
  # add commands
  # ---------------------------------------------------------------------------

  test "a manual add puts an element into the writing node's set" do
    state = Scenarios.fetch(:guest_list) |> Core.new()
    state = Core.command(state, {:add, 3, "Linus"})

    assert state.adds_issued == 1
    assert MapSet.member?(state.elements, "Linus")
    assert MapSet.member?(get_in(state.nodes, [3, :known, state.origin]).elements, "Linus")
  end

  test "add commands are ignored in rumor mode" do
    state = Scenarios.fetch(:ring) |> Core.new()
    state = Core.command(state, {:add, 2, "Linus"})

    assert state.adds_issued == 0
    assert MapSet.size(state.elements) == 0
  end

  test "a manual add after convergence re-arms the run" do
    state = run_to_completion(:guest_list)
    assert state.status == :converged

    state = Core.command(state, {:add, 2, "Barbara"})
    assert state.status == :idle
    assert state.adds_issued == 6
    assert MapSet.size(state.elements) == 5

    state = Core.command(state, {:add, 2, "Linus"})
    assert state.adds_issued == 7
    assert MapSet.size(state.elements) == 6

    state = run_to_converge(state)
    assert state.status == :converged
    assert MapSet.member?(state.elements, "Linus")

    sets =
      Enum.map(state.topology.nodes, fn id ->
        get_in(state.nodes, [id, :known, state.origin]).elements
      end)

    assert Enum.all?(sets, &MapSet.equal?(&1, state.elements))
  end

  test "a scheduled add does not move the convergence target" do
    scenario = %Scenario{
      Scenarios.guest_list()
      | fault_schedule: [%{at: 10, action: {:add, 2, "Ada"}, label: "add"}]
    }

    state = Core.new(scenario)
    state = step_n(state, 20)

    assert state.adds_issued == 1
    assert state.adds_target == 1
    assert MapSet.member?(state.elements, "Ada")
  end

  # ---------------------------------------------------------------------------
  # union merge semantics
  # ---------------------------------------------------------------------------

  test "delivering a message merges sets with union" do
    state = Scenarios.fetch(:guest_list) |> Core.new()

    # Node 1 learns two elements, node 2 learns one.
    state = state |> Core.command({:add, 1, "Ada"}) |> Core.command({:add, 2, "Grace"})
    state = Core.command(state, {:add, 1, "Alan"})

    # Hand node 1's set straight to node 2 as an in-flight message.
    payload = get_in(state.nodes, [1, :known, state.origin])
    queue = [{1, state.seq + 1, {:deliver, 2, payload}}]
    state = %{state | queue: queue}
    {state, _} = Core.step(state, 1)

    elements = get_in(state.nodes, [2, :known, state.origin]).elements
    assert MapSet.equal?(elements, MapSet.new(["Ada", "Grace", "Alan"]))
  end

  test "a duplicate add leaves the set unchanged" do
    state = Scenarios.fetch(:guest_list) |> Core.new()
    state = state |> Core.command({:add, 1, "Ada"}) |> Core.command({:add, 1, "Ada"})

    assert state.adds_issued == 2
    assert MapSet.size(state.elements) == 1
  end

  # ---------------------------------------------------------------------------
  # faults and set state
  # ---------------------------------------------------------------------------

  test "crashing a set node drops its elements" do
    state = Scenarios.fetch(:guest_list) |> Core.new()

    state = %{state | queue: []}
    state = Core.command(state, {:add, 7, "Ada"})
    assert MapSet.member?(get_in(state.nodes, [7, :known, state.origin]).elements, "Ada")

    state = Core.command(state, {:crash, 7})
    assert MapSet.size(get_in(state.nodes, [7, :known, state.origin]).elements) == 0
    refute state.nodes[7].up
  end

  test "a permanently crashed set node blocks convergence" do
    scenario = %Scenario{
      Scenarios.guest_list()
      | topology: SignalGarden.Sim.Topology.line(6),
        seed: 5,
        origin: 1,
        fault_schedule: [%{at: 100, action: {:add, 1, "Ada"}, label: "add"}]
    }

    state = Core.new(scenario)
    state = Core.command(state, {:crash, 6})
    state = run_to_converge(state)

    refute state.status == :converged
    assert state.nodes[6].up == false
  end

  test "restarting a set node lets it re-learn the collection" do
    state = run_to_completion(:guest_list)
    state = Core.command(state, {:crash, 5})
    state = Core.command(state, {:restart, 5})

    assert MapSet.size(get_in(state.nodes, [5, :known, state.origin]).elements) == 0

    state = run_to_converge(state)
    elements = get_in(state.nodes, [5, :known, state.origin]).elements
    assert MapSet.equal?(elements, MapSet.new(["Ada", "Grace", "Alan", "Edsger", "Barbara"]))
  end

  test "add faults appear in the event log" do
    state = Scenarios.fetch(:guest_list) |> Core.new()
    state = Core.command(state, {:add, 3, "Ada"})

    assert :added in Enum.map(state.event_log, & &1.kind)
    assert Enum.any?(state.event_log, &(&1.kind == :added and &1.element == "Ada"))
  end

  # ---------------------------------------------------------------------------
  # snapshot shape
  # ---------------------------------------------------------------------------

  test "the snapshot exposes set fields" do
    state = Scenarios.fetch(:guest_list) |> Core.new() |> Core.command({:add, 1, "Ada"})
    snap = Core.snapshot(state)

    assert snap.mode == :set
    assert snap.set_size == 1
    assert snap.set_adds == 1
    assert snap.set_elements == ["Ada"]

    node = Enum.find(snap.nodes, &(&1.id == 1))
    assert node.value == 1
    assert node.version == 1
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

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
