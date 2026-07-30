defmodule SignalGarden.Sim.Topology do
  @moduledoc """
  Build node graphs and node positions for the simulator.

  A topology is a plain struct with no behaviour. The engine reads the
  node identifiers, the edge list, the neighbour map, and the layout map.
  Layout coordinates are normalised to the unit square `0.0..1.0` so the
  LiveView can scale the graph to any viewport.
  """

  defstruct id: nil,
            label: "topology",
            nodes: [],
            edges: [],
            adjacency: %{},
            layout: %{}

  @type t :: %__MODULE__{
          id: atom(),
          label: String.t(),
          nodes: [pos_integer()],
          edges: [{pos_integer(), pos_integer()}],
          adjacency: %{pos_integer() => [pos_integer()]},
          layout: %{pos_integer() => {float(), float()}}
        }

  @doc "A straight line of `n` nodes linked to their immediate neighbours."
  def line(n) when is_integer(n) and n >= 2 do
    nodes = Enum.to_list(1..n)
    edges = Enum.chunk_every(nodes, 2, 1, :discard) |> Enum.map(fn [a, b] -> {a, b} end)
    layout = line_layout(nodes)
    build(:line, "line", nodes, edges, layout)
  end

  @doc "A closed ring of `n` nodes."
  def ring(n) when is_integer(n) and n >= 3 do
    nodes = Enum.to_list(1..n)
    edges = ring_edges(nodes)
    layout = ring_layout(nodes)
    build(:ring, "ring", nodes, edges, layout)
  end

  @doc "A square grid of `cols` columns and `rows` rows."
  def grid(rows, cols) when is_integer(rows) and is_integer(cols) and rows * cols >= 2 do
    nodes = Enum.to_list(1..(rows * cols))
    edges = grid_edges(rows, cols)
    layout = grid_layout(rows, cols)
    build(:grid, "grid #{rows}x#{cols}", nodes, edges, layout)
  end

  @doc "A fully connected graph of `n` nodes."
  def complete(n) when is_integer(n) and n >= 2 do
    nodes = Enum.to_list(1..n)
    edges = for a <- nodes, b <- nodes, a < b, do: {a, b}
    layout = ring_layout(nodes)
    build(:complete, "complete", nodes, edges, layout)
  end

  @doc """
  A random graph of `n` nodes with a target average degree.

  The edge set is deterministic for a given seed. The graph stays connected
  because a spanning path is added before the random links.
  """
  def random(n, degree, seed) when is_integer(n) and n >= 3 do
    nodes = Enum.to_list(1..n)
    path = Enum.chunk_every(nodes, 2, 1, :discard) |> Enum.map(fn [a, b] -> {a, b} end)
    target = max(n - 1, round(n * degree / 2))
    {rand_edges, _rng} = random_pairs(nodes, target - length(path), seed)
    edges = dedupe_edges(path ++ rand_edges)
    layout = forceless_layout(nodes, edges, seed)
    build(:random, "random #{n}/#{degree}", nodes, edges, layout)
  end

  # ---------------------------------------------------------------------------
  # construction helpers
  # ---------------------------------------------------------------------------

  defp build(id, label, nodes, edges, layout) do
    adjacency =
      Enum.reduce(edges, %{}, fn {a, b}, acc ->
        acc
        |> Map.update(a, [b], &[b | &1])
        |> Map.update(b, [a], &[a | &1])
      end)
      |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end)

    %__MODULE__{
      id: id,
      label: label,
      nodes: Enum.sort(nodes),
      edges: Enum.sort(edges),
      adjacency: adjacency,
      layout: layout
    }
  end

  defp dedupe_edges(edges) do
    edges
    |> Enum.map(fn {a, b} -> if a <= b, do: {a, b}, else: {b, a} end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ring_edges([_ | _] = nodes) do
    [head | _] = nodes
    pairs = Enum.chunk_every(nodes, 2, 1, :discard) |> Enum.map(fn [a, b] -> {a, b} end)
    closers = [{List.last(nodes), head}]
    pairs ++ closers
  end

  defp grid_edges(rows, cols) do
    for r <- 0..(rows - 1), c <- 0..(cols - 1), reduce: [] do
      acc ->
        id = r * cols + c + 1
        right = if c < cols - 1, do: [{id, id + 1}], else: []
        down = if r < rows - 1, do: [{id, id + cols}], else: []
        acc ++ right ++ down
    end
  end

  defp random_pairs(nodes, count, seed) do
    rng = :rand.seed_s(:exsss, {seed, seed, seed})

    Enum.reduce(1..max(count, 0)//1, {[], rng}, fn _, {acc, rng0} ->
      {a, rng1} = pick(nodes, rng0)
      {b, rng2} = pick(nodes, rng1)
      edge = if a <= b, do: {a, b}, else: {b, a}
      new_acc = if a != b, do: [edge | acc], else: acc
      {new_acc, rng2}
    end)
  end

  defp pick(list, rng) do
    {x, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, x - 1), rng}
  end

  # ---------------------------------------------------------------------------
  # layout helpers (unit square)
  # ---------------------------------------------------------------------------

  defp line_layout(nodes) do
    n = length(nodes)
    spacing = if n > 1, do: 1.0 / (n - 1), else: 0.0

    nodes
    |> Enum.with_index(0)
    |> Map.new(fn {id, i} -> {id, {spacing * i, 0.5}} end)
  end

  defp ring_layout(nodes) do
    n = length(nodes)

    nodes
    |> Enum.with_index(0)
    |> Map.new(fn {id, i} ->
      angle = 2 * :math.pi() * i / n
      {id, {0.5 + 0.42 * :math.cos(angle), 0.5 + 0.42 * :math.sin(angle)}}
    end)
  end

  defp grid_layout(rows, cols) do
    xstep = if cols > 1, do: 1.0 / (cols - 1), else: 0.0
    ystep = if rows > 1, do: 1.0 / (rows - 1), else: 0.0

    for r <- 0..(rows - 1), c <- 0..(cols - 1), into: %{} do
      id = r * cols + c + 1
      {id, {xstep * c, ystep * r}}
    end
  end

  defp forceless_layout(nodes, edges, seed) do
    rng = :rand.seed_s(:exsss, {seed + 7, seed + 11, seed + 13})

    initial =
      Enum.reduce(nodes, {%{}, rng}, fn id, {acc, rng0} ->
        {x, rng1} = :rand.uniform_s(rng0)
        {y, rng2} = :rand.uniform_s(rng1)
        {Map.put(acc, id, {x, y}), rng2}
      end)
      |> elem(0)

    relax(initial, edges, 120)
  end

  defp relax(layout, edges, iterations) do
    Enum.reduce(1..iterations//1, layout, fn _, acc ->
      step_relax(acc, edges)
    end)
  end

  defp step_relax(layout, edges) do
    attractive =
      Enum.reduce(edges, %{}, fn {a, b}, acc ->
        {ax, ay} = layout[a]
        {bx, by} = layout[b]
        dx = bx - ax
        dy = by - ay
        dist = max(:math.sqrt(dx * dx + dy * dy), 0.0001)
        # pull connected nodes toward a target length
        target = 0.18
        force = (dist - target) / dist * 0.05
        fx = dx * force / 2
        fy = dy * force / 2

        acc
        |> Map.update(a, {fx, fy}, fn {x, y} -> {x + fx, y + fy} end)
        |> Map.update(b, {-fx, -fy}, fn {x, y} -> {x - fx, y - fy} end)
      end)

    nodes = Map.keys(layout)

    repulsive =
      Enum.reduce(nodes, %{}, fn id, acc ->
        Enum.reduce(nodes, acc, fn other, acc2 ->
          if id >= other do
            acc2
          else
            {ax, ay} = layout[id]
            {bx, by} = layout[other]
            dx = bx - ax
            dy = by - ay
            dist2 = max(dx * dx + dy * dy, 0.0025)
            rep = 0.004 / dist2
            fx = dx * rep
            fy = dy * rep

            acc2
            |> Map.update(id, {fx, fy}, fn {x, y} -> {x + fx, y + fy} end)
            |> Map.update(other, {-fx, -fy}, fn {x, y} -> {x - fx, y - fy} end)
          end
        end)
      end)

    deltas =
      Enum.reduce(nodes, %{}, fn id, acc ->
        {ax, ay} = attractive[id] || {0.0, 0.0}
        {rx, ry} = repulsive[id] || {0.0, 0.0}
        Map.put(acc, id, {ax + rx, ay + ry})
      end)

    Enum.reduce(layout, %{}, fn {id, {x, y}}, acc ->
      {dx, dy} = deltas[id]
      nx = clamp01(x + dx)
      ny = clamp01(y + dy)
      Map.put(acc, id, {nx, ny})
    end)
  end

  defp clamp01(v), do: max(0.04, min(0.96, v))
end
