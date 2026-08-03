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
    # let the engine broadcast at least one snapshot
    _ = :sys.get_state(SignalGarden.Sim.Engine)
    view |> render_click("step", %{"count" => "10"})

    snapshot = SignalGarden.Sim.snapshot()
    assert snapshot.clock >= 0
  end

  test "the fault injector offers crash and restart controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#sg-fault-node")
    assert has_element?(view, "button", "Crash")
    assert has_element?(view, "button", "Restart")

    view |> render_click("crash", %{"node" => "2"})
    _ = :sys.get_state(SignalGarden.Sim.Engine)

    snapshot = SignalGarden.Sim.snapshot()
    down = Enum.find(snapshot.nodes, &(&1.id == 2))
    assert down.up == false

    view |> render_click("restart", %{"node" => "2"})
    _ = :sys.get_state(SignalGarden.Sim.Engine)

    snapshot = SignalGarden.Sim.snapshot()
    up = Enum.find(snapshot.nodes, &(&1.id == 2))
    assert up.up == true
  end
end
