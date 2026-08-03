defmodule Mix.Tasks.Sg.Run do
  @moduledoc """
  Replay a scenario headlessly and print its trace.

  The task drives the deterministic core with no animation loop and no
  browser. Two invocations of the same scenario print the same bytes, so the
  task doubles as a reproducibility check for a given seed and fault
  schedule.

  ## Examples

      mix sg.run
      mix sg.run ring
      mix sg.run --file ring.json
      mix sg.run --list
      mix sg.run --all
      mix sg.run counter --format json
      mix sg.run lossy --events 15

  ## Options

    * `--list` - list the catalog scenarios and exit.
    * `--all` - replay every catalog scenario and print one row per run.
    * `--file PATH` - replay an exported scenario file instead of a catalog id.
    * `--format table|json` - select the output format. The default is `table`.
    * `--events N` - print at most N trace rows in table format.
    * `--steps N` - process at most N events, then stop even if the run
      has not converged.
  """

  use Mix.Task

  @shortdoc "Replay a scenario headlessly and print its trace"

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.Replay
  alias SignalGarden.Sim.ScenarioCodec

  @switches [
    list: :boolean,
    all: :boolean,
    file: :string,
    format: :string,
    events: :integer,
    steps: :integer
  ]

  @impl true
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    opts = validate_opts(opts)

    cond do
      opts[:list] -> Mix.shell().info(Replay.list())
      opts[:all] -> replay_all(opts)
      opts[:file] -> replay_file(Path.expand(opts[:file]), opts)
      true -> replay_id(Enum.at(positional, 0) || "line", opts)
    end
  end

  # ---------------------------------------------------------------------------
  # runners
  # ---------------------------------------------------------------------------

  defp replay_all(opts) do
    traces =
      Enum.map(Scenarios.catalog(), fn scenario ->
        Replay.run(scenario, replay_options(opts))
      end)

    output =
      if opts[:format] == "json" do
        Jason.encode!(traces, pretty: true)
      else
        Replay.format_catalog(traces)
      end

    Mix.shell().info(output)
  end

  defp replay_file(path, opts) do
    with {:ok, json} <- File.read(path),
         {:ok, scenario} <- ScenarioCodec.decode(json) do
      replay(scenario, opts)
    else
      {:error, reason} when reason in [:enoent, :eacces, :eisdir, :enotdir] ->
        Mix.raise("Could not read \"#{path}\": #{:file.format_error(reason)}")

      {:error, {:invalid_json, _}} ->
        Mix.raise("Could not load \"#{path}\": the file is not valid JSON.")

      {:error, reason} ->
        Mix.raise("Could not load \"#{path}\": #{inspect(reason)}")
    end
  end

  defp replay_id(id, opts) do
    case fetch_scenario(id) do
      {:ok, scenario} ->
        replay(scenario, opts)

      :error ->
        Mix.raise("Unknown scenario \"#{id}\". Use --list to see the catalog.")
    end
  end

  defp replay(scenario, opts) do
    trace = Replay.run(scenario, replay_options(opts))

    output =
      if opts[:format] == "json" do
        Jason.encode!(trace, pretty: true)
      else
        Replay.format(trace, opts)
      end

    Mix.shell().info(output)
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp validate_opts(opts) do
    format = Keyword.get(opts, :format, "table")

    unless format in ["table", "json"] do
      Mix.raise("Unknown format \"#{format}\". Use --format table or --format json.")
    end

    Keyword.put(opts, :format, format)
  end

  defp replay_options(opts) do
    []
    |> put_positive(:budget, opts[:steps], "steps")
    |> put_positive(:events, opts[:events], "events")
  end

  defp put_positive(acc, _key, nil, _flag), do: acc

  defp put_positive(acc, key, value, _flag) when is_integer(value) and value > 0,
    do: Keyword.put(acc, key, value)

  defp put_positive(_acc, _key, value, flag),
    do: Mix.raise("Expected a positive integer for --#{flag}, got: #{inspect(value)}")

  defp fetch_scenario(id) do
    Enum.find_value(Scenarios.catalog(), :error, fn scenario ->
      if Atom.to_string(scenario.id) == id, do: {:ok, scenario}
    end)
  end
end
