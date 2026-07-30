defmodule SignalGarden.Sim.Engine do
  @moduledoc """
  The supervised process that owns the simulator state and drives the
  animation loop.

  The engine keeps a `%SignalGarden.Sim.Core{}` struct and turns LiveView
  commands into pure state transitions. When it runs, it advances the core by
  a small burst of logical events per real frame and broadcasts a snapshot
  over PubSub. The engine never sleeps; it relies on a self-sent timer so the
  loop is cheap to pause and resume.
  """

  use GenServer

  alias SignalGarden.Sim.Core
  alias SignalGarden.Scenarios

  @topic "signal_garden:sim"

  defstruct core: nil,
            frame_ms: 60,
            burst: 6,
            loop_ref: nil

  # ---------------------------------------------------------------------------
  # public api
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def load_scenario(id), do: GenServer.call(__MODULE__, {:load_scenario, id})
  def start_run, do: GenServer.cast(__MODULE__, :start_run)
  def pause, do: GenServer.cast(__MODULE__, :pause)
  def step(count \\ 1), do: GenServer.cast(__MODULE__, {:step, count})
  def reset, do: GenServer.cast(__MODULE__, :reset)
  def set_delay(delay), do: GenServer.cast(__MODULE__, {:set_delay, delay})
  def set_drop(drop), do: GenServer.cast(__MODULE__, {:set_drop, drop})
  def set_interval(interval), do: GenServer.cast(__MODULE__, {:set_interval, interval})
  def set_speed(opts), do: GenServer.cast(__MODULE__, {:set_speed, opts})

  def toggle_partition(node),
    do: GenServer.cast(__MODULE__, {:command, {:toggle_partition, node}})

  def assign_partition(node, group),
    do: GenServer.cast(__MODULE__, {:command, {:assign, node, group}})

  def merge, do: GenServer.cast(__MODULE__, {:command, {:merge, :all}})

  # ---------------------------------------------------------------------------
  # gen server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Application.get_env(:signal_garden, :sim, [])

    state = %__MODULE__{
      frame_ms: Keyword.get(config, :frame_ms, 60),
      burst: Keyword.get(config, :burst, 6)
    }

    initial = Keyword.get(opts, :scenario, :line)

    {:ok, load_scenario_into(state, initial)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Core.snapshot(state.core), state}
  end

  @impl true
  def handle_call({:load_scenario, id}, _from, state) do
    new_state = load_scenario_into(state, id)
    broadcast(new_state)
    {:reply, Core.snapshot(new_state.core), new_state}
  end

  @impl true
  def handle_cast(:start_run, state) do
    core =
      if state.core.status in [:idle, :paused] do
        Core.command(state.core, {:set_status, :running})
      else
        state.core
      end

    state = schedule_loop(%{state | core: core})
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:pause, state) when state.loop_ref != nil do
    Process.cancel_timer(state.loop_ref)
    core = Core.command(state.core, {:set_status, :paused})
    state = %{state | core: core, loop_ref: nil}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:pause, state) do
    core = Core.command(state.core, {:set_status, :paused})
    state = %{state | core: core, loop_ref: nil}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:step, count}, state) do
    {core, _processed} = Core.step(state.core, count)
    state = %{state | core: core}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset, state) do
    id = state.core.scenario.id
    new_state = load_scenario_into(state, id)
    broadcast(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:set_delay, delay}, state) do
    core = Core.command(state.core, {:set_delay, delay})
    state = %{state | core: core}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_drop, drop}, state) do
    core = Core.command(state.core, {:set_drop, drop})
    state = %{state | core: core}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_interval, interval}, state) do
    core = Core.command(state.core, {:set_interval, interval})
    state = %{state | core: core}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_speed, opts}, %__MODULE__{} = state) do
    state = %__MODULE__{state | frame_ms: Keyword.get(opts, :frame_ms, state.frame_ms)}
    state = %__MODULE__{state | burst: Keyword.get(opts, :burst, state.burst)}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:command, cmd}, state) do
    core = Core.command(state.core, cmd)
    state = %{state | core: core}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:loop, state) do
    {core, _processed} = Core.step(state.core, state.burst)
    state = %{state | core: core}

    if core.status == :running do
      state = schedule_loop(%{state | loop_ref: nil})
      broadcast(state)
      {:noreply, state}
    else
      broadcast(%{state | loop_ref: nil})
      {:noreply, %{state | loop_ref: nil}}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp load_scenario_into(state, id) do
    scenario = Scenarios.fetch(id) || Scenarios.fetch(:line)
    %{state | core: Core.new(scenario), loop_ref: cancel_loop(state.loop_ref)}
  end

  defp schedule_loop(%__MODULE__{} = state) do
    ref =
      if state.loop_ref != nil and Process.read_timer(state.loop_ref) do
        state.loop_ref
      else
        Process.send_after(self(), :loop, state.frame_ms)
      end

    %{state | loop_ref: ref}
  end

  defp cancel_loop(nil), do: nil

  defp cancel_loop(ref) do
    Process.cancel_timer(ref)
    nil
  end

  defp broadcast(%__MODULE__{} = state) do
    Phoenix.PubSub.broadcast(
      SignalGarden.PubSub,
      @topic,
      {:sim_snapshot, Core.snapshot(state.core)}
    )
  end

  @doc "The PubSub topic the engine broadcasts snapshots on."
  def topic, do: @topic
end
