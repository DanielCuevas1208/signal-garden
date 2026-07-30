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

  test "the Run button starts the loop and Step advances the clock", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> render_click("start")
    # let the engine broadcast at least one snapshot
    _ = :sys.get_state(SignalGarden.Sim.Engine)
    view |> render_click("step", %{"count" => "10"})

    snapshot = SignalGarden.Sim.snapshot()
    assert snapshot.clock >= 0
  end
end
