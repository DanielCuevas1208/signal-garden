defmodule SignalGarden.Sim.ReplayTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.Replay

  @sample_path Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])

  describe "summaries/0" do
    test "returns one summary per catalog scenario" do
      summaries = Replay.summaries()

      assert length(summaries) == length(Scenarios.catalog())
      assert Enum.all?(summaries, &(&1.status == :converged))
    end

    test "each summary carries the core outcome fields" do
      [line | _] = Replay.summaries()

      assert line.scenario == "Line"
      assert line.id == :line
      assert line.mode == :rumor
      assert line.nodes == 8
      assert line.convergence_time > 0
      assert line.hops > 0
      assert line.dropped == 0
      assert line.steps > 0
    end

    test "the counter scenario reports counter mode and total" do
      counter = Enum.find(Replay.summaries(), &(&1.id == :counter))

      assert counter.mode == :counter
      assert counter.counter_total == 9
      assert counter.dropped > 0
    end

    test ~S(the ledger summary includes signed totals) do
      ledger = Enum.find(Replay.summaries(), &(&1.id == :ledger))

      assert ledger.mode == :pn_counter
      assert ledger.pn_adjustments == 5
      assert ledger.pn_counter_total == 1
      assert ledger.pn_positive_total == 8
      assert ledger.pn_negative_total == 7
      assert ledger.dropped > 0
    end

    test "the set scenario reports set mode and element count" do
      guest = Enum.find(Replay.summaries(), &(&1.id == :guest_list))

      assert guest.mode == :set
      assert guest.set_size == 5
      assert guest.dropped > 0
    end

    test "the roster scenario reports orset mode and the surviving members" do
      roster = Enum.find(Replay.summaries(), &(&1.id == :roster))

      assert roster.mode == :orset
      assert roster.orset_adds == 4
      assert roster.orset_removes == 2
      assert roster.orset_size == 2
      assert roster.orset_elements == ["Alan", "Edsger"]
      assert roster.dropped > 0
    end

    test "the register scenario reports register mode and latest value" do
      bulletin = Enum.find(Replay.summaries(), &(&1.id == :bulletin))

      assert bulletin.mode == :register
      assert bulletin.register_value == "All systems nominal"
      assert bulletin.dropped > 0
    end

    test "the service board scenario reports map mode and the converged map" do
      board = Enum.find(Replay.summaries(), &(&1.id == :service_board))

      assert board.mode == :map
      assert board.map_writes == 5
      assert board.map_size == 4
      assert board.dropped > 0

      db = Enum.find(board.map_fields, &(&1.key == "db"))
      assert db.value == "operational"
      assert db.version == 5

      conflict = Enum.find(Replay.summaries(), &(&1.id == :conflict_board))
      assert Enum.map(conflict.mv_timeline, & &1.visible) == [true, true]
      assert Enum.map(conflict.mv_timeline, & &1.observed) == [[], []]
    end
  end

  describe "run/1" do
    test "accepts an id atom, an id string, and a scenario struct" do
      by_atom = Replay.run(:ring)
      by_string = Replay.run("ring")
      by_struct = Replay.run(Scenarios.fetch(:ring))

      assert by_atom.status == :converged
      assert by_string.status == :converged
      assert by_struct.status == :converged
    end

    test "accepts a path to a scenario file" do
      core = Replay.run(@sample_path)
      assert core.scenario.id == :ring
      assert core.status == :converged
    end

    test "raises for an unknown scenario id" do
      assert_raise ArgumentError, ~r/unknown scenario id/, fn ->
        Replay.run(:does_not_exist)
      end
    end

    test "raises for a missing file" do
      assert_raise ArgumentError, ~r/file does not exist/, fn ->
        Replay.run("priv/scenarios/does_not_exist.json")
      end
    end
  end

  describe "event_trace/1" do
    test "returns events oldest first with a non-decreasing clock" do
      trace = Replay.event_trace(:line)

      assert trace != []

      assert Enum.all?(trace, fn event ->
               Map.has_key?(event, :t) and Map.has_key?(event, :kind) and
                 Map.has_key?(event, :from) and Map.has_key?(event, :to) and
                 Map.has_key?(event, :partition)
             end)

      assert Enum.chunk_every(trace, 2, 1, :discard)
             |> Enum.all?(fn [a, b] -> a.t <= b.t end)
    end

    test "records deliveries and partition drops" do
      trace = Replay.event_trace(:line)

      assert Enum.any?(trace, &(&1.kind == :deliver))
    end

    test "marks dropped events caused by a cut link" do
      trace = Replay.event_trace(:cut)

      cut_drop = Enum.find(trace, &(&1.kind == :dropped_cut))
      assert cut_drop != nil
      assert cut_drop.cut == true
      assert cut_drop.to != nil
    end
  end

  describe "determinism_check/1" do
    test "a healthy scenario replays identically" do
      check = Replay.determinism_check(:ring)

      assert check.scenario == "Ring"
      assert check.convergence_time
      assert check.hops
      assert check.dropped
      assert check.steps
      assert check.history
      assert check.event_log
      assert check.mv_timeline
    end

    test "accepts a scenario struct and a path" do
      assert Enum.all?(Replay.determinism_check(Scenarios.ring()), &field_true?/1)
      assert Enum.all?(Replay.determinism_check(@sample_path), &field_true?/1)
    end
  end

  describe "determinism_check_all/0" do
    test "every catalog scenario replays identically" do
      checks = Replay.determinism_check_all()

      assert length(checks) == length(Scenarios.catalog())

      for check <- checks do
        assert Enum.all?(check, &field_true?/1), "check failed for #{check.scenario}"
      end
    end
  end

  describe "compare/2" do
    test "returns deterministic summaries, metric deltas, and trailing traces" do
      comparison = Replay.compare(:ring, :cut)

      assert comparison.left.id == :ring
      assert comparison.right.id == :cut
      assert comparison.left.description == Scenarios.ring().description
      assert comparison.left.latest_value == Scenarios.ring().latest_value
      assert comparison.right.latest_value == Scenarios.cut().latest_value

      assert comparison.deltas.convergence_time ==
               comparison.right.convergence_time - comparison.left.convergence_time

      assert comparison.deltas.dropped > 0
      assert comparison.traces.left != []
      assert comparison.traces.right != []
      assert Enum.all?(comparison.traces.left, &Map.has_key?(&1, :kind))
      assert Enum.all?(comparison.traces.right, &Map.has_key?(&1, :kind))
    end

    test "comparing a scenario with itself produces equal evidence" do
      comparison = Replay.compare(:ring, :ring)

      assert comparison.deltas == %{convergence_time: 0, hops: 0, dropped: 0, steps: 0}
      assert comparison.traces.left == comparison.traces.right
      assert comparison.left == comparison.right
    end
  end

  describe "scenario_from_file/1" do
    test "reads and decodes a scenario file" do
      assert {:ok, scenario} = Replay.scenario_from_file(@sample_path)
      assert scenario.name == "Ring"
    end

    test "returns an error for a missing file" do
      assert {:error, :enoent} = Replay.scenario_from_file("priv/scenarios/nope.json")
    end

    test "returns an error for invalid JSON" do
      path = Path.join(System.tmp_dir!(), "bad.json")
      File.write!(path, "{not json")
      on_exit(fn -> File.rm(path) end)

      assert {:error, {:invalid_json, _}} = Replay.scenario_from_file(path)
    end
  end

  defp field_true?({_field, value}) when is_boolean(value), do: value
  defp field_true?({_field, _label}), do: true
end
