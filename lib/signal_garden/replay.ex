defmodule SignalGarden.Replay do
  @moduledoc """
  Headless replay of a Signal Garden scenario.

  The replay drives the pure `SignalGarden.Sim.Core` to completion and
  captures the full event trace. It runs without the engine, the browser, or
  the wall clock. Two replays of the same scenario produce the same trace,
  the same convergence time, and the same fingerprint.

  The `Mix.Tasks.SignalGarden.Replay` task exposes this module on the command
  line:

      mix signal_garden.replay ring
      mix signal_garden.replay counter --check
      mix signal_garden.replay --all

  Use `run/2` for a single run, `verify/2` for a determinism check, and
  `load_source/1` to resolve a catalog id, a scenario struct, or a JSON file.
  """

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario, ScenarioCodec}

  @default_max_steps 200_000
  @burst 200

  defstruct scenario: nil,
            status: nil,
            clock: nil,
            hops: 0,
            delivered: 0,
            dropped: 0,
            steps: 0,
            counter_total: nil,
            counter_writes: nil,
            events: [],
            history: [],
            fingerprint: nil

  @type t :: %__MODULE__{
          scenario: map(),
          status: Core.status(),
          clock: non_neg_integer() | nil,
          hops: non_neg_integer(),
          delivered: non_neg_integer(),
          dropped: non_neg_integer(),
          steps: non_neg_integer(),
          counter_total: non_neg_integer() | nil,
          counter_writes: non_neg_integer() | nil,
          events: [map()],
          history: [map()],
          fingerprint: String.t() | nil
        }

  # ---------------------------------------------------------------------------
  # loading
  # ---------------------------------------------------------------------------

  @doc """
  Resolve a scenario source.

  Accepts a catalog id atom or string, a `%Scenario{}` struct, or a path to a
  JSON scenario file. Returns `{:ok, scenario}` or `{:error, reason}`.
  """
  @spec load_source(Scenario.t() | atom() | String.t()) ::
          {:ok, Scenario.t()} | {:error, term()}
  def load_source(%Scenario{} = scenario), do: {:ok, scenario}

  def load_source(id) when is_atom(id) do
    case Scenarios.fetch(id) do
      nil -> {:error, {:unknown_scenario, id}}
      scenario -> {:ok, scenario}
    end
  end

  def load_source(source) when is_binary(source) and source != "" do
    case catalog_id(source) do
      {:ok, scenario} -> {:ok, scenario}
      :error -> load_file(source)
    end
  end

  def load_source(_), do: {:error, :invalid_source}

  defp catalog_id(name) do
    case Enum.find(Scenarios.catalog(), fn scenario -> Atom.to_string(scenario.id) == name end) do
      nil -> :error
      scenario -> {:ok, scenario}
    end
  end

  defp load_file(path) do
    case File.read(path) do
      {:ok, json} ->
        ScenarioCodec.decode(json)

      {:error, _reason} ->
        {:error, {:file_not_found, path}}
    end
  end

  # ---------------------------------------------------------------------------
  # running
  # ---------------------------------------------------------------------------

  @doc """
  Replay a scenario to completion and collect the full trace.

  Options:

    * `:max_steps` - the largest number of events to process before giving
      up. Defaults to 200000. A permanent partition can keep a network alive
      forever, so the replay must stop somewhere.

  The status reflects where the run ended: `:converged`, `:exhausted`, or
  `:running` when the budget ran out first.
  """
  @spec run(Scenario.t(), keyword()) :: t()
  def run(%Scenario{} = scenario, opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)

    state =
      scenario
      |> Core.new(log_size: :all)
      |> Core.command({:set_status, :running})
      |> drive(max_steps)

    build_result(state)
  end

  @doc """
  Replay the same scenario twice and compare the results.

  Returns `{:ok, a, b}` when both runs match. Returns
  `{:error, %{a: a, b: b, mismatches: keys}}` when they differ, where
  `keys` lists the fields that changed.
  """
  @spec verify(Scenario.t(), keyword()) :: {:ok, t(), t()} | {:error, map()}
  def verify(%Scenario{} = scenario, opts \\ []) do
    a = run(scenario, opts)
    b = run(scenario, opts)

    mismatches =
      [
        clock: a.clock == b.clock,
        hops: a.hops == b.hops,
        delivered: a.delivered == b.delivered,
        dropped: a.dropped == b.dropped,
        steps: a.steps == b.steps,
        counter_total: a.counter_total == b.counter_total,
        events: a.events == b.events,
        fingerprint: a.fingerprint == b.fingerprint
      ]
      |> Enum.reject(fn {_key, match?} -> match? end)
      |> Enum.map(fn {key, _} -> key end)

    if mismatches == [] do
      {:ok, a, b}
    else
      {:error, %{a: a, b: b, mismatches: mismatches}}
    end
  end

  @doc "Verify every built-in scenario and return one report per run."
  @spec verify_all([Scenario.t()] | nil, keyword()) :: [map()]
  def verify_all(scenarios \\ nil, opts \\ []) do
    (scenarios || Scenarios.catalog())
    |> Enum.map(fn scenario ->
      case verify(scenario, opts) do
        {:ok, result, _other} ->
          %{
            name: result.scenario.name,
            ok: true,
            clock: result.clock,
            events: length(result.events),
            fingerprint: result.fingerprint
          }

        {:error, %{mismatches: mismatches, a: result}} ->
          %{
            name: result.scenario.name,
            ok: false,
            mismatches: mismatches,
            clock: result.clock,
            events: length(result.events),
            fingerprint: nil
          }
      end
    end)
  end

  @doc "A stable content hash of a completed replay."
  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = result) do
    :crypto.hash(:sha256, :erlang.term_to_binary(canonical(result)))
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # rendering
  # ---------------------------------------------------------------------------

  @doc "Render a completed replay as text for the CLI."
  @spec render(t(), keyword()) :: String.t()
  def render(%__MODULE__{} = result, opts \\ []) do
    trace? = Keyword.get(opts, :trace, true)

    [
      summary_block(result),
      if(trace?, do: trace_block(result))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc "Render a list of replay results as a summary table."
  @spec render_summary_table(t() | [t()]) :: String.t()
  def render_summary_table(%__MODULE__{} = single), do: render_summary_table([single])

  def render_summary_table(results) when is_list(results) do
    header =
      String.pad_trailing("scenario", 20) <>
        String.pad_trailing("nodes", 7) <>
        String.pad_trailing("status", 13) <>
        String.pad_trailing("t(ms)", 10) <>
        String.pad_trailing("hops", 7) <>
        String.pad_trailing("dropped", 10) <>
        "steps"

    rows =
      Enum.map(results, fn result ->
        String.pad_trailing(result.scenario.name, 20) <>
          String.pad_trailing("#{result.scenario.nodes}", 7) <>
          String.pad_trailing("#{result.status}", 13) <>
          String.pad_trailing("#{result.clock || 0}", 10) <>
          String.pad_trailing("#{result.hops}", 7) <>
          String.pad_trailing("#{result.dropped}", 10) <>
          "#{result.steps}"
      end)

    Enum.join([header | rows], "\n")
  end

  @doc "Render a verified single replay as a determinism report."
  @spec render_verify(t()) :: String.t()
  def render_verify(%__MODULE__{} = result) do
    """
    #{result.scenario.name}: deterministic. Two runs produced identical traces.
      Converged at: #{result.clock} ms   Events: #{length(result.events)}   Steps: #{result.steps}
      Fingerprint: #{result.fingerprint}
    """
    |> String.trim_trailing()
  end

  @doc "Render verification reports for several scenarios."
  @spec render_verify_table([map()]) :: String.t()
  def render_verify_table(reports) when is_list(reports) do
    header =
      String.pad_trailing("scenario", 20) <>
        String.pad_trailing("deterministic", 15) <>
        String.pad_trailing("t(ms)", 10) <>
        String.pad_trailing("events", 8) <>
        "fingerprint"

    rows =
      Enum.map(reports, fn report ->
        ok = if report.ok, do: "yes", else: "NO"
        fingerprint = report.fingerprint || "failed"

        String.pad_trailing(report.name, 20) <>
          String.pad_trailing(ok, 15) <>
          String.pad_trailing("#{report.clock || 0}", 10) <>
          String.pad_trailing("#{report.events}", 8) <>
          fingerprint
      end)

    Enum.join([header | rows], "\n")
  end

  @doc "Format one trace event as a single line."
  @spec format_event(map()) :: String.t()
  def format_event(%{kind: kind} = event) do
    time = String.pad_leading("#{event.t}", 6)

    case kind do
      :deliver ->
        "t=#{time}  send       #{event.from} -> #{event.to}"

      :dropped_partition ->
        "t=#{time}  partition  #{event.from} -x- #{event.to}"

      :dropped_loss ->
        "t=#{time}  lost       #{event.from} -x- #{event.to}"

      :crashed ->
        "t=#{time}  crashed    #{event.from}"

      :restarted ->
        "t=#{time}  restarted  #{event.from}"

      :increment ->
        "t=#{time}  write      #{event.from} +#{event.amount}"
    end
  end

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  defp drive(state, max_steps) do
    Enum.reduce_while(1..div(max_steps, @burst)//1, state, fn _, acc ->
      {acc, _processed} = Core.step(acc, @burst)

      if acc.status in [:converged, :exhausted] do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end

  defp build_result(%Core{} = state) do
    result = %__MODULE__{
      scenario: %{
        id: state.scenario.id,
        name: state.scenario.name,
        mode: state.mode,
        seed: state.scenario.seed,
        origin: state.origin,
        nodes: map_size(state.nodes),
        edges: length(state.topology.edges)
      },
      status: state.status,
      clock: state.convergence_time,
      hops: state.hops,
      delivered: state.delivered,
      dropped: state.dropped,
      steps: state.steps,
      counter_total: if(state.mode == :counter, do: state.increments_total, else: nil),
      counter_writes: if(state.mode == :counter, do: state.increments_issued, else: nil),
      events: Enum.reverse(state.event_log),
      history: state.history,
      fingerprint: nil
    }

    %{result | fingerprint: fingerprint(result)}
  end

  defp canonical(%__MODULE__{} = result) do
    scenario = result.scenario |> Enum.sort() |> List.to_tuple()

    events =
      Enum.map(result.events, fn event ->
        {event.t, event.kind, event.from, event.to, Map.get(event, :partition),
         Map.get(event, :amount)}
      end)

    {scenario, result.status, result.clock, result.hops, result.delivered, result.dropped,
     result.steps, result.counter_total, result.counter_writes, events}
  end

  defp summary_block(%__MODULE__{} = result) do
    mode = if result.scenario.mode == :counter, do: "counter", else: "rumor"

    counter =
      if result.counter_total != nil do
        "   Counter total: #{result.counter_total} in #{result.counter_writes} writes"
      else
        ""
      end

    """
    Scenario: #{result.scenario.name}  (#{result.scenario.nodes} nodes, seed #{result.scenario.seed}, #{mode})
    Status: #{result.status}#{if result.clock, do: "   Converged at #{result.clock} ms"}#{counter}
    Hops: #{result.hops}   Delivered: #{result.delivered}   Dropped: #{result.dropped}   Steps: #{result.steps}
    Fingerprint: #{result.fingerprint}
    """
    |> String.trim_trailing()
  end

  defp trace_block(%__MODULE__{} = result) do
    header = "\nEvent trace (#{length(result.events)} entries)"

    header <>
      "\n" <>
      Enum.map_join(result.events, "\n", &format_event/1)
  end
end
