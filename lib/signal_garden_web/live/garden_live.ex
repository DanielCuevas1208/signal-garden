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
      |> assign(:fault_node, snapshot.origin)
      |> assign(:fault_element, "")
      |> assign(:link_edges, edge_options(snapshot))
      |> assign(:link_edge, first_edge_value(snapshot))
      |> assign(:show_import, false)
      |> assign(:import_json, "")

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

  def handle_event("toggle_link_cut", %{"a" => a, "b" => b}, socket) do
    Sim.toggle_link_cut(parse_int(a, 1), parse_int(b, 1))
    {:noreply, socket}
  end

  def handle_event("select_link_edge", %{"edge" => edge}, socket) do
    {:noreply, assign(socket, :link_edge, edge)}
  end

  def handle_event("cut_link", %{"edge" => edge}, socket) do
    {a, b} = parse_edge(edge)
    Sim.cut_link(a, b)
    {:noreply, socket}
  end

  def handle_event("heal_link", %{"edge" => edge}, socket) do
    {a, b} = parse_edge(edge)
    Sim.heal_link(a, b)
    {:noreply, socket}
  end

  def handle_event("crash", %{"node" => node_id}, socket) do
    Sim.crash(parse_int(node_id, 1))
    {:noreply, socket}
  end

  def handle_event("restart", %{"node" => node_id}, socket) do
    Sim.restart(parse_int(node_id, 1))
    {:noreply, socket}
  end

  def handle_event("increment", %{"node" => node_id}, socket) do
    Sim.increment(parse_int(node_id, 1))
    {:noreply, socket}
  end

  def handle_event("add_element", %{"element" => element}, socket) do
    case normalize_element(element) do
      nil ->
        {:noreply, socket}

      value ->
        Sim.add(socket.assigns.fault_node, value)
        {:noreply, assign(socket, :fault_element, "")}
    end
  end

  def handle_event("publish_value", %{"value" => value}, socket) do
    case normalize_element(value) do
      nil ->
        {:noreply, socket}

      text ->
        Sim.write(socket.assigns.fault_node, text)
        {:noreply, assign(socket, :fault_element, "")}
    end
  end

  def handle_event("select_fault_node", %{"node" => node_id}, socket) do
    {:noreply, assign(socket, :fault_node, parse_int(node_id, 1))}
  end

  def handle_event("merge", _params, socket) do
    Sim.merge()
    {:noreply, socket}
  end

  def handle_event("export_scenario", _params, socket) do
    json = Sim.export_scenario()
    id = socket.assigns.snapshot.scenario.id
    filename = "#{id}-scenario.json"

    {:noreply, push_event(socket, "download_scenario", %{content: json, filename: filename})}
  end

  def handle_event("toggle_import", _params, socket) do
    {:noreply, assign(socket, :show_import, not socket.assigns.show_import)}
  end

  def handle_event("import_scenario", %{"json" => json}, socket) do
    case Sim.import_scenario(String.trim(json)) do
      {:ok, snapshot} ->
        {:noreply,
         socket
         |> put_flash(:info, "Scenario \"#{snapshot.scenario.name}\" loaded.")
         |> assign(:show_import, false)
         |> assign(:import_json, "")
         |> sync_controls(snapshot)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, import_error(reason))}
    end
  end

  defp import_error({:invalid_json, _}), do: "The file is not valid JSON."

  defp import_error({:unsupported_format, version}),
    do: "Format version #{version} is not supported."

  defp import_error({:invalid_field, field}), do: "The field \"#{field}\" is invalid."

  defp import_error({:invalid_origin, origin}),
    do: "Origin node #{origin} is not in the topology."

  defp import_error(:missing_format), do: "The file is missing a format version."
  defp import_error(_), do: "The scenario file could not be loaded."

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
    |> assign(:fault_node, keep_node(socket.assigns.fault_node, snapshot))
    |> assign(:link_edges, edge_options(snapshot))
    |> assign(:link_edge, keep_edge(socket.assigns.link_edge, snapshot))
  end

  defp keep_node(value, snapshot) do
    if Enum.any?(snapshot.nodes, &(&1.id == value)) do
      value
    else
      snapshot.origin
    end
  end

  defp normalize_element(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      element -> element
    end
  end

  defp normalize_element(_), do: nil

  defp delay_to_form({_lo, hi}), do: hi
  defp delay_to_form(value) when is_integer(value), do: value

  defp edge_options(snapshot) do
    Enum.map(snapshot.edges, fn edge ->
      %{value: edge_value(edge), label: edge_label(edge)}
    end)
  end

  defp edge_value(%{a: a, b: b}), do: "#{a}-#{b}"

  defp edge_label(%{a: a, b: b, cut: cut}) do
    "#{a} - #{b}#{if cut, do: " (cut)", else: ""}"
  end

  defp first_edge_value(snapshot) do
    case snapshot.edges do
      [edge | _] -> edge_value(edge)
      [] -> "1-2"
    end
  end

  defp keep_edge(value, snapshot) do
    if Enum.any?(snapshot.edges, &(edge_value(&1) == value)) do
      value
    else
      first_edge_value(snapshot)
    end
  end

  defp parse_edge("") do
    {1, 2}
  end

  defp parse_edge(value) when is_binary(value) do
    case String.split(value, "-", parts: 2) do
      [a, b] -> {parse_int(a, 1), parse_int(b, 1)}
      _ -> {1, 2}
    end
  end

  defp parse_edge(_), do: {1, 2}

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default
end
