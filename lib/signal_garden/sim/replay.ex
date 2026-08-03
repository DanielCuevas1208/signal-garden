defmodule SignalGarden.Sim.Replay do
  @moduledoc """
  Headless, deterministic replay of a Signal Garden scenario.

  Replay drives the pure `SignalGarden.Sim.Core` to completion with no
  animation loop and no browser. Two replays of the same scenario produce the
  same summary, the same event trace, and the same convergence history. The
  `mix signal_garden.replay` task builds on this module.

  A replay returns a `%Replay{}` struct with three views of one run:

    * `summary` - a compact map with status, convergence time, and counters
    * `trace` - the full event log in chronological order
    * `history` - the informed-count curve over logical time

  Use `replay/2` to load a built-in scenario or a scenario file by name.
  Use `run/1` to replay a scenario struct you already hold. Use `verify/1`
  to prove that every built-in scenario replays identically twice.
  """

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario, ScenarioCodec}

  @burst 200
  @budget 5_000

  @type outcome :: :converged | :exhausted | :timeout

  @type summary :: %{
          scenario: String.t(),
          id: atom(),
          mode: atom(),
          status: atom(),
          outcome: outcome(),
          nodes: pos_integer(),
          clock: non_neg_integer(),
          convergence_time: non_neg_integer() | nil,
          hops: non_neg_integer(),
          delivered: non_neg_integer(),
          dropped: non_neg_integer(),
          steps: non_neg_integer(),
          counter_total: non_neg_integer(),
          counter_writes: non_neg_integer()
        }

  @type t :: %__MODULE__{
          scenario: Scenario.t(),
          summary: summary(),
          trace: [map()],
          history: [map()]
        }

  @derive {Inspect, except: [:trace, :history]}
  defstruct scenario: nil, summary: %{}, trace: [], history: []

  # ---------------------------------------------------------------------------
  # replay
  # ---------------------------------------------------------------------------

  @doc """
  Replay a scenario by catalog id, name, or file path.

  A path that exists on disk is decoded as a scenario file. Anything else is
  matched against the built-in catalog, so `"ring"`, `:ring`, and `"ring.json"`
  all replay the ring scenario. Options:

    * `:seed` - override the simulation seed before running
  """
  @spec replay(atom() | String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def replay(target, opts \\ []) do
    with {:ok, scenario} <- resolve(target),
         {:ok, scenario} <- apply_seed(scenario, opts) do
      {:ok, run(scenario)}
    end
  end

  @doc "Replay a scenario struct to completion."
  @spec run(Scenario.t()) :: t()
  def run(%Scenario{} = scenario) do
    state =
      Core.new(scenario, log_size: :infinity)
      |> Core.command({:set_status, :running})
      |> drive()

    %__MODULE__{
      scenario: scenario,
      summary: summarize(state),
      trace: Enum.reverse(state.event_log),
      history: state.history
    }
  end

  @doc "Replay every built-in catalog scenario."
  @spec run_all() :: [t()]
  def run_all do
    Enum.map(Scenarios.catalog(), &run/1)
  end

  @doc "Resolve a catalog id or file path into a scenario struct."
  @spec resolve(atom() | String.t()) :: {:ok, Scenario.t()} | {:error, term()}
  def resolve(id) when is_atom(id) do
    case Scenarios.fetch(id) do
      nil -> {:error, {:unknown_scenario, id}}
      scenario -> {:ok, scenario}
    end
  end

  def resolve(target) when is_binary(target) do
    if File.regular?(target) do
      resolve_file(target)
    else
      resolve_name(target)
    end
  end

  @doc "Return the built-in catalog as a lightweight list for the CLI."
  @spec list_catalog() :: [map()]
  def list_catalog do
    Enum.map(Scenarios.catalog(), fn scenario ->
      %{
        id: scenario.id,
        name: scenario.name,
        description: scenario.description,
        nodes: length(scenario.topology.nodes),
        mode: scenario.mode
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # determinism
  # ---------------------------------------------------------------------------

  @doc """
  Replay every built-in scenario twice and compare the runs.

  Returns a report with one entry per scenario and `all_match`. The check is
  strong: it compares the summary, the full event trace, and the convergence
  history of the two runs.
  """
  @spec verify(keyword()) :: %{all_match: boolean(), results: [map()]}
  def verify(opts \\ []) do
    scenarios = scenarios_with_seed(opts)

    results =
      Enum.map(scenarios, fn scenario ->
        a = run(scenario)
        b = run(scenario)

        %{
          scenario: scenario.id,
          name: scenario.name,
          match: a.summary == b.summary and a.trace == b.trace and a.history == b.history,
          summary: a.summary
        }
      end)

    %{all_match: Enum.all?(results, & &1.match), results: results}
  end

  # ---------------------------------------------------------------------------
  # rendering
  # ---------------------------------------------------------------------------

  @doc "Render replay summaries as an aligned table."
  @spec format_summary_table([t()]) :: String.t()
  def format_summary_table(replays) do
    columns = summary_columns()
    header = render_row(columns, nil)
    rows = Enum.map(replays, &render_row(columns, &1.summary))
    Enum.join([header | rows], "\n")
  end

  @doc "Render one replay's event trace as aligned lines."
  @spec format_trace(t(), :all | pos_integer()) :: String.t()
  def format_trace(%__MODULE__{trace: trace}, limit \\ :all) do
    columns = trace_columns()
    shown = if limit == :all, do: trace, else: Enum.take(trace, limit)
    header = render_row(columns, nil)
    rows = Enum.map(shown, &render_row(columns, &1))

    rows =
      if is_integer(limit) and length(trace) > limit do
        rows ++ ["... #{length(trace) - limit} more events"]
      else
        rows
      end

    Enum.join([header | rows], "\n")
  end

  @doc "Render a determinism verification report."
  @spec format_verify(%{all_match: boolean(), results: [map()]}) :: String.t()
  def format_verify(%{all_match: all_match, results: results}) do
    lines =
      Enum.map(results, fn result ->
        state = if result.match, do: "deterministic", else: "MISMATCH"
        String.pad_trailing(Atom.to_string(result.scenario), 20) <> state
      end)

    summary =
      if all_match, do: "all scenarios deterministic = true", else: "determinism check FAILED"

    Enum.join(lines ++ [summary], "\n")
  end

  @doc "Encode a replay or a list of replays as pretty JSON."
  @spec to_json(t() | [t()]) :: String.t()
  def to_json(%__MODULE__{} = replay), do: replay |> to_map() |> Jason.encode!(pretty: true)

  def to_json(replays) when is_list(replays) do
    Enum.map(replays, &to_map/1) |> Jason.encode!(pretty: true)
  end

  @doc "Encode a determinism verification report as pretty JSON."
  @spec verify_json(%{all_match: boolean(), results: [map()]}) :: String.t()
  def verify_json(%{all_match: all_match, results: results}) do
    %{
      all_match: all_match,
      scenarios:
        Enum.map(results, fn result ->
          %{
            scenario: result.scenario,
            name: result.name,
            match: result.match,
            summary: result.summary
          }
        end)
    }
    |> Jason.encode!(pretty: true)
  end

  # ---------------------------------------------------------------------------
  # internals
  # ---------------------------------------------------------------------------

  defp drive(state) do
    Enum.reduce_while(1..@budget//1, state, fn _, acc ->
      {acc, _} = Core.step(acc, @burst)

      if acc.status in [:converged, :exhausted] do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end

  defp summarize(state) do
    %{
      scenario: state.scenario.name,
      id: state.scenario.id,
      mode: state.mode,
      status: state.status,
      outcome: outcome(state.status),
      nodes: map_size(state.nodes),
      clock: state.clock,
      convergence_time: state.convergence_time,
      hops: state.hops,
      delivered: state.delivered,
      dropped: state.dropped,
      steps: state.steps,
      counter_total: state.increments_total,
      counter_writes: state.increments_issued
    }
  end

  defp outcome(status) when status in [:converged, :exhausted], do: status
  defp outcome(_status), do: :timeout

  defp resolve_file(path) do
    with {:ok, json} <- File.read(path),
         {:ok, scenario} <- ScenarioCodec.decode(json) do
      {:ok, scenario}
    else
      {:error, %File.Error{reason: reason}} -> {:error, {:read_file, reason}}
      {:error, reason} -> {:error, {:invalid_scenario_file, reason}}
    end
  end

  defp resolve_name(name) do
    target = name |> String.trim() |> String.trim_trailing(".json")

    case Enum.find(Scenarios.catalog(), &(Atom.to_string(&1.id) == target)) do
      nil -> {:error, {:unknown_target, name}}
      scenario -> {:ok, scenario}
    end
  end

  defp apply_seed(%Scenario{} = scenario, opts) do
    case Keyword.get(opts, :seed) do
      nil ->
        {:ok, scenario}

      seed when is_integer(seed) and seed >= 0 ->
        {:ok, %Scenario{scenario | seed: seed}}

      _ ->
        {:error, :invalid_seed}
    end
  end

  defp scenarios_with_seed(opts) do
    case Keyword.get(opts, :seed) do
      nil ->
        Scenarios.catalog()

      seed when is_integer(seed) and seed >= 0 ->
        Enum.map(Scenarios.catalog(), fn %Scenario{} = scenario ->
          %Scenario{scenario | seed: seed}
        end)

      _ ->
        Scenarios.catalog()
    end
  end

  defp to_map(%__MODULE__{} = replay) do
    %{
      scenario: scenario_map(replay.scenario),
      summary: replay.summary,
      trace: replay.trace,
      history: replay.history
    }
  end

  defp scenario_map(%Scenario{} = scenario) do
    %{
      id: scenario.id,
      name: scenario.name,
      description: scenario.description,
      seed: scenario.seed,
      origin: scenario.origin,
      mode: scenario.mode,
      nodes: length(scenario.topology.nodes),
      edges: length(scenario.topology.edges),
      delay_ms: encode_delay(scenario.delay_ms),
      drop_prob: scenario.drop_prob,
      gossip_interval_ms: scenario.gossip_interval_ms
    }
  end

  defp encode_delay({lo, hi}), do: [lo, hi]
  defp encode_delay(value) when is_integer(value), do: value

  defp render_row(columns, nil) do
    columns
    |> Enum.map(fn {title, _get, align, width} -> pad(title, width, align) end)
    |> Enum.join(" ")
    |> String.trim_trailing()
  end

  defp render_row(columns, values) when is_map(values) do
    columns
    |> Enum.map(fn {_title, get, align, width} -> pad(get.(values), width, align) end)
    |> Enum.join(" ")
    |> String.trim_trailing()
  end

  defp pad(value, width, :left), do: value |> to_string() |> String.pad_trailing(width)
  defp pad(value, width, :right), do: value |> to_string() |> String.pad_leading(width)

  defp summary_columns do
    [
      {"scenario", & &1.scenario, :left, 20},
      {"nodes", & &1.nodes, :right, 6},
      {"status", &Atom.to_string(&1.status), :left, 12},
      {"t(ms)", &(&1.convergence_time || "-"), :right, 10},
      {"hops", & &1.hops, :right, 6},
      {"delivered", & &1.delivered, :right, 10},
      {"dropped", & &1.dropped, :right, 8},
      {"steps", & &1.steps, :right, 6}
    ]
  end

  defp trace_columns do
    [
      {"t", & &1.t, :right, 7},
      {"kind", &kind_label(&1.kind), :left, 18},
      {"from", &node_label(&1.from), :right, 5},
      {"to", &node_label(&1.to), :right, 5},
      {"partition", & &1.partition, :left, 9},
      {"amount", &(&1[:amount] || ""), :right, 6}
    ]
  end

  defp kind_label(:deliver), do: "deliver"
  defp kind_label(:dropped_partition), do: "dropped-partition"
  defp kind_label(:dropped_loss), do: "dropped-loss"
  defp kind_label(:crashed), do: "crashed"
  defp kind_label(:restarted), do: "restarted"
  defp kind_label(:increment), do: "increment"
  defp kind_label(other), do: Atom.to_string(other)

  defp node_label(nil), do: "-"
  defp node_label(node), do: to_string(node)
end
