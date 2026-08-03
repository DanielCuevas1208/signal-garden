defmodule SignalGarden.Sim do
  @moduledoc """
  Public facade for the Signal Garden simulator.

  The LiveView talks to the engine only through this module so the runtime
  layout stays easy to follow. Every function maps to one GenServer call or
  cast. See `SignalGarden.Sim.Engine` for the loop and `SignalGarden.Sim.Core`
  for the deterministic core.
  """

  alias SignalGarden.Sim.Engine

  @doc "Read the current snapshot from the engine."
  def snapshot, do: Engine.snapshot()

  @doc "Get the PubSub topic that snapshots arrive on."
  def topic, do: Engine.topic()

  @doc "Load a scenario by id, replacing the current run."
  def load_scenario(id), do: Engine.load_scenario(id)

  @doc "Load a scenario struct, replacing the current run."
  def load_scenario_struct(scenario), do: Engine.load_scenario_struct(scenario)

  @doc "Export the current scenario as pretty-printed JSON."
  def export_scenario, do: Engine.export_scenario()

  @doc "Decode JSON and load the scenario into the engine."
  def import_scenario(json) do
    with {:ok, scenario} <- SignalGarden.Sim.ScenarioCodec.decode(json) do
      {:ok, load_scenario_struct(scenario)}
    end
  end

  @doc "Start the animation loop if the core is idle or paused."
  def start_run, do: Engine.start_run()

  @doc "Stop the loop and mark the core paused."
  def pause, do: Engine.pause()

  @doc "Advance the core by a fixed number of events without starting a loop."
  def step(count \\ 1), do: Engine.step(count)

  @doc "Rebuild the current scenario from its seed."
  def reset, do: Engine.reset()

  @doc "Set the per-message delay, in logical ms."
  def set_delay(delay), do: Engine.set_delay(delay)

  @doc "Set the message loss probability, a float from 0.0 to 1.0."
  def set_drop(drop), do: Engine.set_drop(drop)

  @doc "Set the gossip interval, in logical ms."
  def set_interval(interval), do: Engine.set_interval(interval)

  @doc "Set the animation speed from a keyword list with `:frame_ms` and `:burst`."
  def set_speed(opts), do: Engine.set_speed(opts)

  @doc "Move a node into a partition group."
  def assign_partition(node, group), do: Engine.assign_partition(node, group)

  @doc "Toggle a node between group zero and group one."
  def toggle_partition(node), do: Engine.toggle_partition(node)

  @doc "Take a node out of service until it is restarted."
  def crash(node), do: Engine.crash(node)

  @doc "Return a crashed node to service."
  def restart(node), do: Engine.restart(node)

  @doc "Heal all partitions."
  def merge, do: Engine.merge()
end
