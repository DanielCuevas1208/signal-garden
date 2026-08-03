defmodule SignalGarden.Sim.Replay do
  @moduledoc """
  Headless, deterministic replay of a simulation scenario.

  The replay drives the pure `SignalGarden.Sim.Core` to completion with no
  animation loop and no browser. Every run of the same scenario returns the
  same numbers and the same event trace. The module backs the
  `mix garden.replay` task and the `priv/sample.exs` script.

  ## Outcome

  Each outcome is a plain map. It carries the summary numbers and the full
  event trace, so a caller can render a table, a trace, or JSON without
  touching the core.

  ## Determinism

  Two runs of the same scenario produce identical traces, histories, and
  convergence times. The `verify/1` function replays a scenario twice and
  reports whether the two runs match. The `mix garden.replay --verify`
  task runs this check for every catalog scenario.
  """

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario, ScenarioCodec}

  @log_cap 100_000
  @step_budget 2_000_000

  @type outcome :: %{
          scenario: atom(),
          name: String.t(),
          mode: :rumor | :counter,
          nodes: pos_integer(),
          status: Core.status(),
          convergence_time: non_neg_integer() | nil,
          hops: non_neg_integer(),
          delivered: non_neg_integer(),
          dropped: non_neg_integer(),
          steps: non_neg_integer(),
          counter_total: non_neg_integer(),
          trace: [map()],
          history: [map()]
        }

  @doc """
  Replay a scenario struct to completion.

  The returned map contains the summary numbers and the chronological
  event trace. The trace holds every logged delivery, drop, crash,
  restart, and counter write of the run.
  """
  @spec run(Scenario.t()) :: outcome()
  def run(%Scenario{} = scenario) do
    state =
      scenario
      |> Core.new(log_size: @log_cap)
      |> Core.command({:set_status, :running})
      |> advance_to_done()

    %{
      scenario: scenario.id,
      name: scenario.name,
      mode: scenario.mode,
      nodes: map_size(state.nodes),
      status: state.status,
      convergence_time: state.convergence_time,
      hops: state.hops,
      delivered: state.delivered,
      dropped: state.dropped,
      steps: state.steps,
      counter_total: state.increments_total,
      trace: Enum.reverse(state.event_log),
      history: state.history
    }
  end

  @doc "Replay a catalog scenario by its id atom."
  @spec run_id(atom()) :: {:ok, outcome()} | {:error, {:unknown_scenario, atom()}}
  def run_id(id) when is_atom(id) do
    case Scenarios.fetch(id) do
      nil -> {:error, {:unknown_scenario, id}}
      scenario -> {:ok, run(scenario)}
    end
  end

  @doc """
  Replay a scenario file.

  The file must be in the codec JSON format. Any codec error is returned
  unchanged, so callers can render a friendly message.
  """
  @spec run_file(Path.t()) :: {:ok, outcome()} | {:error, term()}
  def run_file(path) when is_binary(path) do
    with {:ok, json} <- File.read(path),
         {:ok, scenario} <- ScenarioCodec.decode(json) do
      {:ok, run(scenario)}
    end
  end

  @doc "Replay every catalog scenario in order."
  @spec run_all() :: [outcome()]
  def run_all do
    Enum.map(Scenarios.catalog(), &run/1)
  end

  @doc """
  Confirm a scenario replays to an identical result.

  Runs the scenario twice and compares the convergence time, the history,
  and the event trace. Returns a map with a boolean verdict and the stable
  numbers, so a report can show what was verified.
  """
  @spec verify(Scenario.t()) :: map()
  def verify(%Scenario{} = scenario) do
    a = run(scenario)
    b = run(scenario)

    %{
      scenario: scenario.id,
      name: scenario.name,
      deterministic:
        a.convergence_time == b.convergence_time and
          a.history == b.history and
          a.trace == b.trace,
      convergence_time: a.convergence_time,
      steps: a.steps,
      events: length(a.trace)
    }
  end

  @doc "Verify every catalog scenario."
  @spec verify_all() :: [map()]
  def verify_all do
    Enum.map(Scenarios.catalog(), &verify/1)
  end

  # ---------------------------------------------------------------------------
  # formatting
  # ---------------------------------------------------------------------------

  @doc "Format a list of outcomes as a fixed-width table."
  @spec format_table([outcome()]) :: String.t()
  def format_table(outcomes) do
    rows = [table_header() | Enum.map(outcomes, &table_row/1)]
    widths = column_widths(rows)

    rows
    |> Enum.map(&pad_row(&1, widths))
    |> Enum.join("\n")
  end

  @doc "Format a single event map as one trace line."
  @spec format_event(map()) :: String.t()
  def format_event(entry) do
    time = format_time(entry.t)

    case entry.kind do
      :deliver -> "#{time} node #{entry.from} -> node #{entry.to} delivered"
      :dropped_partition -> "#{time} node #{entry.from} -> node #{entry.to} dropped (partition)"
      :dropped_loss -> "#{time} node #{entry.from} -> node #{entry.to} dropped (loss)"
      :crashed -> "#{time} node #{entry.from} crashed"
      :restarted -> "#{time} node #{entry.from} restarted"
      :increment -> "#{time} node #{entry.from} wrote +#{entry.amount}"
      _ -> "#{time} #{entry.kind}"
    end
  end

  @doc "Format the full trace of an outcome as lines."
  @spec format_trace(outcome()) :: String.t()
  def format_trace(%{trace: trace}) do
    Enum.map_join(trace, "\n", &format_event/1)
  end

  defp table_header, do: ["scenario", "nodes", "status", "t(ms)", "hops", "dropped", "steps"]

  defp table_row(outcome) do
    [
      outcome.name,
      "#{outcome.nodes}",
      "#{outcome.status}",
      format_time(outcome.convergence_time),
      "#{outcome.hops}",
      "#{outcome.dropped}",
      "#{outcome.steps}"
    ]
  end

  defp column_widths(rows) do
    rows
    |> Enum.flat_map(fn row -> Enum.with_index(row) end)
    |> Enum.reduce(%{}, fn {cell, i}, acc ->
      Map.update(acc, i, String.length(cell), &max(&1, String.length(cell)))
    end)
  end

  defp pad_row(row, widths) do
    row
    |> Enum.with_index()
    |> Enum.map_join(fn {cell, i} ->
      if i == length(row) - 1 do
        cell
      else
        String.pad_trailing(cell, widths[i] + 2)
      end
    end)
  end

  defp format_time(nil), do: "-"
  defp format_time(t) when is_integer(t), do: "#{t}"

  # ---------------------------------------------------------------------------
  # run loop
  # ---------------------------------------------------------------------------

  defp advance_to_done(%Core{} = state) do
    Enum.reduce_while(1..@step_budget//100, state, fn _, acc ->
      {acc, _} = Core.step(acc, 100)
      if acc.status in [:converged, :exhausted], do: {:halt, acc}, else: {:cont, acc}
    end)
  end
end
