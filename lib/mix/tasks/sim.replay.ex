defmodule Mix.Tasks.Sim.Replay do
  @moduledoc """
  Replay scenarios headlessly and print a trace.

  The task drives the deterministic core with no browser. It can replay one
  scenario or every built-in scenario, and it can verify determinism.

  ## Usage

  Replay every built-in scenario:

      mix sim.replay

  Replay one scenario by catalog id or by file path:

      mix sim.replay ring
      mix sim.replay priv/scenarios/ring.json

  Print the full event trace, or emit JSON for a script:

      mix sim.replay counter --trace
      mix sim.replay ring --json

  Verify that a scenario replays to the same state twice:

      mix sim.replay crash --check

  The command exits with a non-zero status when a target cannot be resolved
  or when a determinism check fails.
  """

  use Mix.Task

  @shortdoc "Replay scenarios headlessly and print a trace"

  alias SignalGarden.Sim.Replay

  @switches [json: :boolean, trace: :boolean, check: :boolean, max_steps: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)

    case positional do
      [] ->
        print(
          if(opts[:json],
            do: Replay.render_json(Replay.run_all(opts)),
            else: Replay.render_table(Replay.run_all(opts))
          )
        )

      [target] ->
        replay_one(target, opts)

      _many ->
        Mix.raise("Expected at most one scenario id or file path.")
    end
  end

  defp replay_one(target, opts) do
    case Replay.resolve(target) do
      {:error, reason} ->
        Mix.raise(Replay.resolve_error(reason))

      {:ok, scenario} ->
        report = Replay.run(scenario, opts)
        json? = Keyword.get(opts, :json, false)
        check? = Keyword.get(opts, :check, false)

        cond do
          json? and check? ->
            print(Replay.render_json_check(report, Replay.check(scenario, opts)))

          json? ->
            print(Replay.render_json(report))

          check? ->
            print(Replay.render(report, opts))
            checks = Replay.check(scenario, opts)
            print(Replay.render_check(checks))

            unless Enum.all?(checks, fn {_name, ok} -> ok end) do
              Mix.raise("Determinism check failed.")
            end

          true ->
            print(Replay.render(report, opts))
        end
    end
  end

  defp print(text), do: Mix.shell().info(text)
end
