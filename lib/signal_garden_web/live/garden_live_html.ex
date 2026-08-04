defmodule SignalGardenWeb.GardenLiveHTML do
  @moduledoc """
  The HTML for the Signal Garden control room.

  The helpers in this module are pure formatting. They turn snapshot maps
  into colors, path strings, and label text so the HEEx template stays
  declarative.
  """

  use SignalGardenWeb, :html

  embed_templates "garden_live_html/*"

  @canvas_width 720
  @canvas_height 540
  @pad 48
  @recent_window 160

  def status_label(:running), do: "Running"
  def status_label(:paused), do: "Paused"
  def status_label(:converged), do: "Converged"
  def status_label(:exhausted), do: "Stalled"
  def status_label(:idle), do: "Ready"
  def status_label(_), do: "Idle"

  def status_tone(:running), do: "sg-tone-running"
  def status_tone(:converged), do: "sg-tone-converged"
  def status_tone(:exhausted), do: "sg-tone-stalled"
  def status_tone(:paused), do: "sg-tone-paused"
  def status_tone(:idle), do: "sg-tone-ready"
  def status_tone(_), do: "sg-tone-ready"

  def format_time(nil), do: "--"

  def format_time(t) do
    if t < 1000, do: "#{t} ms", else: "#{Float.round(t / 1000, 2)} s"
  end

  # map unit-square coords to canvas coords
  def project({x, y}) do
    px = @pad + x * (@canvas_width - @pad * 2)
    py = @pad + y * (@canvas_height - @pad * 2)
    {px, py}
  end

  def canvas_size, do: {@canvas_width, @canvas_height}

  def node_radius, do: 15

  def node_palette(%{up: false}), do: %{fill: "#3f1217", ring: "#fb7185"}
  def node_palette(%{informed: true, is_origin: true}), do: %{fill: "#fbbf24", ring: "#f59e0b"}
  def node_palette(%{informed: true}), do: %{fill: "#34d399", ring: "#10b981"}
  def node_palette(%{is_origin: true}), do: %{fill: "#1e293b", ring: "#f59e0b"}
  def node_palette(_), do: %{fill: "#1e293b", ring: "#475569"}

  def node_class_dash(%{up: false}), do: "6 6"
  def node_class_dash(%{partition: partition}) when partition != 0, do: "4 4"
  def node_class_dash(_), do: ""

  def edge_stroke(edge, clock) do
    recent = recent?(clock, edge.last_time)
    kind = edge.last_kind
    partitioned = edge.partitioned

    cond do
      edge.cut -> "#fb7185"
      partitioned and recent and kind == :deliver -> "#fca5a5"
      partitioned -> "#b45309"
      recent and kind == :deliver -> "#22d3ee"
      recent and kind in [:dropped_loss, :dropped_partition, :dropped_cut] -> "#fb7185"
      true -> "#334155"
    end
  end

  def edge_class(edge, clock) do
    recent = recent?(clock, edge.last_time)

    cond do
      edge.cut -> "sg-edge-cut"
      recent and edge.last_kind == :deliver -> "sg-edge-flow"
      edge.partitioned -> "sg-edge-partitioned"
      true -> ""
    end
  end

  def edge_width(edge, clock) do
    cond do
      edge.cut -> 1.8
      recent?(clock, edge.last_time) -> 2.6
      true -> 1.4
    end
  end

  def recent?(clock, time) when is_integer(clock) and is_integer(time) do
    diff = clock - time
    diff <= @recent_window and diff >= 0
  end

  def recent?(_clock, _time), do: false

  def chart_path(history, w, h) do
    points = chart_points(history, w, h)

    points
    |> Enum.with_index()
    |> Enum.map(fn {{x, y}, i} -> "#{if(i == 0, do: "M", else: "L")} #{x} #{y}" end)
    |> Enum.join(" ")
  end

  def chart_area_path(history, w, h) do
    points = chart_points(history, w, h)

    case points do
      [] ->
        ""

      [{fx, _} | _] = pts ->
        {lx, _} = List.last(pts)

        outline =
          Enum.map(Enum.with_index(pts), fn {{x, y}, i} ->
            "#{if(i == 0, do: "M", else: "L")} #{x} #{y}"
          end)

        (outline ++ ["L #{lx} #{h}", "L #{fx} #{h}", "Z"]) |> Enum.join(" ")
    end
  end

  defp chart_points(history, w, h) do
    n = length(history)

    Enum.with_index(history)
    |> Enum.map(fn {p, i} ->
      x = if(n <= 1, do: 0, else: round(i * w / (n - 1)))
      ratio = if(p.total == 0, do: 0.0, else: p.informed / p.total)
      {x, h - round(ratio * h)}
    end)
  end

  def log_tone(kind) do
    case kind do
      :deliver -> "text-cyan-300"
      :dropped_partition -> "text-amber-300"
      :dropped_loss -> "text-rose-300"
      :dropped_cut -> "text-rose-300"
      :crashed -> "text-rose-400"
      :restarted -> "text-emerald-300"
      :increment -> "text-violet-300"
      :added -> "text-fuchsia-300"
      _ -> "text-slate-300"
    end
  end

  def log_label(:deliver), do: "delivered"
  def log_label(:dropped_partition), do: "dropped (partition)"
  def log_label(:dropped_loss), do: "dropped (loss)"
  def log_label(:dropped_cut), do: "dropped (cut link)"
  def log_label(:crashed), do: "crashed"
  def log_label(:restarted), do: "restarted"
  def log_label(:increment), do: "wrote"
  def log_label(:added), do: "added"
  def log_label(_), do: "event"

  def reached_percent(snapshot) do
    if snapshot.total == 0, do: 0, else: round(snapshot.reached * 100 / snapshot.total)
  end

  # ---------------------------------------------------------------------------
  # graph panel
  # ---------------------------------------------------------------------------

  attr :snapshot, :map, required: true
  attr :canvas, :any, required: true

  def graph_panel(assigns) do
    ~H"""
    <div class="sg-graph">
      <div class="sg-graph__bar">
        <div class="sg-legend">
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--signal"></i>informed</span>
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--pending"></i>pending</span>
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--origin"></i>origin</span>
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--split"></i>partitioned</span>
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--cut"></i>cut link</span>
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--down"></i>crashed</span>
        </div>
        <p class="sg-graph__readout">
          <%= case @snapshot.mode do %>
            <% :counter -> %>
              {@snapshot.reached}/{@snapshot.total} nodes at total {@snapshot.counter_total}
              <span class="sg-graph__percent">{reached_percent(@snapshot)}%</span>
            <% :set -> %>
              {@snapshot.reached}/{@snapshot.total} nodes hold the full set
              <span class="sg-graph__percent">{reached_percent(@snapshot)}%</span>
            <% _ -> %>
              {@snapshot.reached}/{@snapshot.total} nodes know the latest value
              <span class="sg-graph__percent">{reached_percent(@snapshot)}%</span>
          <% end %>
        </p>
      </div>

      <div class="sg-graph__stage" id="sg-stage">
        <%= case @snapshot do %>
          <% %{nodes: []} -> %>
            <p class="sg-graph__empty">No nodes loaded. Pick a scenario to start.</p>
          <% sg -> %>
            <svg
              viewBox={"0 0 #{canvas_width()} #{canvas_height()}"}
              class="sg-svg"
              role="img"
              aria-label="Network graph"
            >
              <defs>
                <radialGradient id="sg-edge-glow" cx="50%" cy="50%" r="50%">
                  <stop offset="0%" stop-color="#22d3ee" stop-opacity="0.9" />
                  <stop offset="100%" stop-color="#22d3ee" stop-opacity="0" />
                </radialGradient>
                <linearGradient id="sg-grad-converge" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stop-color="#22d3ee" stop-opacity="0.35" />
                  <stop offset="100%" stop-color="#22d3ee" stop-opacity="0.02" />
                </linearGradient>
              </defs>

              <g class="sg-edges">
                <g
                  :for={edge <- @snapshot.edges}
                  class="sg-edge-wrap"
                  phx-click="toggle_link_cut"
                  phx-value-a={edge.a}
                  phx-value-b={edge.b}
                  role="button"
                  tabindex="0"
                  aria-label={"Toggle link #{edge.a} - #{edge.b}"}
                >
                  <line
                    class="sg-edge__hit"
                    x1={px(edge.a, sg, :x)}
                    y1={px(edge.a, sg, :y)}
                    x2={px(edge.b, sg, :x)}
                    y2={px(edge.b, sg, :y)}
                  />
                  <line
                    x1={px(edge.a, sg, :x)}
                    y1={px(edge.a, sg, :y)}
                    x2={px(edge.b, sg, :x)}
                    y2={px(edge.b, sg, :y)}
                    class={"sg-edge #{edge_class(edge, sg.clock)}"}
                    stroke={edge_stroke(edge, sg.clock)}
                    stroke-width={edge_width(edge, sg.clock)}
                  />
                  <%= if edge.cut do %>
                    <g
                      class="sg-edge__cutmark"
                      transform={"translate(#{mx(edge, sg)} #{my(edge, sg)})"}
                    >
                      <circle r="7" class="sg-edge__cutdisc" />
                      <line x1="-3.5" y1="-3.5" x2="3.5" y2="3.5" class="sg-edge__cutcross" />
                      <line x1="3.5" y1="-3.5" x2="-3.5" y2="3.5" class="sg-edge__cutcross" />
                    </g>
                  <% end %>
                </g>
              </g>

              <g class="sg-nodes">
                <g
                  :for={node <- @snapshot.nodes}
                  class="sg-node"
                  phx-click="toggle_partition"
                  phx-value-node={node.id}
                  role="button"
                  tabindex="0"
                >
                  <circle
                    cx={px(node.id, sg, :x)}
                    cy={px(node.id, sg, :y)}
                    r={node_radius()}
                    class="sg-node__halo"
                  />
                  <circle
                    cx={px(node.id, sg, :x)}
                    cy={px(node.id, sg, :y)}
                    r={node_radius()}
                    class="sg-node__body"
                    fill={node_palette(node).fill}
                    stroke={node_palette(node).ring}
                    stroke-width={if(node.partition != 0, do: 2.5, else: 1.6)}
                    stroke-dasharray={node_class_dash(node)}
                  />
                  <%= if node.is_origin do %>
                    <circle
                      cx={px(node.id, sg, :x)}
                      cy={px(node.id, sg, :y)}
                      r={node_radius() + 6}
                      class="sg-node__origin"
                    />
                  <% end %>
                  <%= if not node.up do %>
                    <line
                      x1={px(node.id, sg, :x) - 5}
                      y1={px(node.id, sg, :y) - 5}
                      x2={px(node.id, sg, :x) + 5}
                      y2={px(node.id, sg, :y) + 5}
                      class="sg-node__down"
                    />
                    <line
                      x1={px(node.id, sg, :x) + 5}
                      y1={px(node.id, sg, :y) - 5}
                      x2={px(node.id, sg, :x) - 5}
                      y2={px(node.id, sg, :y) + 5}
                      class="sg-node__down"
                    />
                  <% end %>
                  <text
                    x={px(node.id, sg, :x)}
                    y={py_label(node.id, sg)}
                    class="sg-node__label"
                  >
                    {node.id}
                  </text>
                  <%= if sg.mode in [:counter, :set] do %>
                    <text
                      x={px(node.id, sg, :x)}
                      y={py_value(node.id, sg)}
                      class="sg-node__value"
                    >
                      {node.value}
                    </text>
                  <% end %>
                </g>
              </g>
            </svg>
        <% end %>
      </div>

      <.timeline snapshot={@snapshot} />
    </div>
    """
  end

  defp canvas_width, do: @canvas_width
  defp canvas_height, do: @canvas_height

  defp px(id, sg, :x), do: project(sg_layout(sg, id)) |> elem(0)
  defp px(id, sg, :y), do: project(sg_layout(sg, id)) |> elem(1)

  defp mx(edge, sg), do: (px(edge.a, sg, :x) + px(edge.b, sg, :x)) / 2
  defp my(edge, sg), do: (px(edge.a, sg, :y) + px(edge.b, sg, :y)) / 2

  defp py_label(id, sg) do
    project(sg_layout(sg, id)) |> elem(1) |> Kernel.+(node_radius() + 14)
  end

  defp py_value(id, sg) do
    project(sg_layout(sg, id)) |> elem(1) |> Kernel.-(node_radius() + 10)
  end

  defp sg_layout(snapshot, id) do
    Enum.find_value(snapshot.nodes, fn n -> if n.id == id, do: {n.x, n.y} end)
  end

  # ---------------------------------------------------------------------------
  # timeline
  # ---------------------------------------------------------------------------

  attr :snapshot, :map, required: true

  def timeline(assigns) do
    ~H"""
    <div class="sg-timeline">
      <header class="sg-timeline__head">
        <h2>Convergence</h2>
        <span class="sg-timeline__time">
          reached {reached_percent(@snapshot)}% in {format_time(
            @snapshot.convergence_time || @snapshot.clock
          )}
        </span>
      </header>

      <svg viewBox="0 0 220 64" class="sg-timeline__svg" aria-hidden="true">
        <path d={chart_area_path(@snapshot.history, 220, 64)} fill="url(#sg-grad-converge)" />
        <path d={chart_path(@snapshot.history, 220, 64)} class="sg-timeline__line" fill="none" />
        <line x1="0" y1="64" x2="220" y2="64" class="sg-timeline__baseline" />
      </svg>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # side panel
  # ---------------------------------------------------------------------------

  attr :snapshot, :map, required: true
  attr :scenarios, :list, required: true
  attr :selected, :atom, required: true
  attr :delay_value, :any, required: true
  attr :drop_value, :any, required: true
  attr :speed, :any, required: true
  attr :fault_node, :any, required: true
  attr :fault_element, :string, required: true
  attr :link_edges, :list, required: true
  attr :link_edge, :string, required: true
  attr :show_import, :boolean, required: true
  attr :import_json, :string, required: true

  def side_panel(assigns) do
    ~H"""
    <aside class="sg-side">
      <.controls
        snapshot={@snapshot}
        scenarios={@scenarios}
        selected={@selected}
        delay_value={@delay_value}
        drop_value={@drop_value}
        speed={@speed}
        fault_node={@fault_node}
        fault_element={@fault_element}
        link_edges={@link_edges}
        link_edge={@link_edge}
        show_import={@show_import}
        import_json={@import_json}
      />
      <.stats snapshot={@snapshot} />
      <.event_log snapshot={@snapshot} />
    </aside>
    """
  end

  attr :snapshot, :map, required: true
  attr :scenarios, :list, required: true
  attr :selected, :atom, required: true
  attr :delay_value, :any, required: true
  attr :drop_value, :any, required: true
  attr :speed, :any, required: true
  attr :fault_node, :any, required: true
  attr :fault_element, :string, required: true
  attr :link_edges, :list, required: true
  attr :link_edge, :string, required: true
  attr :show_import, :boolean, required: true
  attr :import_json, :string, required: true

  def controls(assigns) do
    ~H"""
    <section class="sg-card sg-controls">
      <h2 class="sg-card__title">Run</h2>

      <div class="sg-controls__row">
        <%= cond do %>
          <% @snapshot.status == :running -> %>
            <button class="sg-btn sg-btn--solid" phx-click="pause">Pause</button>
            <button class="sg-btn" phx-click="step" phx-value-count="1" disabled>
              Step
            </button>
          <% @snapshot.status == :converged -> %>
            <button class="sg-btn" phx-click="reset">Reset</button>
            <button class="sg-btn" phx-click="step" phx-value-count="50" disabled>
              Step
            </button>
          <% @snapshot.status == :exhausted -> %>
            <button class="sg-btn" phx-click="reset">Reset</button>
            <button class="sg-btn" phx-click="merge">Heal net</button>
          <% true -> %>
            <button class="sg-btn sg-btn--solid" phx-click="start">Run</button>
            <button class="sg-btn" phx-click="step" phx-value-count="50">Step</button>
        <% end %>
        <button class="sg-btn sg-btn--ghost" phx-click="reset">Reset</button>
      </div>

      <.form for={nil} id="sg-form-scenario" phx-change="select_scenario" class="sg-form">
        <label class="sg-form__label" for="sg-scenario">Scenario</label>
        <%= if @selected == :imported do %>
          <p class="sg-form__note">
            Loaded file: <strong>{@snapshot.scenario.name}</strong>
          </p>
        <% end %>
        <select name="scenario" id="sg-scenario" class="sg-select">
          <%= for option <- @scenarios do %>
            <option value={option.id} selected={option.id == @selected}>
              {option.name}
            </option>
          <% end %>
        </select>
      </.form>

      <.form for={nil} id="sg-form-delay" phx-change="set_delay" class="sg-form">
        <div class="sg-form__line">
          <label class="sg-form__label" for="sg-delay">Delay</label>
          <span class="sg-form__value">{@delay_value} ms</span>
        </div>
        <input
          type="range"
          id="sg-delay"
          name="delay"
          min="0"
          max="240"
          step="1"
          value={@delay_value}
          class="sg-range"
        />
      </.form>

      <.form for={nil} id="sg-form-drop" phx-change="set_drop" class="sg-form">
        <div class="sg-form__line">
          <label class="sg-form__label" for="sg-drop">Loss</label>
          <span class="sg-form__value">{@drop_value}%</span>
        </div>
        <input
          type="range"
          id="sg-drop"
          name="drop"
          min="0"
          max="80"
          step="1"
          value={@drop_value}
          class="sg-range"
        />
      </.form>

      <.form for={nil} id="sg-form-speed" phx-change="set_speed" class="sg-form">
        <div class="sg-form__line">
          <label class="sg-form__label" for="sg-speed">Speed</label>
          <span class="sg-form__value">events / frame</span>
        </div>
        <input
          type="range"
          id="sg-speed"
          name="burst"
          min="1"
          max="40"
          step="1"
          value={@speed}
          class="sg-range"
        />
      </.form>

      <div class="sg-faults">
        <div class="sg-faults__head">Node fault</div>
        <.form for={nil} id="sg-form-fault" phx-change="select_fault_node" class="sg-faults__form">
          <div class="sg-faults__row">
            <select id="sg-fault-node" name="node" class="sg-faults__select">
              <%= for node <- @snapshot.nodes do %>
                <option value={node.id} selected={node.id == @fault_node}>
                  {node.id} {if node.up, do: "(up)", else: "(down)"}
                </option>
              <% end %>
            </select>
            <button
              class="sg-btn sg-btn--fault"
              type="button"
              phx-click="crash"
              phx-value-node={@fault_node}
            >
              Crash
            </button>
            <button
              class="sg-btn sg-btn--heal"
              type="button"
              phx-click="restart"
              phx-value-node={@fault_node}
            >
              Restart
            </button>
            <%= if @snapshot.mode == :counter do %>
              <button
                class="sg-btn sg-btn--write"
                type="button"
                phx-click="increment"
                phx-value-node={@fault_node}
              >
                +1
              </button>
            <% end %>
          </div>
        </.form>

        <%= if @snapshot.mode == :set do %>
          <.form for={nil} id="sg-form-add" phx-submit="add_element" class="sg-faults__form">
            <div class="sg-faults__row">
              <input
                id="sg-add-element"
                name="element"
                type="text"
                value={@fault_element}
                class="sg-faults__input"
                placeholder="member name"
                aria-label="Element to add to the set"
              />
              <button class="sg-btn sg-btn--write" type="submit">Add</button>
            </div>
          </.form>
        <% end %>

        <p class="sg-faults__note">
          <%= case @snapshot.mode do %>
            <% :counter -> %>
              Pick a node, then write to its counter cell or crash and restart it.
            <% :set -> %>
              Pick a node, then add a member to its set or crash and restart it.
            <% _ -> %>
              Pick a node, then crash or restart it while the run is active.
          <% end %>
        </p>
      </div>

      <div class="sg-faults">
        <div class="sg-faults__head">Link cut</div>
        <.form for={nil} id="sg-form-link" phx-change="select_link_edge" class="sg-faults__form">
          <div class="sg-faults__row">
            <select id="sg-link-edge" name="edge" class="sg-faults__select">
              <%= for edge <- @link_edges do %>
                <option value={edge.value} selected={edge.value == @link_edge}>
                  {edge.label}
                </option>
              <% end %>
            </select>
            <button
              class="sg-btn sg-btn--fault"
              type="button"
              phx-click="cut_link"
              phx-value-edge={@link_edge}
            >
              Cut
            </button>
            <button
              class="sg-btn sg-btn--heal"
              type="button"
              phx-click="heal_link"
              phx-value-edge={@link_edge}
            >
              Heal
            </button>
          </div>
        </.form>
        <p class="sg-faults__note">
          Pick an edge, then cut or heal it. Click any edge on the graph to toggle its cut.
        </p>
      </div>

      <div class="sg-controls__hint">
        Click a node to toggle its partition group. Click
        <button class="sg-link" phx-click="merge" type="button">heal</button>
        to merge all groups and repair every cut link.
      </div>

      <div class="sg-share">
        <div class="sg-share__row">
          <button class="sg-btn sg-btn--ghost" type="button" phx-click="export_scenario">
            Export JSON
          </button>
          <button class="sg-btn sg-btn--ghost" type="button" phx-click="toggle_import">
            {if @show_import, do: "Hide import", else: "Import JSON"}
          </button>
        </div>

        <%= if @show_import do %>
          <.form for={nil} id="sg-form-import" phx-submit="import_scenario" class="sg-form sg-import">
            <label class="sg-form__label" for="sg-import-json">Scenario JSON</label>
            <textarea
              id="sg-import-json"
              name="json"
              class="sg-textarea"
              rows="8"
              placeholder="Paste a scenario file or open priv/scenarios/ring.json"
            >{@import_json}</textarea>
            <button class="sg-btn sg-btn--solid sg-import__submit" type="submit">Load file</button>
          </.form>
        <% end %>
      </div>
    </section>
    """
  end

  attr :snapshot, :map, required: true

  def stats(assigns) do
    ~H"""
    <section class="sg-card sg-stats">
      <h2 class="sg-card__title">Telemetry</h2>
      <dl class="sg-stats__grid">
        <div>
          <dt>Status</dt><dd>{status_label(@snapshot.status)}</dd>
        </div>
        <div>
          <dt>Clock</dt><dd>{format_time(@snapshot.clock)}</dd>
        </div>
        <div>
          <dt>Hops</dt><dd>{@snapshot.hops}</dd>
        </div>
        <div>
          <dt>Delivered</dt><dd>{@snapshot.delivered}</dd>
        </div>
        <div>
          <dt>Dropped</dt><dd>{@snapshot.dropped}</dd>
        </div>
        <%= if @snapshot.mode == :counter do %>
          <div>
            <dt>Writes</dt><dd>{@snapshot.counter_writes}</dd>
          </div>
          <div>
            <dt>Counter total</dt><dd>{@snapshot.counter_total}</dd>
          </div>
        <% end %>
        <%= if @snapshot.mode == :set do %>
          <div>
            <dt>Adds</dt><dd>{@snapshot.set_adds}</dd>
          </div>
          <div>
            <dt>Elements</dt><dd>{@snapshot.set_size}</dd>
          </div>
        <% end %>
        <div>
          <dt>Converged in</dt><dd>{format_time(@snapshot.convergence_time)}</dd>
        </div>
      </dl>

      <%= if @snapshot.mode == :set and @snapshot.set_elements != [] do %>
        <div class="sg-set">
          <h3 class="sg-card__title">Set contents</h3>
          <ul class="sg-set__list">
            <li :for={element <- @snapshot.set_elements} class="sg-set__chip">
              {element}
            </li>
          </ul>
        </div>
      <% end %>
    </section>
    """
  end

  attr :snapshot, :map, required: true

  def event_log(assigns) do
    ~H"""
    <section class="sg-card sg-log">
      <h2 class="sg-card__title">Event feed</h2>
      <%= cond do %>
        <% @snapshot.event_log == [] -> %>
          <p class="sg-log__empty">Press Run to watch messages flow.</p>
        <% true -> %>
          <ul class="sg-log__list">
            <%= for entry <- Enum.take(@snapshot.event_log, 12) do %>
              <li class="sg-log__row">
                <span class="sg-log__time">T={entry.t}</span>
                <span class={"sg-log__kind #{log_tone(entry.kind)}"}>
                  <%= cond do %>
                    <% entry.kind == :increment -> %>
                      node {entry.from} wrote +{entry.amount}
                    <% entry.kind == :added -> %>
                      node {entry.from} added "{entry.element}"
                    <% entry.to -> %>
                      {entry.from} -> {entry.to} {log_label(entry.kind)}
                    <% true -> %>
                      node {entry.from} {log_label(entry.kind)}
                  <% end %>
                </span>
              </li>
            <% end %>
          </ul>
      <% end %>
    </section>
    """
  end
end
