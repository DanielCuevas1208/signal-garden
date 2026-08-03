defmodule Mix.Tasks.SignalGarden.Replay do
  @moduledoc """
  Replay a scenario headlessly and print a deterministic trace.

  Accepts a catalog id, a JSON scenario file, or `all`.

      mix signal_garden.replay counter
      mix signal_garden.replay priv/scenarios/ring.json
      mix signal_garden.replay all

  Options:

    --json       print JSON instead of text
    --events N   print N trace lines (default 15, 0 hides them)
    --full       print the whole trace
    --no-check   skip the two-run determinism check
    --budget N   stop a run after N events (default 100000)
    --list       list catalog scenarios

  Exit codes:

    0  converged or replayed
    1  usage or load error
    2  the run did not converge
  """

  use Mix.Task

  @shortdoc "Run a scenario headlessly and print a deterministic trace"

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.Replay

  @switches [
    json: :boolean,
    full: :boolean,
    list: :boolean,
    check: :boolean,
    budget: :integer,
    events: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, targets} = OptionParser.parse!(args, strict: @switches)

    if opts[:list] do
      print_list()
    else
      targets = if targets == [], do: ["all"], else: targets
      exit_code = replay_targets(targets, opts)
      if exit_code != 0, do: exit({:shutdown, exit_code})
    end
  end

  defp replay_targets(targets, opts) do
    {replays, errors} =
      targets
      |> Enum.map(&resolve(&1, opts))
      |> Enum.split_with(&match?({:ok, _}, &1))

    replays = Enum.flat_map(replays, fn {:ok, list} -> list end)
    errors = Enum.map(errors, fn {:error, reason} -> reason end)

    cond do
      opts[:json] ->
        json =
          if length(replays) == 1 do
            Replay.to_json(hd(replays))
          else
            Replay.to_json(replays)
          end

        Mix.shell().info(json)

      length(replays) == 1 ->
        Mix.shell().info(Replay.format(hd(replays), format_opts(opts)))

      true ->
        Mix.shell().info(Replay.format_table(replays))
    end

    Enum.each(errors, &Mix.shell().error("error: " <> Replay.format_error(&1)))

    cond do
      errors != [] -> 1
      Enum.any?(replays, &(&1.snapshot.status != :converged)) -> 2
      true -> 0
    end
  end

  defp resolve(target, opts) do
    cond do
      target == "all" ->
        {:ok, Replay.run_all(opts)}

      file_path?(target) ->
        case Replay.run_file(target, opts) do
          {:ok, replay} -> {:ok, [replay]}
          {:error, reason} -> {:error, reason}
        end

      true ->
        case Enum.find(Scenarios.catalog(), &(Atom.to_string(&1.id) == target)) do
          nil -> {:error, {:unknown_scenario, target}}
          scenario -> {:ok, [Replay.run(scenario, opts)]}
        end
    end
  end

  defp file_path?(target) do
    Path.extname(target) == ".json" or File.exists?(target)
  end

  defp format_opts(opts) do
    [full: opts[:full] == true, trace: opts[:events] || 15]
  end

  defp print_list do
    rows =
      Enum.map(Replay.list(), fn {id, name} ->
        "  #{String.pad_trailing(Atom.to_string(id), 10)}#{name}"
      end)

    Mix.shell().info("Available scenarios:\n" <> Enum.join(rows, "\n"))
    Mix.shell().info("Pass a JSON file path to replay an imported scenario.")
  end
end
