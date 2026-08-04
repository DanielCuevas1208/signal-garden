defmodule SignalGarden.Sim.Replay do
  @moduledoc """
  Run a scenario to completion without a browser.

  The replay drives the pure `SignalGarden.Sim.Core` with no animation loop
  and no web layer. It steps the scenario until the network converges or the
  event queue empties. It returns a report with the final state, the per-node
  results, and the full event trace.

  A replay is deterministic. Two runs of the same scenario produce identical
  reports. This makes the tool a ground-truth check for the interactive
  control room and a way to share a run between machines.

  ## Report

  A report is a `%Replay{}` struct. It carries the final status, the logical
  clock, the convergence time, the traffic counters, and the node states. The
  `trace` field lists every network event in chronological order.

  ## Formats

  Use `summary_line/1` and `to_table/1` for text output. Use `to_trace/1`
  for a line-by-line event walk and `to_json/1` for machine-readable output.

  The `mix signal_garden.replay` task wraps this module as a CLI. See
  `Mix.Tasks.SignalGarden.Replay`.
  """

  alias SignalGarden.Sim.{Core, Scenario}

  @default_max_steps 1_000_000
  @default_log_size 1_000_000

  defstruct scenario: nil,
            status: nil,
            clock: 0,
            convergence_time: nil,
            steps: 0,
            hops: 0,
            delivered: 0,
            dropped: 0,
            counter_total: nil,
            counter_writes: nil,
            nodes: [],
            trace: []

  @type t :: %__MODULE__{
          scenario: Scenario.t(),
          status: Core.status(),
          clock: non_neg_integer(),
          convergence_time: non_neg_integer() | nil,
          steps: non_neg_integer(),
          hops: non_neg_integer(),
          delivered: non_neg_integer(),
          dropped: non_neg_integer(),
          counter_total: non_neg_integer() | nil,
          counter_writes: non_neg_integer() | nil,
          nodes: [map()],
          trace: [map()]
        }

  @doc """
  Run a scenario and return a report.

  ## Options

    * `:max_steps` - the event budget. The run stops at the budget even
      when the network has not converged. Defaults to 1_000_000.
    * `:log_size` - the cap on the captured trace. Defaults to 1_000_000.
    * `:seed` - overrides the scenario seed for a different run.
    * `:origin` - overrides the origin node for a different run.

  The report status stays `:running` when the budget runs out. A status of
  `:exhausted` means the event queue emptied before convergence.
  """
  @spec run(Scenario.t(), keyword()) :: t()
  def run(%Scenario{} = scenario, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    log_size = Keyword.get(opts, :log_size, @default_log_size)
    seed = Keyword.get(opts, :seed, scenario.seed)
    origin = Keyword.get(opts, :origin, scenario.origin)

    scenario = %Scenario{scenario | seed: seed, origin: origin}

    state =
      scenario
      |> Core.new(log_size: log_size)
      |> Core.command({:set_status, :running})

    final = step_to_completion(state, max_steps)
    build_report(scenario, final)
  end

  @doc """
  Return true when two runs of the scenario produce identical reports.

  This is the determinism proof. Any divergence in the seed, the topology,
  or the fault schedule shows up as a false result.
  """
  @spec deterministic?(Scenario.t(), keyword()) :: boolean()
  def deterministic?(%Scenario{} = scenario, opts \\ []) do
    a = run(scenario, opts)
    b = run(scenario, opts)
    a == b
  end

  @doc "Return the summary table header line."
  @spec table_header() :: String.t()
  def table_header do
    String.pad_trailing("scenario", 20) <>
      String.pad_trailing("nodes", 7) <>
      String.pad_trailing("status", 13) <>
      String.pad_trailing("t(ms)", 10) <>
      String.pad_trailing("hops", 7) <>
      String.pad_trailing("dropped", 10) <>
      "steps"
  end

  @doc "Return one summary line for a report."
  @spec summary_line(t()) :: String.t()
  def summary_line(%__MODULE__{} = report) do
    String.pad_trailing(report.scenario.name, 20) <>
      String.pad_trailing("#{length(report.nodes)}", 7) <>
      String.pad_trailing("#{report.status}", 13) <>
      String.pad_trailing("#{report.convergence_time}", 10) <>
      String.pad_trailing("#{report.hops}", 7) <>
      String.pad_trailing("#{report.dropped}", 10) <>
      "#{report.steps}"
  end

  @doc "Render a list of reports as an aligned text table."
  @spec to_table([t()]) :: String.t()
  def to_table(reports) when is_list(reports) do
    [table_header() | Enum.map(reports, &summary_line/1)]
    |> Enum.join("\n")
  end

  @doc "Render the full event trace as text lines."
  @spec to_trace(t()) :: String.t()
  def to_trace(%__MODULE__{} = report) do
    lines =
      Enum.map(report.trace, fn entry ->
        "  #{String.pad_leading("#{entry.t}", 5)}  " <>
          String.pad_trailing(describe_kind(entry), 15) <>
          describe_path(entry)
      end)

    (["scenario: #{report.scenario.name}", "status: #{report.status}", "trace:"] ++ lines)
    |> Enum.join("\n")
  end

  @doc "Encode a report as pretty-printed JSON."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = report) do
    report
    |> to_map()
    |> Jason.encode!(pretty: true)
  end

  # ---------------------------------------------------------------------------
  # internals
  # ---------------------------------------------------------------------------

  defp step_to_completion(state, max_steps) do
    Enum.reduce_while(1..max_steps//1, state, fn _, acc ->
      {acc, _processed} = Core.step(acc, 200)

      if acc.status in [:converged, :exhausted] do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end

  defp build_report(scenario, state) do
    %__MODULE__{
      scenario: scenario,
      status: state.status,
      clock: state.clock,
      convergence_time: state.convergence_time,
      steps: state.steps,
      hops: state.hops,
      delivered: state.delivered,
      dropped: state.dropped,
      counter_total: counter_value(state),
      counter_writes: counter_writes(state),
      nodes: node_report(state),
      trace: Enum.reverse(state.event_log)
    }
  end

  defp counter_value(%Core{mode: :counter, increments_total: total}), do: total
  defp counter_value(%Core{}), do: nil

  defp counter_writes(%Core{mode: :counter, increments_issued: issued}), do: issued
  defp counter_writes(%Core{}), do: nil

  defp node_report(%Core{} = state) do
    Enum.map(state.topology.nodes, fn id ->
      node = state.nodes[id]

      %{
        id: id,
        up: node.up,
        informed: node.informed,
        value: node_value(state, node),
        version: node_version(state, node)
      }
    end)
  end

  defp node_value(%Core{mode: :counter, origin: origin}, node) do
    Enum.sum(Map.values(node.known[origin].cells))
  end

  defp node_value(%Core{origin: origin}, node) do
    get_in(node, [Access.key(:known), origin, Access.key(:value)])
  end

  defp node_version(%Core{mode: :counter} = state, _node), do: state.increments_issued

  defp node_version(%Core{origin: origin}, node) do
    get_in(node, [Access.key(:known), origin, Access.key(:version)])
  end

  defp describe_kind(%{kind: :deliver}), do: "deliver"
  defp describe_kind(%{kind: :dropped_partition}), do: "drop (group)"
  defp describe_kind(%{kind: :dropped_loss}), do: "drop (loss)"
  defp describe_kind(%{kind: :crashed}), do: "crash"
  defp describe_kind(%{kind: :restarted}), do: "restart"
  defp describe_kind(%{kind: :increment}), do: "increment"
  defp describe_kind(_), do: "event"

  defp describe_path(%{kind: kind, from: from, to: to})
       when kind in [:deliver, :dropped_partition, :dropped_loss] do
    "#{from} -> #{to}"
  end

  defp describe_path(%{kind: :crashed, from: from}), do: "node #{from} down"
  defp describe_path(%{kind: :restarted, from: from}), do: "node #{from} up"

  defp describe_path(%{kind: :increment, from: from, amount: amount}),
    do: "+#{amount} on node #{from}"

  defp describe_path(_), do: "-"

  defp to_map(%__MODULE__{} = report) do
    %{
      "scenario" => %{
        "id" => Atom.to_string(report.scenario.id),
        "name" => report.scenario.name,
        "mode" => Atom.to_string(report.scenario.mode),
        "seed" => report.scenario.seed
      },
      "status" => Atom.to_string(report.status),
      "clock" => report.clock,
      "convergence_time" => report.convergence_time,
      "steps" => report.steps,
      "hops" => report.hops,
      "delivered" => report.delivered,
      "dropped" => report.dropped,
      "counter_total" => report.counter_total,
      "counter_writes" => report.counter_writes,
      "nodes" => Enum.map(report.nodes, &json_node/1),
      "trace" => Enum.map(report.trace, &json_entry/1)
    }
  end

  defp json_node(%{id: id, up: up, informed: informed, value: value, version: version}) do
    %{"id" => id, "up" => up, "informed" => informed, "value" => value, "version" => version}
  end

  defp json_entry(entry) do
    entry
    |> Map.take([:t, :from, :to, :amount, :partition])
    |> Map.put(:kind, Atom.to_string(entry.kind))
  end
end
