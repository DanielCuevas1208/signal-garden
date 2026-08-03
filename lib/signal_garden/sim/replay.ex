defmodule SignalGarden.Sim.Replay do
  @moduledoc """
  Run a scenario headlessly and return a full deterministic trace.

  The replay runner drives the pure `SignalGarden.Sim.Core` to the end of a
  run. It needs no animation loop, no GenServer, and no browser. It keeps the
  entire event log, so the trace shows every hazard the network applied:
  deliveries, drops, crashes, restarts, and increments.

  Two replays of the same scenario always produce the same trace and the same
  convergence time. Anyone can share a scenario file and reproduce the run on
  another machine.

  ## Sources

  A source is one of:

    * a `SignalGarden.Sim.Scenario` struct
    * a catalog id atom, such as `:ring`
    * a path to a scenario JSON file
    * a JSON string in the scenario format

  ## Options

    * `:steps` - run at most this many events. Defaults to `:all`.
    * `:batch` - events processed per core step. Defaults to 100.
    * `:budget` - loop iterations before the runner gives up. Defaults to 20000.

  The `mix sg.replay` task wraps this module for the command line.
  """

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario, ScenarioCodec}

  @type source :: Scenario.t() | atom() | String.t()
  @type run_opts :: [
          {:steps, :all | pos_integer()} | {:batch, pos_integer()} | {:budget, pos_integer()}
        ]

  @doc "Resolve a scenario source into a scenario struct."
  @spec resolve(source()) :: {:ok, Scenario.t()} | {:error, term()}
  def resolve(%Scenario{} = scenario), do: {:ok, scenario}

  def resolve(source) when is_atom(source) do
    case Scenarios.fetch(source) do
      nil -> {:error, {:unknown_scenario, source}}
      scenario -> {:ok, scenario}
    end
  end

  def resolve(source) when is_binary(source) do
    case lookup_catalog(source) do
      {:ok, scenario} -> {:ok, scenario}
      :error -> decode_source(source)
    end
  end

  @doc """
  Run a scenario headlessly and return the full result map.

  The result carries the scenario brief, the final counters, the convergence
  time, the complete event trace, and the convergence history. The run stops
  at convergence, at exhaustion, or at the `:steps` or `:budget` limit.
  """
  @spec run(source(), run_opts()) :: {:ok, map()} | {:error, term()}
  def run(source, opts \\ []) do
    with {:ok, scenario} <- resolve(source) do
      {:ok, run_scenario(scenario, opts)}
    end
  end

  @doc """
  Replay a scenario twice and compare the two runs.

  Returns both results plus a set of equality booleans. The trace, the
  history, and the convergence time must match exactly.
  """
  @spec verify(source(), run_opts()) :: {:ok, map()} | {:error, term()}
  def verify(source, opts \\ []) do
    with {:ok, a} <- run(source, opts),
         {:ok, b} <- run(source, opts) do
      {:ok,
       %{
         run_a: a,
         run_b: b,
         convergence_time_equal: a.convergence_time == b.convergence_time,
         trace_equal: a.trace == b.trace,
         history_equal: a.history == b.history,
         equal:
           a.convergence_time == b.convergence_time and a.trace == b.trace and
             a.history == b.history
       }}
    end
  end

  @doc "Format the result summary as a text block."
  @spec format_summary(map()) :: String.t()
  def format_summary(%{} = result) do
    base = [
      "Replay: #{result.scenario.name} (#{result.scenario.id})",
      "  #{result.total} nodes, seed #{result.scenario.seed}, mode #{result.scenario.mode}",
      "",
      "  status          #{result.status}",
      "  logical time    #{format_time(result.convergence_time || result.clock)}",
      "  hops            #{result.hops}",
      "  delivered       #{result.delivered}",
      "  dropped         #{result.dropped}",
      "  steps           #{result.steps}",
      "  reached         #{result.reached} / #{result.total}"
    ]

    base =
      if result.counter_total == nil do
        base
      else
        base ++ ["  counter total   #{result.counter_total}"]
      end

    Enum.join(base, "\n")
  end

  @doc "Format the event trace as a list of text lines."
  @spec format_trace(map(), [{:limit, :all | pos_integer()}]) :: [String.t()]
  def format_trace(%{} = result, opts \\ []) do
    limit = Keyword.get(opts, :limit, :all)
    entries = if limit == :all, do: result.trace, else: Enum.take(result.trace, limit)
    Enum.map(entries, &format_line/1)
  end

  @doc "Format one event-log entry as a text line."
  @spec format_line(map()) :: String.t()
  def format_line(%{kind: :increment, t: t, from: from, amount: amount}) do
    "T=#{t} node #{from} wrote +#{amount}"
  end

  def format_line(%{kind: kind, t: t, from: from, to: to}) when is_integer(to) do
    "T=#{t} #{from} -> #{to} #{label(kind)}"
  end

  def format_line(%{kind: kind, t: t, from: from}) do
    "T=#{t} node #{from} #{label(kind)}"
  end

  @doc "Format a determinism report as a text block."
  @spec format_determinism(map()) :: String.t()
  def format_determinism(%{} = report) do
    [
      "Determinism (two replays)",
      "  convergence_time equal = #{report.convergence_time_equal}",
      "  trace equal            = #{report.trace_equal}",
      "  history equal          = #{report.history_equal}"
    ]
    |> Enum.join("\n")
  end

  @doc "Build a JSON-safe map from a result map."
  @spec to_json_map(map()) :: map()
  def to_json_map(%{} = result) do
    %{
      "scenario" => %{
        "id" => Atom.to_string(result.scenario.id),
        "name" => result.scenario.name,
        "description" => result.scenario.description,
        "seed" => result.scenario.seed,
        "mode" => Atom.to_string(result.scenario.mode)
      },
      "status" => Atom.to_string(result.status),
      "clock" => result.clock,
      "steps" => result.steps,
      "hops" => result.hops,
      "delivered" => result.delivered,
      "dropped" => result.dropped,
      "reached" => result.reached,
      "total" => result.total,
      "convergence_time" => result.convergence_time,
      "counter_total" => result.counter_total,
      "history" => Enum.map(result.history, &history_point_json/1),
      "trace" => Enum.map(result.trace, &entry_json/1)
    }
  end

  # ---------------------------------------------------------------------------
  # internals
  # ---------------------------------------------------------------------------

  defp run_scenario(scenario, opts) do
    steps = Keyword.get(opts, :steps, :all)
    batch = Keyword.get(opts, :batch, 100)
    budget = Keyword.get(opts, :budget, 20_000)

    state = Core.new(scenario, log_size: :infinity, history_size: 1000)
    state = Core.command(state, {:set_status, :running})
    {final, _processed} = drive(state, steps, batch, budget)
    result(final)
  end

  defp drive(state, steps, batch, budget) do
    iterations = if is_integer(steps), do: div(steps, batch) + 2, else: budget

    Enum.reduce_while(1..iterations//1, {state, 0}, fn _, {acc, processed} ->
      cond do
        acc.status in [:converged, :exhausted] ->
          {:halt, {acc, processed}}

        is_integer(steps) and processed >= steps ->
          {:halt, {acc, processed}}

        true ->
          max_events = if is_integer(steps), do: min(batch, steps - processed), else: batch
          {acc, count} = Core.step(acc, max_events)
          {:cont, {acc, processed + count}}
      end
    end)
  end

  defp result(state) do
    %{
      scenario: %{
        id: state.scenario.id,
        name: state.scenario.name,
        description: state.scenario.description,
        seed: state.scenario.seed,
        mode: state.mode
      },
      status: state.status,
      clock: state.clock,
      steps: state.steps,
      hops: state.hops,
      delivered: state.delivered,
      dropped: state.dropped,
      total: map_size(state.nodes),
      reached: MapSet.size(state.informed),
      convergence_time: state.convergence_time,
      counter_total: if(state.mode == :counter, do: state.increments_total, else: nil),
      trace: Enum.reverse(state.event_log),
      history: Enum.reverse(state.history)
    }
  end

  defp decode_source(source) do
    cond do
      File.regular?(source) ->
        case File.read(source) do
          {:ok, json} -> ScenarioCodec.decode(json)
          {:error, reason} -> {:error, {:read_failed, source, reason}}
        end

      looks_like_json?(source) ->
        ScenarioCodec.decode(source)

      true ->
        {:error, {:unknown_scenario, source}}
    end
  end

  defp looks_like_json?(source), do: String.starts_with?(String.trim(source), "{")

  defp lookup_catalog(name) do
    case Enum.find(Scenarios.catalog(), fn s ->
           Atom.to_string(s.id) == name or s.name == name
         end) do
      nil -> :error
      scenario -> {:ok, scenario}
    end
  end

  defp label(:deliver), do: "delivered"
  defp label(:dropped_partition), do: "dropped (partition)"
  defp label(:dropped_loss), do: "dropped (loss)"
  defp label(:crashed), do: "crashed"
  defp label(:restarted), do: "restarted"
  defp label(_), do: "event"

  defp format_time(nil), do: "--"
  defp format_time(t) when t < 1000, do: "#{t} ms"
  defp format_time(t), do: "#{Float.round(t / 1000, 2)} s"

  defp history_point_json(point) do
    %{
      "t" => point.t,
      "informed" => point.informed,
      "total" => point.total,
      "steps" => point.steps
    }
  end

  defp entry_json(%{kind: kind, t: t, from: from, to: to} = entry) do
    base = %{
      "t" => t,
      "kind" => Atom.to_string(kind),
      "from" => from,
      "to" => to,
      "partition" => Map.get(entry, :partition, false)
    }

    if kind == :increment, do: Map.put(base, "amount", entry.amount), else: base
  end
end
