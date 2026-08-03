defmodule SignalGarden.Sim.TopologyTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Sim.Topology

  test "a line links neighbours and places nodes on a row" do
    topo = Topology.line(4)
    assert topo.nodes == [1, 2, 3, 4]
    assert topo.edges == [{1, 2}, {2, 3}, {3, 4}]
    assert topo.adjacency == %{1 => [2], 2 => [1, 3], 3 => [2, 4], 4 => [3]}

    {x1, y1} = topo.layout[1]
    {x4, y4} = topo.layout[4]
    assert x1 < x4
    assert y1 == y4
  end

  test "a ring closes the loop on both ends" do
    topo = Topology.ring(4)
    assert {4, 1} in topo.edges
    assert length(topo.edges) == 4
    assert Enum.all?(1..4, &Map.has_key?(topo.layout, &1))
  end

  test "a grid keeps rows and columns connected" do
    topo = Topology.grid(2, 3)
    assert topo.nodes == [1, 2, 3, 4, 5, 6]
    assert {1, 2} in topo.edges
    assert {1, 4} in topo.edges
    assert {3, 6} in topo.edges
  end

  test "a complete graph has every pair linked" do
    topo = Topology.complete(4)
    assert length(topo.edges) == 6
    assert {1, 4} in topo.edges
  end

  test "a random graph is deterministic for a fixed seed" do
    a = Topology.random(10, 3, 5)
    b = Topology.random(10, 3, 5)
    assert a.edges == b.edges
    assert a.layout == b.layout
  end

  test "every node has a layout coordinate in the unit square" do
    topo = Topology.random(8, 2, 1)

    for {_id, {x, y}} <- topo.layout do
      assert x >= 0.0 and x <= 1.0
      assert y >= 0.0 and y <= 1.0
    end
  end

  test "from_export rebuilds a topology from JSON data" do
    source = Topology.ring(5)

    data = %{
      "id" => "ring",
      "label" => "ring",
      "nodes" => source.nodes,
      "edges" => Enum.map(source.edges, fn {a, b} -> [a, b] end),
      "layout" => Map.new(source.layout, fn {k, {x, y}} -> {Integer.to_string(k), [x, y]} end)
    }

    assert {:ok, topo} = Topology.from_export(data)
    assert topo.nodes == source.nodes
    assert topo.edges == source.edges
  end
end
