defmodule SignalGardenWeb.PageController do
  use SignalGardenWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
