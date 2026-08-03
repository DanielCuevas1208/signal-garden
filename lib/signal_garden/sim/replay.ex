defmodule SignalGarden.Sim.Replay do
  @moduledoc """
  Run a scenario to completion and return a full trace.

  A replay drives the pure `Core` state machine with no animation loop, no
  GenServer, and no browser. Two replays of the same scenario produce the
  same summary, the same event trace, and the same history, so the module
  doubles as a determinism check for the simulator.

  The returned map holds a scenario brief, a summary of the final state, the
  ordered event trace, and the convergence history. The `Mix.Tasks.Sg.Run`
  task renders this data as a table or as JSON.

  The replay keeps the complete event log and history. The browser caps both
  at 80 entries; the replay does not, so the trace is reproducible end to end.
  """

  alias SignalGarden.Sim.Core
  alias SignalGarden.Sim.Scenario

  @default_budget 200_000
  @chunk 200

  @type summary :: %{
          status: Core.status(),
          convergence_time: non_neg_integer() | nil,
          steps: non_neg_integer(),
          hops: non_neg_integer(),
          delivered: non_neg_integer(),
          dropped: non_neg_integer(),
          informed: non_neg_integer(),
          total: non_neg_integer()
        }

  @type t :: %{
          scenario: map(),
          summary: summary(),
          events: [map()],
          history: [map()]
        }

  @doc """
  Replay `scenario` to completion and return its trace.

  Options:

    * `:budget` - the maximum number of events to process. Defaults to 200_000.
    * `:chunk` - the number of events per core step. Defaults to 200.
    * `:log_size` - passed to `Core.new/2`. Defaults to `:infinity`, which
      keeps the full event log and history.

  A small `:budget` stops the replay early. The summary then reports the
  status the run reached, which is usually `:running`.
  """
  @spec run(Scenario.t(), keyword()) :: t()
  def run(%Scenario{} = scenario, opts \\ []) do
    budget = Keyword.get(opts, :budget, @default_budget)
    chunk = Keyword.get(opts, :chunk, @chunk)
    log_size = Keyword.get(opts, :log_size, :infinity)

    final =
      scenario
      |> Core.new(log_size: log_size)
      |> Core.command({:set_status, :running})
      |> run_loop(budget, chunk)

    %{
      scenario: scenario_brief(scenario),
      summary: summarize(final),
      events: Enum.reverse(final.event_log),
      history: final.history
    }
  end

  @doc """
  Replay `scenario` and return only the summary map.

  The summary is deterministic. Two calls with the same scenario return equal
  maps, which makes it a cheap convergence check for a batch of scenarios.
  """
  @spec summary(Scenario.t(), keyword()) :: summary()
  def summary(scenario, opts \\ []) do
    scenario |> run(opts) |> Map.fetch!(:summary)
  end

  @doc """
  Render one replay as a readable table.

  The `:events` option sets the number of trace rows to print. The default
  is 30. The table includes the scenario brief, the first trace rows, and
  the summary.
  """
  @spec format(t(), keyword()) :: String.t()
  def format(%{scenario: brief, summary: summary, events: events}, opts \\ []) do
    shown = Enum.take(events, Keyword.get(opts, :events, 30))

    [
      "Scenario: #{brief.name}",
      "Mode: #{brief.mode}      Nodes: #{brief.nodes}       Edges: #{brief.edges}       " <>
        "Origin: #{brief.origin}       Seed: #{brief.seed}",
      "Status: #{status_label(summary.status)}     " <>
        "Converged in: #{format_ms(summary.convergence_time)}",
      "",
      "Trace (first #{length(shown)} of #{length(events)} events)",
      "t(ms)  #{pad("kind", 20)}#{pad("from", 6)}to",
      Enum.map(shown, &trace_line/1),
      "",
      "Summary",
      "Steps: #{summary.steps}   Hops: #{summary.hops}   Delivered: #{summary.delivered}   " <>
        "Dropped: #{summary.dropped}   Informed: #{summary.informed}/#{summary.total}"
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc """
  Render one summary row per replay for the catalog table.

  The rows align with the "Sample output" section in the README, so a
  checkout can regenerate that evidence with `mix sg.run --all`.
  """
  @spec format_catalog([t()]) :: String.t()
  def format_catalog(traces) do
    header =
      pad("scenario", 20) <>
        pad("status", 13) <>
        pad("t(ms)", 10) <>
        pad("hops", 7) <>
        pad("dropped", 10) <>
        pad("steps", 8) <>
        "informed"

    rows =
      Enum.map(traces, fn %{scenario: brief, summary: summary} ->
        pad(brief.name, 20) <>
          pad(status_label(summary.status), 13) <>
          pad("#{summary.convergence_time}", 10) <>
          pad("#{summary.hops}", 7) <>
          pad("#{summary.dropped}", 10) <>
          pad("#{summary.steps}", 8) <>
          "#{summary.informed}/#{summary.total}"
      end)

    Enum.join([header | rows], "\n")
  end

  @doc """
  Return the id and name of every catalog scenario.

  Used by `mix sg.run --list`.
  """
  @spec list() :: String.t()
  def list do
    catalog =
      SignalGarden.Scenarios.catalog()
      |> Enum.map(&"#{pad(Atom.to_string(&1.id), 20)}#{&1.name}")

    Enum.join(catalog, "\n")
  end

  # ---------------------------------------------------------------------------
  # internals
  # ---------------------------------------------------------------------------

  defp run_loop(state, _budget, _chunk) when state.status in [:converged, :exhausted],
    do: state

  defp run_loop(state, budget, _chunk) when budget <= 0, do: state

  defp run_loop(state, budget, chunk) do
    {state, _processed} = Core.step(state, min(chunk, budget))
    run_loop(state, budget - chunk, chunk)
  end

  defp summarize(%Core{} = state) do
    %{
      status: state.status,
      convergence_time: state.convergence_time,
      steps: state.steps,
      hops: state.hops,
      delivered: state.delivered,
      dropped: state.dropped,
      informed: MapSet.size(state.informed),
      total: map_size(state.nodes)
    }
  end

  defp scenario_brief(%Scenario{} = scenario) do
    %{
      id: scenario.id,
      name: scenario.name,
      mode: scenario.mode,
      seed: scenario.seed,
      origin: scenario.origin,
      nodes: length(scenario.topology.nodes),
      edges: length(scenario.topology.edges)
    }
  end

  defp status_label(:running), do: "running"
  defp status_label(:converged), do: "converged"
  defp status_label(:exhausted), do: "stalled"
  defp status_label(:paused), do: "paused"
  defp status_label(:idle), do: "ready"

  defp format_ms(nil), do: "n/a"

  defp format_ms(ms) do
    if ms < 1000, do: "#{ms} ms", else: "#{Float.round(ms / 1000, 2)} s"
  end

  defp trace_line(entry) do
    t = pad("#{entry.t}", 7)
    kind = pad(kind_label(entry.kind), 20)
    from = pad("#{entry.from}", 6)
    to = if entry.to, do: "#{entry.to}", else: "-"
    extra = if entry.kind == :increment, do: " (+#{entry.amount})", else: ""

    "#{t}#{kind}#{from}#{to}#{extra}"
  end

  defp kind_label(:deliver), do: "delivered"
  defp kind_label(:dropped_partition), do: "dropped (partition)"
  defp kind_label(:dropped_loss), do: "dropped (loss)"
  defp kind_label(:crashed), do: "crashed"
  defp kind_label(:restarted), do: "restarted"
  defp kind_label(:increment), do: "wrote"
  defp kind_label(_), do: "event"

  defp pad(text, width), do: String.pad_trailing(text, width)
end
