defmodule SignalGardenWeb.GardenLive do
  @moduledoc """
  The single-page control room for the simulator.

  The LiveView subscribes to the engine snapshot topic and re-renders the
  graph, the timeline, and the event log whenever the core advances. All
  interaction is local; the page needs no backend beyond the engine.
  """

  use SignalGardenWeb, :live_view

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim

  # Canvas dimensions in user units; the view scales the SVG to its container.
  @canvas_width 720
  @canvas_height 540

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SignalGarden.PubSub, Sim.topic())
    end

    snapshot = Sim.snapshot()

    socket =
      socket
      |> assign(:page_title, "Signal Garden")
      |> assign(:snapshot, snapshot)
      |> assign(:scenarios, Enum.map(Scenarios.catalog(), &scenario_option/1))
      |> assign(:selected_scenario, snapshot.scenario.id)
      |> assign(:canvas, {@canvas_width, @canvas_height})
      |> assign(:delay_value, delay_to_form(snapshot.delay_ms))
      |> assign(:drop_value, round(snapshot.drop_prob * 100))
      |> assign(:speed, 6)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    SignalGardenWeb.GardenLiveHTML.show(assigns)
  end

  @impl true
  def handle_info({:sim_snapshot, snapshot}, socket) do
    {:noreply, sync_controls(socket, snapshot)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start", _params, socket) do
    Sim.start_run()
    {:noreply, socket}
  end

  def handle_event("pause", _params, socket) do
    Sim.pause()
    {:noreply, socket}
  end

  def handle_event("step", %{"count" => count}, socket) do
    Sim.step(parse_int(count, 1))
    {:noreply, socket}
  end

  def handle_event("reset", _params, socket) do
    Sim.reset()
    {:noreply, socket}
  end

  def handle_event("select_scenario", %{"scenario" => id}, socket) do
    id = String.to_existing_atom(id)
    Sim.load_scenario(id)
    {:noreply, assign(socket, :selected_scenario, id)}
  end

  def handle_event("set_delay", %{"delay" => value}, socket) do
    delay = parse_int(value, 35)
    Sim.set_delay(delay)
    {:noreply, assign(socket, :delay_value, delay)}
  end

  def handle_event("set_drop", %{"drop" => value}, socket) do
    percent = parse_int(value, 0)
    percent = max(0, min(100, percent))
    Sim.set_drop(percent / 100)
    {:noreply, assign(socket, :drop_value, percent)}
  end

  def handle_event("set_speed", %{"burst" => value}, socket) do
    burst = parse_int(value, 6)
    burst = max(1, min(40, burst))
    Sim.set_speed(burst: burst, frame_ms: 60)
    {:noreply, assign(socket, :speed, burst)}
  end

  def handle_event("toggle_partition", %{"node" => node_id}, socket) do
    Sim.toggle_partition(parse_int(node_id, 1))
    {:noreply, socket}
  end

  def handle_event("merge", _params, socket) do
    Sim.merge()
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp scenario_option(scenario) do
    %{id: scenario.id, name: scenario.name, description: scenario.description}
  end

  defp sync_controls(socket, snapshot) do
    socket
    |> assign(:snapshot, snapshot)
    |> assign(:selected_scenario, snapshot.scenario.id)
    |> assign(:delay_value, delay_to_form(snapshot.delay_ms))
    |> assign(:drop_value, round(snapshot.drop_prob * 100))
  end

  defp delay_to_form({_lo, hi}), do: hi
  defp delay_to_form(value) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default
end
