defmodule SignalGarden.Sim.Replay do
  @moduledoc """
  Replay scenarios headlessly and inspect the trace.

  The replay runner drives the pure `SignalGarden.Sim.Core` with no animation
  loop and no browser. It captures every network event in order, plus the
  faults that fired and the final counters. A terminal, a script, or a CI job
  can read the same run that the control room shows.

  Replays are deterministic. Two replays of one scenario produce the same
  trace, the same history, and the same convergence time. `check/2` runs a
  scenario twice and verifies that the runs agree.

  The `mix sim.replay` task uses this module as its engine.
  """

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario, ScenarioCodec}

  @default_max_steps 500_000
  @trace_window 16

  defstruct scenario: nil,
            status: nil,
            convergence_time: nil,
            steps: 0,
            hops: 0,
            delivered: 0,
            dropped: 0,
            counter_total: 0,
            counter_writes: 0,
            trace: [],
            history: [],
            max_steps: @default_max_steps,
            budget_exhausted?: false

  @type t :: %__MODULE__{}

  @type trace_event ::
          {:deliver, non_neg_integer(), pos_integer(), pos_integer()}
          | {:dropped, non_neg_integer(), pos_integer(), pos_integer(), :partition | :loss}
          | {:crashed, non_neg_integer(), pos_integer()}
          | {:restarted, non_neg_integer(), pos_integer()}
          | {:increment, non_neg_integer(), pos_integer(), pos_integer()}
          | {:partition, non_neg_integer(), pos_integer(), integer()}
          | {:converged, non_neg_integer()}
          | {:exhausted, non_neg_integer()}

  # ---------------------------------------------------------------------------
  # replay
  # ---------------------------------------------------------------------------

  @doc "Replay one scenario to completion and return a report."
  @spec run(Scenario.t(), keyword()) :: t()
  def run(%Scenario{} = scenario, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    state = Core.new(scenario) |> Core.command({:set_status, :running})
    {final, trace, budget_exhausted?} = drive(state, max_steps, [])

    %__MODULE__{
      scenario: scenario,
      status: final.status,
      convergence_time: final.convergence_time,
      steps: final.steps,
      hops: final.hops,
      delivered: final.delivered,
      dropped: final.dropped,
      counter_total: final.increments_total,
      counter_writes: final.increments_issued,
      trace: Enum.reverse(trace),
      history: final.history,
      max_steps: max_steps,
      budget_exhausted?: budget_exhausted?
    }
  end

  @doc "Replay every built-in scenario and return one report per scenario."
  @spec run_all(keyword()) :: [t()]
  def run_all(opts \\ []) do
    Enum.map(Scenarios.catalog(), &run(&1, opts))
  end

  @doc """
  Resolve a CLI target into a scenario.

  Accepts a catalog id string, or the path to a scenario JSON file.
  """
  @spec resolve(String.t()) :: {:ok, Scenario.t()} | {:error, term()}
  def resolve(target) when is_binary(target) do
    cond do
      catalog_scenario(target) != nil -> {:ok, catalog_scenario(target)}
      File.exists?(target) -> decode_file(target)
      true -> {:error, {:unknown_scenario, target}}
    end
  end

  @doc "Turn a resolve or decode error into a human-readable message."
  @spec resolve_error(term()) :: String.t()
  def resolve_error({:unknown_scenario, target}),
    do: "No scenario named \"#{target}\" and no file at that path."

  def resolve_error({:file_error, _reason}), do: "The scenario file could not be read."

  def resolve_error({:invalid_json, _reason}), do: "The scenario file is not valid JSON."

  def resolve_error({:unsupported_format, version}),
    do: "The scenario file uses unsupported format version #{version}."

  def resolve_error({:invalid_field, field}),
    do: "The scenario file has an invalid value for the field \"#{field}\"."

  def resolve_error({:invalid_origin, origin}),
    do: "Origin node #{origin} is not in the topology."

  def resolve_error(:missing_format), do: "The scenario file has no format version."
  def resolve_error(_), do: "The scenario file could not be decoded."

  @doc "Replay a scenario twice and report whether the runs agree."
  @spec check(Scenario.t(), keyword()) :: %{atom() => boolean()}
  def check(%Scenario{} = scenario, opts \\ []) do
    a = run(scenario, opts)
    b = run(scenario, opts)

    %{
      convergence_time: a.convergence_time == b.convergence_time,
      trace: a.trace == b.trace,
      history: a.history == b.history,
      counters: a.counter_total == b.counter_total and a.counter_writes == b.counter_writes,
      result:
        a.status == b.status and a.steps == b.steps and a.hops == b.hops and
          a.delivered == b.delivered and a.dropped == b.dropped
    }
  end

  # ---------------------------------------------------------------------------
  # text rendering
  # ---------------------------------------------------------------------------

  @doc "Render one replay report as human-readable text."
  @spec render(t(), keyword()) :: String.t()
  def render(%__MODULE__{} = report, opts \\ []) do
    [render_header(report), "", render_summary(report), "", render_trace(report, opts)]
    |> Enum.join("\n")
  end

  @doc "Render the determinism check as human-readable text."
  @spec render_check(%{atom() => boolean()}) :: String.t()
  def render_check(checks) when is_map(checks) do
    rows = [
      {"convergence_time", checks.convergence_time},
      {"trace", checks.trace},
      {"history", checks.history},
      {"counters", checks.counters},
      {"result", checks.result}
    ]

    (["Determinism check"] ++
       Enum.map(rows, fn {name, ok} -> "  #{pad(name, 18)}equal = #{ok}" end))
    |> Enum.join("\n")
  end

  @doc "Render several replay reports as a comparison table."
  @spec render_table([t()]) :: String.t()
  def render_table(reports) when is_list(reports) do
    header =
      pad("scenario", 20) <>
        pad("nodes", 7) <>
        pad("status", 13) <>
        pad("t(ms)", 10) <>
        pad("hops", 7) <>
        pad("dropped", 10) <>
        "steps"

    rows =
      Enum.map(reports, fn report ->
        s = report.scenario
        time = if report.convergence_time == nil, do: "--", else: "#{report.convergence_time}"

        pad(s.name, 20) <>
          pad("#{length(s.topology.nodes)}", 7) <>
          pad(status_label(report.status), 13) <>
          pad(time, 10) <>
          pad("#{report.hops}", 7) <>
          pad("#{report.dropped}", 10) <>
          "#{report.steps}"
      end)

    Enum.join([header | rows], "\n")
  end

  @doc "Render a report or a list of reports as JSON."
  @spec render_json(t() | [t()]) :: String.t()
  def render_json(%__MODULE__{} = report), do: report |> to_map() |> Jason.encode!(pretty: true)

  def render_json(reports) when is_list(reports),
    do: reports |> Enum.map(&to_map/1) |> Jason.encode!(pretty: true)

  @doc "Render a report plus its determinism check as JSON."
  @spec render_json_check(t(), %{atom() => boolean()}) :: String.t()
  def render_json_check(%__MODULE__{} = report, checks) do
    report
    |> to_map()
    |> Map.put("determinism", checks)
    |> Jason.encode!(pretty: true)
  end

  @doc "Return the text label for a status atom."
  @spec status_label(atom()) :: String.t()
  def status_label(:running), do: "running"
  def status_label(:paused), do: "paused"
  def status_label(:converged), do: "converged"
  def status_label(:exhausted), do: "stalled"
  def status_label(:idle), do: "ready"
  def status_label(_), do: "idle"

  # ---------------------------------------------------------------------------
  # driving the core
  # ---------------------------------------------------------------------------

  defp drive(state, max_steps, trace) do
    drive_loop(state, max_steps, trace)
  end

  defp drive_loop(state, _remaining, trace)
       when state.status in [:converged, :exhausted] do
    {state, trace, false}
  end

  defp drive_loop(state, 0, trace) do
    {%{state | status: :exhausted}, trace, true}
  end

  defp drive_loop(state, remaining, trace) do
    {next, _processed} = Core.step(state, 1)
    trace = observe(trace, state, next)
    drive_loop(next, remaining - 1, trace)
  end

  defp observe(trace, prev, next) do
    trace
    |> observe_log(prev, next)
    |> observe_partitions(prev, next)
    |> observe_status(prev, next)
  end

  # The core logs events into a bounded buffer. Stepping one event at a time
  # puts the newest entry at the head, so reading the head after every step
  # recovers the complete trace in order.
  defp observe_log(trace, prev, next) do
    if next.event_log == prev.event_log do
      trace
    else
      [event_from_entry(List.first(next.event_log)) | trace]
    end
  end

  defp event_from_entry(%{kind: :deliver} = e), do: {:deliver, e.t, e.from, e.to}

  defp event_from_entry(%{kind: :dropped_partition} = e),
    do: {:dropped, e.t, e.from, e.to, :partition}

  defp event_from_entry(%{kind: :dropped_loss} = e), do: {:dropped, e.t, e.from, e.to, :loss}
  defp event_from_entry(%{kind: :crashed} = e), do: {:crashed, e.t, e.from}
  defp event_from_entry(%{kind: :restarted} = e), do: {:restarted, e.t, e.from}

  defp event_from_entry(%{kind: :increment} = e), do: {:increment, e.t, e.from, e.amount}

  defp observe_partitions(trace, prev, next) do
    prev.partitions
    |> Map.keys()
    |> Enum.concat(Map.keys(next.partitions))
    |> Enum.uniq()
    |> Enum.reduce(trace, fn node, acc ->
      case {Map.get(prev.partitions, node, 0), Map.get(next.partitions, node, 0)} do
        {old, new} when old != new -> [{:partition, next.clock, node, new} | acc]
        _ -> acc
      end
    end)
  end

  defp observe_status(trace, prev, next) do
    cond do
      next.status == :converged and prev.status != :converged ->
        [{:converged, next.convergence_time} | trace]

      next.status == :exhausted and prev.status != :exhausted ->
        [{:exhausted, next.clock} | trace]

      true ->
        trace
    end
  end

  # ---------------------------------------------------------------------------
  # header / summary
  # ---------------------------------------------------------------------------

  defp render_header(report) do
    s = report.scenario

    [
      "Scenario: #{s.name}",
      "Mode: #{Atom.to_string(s.mode)} | Topology: #{s.topology.label}",
      "Nodes: #{length(s.topology.nodes)} | Seed: #{s.seed} | Origin: node #{s.origin}"
    ]
    |> Enum.join("\n")
  end

  defp render_summary(report) do
    rows = [
      {"Result", status_label(report.status)},
      {"Convergence time", format_time(report.convergence_time)},
      {"Events processed", report.steps},
      {"Hops", report.hops},
      {"Delivered", report.delivered},
      {"Dropped", report.dropped}
    ]

    rows =
      if report.scenario.mode == :counter do
        rows ++
          [{"Counter total", report.counter_total}, {"Counter writes", report.counter_writes}]
      else
        rows
      end

    rows
    |> Enum.map(fn {label, value} -> pad("#{label}:", 20) <> "#{value}" end)
    |> Enum.join("\n")
  end

  defp format_time(nil), do: "--"

  defp format_time(t) when t < 1000, do: "#{t} ms"
  defp format_time(t), do: "#{Float.round(t / 1000, 2)} s"

  # ---------------------------------------------------------------------------
  # trace rendering
  # ---------------------------------------------------------------------------

  defp render_trace(%__MODULE__{trace: []}, _opts) do
    "Trace: no events recorded."
  end

  defp render_trace(%__MODULE__{} = report, opts) do
    full? = Keyword.get(opts, :trace, false)
    all = report.trace

    shown =
      if full? do
        all
      else
        Enum.take(all, -@trace_window)
      end

    note =
      if full? do
        "Trace (#{length(all)} events):"
      else
        "Trace (#{length(all)} events; last #{length(shown)} shown, pass --trace for all):"
      end

    lines = Enum.map(shown, &render_trace_line(report, &1))
    Enum.join([note | lines], "\n")
  end

  defp render_trace_line(report, event) do
    t = elem(event, 1)
    "  #{pad("t=#{t}", 9)}  #{trace_text(report, event)}"
  end

  defp trace_text(report, event) do
    case event do
      {:deliver, _t, from, to} ->
        "node #{from} -> node #{to} delivered"

      {:dropped, _t, from, to, :partition} ->
        "node #{from} -> node #{to} dropped (partition)"

      {:dropped, _t, from, to, :loss} ->
        "node #{from} -> node #{to} dropped (loss)"

      {:crashed, _t, node} ->
        "node #{node} crashed" <> fault_suffix(report, event)

      {:restarted, _t, node} ->
        "node #{node} restarted" <> fault_suffix(report, event)

      {:increment, _t, node, amount} ->
        "node #{node} wrote +#{amount}" <> fault_suffix(report, event)

      {:partition, _t, node, group} ->
        "node #{node} joined group #{group}" <> fault_suffix(report, event)

      {:converged, _t} ->
        "converged"

      {:exhausted, _t} ->
        "stalled: the event queue emptied"

      _ ->
        "event"
    end
  end

  defp fault_suffix(report, event) do
    case fault_label(report.scenario, event) do
      nil -> ""
      label -> " (#{label})"
    end
  end

  defp fault_label(%Scenario{} = scenario, event) do
    Enum.find_value(scenario.fault_schedule, fn fault ->
      if fault_matches?(fault, event), do: fault.label, else: nil
    end)
  end

  defp fault_matches?(%{at: t, action: action}, event) do
    case event do
      {:crashed, ^t, node} -> action == {:crash, node}
      {:restarted, ^t, node} -> action == {:restart, node}
      {:increment, ^t, node, amount} -> action == {:increment, node, amount}
      {:partition, ^t, node, group} -> action == {:assign, node, group} or merge?(action, group)
      _ -> false
    end
  end

  defp merge?({:merge, :all}, 0), do: true
  defp merge?(_, _), do: false

  # ---------------------------------------------------------------------------
  # json rendering
  # ---------------------------------------------------------------------------

  defp to_map(%__MODULE__{} = report) do
    %{
      "scenario" => scenario_map(report.scenario),
      "result" => %{
        "status" => Atom.to_string(report.status),
        "convergence_time_ms" => report.convergence_time,
        "steps" => report.steps,
        "hops" => report.hops,
        "delivered" => report.delivered,
        "dropped" => report.dropped,
        "counter_total" => report.counter_total,
        "counter_writes" => report.counter_writes,
        "budget_exhausted" => report.budget_exhausted?
      },
      "trace" => Enum.map(report.trace, &trace_to_map/1),
      "history" => report.history
    }
  end

  defp scenario_map(%Scenario{} = s) do
    %{
      "id" => Atom.to_string(s.id),
      "name" => s.name,
      "description" => s.description,
      "mode" => Atom.to_string(s.mode),
      "seed" => s.seed,
      "origin" => s.origin,
      "nodes" => length(s.topology.nodes),
      "edges" => length(s.topology.edges),
      "topology" => s.topology.label
    }
  end

  defp trace_to_map({:deliver, t, from, to}),
    do: %{"t" => t, "kind" => "deliver", "from" => from, "to" => to}

  defp trace_to_map({:dropped, t, from, to, reason}),
    do: %{"t" => t, "kind" => "dropped", "from" => from, "to" => to, "reason" => reason}

  defp trace_to_map({:crashed, t, node}), do: %{"t" => t, "kind" => "crashed", "node" => node}
  defp trace_to_map({:restarted, t, node}), do: %{"t" => t, "kind" => "restarted", "node" => node}

  defp trace_to_map({:increment, t, node, amount}),
    do: %{"t" => t, "kind" => "increment", "node" => node, "amount" => amount}

  defp trace_to_map({:partition, t, node, group}),
    do: %{"t" => t, "kind" => "partition", "node" => node, "group" => group}

  defp trace_to_map({:converged, t}), do: %{"t" => t, "kind" => "converged"}
  defp trace_to_map({:exhausted, t}), do: %{"t" => t, "kind" => "exhausted"}

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp catalog_scenario(target) do
    Enum.find(Scenarios.catalog(), fn scenario -> Atom.to_string(scenario.id) == target end)
  end

  defp decode_file(path) do
    case File.read(path) do
      {:ok, contents} -> ScenarioCodec.decode(contents)
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  defp pad(value, width), do: String.pad_trailing(to_string(value), width)
end
