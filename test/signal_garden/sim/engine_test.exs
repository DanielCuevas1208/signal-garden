defmodule SignalGarden.Sim.EngineTest do
  use ExUnit.Case, async: false

  alias SignalGarden.Sim.Engine

  setup do
    Engine.load_scenario(:line)
    :ok
  end

  test "the engine loads the default scenario and returns a snapshot" do
    snap = Engine.snapshot()
    assert snap.scenario.id == :line
    assert snap.status == :idle
    assert length(snap.nodes) == 8
  end

  test "stepping advances logical time without starting the loop" do
    Engine.step(20)
    _ = :sys.get_state(Engine)

    snap = Engine.snapshot()
    assert snap.clock > 0
    assert snap.steps > 0
  end

  test "loading a scenario rebuilds the core from its seed" do
    Engine.step(50)
    before = Engine.snapshot()

    Engine.load_scenario(:ring)
    after_load = Engine.snapshot()

    assert after_load.scenario.id == :ring
    assert after_load.clock == 0
    refute after_load.steps == before.steps
  end

  test "runtime delay commands reach the core" do
    Engine.set_delay(120)
    _ = :sys.get_state(Engine)

    assert Engine.snapshot().delay_ms == {120, 120}
  end
end
