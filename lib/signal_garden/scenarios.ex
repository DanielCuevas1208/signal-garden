defmodule SignalGarden.Scenarios do
  @moduledoc """
  Built-in deterministic scenarios for Signal Garden.

  Each function builds a `%SignalGarden.Sim.Scenario{}` struct. The catalog
  feeds the LiveView scenario picker. Add a new scenario here and it shows up
  in the interface with no other wiring.
  """

  alias SignalGarden.Sim.Scenario
  alias SignalGarden.Sim.Topology

  @doc "Return all built-in scenarios ordered by intended difficulty."
  def catalog do
    [
      line(),
      ring(),
      grid(),
      random(),
      split(),
      churn(),
      lossy(),
      crash(),
      counter()
    ]
  end

  @doc "Fetch a scenario by its id atom."
  def fetch(id) when is_atom(id) do
    Enum.find(catalog(), fn scenario -> scenario.id == id end)
  end

  def line do
    topology = Topology.line(8)

    %Scenario{
      id: :line,
      name: "Line",
      description: "Eight nodes in a straight chain. Convergence is slow.",
      seed: 1,
      topology: topology,
      origin: 1,
      latest_value: 100,
      delay_ms: {25, 55},
      drop_prob: 0.0,
      gossip_interval_ms: 90
    }
  end

  def ring do
    topology = Topology.ring(12)

    %Scenario{
      id: :ring,
      name: "Ring",
      description: "Twelve nodes in a closed ring. Gossip spreads both ways.",
      seed: 2,
      topology: topology,
      origin: 6,
      latest_value: 77,
      delay_ms: {20, 50},
      drop_prob: 0.0,
      gossip_interval_ms: 80
    }
  end

  def grid do
    topology = Topology.grid(5, 6)

    %Scenario{
      id: :grid,
      name: "Grid",
      description: "A five by six lattice. Rumor fans out in two dimensions.",
      seed: 3,
      topology: topology,
      origin: 13,
      latest_value: 51,
      delay_ms: {25, 60},
      drop_prob: 0.0,
      gossip_interval_ms: 70
    }
  end

  def random do
    topology = Topology.random(16, 3, 42)

    %Scenario{
      id: :random,
      name: "Random graph",
      description: "Sixteen nodes connected by a sparse random graph.",
      seed: 42,
      topology: topology,
      origin: 1,
      latest_value: 64,
      delay_ms: {30, 65},
      drop_prob: 0.0,
      gossip_interval_ms: 75
    }
  end

  @doc "A random graph where a pair of nodes crash and restart mid-run."
  def crash do
    topology = Topology.random(12, 3, 11)

    %Scenario{
      id: :crash,
      name: "Crash and recover",
      description: "Two nodes crash at T=500, then restart at T=1500.",
      seed: 11,
      topology: topology,
      origin: 1,
      latest_value: 44,
      delay_ms: {25, 55},
      drop_prob: 0.0,
      gossip_interval_ms: 75,
      fault_schedule: [
        %{at: 500, action: {:crash, 4}, label: "Node 4 crashes"},
        %{at: 700, action: {:crash, 9}, label: "Node 9 crashes"},
        %{at: 1500, action: {:restart, 4}, label: "Node 4 restarts"},
        %{at: 1700, action: {:restart, 9}, label: "Node 9 restarts"}
      ]
    }
  end

  @doc "A random graph with a network split that heals after a delay."
  def split do
    topology = Topology.random(14, 3, 7)

    %Scenario{
      id: :split,
      name: "Healing partition",
      description: "A split forms at T=400, then heals at T=2600.",
      seed: 7,
      topology: topology,
      origin: 1,
      latest_value: 90,
      delay_ms: {30, 60},
      drop_prob: 0.0,
      gossip_interval_ms: 80,
      fault_schedule: [
        %{at: 400, action: {:assign, 9, 1}, label: "Node 9 joins group B"},
        %{at: 460, action: {:assign, 10, 1}, label: "Node 10 joins group B"},
        %{at: 520, action: {:assign, 12, 1}, label: "Node 12 joins group B"},
        %{at: 580, action: {:assign, 14, 1}, label: "Node 14 joins group B"},
        %{at: 2600, action: {:merge, :all}, label: "Network heals"}
      ]
    }
  end

  @doc "A random graph where the drop probability is non-zero but fair."
  def lossy do
    topology = Topology.random(14, 4, 19)

    %Scenario{
      id: :lossy,
      name: "Lossy link",
      description: "Five percent of gossip messages are lost in flight.",
      seed: 19,
      topology: topology,
      origin: 7,
      latest_value: 33,
      delay_ms: {25, 55},
      drop_prob: 0.05,
      gossip_interval_ms: 70
    }
  end

  @doc "A random graph that partitions and restores on a schedule."
  def churn do
    topology = Topology.random(15, 3, 99)

    %Scenario{
      id: :churn,
      name: "Churn",
      description: "Partitions toggle on a fixed schedule.",
      seed: 99,
      topology: topology,
      origin: 1,
      latest_value: 12,
      delay_ms: {25, 55},
      drop_prob: 0.0,
      gossip_interval_ms: 75,
      fault_schedule: [
        %{at: 500, action: {:assign, 10, 1}, label: "Group split starts"},
        %{at: 560, action: {:assign, 11, 1}, label: "Group split grows"},
        %{at: 560, action: {:assign, 12, 1}, label: "Group split grows"},
        %{at: 560, action: {:assign, 13, 1}, label: "Group split grows"},
        %{at: 560, action: {:assign, 14, 1}, label: "Group split grows"},
        %{at: 560, action: {:assign, 15, 1}, label: "Group split grows"},
        %{at: 1900, action: {:merge, :all}, label: "Heal"},
        %{at: 2400, action: {:assign, 4, 1}, label: "Quick split"},
        %{at: 2450, action: {:assign, 5, 1}, label: "Quick split"},
        %{at: 3200, action: {:merge, :all}, label: "Heal"}
      ]
    }
  end

  @doc """
  A random graph that replicates a grow-only counter.

  Five writes climb the counter on a schedule. Each node keeps one cell per
  node id and merges with element-wise max, so the total converges even while
  the network keeps losing and reordering messages.
  """
  def counter do
    topology = Topology.random(12, 3, 21)

    %Scenario{
      id: :counter,
      name: "Grow-only counter",
      description: "Twelve nodes replicate a G-Counter. Writes climb on a schedule.",
      seed: 21,
      topology: topology,
      origin: 1,
      latest_value: 0,
      delay_ms: {25, 55},
      drop_prob: 0.05,
      gossip_interval_ms: 70,
      mode: :counter,
      fault_schedule: [
        %{at: 400, action: {:increment, 1, 1}, label: "Node 1 writes +1"},
        %{at: 900, action: {:increment, 6, 2}, label: "Node 6 writes +2"},
        %{at: 1500, action: {:increment, 9, 1}, label: "Node 9 writes +1"},
        %{at: 2200, action: {:increment, 4, 3}, label: "Node 4 writes +3"},
        %{at: 2800, action: {:increment, 1, 2}, label: "Node 1 writes +2"}
      ]
    }
  end
end
