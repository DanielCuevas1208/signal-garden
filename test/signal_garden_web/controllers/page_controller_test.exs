defmodule SignalGardenWeb.PageControllerTest do
  use SignalGardenWeb.ConnCase

  test "GET / renders the garden LiveView root", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Signal Garden"
  end
end
