defmodule Mix.Tasks.SignalGarden.Replay do
  @shortdoc "Run scenarios headlessly and print a deterministic trace"

  @moduledoc """
  Replay Signal Garden scenarios from the command line.

  The task drives the pure `SignalGarden.Sim.Core` with no browser and no
  animation loop. A scenario can be a catalog id (for example `ring`) or a
  path to a scenario JSON file. Two runs of the same scenario always produce
  the same output, which makes the task a reproducible evidence tool.

  ## Usage

      mix signal_garden.replay
      mix signal_garden.replay ring
      mix signal_garden.replay priv/scenarios/ring.json
      mix signal_garden.replay --json
      mix signal_garden.replay --json ring
      mix signal_garden.replay --trace ring
      mix signal_garden.replay --check ring
      mix signal_garden.replay --check-all

  With no arguments the task prints a summary table for every catalog
  scenario. Options:

    * `--json` - print summaries as one JSON document
    * `--trace` - print the recent event trace as JSON
    * `--check` - run a scenario twice and compare the outcomes
    * `--check-all` - run a determinism check for every catalog scenario
    * `--help` - print this help text

  The exit status is zero on success. A failed determinism check or a load
  error returns a non-zero exit status, which suits scripted checks.
  """

  use Mix.Task

  alias SignalGarden.Sim.Replay

  @switches [
    json: :boolean,
    trace: :boolean,
    check: :boolean,
    check_all: :boolean,
    help: :boolean
  ]

  @aliases [h: :help]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.shell().error("Unknown options: #{Enum.join(invalid, ", ")}")
      print_help()
      exit({:shutdown, 1})
    end

    cond do
      opts[:help] ->
        print_help()

      opts[:check_all] ->
        run_check_all()

      opts[:check] ->
        run_check(positional)

      opts[:trace] ->
        run_trace(positional)

      opts[:json] ->
        run_json(positional)

      positional == [] ->
        run_table(:all)

      true ->
        run_table(positional)
    end
  rescue
    e in ArgumentError ->
      Mix.shell().error(e.message)
      exit({:shutdown, 1})
  end

  defp run_table(targets) do
    summaries =
      case targets do
        :all -> Replay.summaries()
        ids -> Enum.map(ids, &Replay.summarize(Replay.run(&1)))
      end

    IO.puts(column_row(["scenario", "nodes", "status", "t(ms)", "hops", "dropped", "steps"]))

    for summary <- summaries do
      IO.puts(summary_row(summary))
    end
  end

  defp run_json(targets) do
    summaries =
      case targets do
        [] -> Replay.summaries()
        ids -> Enum.map(ids, &Replay.summarize(Replay.run(&1)))
      end

    IO.puts(Jason.encode!(summaries, pretty: true))
  end

  defp run_trace(targets) do
    trace =
      case targets do
        [target | _] -> Replay.event_trace(target)
        [] -> Replay.event_trace(:line)
      end

    IO.puts(Jason.encode!(trace, pretty: true))
  end

  defp run_check(targets) do
    checks =
      case targets do
        [target | _] -> [Replay.determinism_check(target)]
        [] -> [Replay.determinism_check(:line)]
      end

    run_check_report(checks)
  end

  defp run_check_all do
    run_check_report(Replay.determinism_check_all())
  end

  defp run_check_report(checks) do
    failures =
      Enum.reduce(checks, [], fn check, acc ->
        mismatched =
          for {field, value} <- check,
              field not in [:scenario, :id] and value == false,
              do: field

        if mismatched == [] do
          IO.puts("ok      #{check.scenario} (run twice, identical)")
          acc
        else
          IO.puts("FAILED  #{check.scenario} (#{Enum.join(mismatched, ", ")})")
          [check.scenario | acc]
        end
      end)

    if failures == [] do
      :ok
    else
      Mix.shell().error("Determinism check failed for #{length(failures)} scenario(s).")
      exit({:shutdown, 1})
    end
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end

  defp column_row(headers) do
    headers
    |> Enum.with_index()
    |> Enum.map_join("", fn {header, index} -> pad(header, width_for(index)) end)
    |> String.trim_trailing()
  end

  defp summary_row(summary) do
    fields = [
      summary.scenario,
      Integer.to_string(summary.nodes),
      Atom.to_string(summary.status),
      format_time(summary.convergence_time),
      Integer.to_string(summary.hops),
      Integer.to_string(summary.dropped),
      Integer.to_string(summary.steps)
    ]

    fields
    |> Enum.with_index()
    |> Enum.map_join("", fn {value, index} -> pad(value, width_for(index)) end)
    |> String.trim_trailing()
  end

  defp width_for(0), do: 22
  defp width_for(1), do: 8
  defp width_for(2), do: 14
  defp width_for(3), do: 10
  defp width_for(4), do: 8
  defp width_for(5), do: 11
  defp width_for(_), do: 6

  defp pad(value, width), do: String.pad_trailing(value, width)

  defp format_time(nil), do: "-"
  defp format_time(value) when is_integer(value), do: Integer.to_string(value)
end
