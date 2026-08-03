defmodule Mix.Tasks.SignalGarden.Replay do
  @moduledoc """
  Replay Signal Garden scenarios from the command line.

  The task drives the pure simulation core. It never starts the browser or
  the animation loop, so two runs of the same scenario print the same bytes.

  ## Usage

      mix signal_garden.replay                # replay every catalog scenario
      mix signal_garden.replay ring           # replay one catalog scenario
      mix signal_garden.replay ring.json      # a catalog scenario by file name
      mix signal_garden.replay path/to.json   # an exported scenario file
      mix signal_garden.replay --trace ring   # append the full event trace
      mix signal_garden.replay --json ring    # print machine-readable JSON
      mix signal_garden.replay --verify       # prove determinism per scenario
      mix signal_garden.replay --list         # list the catalog
      mix signal_garden.replay ring --seed 99 # override the simulation seed
      mix signal_garden.replay --help         # show this help

  The `--json` flag prints the scenario, the summary, the full event trace,
  and the convergence history. The `--verify` flag replays every catalog
  scenario twice and exits non-zero when any run differs.
  """

  use Mix.Task

  @shortdoc "Replay Signal Garden scenarios from the command line"

  alias SignalGarden.Sim.Replay

  @switches [
    seed: :integer,
    trace: :boolean,
    json: :boolean,
    verify: :boolean,
    list: :boolean,
    help: :boolean
  ]

  @aliases [h: :help, j: :json, l: :list, t: :trace]

  @impl Mix.Task
  def run(args) do
    {opts, targets, invalid} =
      OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      invalid != [] ->
        Mix.raise("Invalid options: " <> invalid_summary(invalid))

      opts[:help] ->
        Mix.shell().info(@moduledoc)

      opts[:list] ->
        print_list()

      opts[:verify] ->
        run_verify(opts)

      true ->
        replay_targets(targets, opts)
    end
  end

  defp replay_targets(targets, opts) do
    targets =
      if targets == [] do
        Enum.map(Replay.list_catalog(), &Atom.to_string(&1.id))
      else
        targets
      end

    replays = Enum.map(targets, &replay_one(&1, opts))

    if opts[:json] do
      output =
        case replays do
          [single] -> Replay.to_json(single)
          _ -> Replay.to_json(replays)
        end

      Mix.shell().info(output)
    else
      Mix.shell().info(Replay.format_summary_table(replays))

      case replays do
        [single] ->
          if opts[:trace] do
            Mix.shell().info("")
            Mix.shell().info(Replay.format_trace(single))
          end

        _ ->
          :ok
      end
    end
  end

  defp replay_one(target, opts) do
    case Replay.replay(target, Keyword.take(opts, [:seed])) do
      {:ok, replay} ->
        replay

      {:error, {:unknown_scenario, id}} ->
        Mix.raise("Unknown scenario id: #{inspect(id)}")

      {:error, {:unknown_target, name}} ->
        Mix.raise("Unknown scenario or file: #{name}")

      {:error, {:read_file, reason}} ->
        Mix.raise("Could not read scenario file: #{reason}")

      {:error, {:invalid_scenario_file, reason}} ->
        Mix.raise("Invalid scenario file: #{inspect(reason)}")

      {:error, :invalid_seed} ->
        Mix.raise("Seed must be a non-negative integer")
    end
  end

  defp run_verify(opts) do
    report = Replay.verify(Keyword.take(opts, [:seed]))

    if opts[:json] do
      Mix.shell().info(Replay.verify_json(report))
    else
      Mix.shell().info(Replay.format_verify(report))
    end

    unless report.all_match do
      Mix.raise("Determinism check failed")
    end
  end

  defp print_list do
    header = String.pad_trailing("id", 12) <> String.pad_trailing("nodes", 8) <> "name"

    rows =
      Enum.map(Replay.list_catalog(), fn scenario ->
        String.pad_trailing(Atom.to_string(scenario.id), 12) <>
          String.pad_trailing("#{scenario.nodes}", 8) <> scenario.name
      end)

    Mix.shell().info(Enum.join([header | rows], "\n"))
  end

  defp invalid_summary(invalid) do
    invalid
    |> Enum.map(fn {option, _value} -> option end)
    |> Enum.join(", ")
  end
end
