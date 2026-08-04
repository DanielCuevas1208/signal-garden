defmodule SignalGarden.Sim.Replay do
  @moduledoc """
  Drive scenarios to completion with no browser and no animation loop.

  The headless replay tool is the evidence side of Signal Garden. It runs a
  scenario through the pure `SignalGarden.Sim.Core` and reports the outcome.
  The same scenario always produces the same summary and the same event trace,
  so a machine can prove a run is reproducible.

  The `Mix.Tasks.SignalGarden.Replay` task wraps this module for the command
  line. The module itself stays free of `IO`, `Mix`, and process state, which
  keeps it fast and testable.
  """

  alias SignalGarden.{Scenarios, Sim.Core, Sim.Scenario}

  @budget_events 200
  @max_batches 10_000

  @type summary :: %{
          scenario: String.t(),
          id: atom(),
          mode: Core.mode(),
          nodes: pos_integer(),
          status: Core.status(),
          convergence_time: non_neg_integer() | nil,
          hops: non_neg_integer(),
          dropped: non_neg_integer(),
          steps: non_neg_integer(),
          counter_total: non_neg_integer()
        }

  @type event :: map()

  @type check :: %{
          scenario: String.t(),
          id: atom(),
          convergence_time: boolean(),
          hops: boolean(),
          dropped: boolean(),
          steps: boolean(),
          history: boolean(),
          event_log: boolean()
        }

  @doc """
  Run a scenario to completion and return the final core state.

  Accepts a `%Scenario{}` struct, a catalog id atom or string (for example
  `:ring` or `"ring"`), or a path to a scenario file. A string that does not
  match a catalog id is treated as a file path.
  """
  @spec run(Scenario.t() | atom() | String.t() | Path.t()) :: Core.t()
  def run(%Scenario{} = scenario), do: run_to_completion(scenario)

  def run(id) when is_atom(id), do: run(fetch_or_raise(id))

  def run(target) when is_binary(target) do
    scenario = resolve_or_raise(target)
    run(scenario)
  end

  @doc "Run every catalog scenario to completion."
  @spec run_all() :: [Core.t()]
  def run_all, do: Enum.map(Scenarios.catalog(), &run_to_completion/1)

  @doc "Build a summary map from a completed core state."
  @spec summarize(Core.t()) :: summary()
  def summarize(%Core{} = core) do
    %{
      scenario: core.scenario.name,
      id: core.scenario.id,
      mode: core.scenario.mode,
      nodes: map_size(core.nodes),
      status: core.status,
      convergence_time: core.convergence_time,
      hops: core.hops,
      dropped: core.dropped,
      steps: core.steps,
      counter_total: core.increments_total
    }
  end

  @doc "Summaries for every catalog scenario, in catalog order."
  @spec summaries() :: [summary()]
  def summaries, do: Enum.map(run_all(), &summarize/1)

  @doc """
  The recent event trace for a scenario, oldest first.

  The core keeps a rolling window of the most recent events. Each event is a
  plain map with a `t` clock and a `kind`. Fault events also carry the node
  and the increment amount where relevant.
  """
  @spec event_trace(Scenario.t() | atom() | String.t() | Path.t()) :: [event()]
  def event_trace(target), do: target |> run() |> recent_trace()

  @doc """
  Run a scenario twice and compare the outcomes.

  Returns a map with one boolean per compared field. A false field means the
  run is not reproducible, which is a bug in the core or the scenario.
  """
  @spec determinism_check(Scenario.t() | atom() | String.t()) :: check()
  def determinism_check(%Scenario{} = scenario) do
    a = run_to_completion(scenario)
    b = run_to_completion(scenario)

    %{
      scenario: scenario.name,
      id: scenario.id,
      convergence_time: a.convergence_time == b.convergence_time,
      hops: a.hops == b.hops,
      dropped: a.dropped == b.dropped,
      steps: a.steps == b.steps,
      history: a.history == b.history,
      event_log: a.event_log == b.event_log
    }
  end

  def determinism_check(id) when is_atom(id), do: determinism_check(fetch(id))

  def determinism_check(target) when is_binary(target) do
    determinism_check(resolve_or_raise(target))
  end

  @doc "Run a determinism check for every catalog scenario."
  @spec determinism_check_all() :: [check()]
  def determinism_check_all, do: Enum.map(Scenarios.catalog(), &determinism_check/1)

  @doc "Read and decode a scenario file as a tagged result."
  @spec scenario_from_file(Path.t()) :: {:ok, Scenario.t()} | {:error, term()}
  def scenario_from_file(path) when is_binary(path) do
    with {:ok, json} <- File.read(path),
         {:ok, scenario} <- SignalGarden.Sim.ScenarioCodec.decode(json) do
      {:ok, scenario}
    end
  end

  defp fetch_or_raise(id) do
    case Scenarios.fetch(id) do
      nil -> raise ArgumentError, "unknown scenario id: #{inspect(id)}"
      scenario -> scenario
    end
  end

  defp resolve_or_raise(target) do
    case id_from_string(target) do
      {:ok, scenario} ->
        scenario

      :error ->
        case scenario_from_file(target) do
          {:ok, scenario} ->
            scenario

          {:error, :enoent} ->
            raise ArgumentError,
                  "not a catalog id and the file does not exist: #{inspect(target)}"

          {:error, reason} ->
            raise ArgumentError, "cannot load scenario: #{format_error(reason)}"
        end
    end
  end

  defp id_from_string(target) do
    atom = String.to_existing_atom(target)

    case Scenarios.fetch(atom) do
      nil -> :error
      scenario -> {:ok, scenario}
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Load a scenario by id, raising for unknown ids."
  @spec fetch(atom()) :: Scenario.t()
  def fetch(id) when is_atom(id), do: fetch_or_raise(id)

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  defp run_to_completion(%Scenario{} = scenario) do
    scenario
    |> Core.new()
    |> Core.command({:set_status, :running})
    |> then(fn state ->
      Enum.reduce_while(1..@max_batches//1, state, fn _, acc ->
        {acc, _} = Core.step(acc, @budget_events)

        if acc.status in [:converged, :exhausted] do
          {:halt, acc}
        else
          {:cont, acc}
        end
      end)
    end)
  end

  defp recent_trace(%Core{} = core) do
    core.event_log
    |> Enum.reverse()
    |> Enum.map(&normalize_event/1)
  end

  defp normalize_event(%{kind: kind} = entry) do
    base = %{t: entry.t, kind: kind, from: entry.from, to: entry.to, partition: entry.partition}

    case kind do
      :increment -> Map.put(base, :amount, entry.amount)
      _ -> base
    end
  end

  defp format_error(%File.Error{reason: reason, path: path}), do: "#{reason}: #{path}"
  defp format_error({:invalid_json, _}), do: "the file is not valid JSON"
  defp format_error({:missing_format, _}), do: "the file is missing a format version"
  defp format_error({:unsupported_format, version}), do: "unsupported format version #{version}"
  defp format_error(reason), do: inspect(reason)
end
