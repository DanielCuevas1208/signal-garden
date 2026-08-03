defmodule Mix.Tasks.Garden.ReplayTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @task Mix.Tasks.Garden.Replay

  test "the task prints a table for every catalog scenario" do
    output = capture_io(fn -> @task.run([]) end)

    assert output =~ "scenario"
    assert output =~ "Grow-only counter"
    assert output =~ "converged"
  end

  test "the task replays one scenario by id" do
    output = capture_io(fn -> @task.run(["ring"]) end)
    assert output =~ "Ring"
    assert output =~ "converged"
  end

  test "the task prints a trace when asked" do
    output = capture_io(fn -> @task.run(["line", "--trace"]) end)
    assert output =~ "delivered"
  end

  test "the task replays a scenario file" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "counter.json"])
    output = capture_io(fn -> @task.run([path]) end)
    assert output =~ "Grow-only counter"
  end

  test "the task verifies determinism across the catalog" do
    output = capture_io(fn -> @task.run(["--verify"]) end)
    assert output =~ "deterministic"
    refute output =~ "MISMATCH"
  end

  test "the task emits machine-readable JSON" do
    output = capture_io(fn -> @task.run(["ring", "--json"]) end)
    assert {:ok, json} = Jason.decode(output)
    assert json["name"] == "Ring"
    assert json["status"] == "converged"
    assert is_list(json["trace"])
  end

  test "an unknown scenario raises a friendly error" do
    assert_raise Mix.Error, ~r/Unknown scenario or file/, fn ->
      capture_io(fn -> @task.run(["nope"]) end)
    end
  end

  test "a missing file raises a friendly error" do
    assert_raise Mix.Error, ~r/No such file/, fn ->
      capture_io(fn -> @task.run(["missing.json"]) end)
    end
  end
end
