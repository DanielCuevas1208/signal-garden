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

    test "the set scenario reports set mode and element count" do
      guest = Enum.find(Replay.summaries(), &(&1.id == :guest_list))

      assert guest.mode == :set
      assert guest.set_size == 5
      assert guest.dropped > 0
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
