defmodule Mix.Tasks.SignalGarden.Replay do
  use Mix.Task

  alias SignalGarden.Sim.{Replay, ScenarioCodec}
  alias SignalGarden.Scenarios

  @shortdoc "Run scenarios from the CLI and print a trace"

  @moduledoc """
  Run scenarios from the command line without a browser.

  The task drives the deterministic core to completion. It prints a summary
  table by default. Use flags to print a full event trace or JSON.

  ## Examples

      # Run every built-in scenario and check determinism.
      mix signal_garden.replay --check

      # Run one built-in scenario.
      mix signal_garden.replay ring

      # Run a scenario file exported from the control room.
      mix signal_garden.replay path/to/scenario.json

      # Print the full event trace.
      mix signal_garden.replay counter --trace

      # Print machine-readable JSON.
      mix signal_garden.replay lossy --json

      # Override the seed and cap the event budget.
      mix signal_garden.replay ring --seed 42 --steps 5000

  ## Flags

    * `--json` - print JSON instead of text
    * `--trace` - print the full event trace
    * `--check` - run the scenario twice and report determinism
    * `--steps N` - stop after N event batches of 200 events
    * `--seed N` - override the scenario seed
  """

  @switches [json: :boolean, trace: :boolean, check: :boolean, steps: :integer, seed: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown arguments: #{Enum.join(invalid, ", ")}")
    end

    case positional do
      [] -> run_catalog(opts)
      [target] -> run_one(target, opts)
      many -> Mix.raise("Replay accepts one scenario, got: #{Enum.join(many, ", ")}")
    end
  end

  # ---------------------------------------------------------------------------
  # catalog mode
  # ---------------------------------------------------------------------------

  defp run_catalog(opts) do
    scenarios = Scenarios.catalog()

    reports =
      Enum.map(scenarios, fn scenario ->
        run_with_reports(scenario, opts)
      end)

    cond do
      opts[:json] ->
        json =
          Enum.map(reports, fn {report, _checks} -> Replay.to_json(report) end)
          |> then(fn list -> "[#{Enum.join(list, ",\n")}]" end)

        IO.puts(json)

      opts[:trace] ->
        Enum.each(reports, fn {report, _checks} -> IO.puts(Replay.to_trace(report)) end)
        IO.puts("")

      true ->
        IO.puts(Replay.to_table(Enum.map(reports, &elem(&1, 0))))
    end

    if opts[:check] do
      print_checks(reports)
    end
  end

  # ---------------------------------------------------------------------------
  # single scenario mode
  # ---------------------------------------------------------------------------

  defp run_one(target, opts) do
    scenario = load_scenario(target)

    {report, checks} = run_with_reports(scenario, opts)

    cond do
      opts[:json] ->
        IO.puts(Replay.to_json(report))

      opts[:trace] ->
        IO.puts(Replay.to_trace(report))

      true ->
        IO.puts(Replay.to_table([report]))
    end

    print_checks([{report, checks}])
  end

  defp load_scenario(target) do
    cond do
      String.ends_with?(target, ".json") ->
        case File.read(target) do
          {:ok, json} ->
            case ScenarioCodec.decode(json) do
              {:ok, scenario} -> scenario
              {:error, reason} -> Mix.raise("Cannot load #{target}: #{inspect(reason)}")
            end

          {:error, reason} ->
            Mix.raise("Cannot read #{target}: #{inspect(reason)}")
        end

      true ->
        id = parse_scenario_id(target)

        case id && Scenarios.fetch(id) do
          nil ->
            available = Scenarios.catalog() |> Enum.map(& &1.id) |> Enum.join(", ")
            Mix.raise("Unknown scenario #{target}. Choose one of: #{available}")

          scenario ->
            scenario
        end
    end
  end

  defp parse_scenario_id(target) do
    case Integer.parse(target) do
      {_n, _rest} -> nil
      :error -> String.to_existing_atom(target)
    end
  rescue
    ArgumentError -> nil
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp run_with_reports(scenario, opts) do
    report =
      scenario
      |> Replay.run(replay_opts(opts))

    checks =
      if opts[:check] do
        %{
          deterministic: Replay.deterministic?(scenario, replay_opts(opts))
        }
      else
        nil
      end

    {report, checks}
  end

  defp replay_opts(opts) do
    []
    |> maybe_put(:seed, opts)
    |> maybe_put(:max_steps, opts, :steps)
  end

  defp maybe_put(acc, key, opts) do
    if Keyword.has_key?(opts, key), do: Keyword.put(acc, key, opts[key]), else: acc
  end

  defp maybe_put(acc, key, opts, from_key) do
    if Keyword.has_key?(opts, from_key), do: Keyword.put(acc, key, opts[from_key]), else: acc
  end

  defp print_checks(reports) do
    checks = Enum.reject(reports, fn {_report, check} -> is_nil(check) end)

    if checks != [] do
      IO.puts("")

      Enum.each(checks, fn {report, check} ->
        IO.puts(
          "#{String.pad_trailing(report.scenario.name, 20)} " <>
            "deterministic = #{check.deterministic}"
        )
      end)
    end
  end
end
