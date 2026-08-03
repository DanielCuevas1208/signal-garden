defmodule Mix.Tasks.Garden.Replay do
  @moduledoc """
  Replay Signal Garden scenarios from the command line.

  Runs the deterministic core to completion with no browser and no
  animation loop. The output is reproducible: the same scenario always
  prints the same table and the same trace.

  ## Usage

      mix garden.replay                  # table for every catalog scenario
      mix garden.replay ring             # one scenario by id
      mix garden.replay file.json        # one scenario file
      mix garden.replay --verify         # confirm determinism
      mix garden.replay --json           # machine-readable JSON

  The `--trace` flag prints the full event trace for the selected run.
  Use `--json` to emit the outcome as JSON for a script or a diff.
  """

  use Mix.Task

  @shortdoc "Replay scenarios and print a deterministic report"

  alias SignalGarden.Sim.Replay

  @impl true
  def run(args) do
    {opts, targets, invalid} =
      OptionParser.parse(args,
        strict: [verify: :boolean, json: :boolean, trace: :boolean],
        aliases: [v: :verify, j: :json, t: :trace]
      )

    cond do
      invalid != [] ->
        Mix.raise("Unknown option: #{Enum.join(invalid, ", ")}")

      targets == [] and opts[:verify] ->
        print_verify(Replay.verify_all())

      targets == [] ->
        print_table(Replay.run_all(), opts)

      true ->
        print_target(hd(targets), opts)
    end
  end

  defp print_target(target, opts) do
    with {:ok, scenario} <- resolve_scenario(target) do
      if opts[:verify] do
        print_verify([Replay.verify(scenario)])
      else
        outcome = Replay.run(scenario)

        if opts[:json] do
          print_json(outcome)
        else
          IO.puts(Replay.format_table([outcome]))
          IO.puts("")

          if opts[:trace] do
            IO.puts(Replay.format_trace(outcome))
          end
        end
      end
    else
      {:error, reason} -> Mix.raise(friendly_error(reason, target))
    end
  end

  defp print_verify(reports) do
    for report <- reports do
      verdict = if report.deterministic, do: "deterministic", else: "MISMATCH"

      IO.puts(
        "#{report.name}: #{verdict} (t=#{report.convergence_time}ms, #{report.steps} steps, #{report.events} events)"
      )
    end
  end

  defp print_table(outcomes, opts) do
    if opts[:json] do
      print_json(outcomes)
    else
      IO.puts(Replay.format_table(outcomes))
    end
  end

  defp print_json(data) do
    IO.puts(Jason.encode!(data, pretty: true))
  end

  defp resolve_scenario(target) do
    cond do
      String.ends_with?(target, ".json") ->
        with {:ok, json} <- File.read(target) do
          SignalGarden.Sim.ScenarioCodec.decode(json)
        else
          {:error, :enoent} -> {:error, {:no_such_file, target}}
          other -> other
        end

      is_catalog_id?(target) ->
        case SignalGarden.Scenarios.fetch(String.to_existing_atom(target)) do
          nil -> {:error, :unknown_target}
          scenario -> {:ok, scenario}
        end

      true ->
        {:error, :unknown_target}
    end
  end

  defp friendly_error(:unknown_target, target) do
    "Unknown scenario or file: #{target}. Use a catalog id or a .json path."
  end

  defp friendly_error({:no_such_file, path}, _target), do: "No such file: #{path}"

  defp friendly_error({:invalid_field, field}, _target),
    do: "The file is missing or has an invalid \"#{field}\" field."

  defp friendly_error(:missing_format, _target), do: "The file has no format version."

  defp friendly_error({:unsupported_format, version}, _target),
    do: "The file uses unsupported format version #{version}."

  defp friendly_error({:invalid_json, _}, _target), do: "The file is not valid JSON."

  defp friendly_error({:invalid_origin, origin}, _target),
    do: "The origin node #{origin} is not in the topology."

  defp friendly_error(_other, _target), do: "The scenario could not be replayed."

  defp is_catalog_id?(target) do
    target in ~w(line ring grid random split churn lossy crash counter)
  end
end
