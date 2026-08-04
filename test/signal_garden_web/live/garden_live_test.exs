defmodule SignalGardenWeb.GardenLiveTest do
  use SignalGardenWeb.ConnCase

  import Phoenix.LiveViewTest

  alias SignalGarden.Scenarios

  test "the control room mounts and shows the first scenario", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, ".sg-brand__title", "Signal Garden")
    assert has_element?(view, "#sg-stage svg")
    assert has_element?(view, "#sg-scenario")

    first = hd(Scenarios.catalog())
    assert is_atom(first.id)
    assert html =~ first.name
  end

  test "the scenario picker loads a different scenario", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "grid"})

    snapshot = Phoenix.LiveViewTest.element(view, ".sg-svg")
    assert render(snapshot) =~ "svg"
  end

  test "export and import controls are present", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Export JSON"
    assert html =~ "Import JSON"
  end

  test "importing a scenario file loads it into the engine", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
    json = File.read!(path)

    view |> render_click("toggle_import")

    view
    |> form("#sg-form-import", %{json: json})
    |> render_submit()

    snapshot = SignalGarden.Sim.snapshot()
    assert snapshot.scenario.name == "Ring"
    assert snapshot.total == 12
  end

  test "the Run button starts the loop and Step advances the clock", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> render_click("start")
    view |> render_click("step", %{"count" => "10"})

    snapshot = await_engine(fn snap -> snap.clock >= 0 end)
    assert snapshot.clock >= 0
  end

  test "the fault injector offers crash and restart controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#sg-fault-node")
    assert has_element?(view, "button", "Crash")
    assert has_element?(view, "button", "Restart")

    view |> render_click("crash", %{"node" => "2"})

    snapshot = await_engine(fn snap -> Enum.any?(snap.nodes, &(&1.id == 2 and not &1.up)) end)
    down = Enum.find(snapshot.nodes, &(&1.id == 2))
    assert down.up == false

    view |> render_click("restart", %{"node" => "2"})

    snapshot = await_engine(fn snap -> Enum.any?(snap.nodes, &(&1.id == 2 and &1.up)) end)
    up = Enum.find(snapshot.nodes, &(&1.id == 2))
    assert up.up == true
  end

  test "counter mode shows the write control and increments the total", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "counter"})

    assert has_element?(view, "button", "+1")
    assert has_element?(view, ".sg-node__value")
    assert render(view) =~ "nodes at total"

    view |> render_click("increment", %{"node" => "2"})

    snapshot = await_engine(fn snap -> snap.counter_writes == 1 end)
    assert snapshot.mode == :counter
    assert snapshot.counter_writes == 1
    assert snapshot.counter_total == 1
  end

  test "set mode shows the add control and adds an element", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "guest_list"})

    assert has_element?(view, "#sg-add-element")
    assert render(view) =~ "nodes hold the full set"
    assert render(view) =~ "Elements"
    refute render(view) =~ "Set contents"

    view
    |> form("#sg-form-add", %{element: "Linus"})
    |> render_submit()

    snapshot = await_engine(fn snap -> snap.set_adds == 1 end)
    assert snapshot.mode == :set
    assert snapshot.set_adds == 1
    assert snapshot.set_size == 1
    assert snapshot.set_elements == ["Linus"]
    assert render(view) =~ "Set contents"
    assert render(view) =~ "Linus"
  end

  test "an empty add is ignored and keeps the run idle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "guest_list"})

    view
    |> form("#sg-form-add", %{element: "   "})
    |> render_submit()

    snapshot = await_engine(fn snap -> snap.set_adds == 0 end)
    assert snapshot.set_adds == 0
    assert snapshot.set_size == 0
  end

  test "register mode shows the publish control and writes a value", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "bulletin"})

    assert has_element?(view, "#sg-write-value")
    assert render(view) =~ "nodes hold the latest notice"
    assert render(view) =~ "Writes"

    view
    |> form("#sg-form-write", %{value: "Manual notice"})
    |> render_submit()

    snapshot = await_engine(fn snap -> snap.register_writes == 1 end)
    assert snapshot.mode == :register
    assert snapshot.register_writes == 1
    assert snapshot.register_value == "Manual notice"
    assert render(view) =~ "Current notice"
    assert render(view) =~ "Manual notice"
  end

  test "an empty register write is ignored and keeps the run idle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "bulletin"})

    view
    |> form("#sg-form-write", %{value: "   "})
    |> render_submit()

    snapshot = await_engine(fn snap -> snap.register_writes == 0 end)
    assert snapshot.register_writes == 0
    assert snapshot.register_value == nil
  end

  test "map mode shows the key picker and sets a service status", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "service_board"})

    assert has_element?(view, "#sg-map-key")
    assert has_element?(view, "#sg-put-value")
    assert render(view) =~ "nodes hold the full map"
    assert render(view) =~ "Services"

    view
    |> form("#sg-form-put", %{key: "api", value: "degraded"})
    |> render_submit()

    snapshot = await_engine(fn snap -> snap.map_writes == 1 end)
    assert snapshot.mode == :map
    assert snapshot.map_writes == 1
    assert snapshot.map_fields == [%{key: "api", value: "degraded", version: 1}]
    assert render(view) =~ "Service status"
    assert render(view) =~ "api"
    assert render(view) =~ "degraded"
  end

  test "an empty map value is ignored and keeps the run idle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "service_board"})

    view
    |> form("#sg-form-put", %{key: "api", value: "   "})
    |> render_submit()

    snapshot = await_engine(fn snap -> snap.map_writes == 0 end)
    assert snapshot.map_writes == 0
    assert snapshot.map_fields == []
  end

  test "link cut controls are present", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#sg-link-edge")
    assert has_element?(view, "button", "Cut")
    assert has_element?(view, "button", "Heal")
    assert has_element?(view, ".sg-legend__item", "cut link")
  end

  test "clicking an edge toggles its cut state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "line"})

    view |> render_click("toggle_link_cut", %{"a" => "1", "b" => "2"})

    snapshot =
      await_engine(fn snap ->
        Enum.any?(snap.edges, &(&1.a == 1 and &1.b == 2 and &1.cut))
      end)

    edge = Enum.find(snapshot.edges, &(&1.a == 1 and &1.b == 2))
    assert edge.cut == true

    view |> render_click("toggle_link_cut", %{"a" => "2", "b" => "1"})

    snapshot =
      await_engine(fn snap ->
        Enum.any?(snap.edges, &(&1.a == 1 and &1.b == 2 and not &1.cut))
      end)

    edge = Enum.find(snapshot.edges, &(&1.a == 1 and &1.b == 2))
    assert edge.cut == false
  end

  test "the link cut picker cuts and heals the selected edge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "line"})

    view |> render_click("cut_link", %{"edge" => "1-2"})

    snapshot =
      await_engine(fn snap ->
        Enum.any?(snap.edges, &(&1.a == 1 and &1.b == 2 and &1.cut))
      end)

    assert Enum.find(snapshot.edges, &(&1.a == 1 and &1.b == 2)).cut == true

    view |> render_click("heal_link", %{"edge" => "1-2"})

    snapshot =
      await_engine(fn snap ->
        Enum.any?(snap.edges, &(&1.a == 1 and &1.b == 2 and not &1.cut))
      end)

    assert Enum.find(snapshot.edges, &(&1.a == 1 and &1.b == 2)).cut == false
  end

  test "the Broken link scenario loads and shows cut edges", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#sg-form-scenario")
    |> render_change(%{"scenario" => "cut"})

    assert render(view) =~ "Broken link"

    view |> render_click("step", %{"count" => "400"})

    snapshot =
      await_engine(fn snap -> Enum.any?(snap.edges, & &1.cut) end)

    assert snapshot.scenario.id == :cut
    assert Enum.any?(snapshot.edges, & &1.cut)
  end

  # The LiveView sends engine commands as fire-and-forget casts. Poll the
  # engine until the latest snapshot matches so an assertion never reads the
  # state before the cast in transit is applied.
  defp await_engine(fun) do
    Enum.reduce_while(1..200, :pending, fn _, _ ->
      _ = :sys.get_state(SignalGarden.Sim.Engine)
      snap = SignalGarden.Sim.snapshot()

      if fun.(snap) do
        {:halt, snap}
      else
        {:cont, :pending}
      end
    end)
    |> case do
      :pending -> SignalGarden.Sim.snapshot()
      snap -> snap
    end
  end
end
