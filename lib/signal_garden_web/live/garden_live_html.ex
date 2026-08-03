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
      partitioned and recent and kind == :deliver -> "#fca5a5"
      partitioned -> "#b45309"
      recent and kind == :deliver -> "#22d3ee"
      recent and kind in [:dropped_loss, :dropped_partition] -> "#fb7185"
      true -> "#334155"
    end
  end

  def edge_class(edge, clock) do
    recent = recent?(clock, edge.last_time)

    cond do
      recent and edge.last_kind == :deliver -> "sg-edge-flow"
      edge.partitioned -> "sg-edge-partitioned"
      true -> ""
    end
  end

  def edge_width(edge, clock) do
    if recent?(clock, edge.last_time), do: 2.6, else: 1.4
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
      :crashed -> "text-rose-400"
      :restarted -> "text-emerald-300"
      :increment -> "text-violet-300"
      _ -> "text-slate-300"
    end
  end

  def log_label(:deliver), do: "delivered"
  def log_label(:dropped_partition), do: "dropped (partition)"
  def log_label(:dropped_loss), do: "dropped (loss)"
  def log_label(:crashed), do: "crashed"
  def log_label(:restarted), do: "restarted"
  def log_label(:increment), do: "counted"
  def log_label(_), do: "event"

  def mode_label(:counter), do: "G-Counter"
  def mode_label(:rumor), do: "Rumor"
  def mode_label(_), do: "Rumor"

  def readout_text(%{mode: :counter, reached: reached, total: total}) do
    "#{reached}/#{total} nodes hold the full counter"
  end

  def readout_text(%{reached: reached, total: total}) do
    "#{reached}/#{total} nodes know the latest value"
  end

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
          <span class="sg-mode-badge">{mode_label(@snapshot.mode)}</span>
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--signal"></i>informed</span>
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--pending"></i>pending</span>
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--origin"></i>origin</span>
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--split"></i>partitioned</span>
          <span class="sg-legend__item"><i class="sg-swatch sg-swatch--down"></i>crashed</span>
        </div>
        <p class="sg-graph__readout">
          {readout_text(@snapshot)}
          <span class="sg-graph__percent">{reached_percent(@snapshot)}%</span>
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
                <line
                  :for={edge <- @snapshot.edges}
                  x1={px(edge.a, sg, :x)}
                  y1={px(edge.a, sg, :y)}
                  x2={px(edge.b, sg, :x)}
                  y2={px(edge.b, sg, :y)}
                  class={"sg-edge #{edge_class(edge, sg.clock)}"}
                  stroke={edge_stroke(edge, sg.clock)}
                  stroke-width={edge_width(edge, sg.clock)}
                  stroke-dasharray={edge.partitioned && "6 6"}
                />
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
                  <%= if @snapshot.mode == :counter do %>
                    <text
                      x={px(node.id, sg, :x)}
                      y={py_count(node.id, sg)}
                      class="sg-node__count"
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

  defp py_label(id, sg) do
    project(sg_layout(sg, id)) |> elem(1) |> Kernel.+(node_radius() + 14)
  end

  defp py_count(id, sg) do
    project(sg_layout(sg, id)) |> elem(1) |> Kernel.+(node_radius() + 28)
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
                class="sg-btn sg-btn--increment"
                type="button"
                phx-click="increment"
                phx-value-node={@fault_node}
              >
                Count
              </button>
            <% end %>
          </div>
        </.form>
        <p class="sg-faults__note">
          Pick a node, then crash or restart it while the run is active.
        </p>
        <%= if @snapshot.mode == :counter do %>
          <p class="sg-faults__note">
            Use Count to add an increment to the selected node.
          </p>
        <% end %>
      </div>

      <div class="sg-controls__hint">
        Click a node to toggle its partition group. Click
        <button class="sg-link" phx-click="merge" type="button">heal</button>
        to merge all groups.
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
        <div>
          <dt>Converged in</dt><dd>{format_time(@snapshot.convergence_time)}</dd>
        </div>
        <%= if @snapshot.mode == :counter do %>
          <div>
            <dt>Value</dt><dd>{@snapshot.best_value}</dd>
          </div>
          <div>
            <dt>Reached</dt><dd>{@snapshot.reached}/{@snapshot.total}</dd>
          </div>
        <% end %>
      </dl>
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
                  <%= if entry.to do %>
                    {entry.from} -> {entry.to} {log_label(entry.kind)}
                  <% else %>
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
