defmodule Mix.Tasks.SignalGarden.Replay do
  @shortdoc "Replay a Signal Garden scenario from the CLI"
  @moduledoc """
  Replay a Signal Garden scenario headless and print a full event trace.

  The tool drives the deterministic core only. It needs no server, no
  browser, and no wall clock. Two runs of the same scenario produce the
  same trace and the same fingerprint.

  ## Usage

      mix signal_garden.replay [scenario|file] [options]

  ## Arguments

      scenario|file   A catalog id, such as `ring` or `counter`, or a path
                      to a JSON scenario file. Omit the argument to replay
                      every built-in scenario.

  ## Options

      --all          Replay every built-in scenario as a summary table.
      --check        Replay twice and confirm the traces match.
      --json         Print machine-readable JSON instead of text.
      --no-trace     Print only the summary, not the event trace.

  ## Examples

      mix signal_garden.replay ring
      mix signal_garden.replay priv/scenarios/ring.json
      mix signal_garden.replay counter --check
      mix signal_garden.replay --all
      mix signal_garden.replay --json

  The `--check` flag works with one scenario or with the whole catalog. Use
  it to confirm that a scenario is reproducible before sharing it.
  """

  use Mix.Task

  alias SignalGarden.Replay
  alias SignalGarden.Scenarios

  @switches [all: :boolean, check: :boolean, json: :boolean, trace: :boolean]
  @aliases [a: :all, c: :check, j: :json]

  @impl true
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:check] -> run_check(positional, opts)
      opts[:json] -> run_json(positional)
      opts[:all] || positional == [] -> run_all()
      true -> run_single(hd(positional), opts)
    end
  end

  defp run_single(source, opts) do
    with {:ok, scenario} <- Replay.load_source(source) do
      result = Replay.run(scenario)
      IO.puts(Replay.render(result, trace: Keyword.get(opts, :trace, true)))
    else
      {:error, reason} ->
        Mix.raise("Could not load scenario #{inspect(source)}: #{inspect(reason)}")
    end
  end

  defp run_all do
    results = Enum.map(Scenarios.catalog(), &Replay.run/1)
    IO.puts(Replay.render_summary_table(results))
  end

  defp run_check([], _opts) do
    reports = Replay.verify_all()
    IO.puts(Replay.render_verify_table(reports))

    unless Enum.all?(reports, & &1.ok) do
      Mix.raise("Determinism check failed for at least one scenario")
    end
  end

  defp run_check([source | _], _opts) do
    with {:ok, scenario} <- Replay.load_source(source) do
      case Replay.verify(scenario) do
        {:ok, result, _other} ->
          IO.puts(Replay.render_verify(result))

        {:error, %{mismatches: mismatches, a: result}} ->
          Mix.raise(
            "Determinism check FAILED for #{result.scenario.name}: mismatched #{inspect(mismatches)}"
          )
      end
    else
      {:error, reason} ->
        Mix.raise("Could not load scenario #{inspect(source)}: #{inspect(reason)}")
    end
  end

  defp run_json([]) do
    payload = Enum.map(Scenarios.catalog(), &Replay.run/1) |> Enum.map(&to_json_map/1)
    IO.puts(Jason.encode!(payload))
  end

  defp run_json([source | _]) do
    with {:ok, scenario} <- Replay.load_source(source) do
      IO.puts(Jason.encode!(to_json_map(Replay.run(scenario))))
    else
      {:error, reason} ->
        Mix.raise("Could not load scenario #{inspect(source)}: #{inspect(reason)}")
    end
  end

  defp to_json_map(%Replay{} = result) do
    %{
      scenario: result.scenario,
      status: result.status,
      clock: result.clock,
      hops: result.hops,
      delivered: result.delivered,
      dropped: result.dropped,
      steps: result.steps,
      counter_total: result.counter_total,
      counter_writes: result.counter_writes,
      events: result.events,
      history: result.history,
      fingerprint: result.fingerprint
    }
  end
end
