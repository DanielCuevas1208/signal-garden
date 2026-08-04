defmodule SignalGarden.ReplayTest do
  use ExUnit.Case, async: true

  alias SignalGarden.{Replay, Scenarios}
  alias SignalGarden.Sim.{Core, Scenario}

  describe "run/2" do
    test "replays a scenario to convergence and reports the same metrics as the core" do
      scenario = Scenarios.ring()
      result = Replay.run(scenario)

      assert result.status == :converged
      assert result.clock != nil
      assert result.scenario.name == "Ring"
      assert result.scenario.nodes == 12

      direct = direct_run(scenario)
      assert result.clock == direct.convergence_time
      assert result.hops == direct.hops
      assert result.steps == direct.steps
      assert result.dropped == direct.dropped
    end

    test "collects a full chronological event trace" do
      result = Replay.run(Scenarios.lossy())

      assert result.events != []
      assert Enum.map(result.events, & &1.t) == Enum.sort(Enum.map(result.events, & &1.t))
      assert Enum.any?(result.events, &(&1.kind == :deliver))
      assert Enum.any?(result.events, &(&1.kind == :dropped_loss))
    end

    test "records counter metrics in counter mode" do
      result = Replay.run(Scenarios.counter())

      assert result.status == :converged
      assert result.counter_total == 9
      assert result.counter_writes == 5
      assert Enum.any?(result.events, &(&1.kind == :increment))
    end

    test "crashes and restarts appear in the trace" do
      result = Replay.run(Scenarios.crash())

      assert Enum.any?(result.events, &(&1.kind == :crashed))
      assert Enum.any?(result.events, &(&1.kind == :restarted))
    end

    test "two runs produce identical traces and fingerprints" do
      a = Replay.run(Scenarios.ring())
      b = Replay.run(Scenarios.ring())

      assert a.events == b.events
      assert a.history == b.history
      assert a.fingerprint == b.fingerprint
    end

    test "a different seed changes the fingerprint and the trace" do
      a = Replay.run(Scenarios.ring())
      changed = %Scenario{Scenarios.ring() | seed: 999}
      b = Replay.run(changed)

      refute a.fingerprint == b.fingerprint
      refute a.events == b.events
    end
  end

  describe "load_source/1" do
    test "accepts a catalog id atom, a catalog id string, and a struct" do
      assert {:ok, %Scenario{id: :ring}} = Replay.load_source(:ring)
      assert {:ok, %Scenario{id: :ring}} = Replay.load_source("ring")
      assert {:ok, %Scenario{id: :ring}} = Replay.load_source(Scenarios.ring())
    end

    test "accepts a JSON scenario file path" do
      path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
      assert {:ok, %Scenario{} = scenario} = Replay.load_source(path)
      assert scenario.name == "Ring"
    end

    test "rejects unknown sources" do
      assert {:error, {:unknown_scenario, :nope}} = Replay.load_source(:nope)
      assert {:error, {:file_not_found, _}} = Replay.load_source("missing/file.json")
    end
  end

  describe "verify/2" do
    test "confirms that the same seed is deterministic" do
      assert {:ok, a, b} = Replay.verify(Scenarios.ring())
      assert a.fingerprint == b.fingerprint
      assert a.events == b.events
    end

    test "verify_all reports every built-in scenario as deterministic" do
      reports = Replay.verify_all()

      assert length(reports) == length(Scenarios.catalog())
      assert Enum.all?(reports, & &1.ok)
      assert Enum.all?(reports, &is_binary(&1.fingerprint))
    end
  end

  describe "rendering" do
    test "the summary table reproduces the sample columns" do
      results = Enum.map(Scenarios.catalog(), &Replay.run/1)
      text = Replay.render_summary_table(results)
      lines = String.split(text, "\n")

      assert hd(lines) =~ "scenario"
      assert Enum.at(lines, 1) =~ "Line"
      assert List.last(lines) =~ "Grow-only counter"
    end

    test "render includes the summary and the trace" do
      result = Replay.run(Scenarios.ring())
      text = Replay.render(result)

      assert text =~ "Scenario: Ring"
      assert text =~ "Fingerprint:"
      assert text =~ "Event trace"
      assert text =~ "send"
    end

    test "render without a trace omits the events" do
      result = Replay.run(Scenarios.ring())
      refute Replay.render(result, trace: false) =~ "Event trace"
    end

    test "format_event renders one line per event kind" do
      assert Replay.format_event(%{t: 10, kind: :deliver, from: 1, to: 2}) =~ "send"
      assert Replay.format_event(%{t: 10, kind: :crashed, from: 4}) =~ "crashed"
      assert Replay.format_event(%{t: 10, kind: :increment, from: 1, amount: 2}) =~ "write"
      assert Replay.format_event(%{t: 10, kind: :dropped_loss, from: 1, to: 2}) =~ "lost"
    end
  end

  describe "fingerprint/1" do
    test "is stable across separate runs" do
      a = Replay.run(Scenarios.counter())
      b = Replay.run(Scenarios.counter())
      assert a.fingerprint == b.fingerprint
    end

    test "is a lower-case hex digest" do
      result = Replay.run(Scenarios.ring())
      assert result.fingerprint =~ ~r/^[0-9a-f]{64}$/
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp direct_run(scenario) do
    scenario
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
end
