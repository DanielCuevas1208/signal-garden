defmodule SignalGarden.Sim.Replay do
  @moduledoc """
  Run a scenario headlessly and return a deterministic trace.

  A replay advances the pure core to a terminal state and records every
  logged event in order. It uses no engine, no browser, and no wall clock.
  Two replays of the same scenario always produce identical output.

  Use this module from code, or run the CLI task:

      mix signal_garden.replay counter

  The `Mix.Tasks.SignalGarden.Replay` task prints what this module produces.
  """

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario, ScenarioCodec}

  @max_events 100_000

  @type t :: %__MODULE__{
          scenario: Scenario.t(),
          snapshot: map(),
          trace: [map()],
          faults: [map()],
          budget_hit: boolean(),
          deterministic: boolean() | nil
        }

  @enforce_keys [:scenario, :snapshot, :trace]
  defstruct scenario: nil,
            snapshot: nil,
            trace: [],
            faults: [],
            budget_hit: false,
            deterministic: nil

  @doc """
  Replay a scenario struct or a catalog id to its terminal state.

  A `%Scenario{}` returns a `%Replay{}` directly. A catalog id returns
  `{:ok, %Replay{}}` or `{:error, {:unknown_scenario, id}}`. Set
  `check: false` to skip the two-run determinism check. Set `budget: n`
  to bound how many events a run may process.
  """
  @spec run(Scenario.t() | atom(), keyword()) :: t() | {:ok, t()} | {:error, term()}
  def run(scenario_or_id, opts \\ [])

  def run(%Scenario{} = scenario, opts) do
    budget = Keyword.get(opts, :budget, @max_events)
    replay = build_replay(scenario, budget)

    deterministic =
      if Keyword.get(opts, :check, true), do: replay == build_replay(scenario, budget)

    %{replay | deterministic: deterministic}
  end

  def run(id, opts) when is_atom(id) do
    case Scenarios.fetch(id) do
      nil -> {:error, {:unknown_scenario, id}}
      scenario -> {:ok, run(scenario, opts)}
    end
  end

  @doc """
  Replay a scenario from a JSON file.

  Returns `{:ok, %Replay{}}` or `{:error, {:file, reason}}` /
  `{:error, {:decode, reason}}`.
  """
  @spec run_file(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def run_file(path, opts \\ []) when is_binary(path) do
    with {:ok, json} <- File.read(path),
         {:ok, scenario} <- ScenarioCodec.decode(json) do
      {:ok, run(scenario, opts)}
    else
      {:error, %File.Error{reason: reason}} -> {:error, {:file, reason}}
      {:error, reason} when is_atom(reason) -> {:error, {:file, reason}}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  @doc "Replay every scenario in the catalog."
  @spec run_all(keyword()) :: [t()]
  def run_all(opts \\ []) do
    Enum.map(Scenarios.catalog(), &run(&1, opts))
  end

  @doc "List the catalog as `{id, name}` pairs."
  @spec list() :: [{atom(), String.t()}]
  def list do
    Enum.map(Scenarios.catalog(), &{&1.id, &1.name})
  end

  @doc "Print a replay as human-readable text."
  @spec format(t(), keyword()) :: String.t()
  def format(%__MODULE__{} = replay, opts \\ []) do
    trace_count = Keyword.get(opts, :trace, 15)
    full? = Keyword.get(opts, :full, false)
    s = replay.snapshot

    [
      "Signal Garden replay",
      "",
      kv("Scenario", replay.scenario.name),
      kv("Mode", Atom.to_string(replay.scenario.mode)),
      kv("Seed", Integer.to_string(replay.scenario.seed)),
      kv("Topology", replay.scenario.topology.label),
      kv("Nodes", Integer.to_string(length(replay.scenario.topology.nodes))),
      kv("Origin", "node #{replay.scenario.origin}"),
      kv("Network", network_description(replay.scenario)),
      "",
      kv("Status", status_line(replay)),
      kv("Converged", time_description(s.convergence_time)),
      kv("Steps", Integer.to_string(s.steps)),
      kv("Hops", Integer.to_string(s.hops)),
      kv("Delivered", Integer.to_string(s.delivered)),
      kv("Dropped", Integer.to_string(s.dropped)),
      kv("Coverage", "#{s.reached}/#{s.total} nodes")
    ]
    |> maybe_counter_line(s)
    |> maybe_fault_section(replay)
    |> trace_section(replay, trace_count, full?)
    |> maybe_determinism_line(replay)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  @doc "Print a set of replays as a comparison table."
  @spec format_table([t()]) :: String.t()
  def format_table(replays) when is_list(replays) do
    header = ["scenario", "mode", "nodes", "status", "t(ms)", "hops", "dropped", "steps", "det"]

    rows =
      Enum.map(replays, fn replay ->
        s = replay.snapshot
        det = if is_nil(replay.deterministic), do: "-", else: to_string(replay.deterministic)

        [
          replay.scenario.name,
          Atom.to_string(replay.scenario.mode),
          Integer.to_string(s.total),
          status_word(s.status),
          format_int(s.convergence_time),
          Integer.to_string(s.hops),
          Integer.to_string(s.dropped),
          Integer.to_string(s.steps),
          det
        ]
      end)

    render_table(header, rows)
  end

  @doc "Encode a replay or a list of replays as pretty JSON."
  @spec to_json(t() | [t()]) :: String.t()
  def to_json(%__MODULE__{} = replay), do: replay |> to_map() |> Jason.encode!(pretty: true)

  def to_json(replays) when is_list(replays) do
    replays
    |> Enum.map(&to_map/1)
    |> Jason.encode!(pretty: true)
  end

  @doc "Format an error tuple as a message."
  @spec format_error(term()) :: String.t()
  def format_error({:unknown_scenario, id}),
    do: "Unknown scenario #{inspect(id)}. Use --list to see the catalog."

  def format_error({:file, reason}), do: "Cannot read the file: #{inspect(reason)}"
  def format_error({:decode, {:invalid_json, _}}), do: "The file is not valid JSON."

  def format_error({:decode, {:unsupported_format, version}}),
    do: "Format version #{version} is not supported."

  def format_error({:decode, {:invalid_field, field}}),
    do: "The field #{inspect(field)} is invalid."

  def format_error({:decode, :missing_format}), do: "The file has no format version."
  def format_error(other), do: "Replay failed: #{inspect(other)}"

  # ---------------------------------------------------------------------------
  # replay core
  # ---------------------------------------------------------------------------

  defp build_replay(scenario, budget) do
    {final, trace} = execute(scenario, budget)

    %__MODULE__{
      scenario: scenario,
      snapshot: Core.snapshot(final),
      trace: trace,
      faults: fault_timeline(scenario, final.clock),
      budget_hit: final.status not in [:converged, :exhausted]
    }
  end

  defp execute(scenario, budget) do
    scenario
    |> Core.new()
    |> Core.command({:set_status, :running})
    |> step_to_terminal(nil, [], 0, budget)
  end

  defp step_to_terminal(state, _prev_log, trace, _processed, _budget)
       when state.status in [:converged, :exhausted] do
    {state, Enum.reverse(trace)}
  end

  defp step_to_terminal(state, _prev_log, trace, processed, budget) when processed >= budget do
    {state, Enum.reverse(trace)}
  end

  defp step_to_terminal(state, prev_log, trace, processed, budget) do
    {next, _} = Core.step(state, 1)

    case next.event_log do
      [entry | _] when next.event_log != prev_log ->
        step_to_terminal(next, next.event_log, [entry | trace], processed + 1, budget)

      _ ->
        step_to_terminal(next, prev_log, trace, processed + 1, budget)
    end
  end

  defp fault_timeline(%Scenario{fault_schedule: schedule}, clock) do
    Enum.map(schedule, fn fault ->
      %{at: fault.at, action: fault.action, label: fault.label, fired: fault.at <= clock}
    end)
  end

  # ---------------------------------------------------------------------------
  # json
  # ---------------------------------------------------------------------------

  defp to_map(%__MODULE__{} = replay) do
    s = replay.snapshot
    scenario = replay.scenario

    %{
      "scenario" => %{
        "id" => scenario.id,
        "name" => scenario.name,
        "description" => scenario.description,
        "seed" => scenario.seed,
        "mode" => scenario.mode,
        "topology" => scenario.topology.label,
        "nodes" => scenario.topology.nodes,
        "edges" => Enum.map(scenario.topology.edges, fn {a, b} -> [a, b] end),
        "origin" => scenario.origin,
        "delay_ms" => encode_delay(s.delay_ms),
        "drop_prob" => s.drop_prob,
        "gossip_interval_ms" => s.gossip_interval_ms,
        "partitions" => s.partitions
      },
      "status" => s.status,
      "convergence_time_ms" => s.convergence_time,
      "steps" => s.steps,
      "hops" => s.hops,
      "delivered" => s.delivered,
      "dropped" => s.dropped,
      "reached" => s.reached,
      "total" => s.total,
      "counter_total" => s.counter_total,
      "counter_writes" => s.counter_writes,
      "budget_hit" => replay.budget_hit,
      "deterministic" => replay.deterministic,
      "faults" => Enum.map(replay.faults, &fault_to_map/1),
      "trace" => replay.trace
    }
  end

  defp fault_to_map(fault) do
    %{"at" => fault.at, "label" => fault.label, "fired" => fault.fired}
    |> Map.merge(action_to_map(fault.action))
  end

  defp encode_delay({lo, hi}), do: [lo, hi]
  defp encode_delay(value) when is_integer(value), do: value

  defp action_to_map({:merge, :all}), do: %{"action" => "merge"}

  defp action_to_map({:assign, node, group}),
    do: %{"action" => "assign", "node" => node, "group" => group}

  defp action_to_map({:crash, node}), do: %{"action" => "crash", "node" => node}
  defp action_to_map({:restart, node}), do: %{"action" => "restart", "node" => node}

  defp action_to_map({:increment, node, amount}),
    do: %{"action" => "increment", "node" => node, "amount" => amount}

  # ---------------------------------------------------------------------------
  # formatting helpers
  # ---------------------------------------------------------------------------

  @key_width 14

  defp kv(key, value), do: String.pad_trailing(key, @key_width) <> value

  defp maybe_counter_line(lines, %{mode: :counter} = s) do
    lines ++ [kv("Counter", "#{s.counter_total} total, #{s.counter_writes} writes")]
  end

  defp maybe_counter_line(lines, _s), do: lines

  defp maybe_fault_section(lines, %{faults: []}), do: lines

  defp maybe_fault_section(lines, replay) do
    rows =
      Enum.map(replay.faults, fn fault ->
        "  T=" <>
          String.pad_leading(Integer.to_string(fault.at), 4) <>
          "  #{fault.label}#{if fault.fired, do: "", else: "  (not reached)"}"
      end)

    lines ++ ["" | ["Fault schedule" | rows]] ++ [""]
  end

  defp trace_section(lines, replay, trace_count, full?) do
    trace = replay.trace
    total = length(trace)

    shown =
      cond do
        full? -> trace
        trace_count <= 0 -> []
        true -> Enum.take(trace, -trace_count)
      end

    title =
      cond do
        full? -> "Trace (all #{total} events)"
        total == 0 -> "Trace"
        true -> "Trace (last #{length(shown)} of #{total} events)"
      end

    lines ++ ["" | [title | Enum.map(shown, &trace_line/1)]]
  end

  defp trace_line(entry) do
    case entry.kind do
      :deliver ->
        "  T=#{pad_t(entry.t)}  #{entry.from} -> #{entry.to}  delivered"

      :dropped_partition ->
        "  T=#{pad_t(entry.t)}  #{entry.from} -> #{entry.to}  dropped (partition)"

      :dropped_loss ->
        "  T=#{pad_t(entry.t)}  #{entry.from} -> #{entry.to}  dropped (loss)"

      :crashed ->
        "  T=#{pad_t(entry.t)}  node #{entry.from}  crashed"

      :restarted ->
        "  T=#{pad_t(entry.t)}  node #{entry.from}  restarted"

      :increment ->
        "  T=#{pad_t(entry.t)}  node #{entry.from}  wrote +#{entry.amount}"

      _ ->
        "  T=#{pad_t(entry.t)}  #{entry.from} -> #{entry.to}  event"
    end
  end

  defp pad_t(t), do: String.pad_leading(Integer.to_string(t), 4)

  defp maybe_determinism_line(lines, replay) do
    lines ++ [kv("Determinism", determinism_description(replay.deterministic))]
  end

  defp determinism_description(true), do: "true (two runs identical)"
  defp determinism_description(false), do: "false (two runs differ)"
  defp determinism_description(nil), do: "not checked"

  defp status_line(replay) do
    base = status_word(replay.snapshot.status)
    if replay.budget_hit, do: base <> " (event budget reached)", else: base
  end

  defp status_word(:converged), do: "converged"
  defp status_word(:exhausted), do: "stalled"
  defp status_word(:idle), do: "not converged"
  defp status_word(other), do: Atom.to_string(other)

  defp time_description(nil), do: "--"
  defp time_description(t), do: "#{t} ms"

  defp format_int(nil), do: "--"
  defp format_int(n), do: Integer.to_string(n)

  defp network_description(%Scenario{delay_ms: delay_ms} = scenario) do
    delay =
      case delay_ms do
        {lo, hi} -> "#{lo}..#{hi} ms"
        value when is_integer(value) -> "#{value} ms"
      end

    loss =
      if scenario.drop_prob > 0.0 do
        "#{round(scenario.drop_prob * 100)}% loss"
      else
        "no loss"
      end

    "#{delay}, #{loss}, gossip every #{scenario.gossip_interval_ms} ms"
  end

  defp render_table(header, rows) do
    widths =
      header
      |> Enum.with_index()
      |> Enum.map(fn {_cell, i} ->
        Enum.map([header | rows], fn row -> row |> Enum.at(i) |> String.length() end)
        |> Enum.max()
      end)

    pad_row =
      fn cells ->
        cells
        |> Enum.with_index()
        |> Enum.map(fn {cell, i} -> String.pad_trailing(cell, Enum.at(widths, i)) end)
        |> Enum.join("  ")
      end

    [pad_row.(header) | Enum.map(rows, pad_row)]
    |> Enum.join("\n")
  end
end
