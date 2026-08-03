defmodule Mix.Tasks.Sg.Replay do
  @shortdoc "Replay a scenario from the CLI and print a deterministic trace"

  @moduledoc """
  Replays a scenario headlessly and prints a full deterministic trace.

  The runner drives the pure simulation core. It needs no browser and no
  animation loop, so the same scenario always prints the same bytes.

  ## Usage

      mix sg.replay SCENARIO [options]

  `SCENARIO` is a catalog id (`ring`, `grid`, `counter`, ...), a path to a
  scenario JSON file, or inline scenario JSON.

  ## Options

    * `--steps N` - run at most N events instead of running to the end
    * `--limit N` - print at most N trace lines
    * `--no-trace` - print the summary only
    * `--checks` - replay twice and report determinism
    * `--json` - print the result as JSON for other tools
    * `--help` - print this help

  ## Examples

      mix sg.replay ring
      mix sg.replay counter --checks
      mix sg.replay priv/scenarios/ring.json --no-trace
      mix sg.replay lossy --steps 400 --json | jq .convergence_time
  """

  use Mix.Task

  alias SignalGarden.Sim.Replay

  @switches [
    steps: :integer,
    limit: :integer,
    no_trace: :boolean,
    checks: :boolean,
    json: :boolean,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        IO.puts(@moduledoc)

      invalid != [] or positional == [] ->
        Mix.raise("invalid arguments: mix sg.replay SCENARIO [options]")

      true ->
        execute(hd(positional), opts)
    end
  end

  defp execute(source, opts) do
    json? = opts[:json] == true
    checks? = opts[:checks] == true

    cond do
      json? and checks? ->
        with {:ok, report} <- Replay.verify(source, replay_opts(opts)) do
          IO.puts(Jason.encode!(verify_payload(report)))
        else
          {:error, reason} -> Mix.raise(format_error(reason, source))
        end

      json? ->
        with {:ok, result} <- Replay.run(source, replay_opts(opts)) do
          IO.puts(Jason.encode!(Replay.to_json_map(result)))
        else
          {:error, reason} -> Mix.raise(format_error(reason, source))
        end

      checks? ->
        with {:ok, result} <- Replay.run(source, replay_opts(opts)) do
          print_result(result, opts)

          with {:ok, report} <- Replay.verify(source, replay_opts(opts)) do
            IO.puts("")
            IO.puts(Replay.format_determinism(report))
          else
            {:error, reason} -> Mix.raise(format_error(reason, source))
          end
        else
          {:error, reason} -> Mix.raise(format_error(reason, source))
        end

      true ->
        with {:ok, result} <- Replay.run(source, replay_opts(opts)) do
          print_result(result, opts)
        else
          {:error, reason} -> Mix.raise(format_error(reason, source))
        end
    end
  end

  defp print_result(result, opts) do
    IO.puts(Replay.format_summary(result))

    unless opts[:no_trace] == true do
      IO.puts("")
      IO.puts("Trace (#{length(result.trace)} events)")
      trace_opts = if is_integer(opts[:limit]), do: [limit: opts[:limit]], else: []
      IO.puts(Enum.join(Replay.format_trace(result, trace_opts), "\n"))
    end
  end

  defp verify_payload(report) do
    %{
      "run" => Replay.to_json_map(report.run_a),
      "determinism" => %{
        "equal" => report.equal,
        "convergence_time_equal" => report.convergence_time_equal,
        "trace_equal" => report.trace_equal,
        "history_equal" => report.history_equal
      }
    }
  end

  defp replay_opts(opts), do: Keyword.take(opts, [:steps])

  defp format_error({:unknown_scenario, id}, _source) when is_atom(id),
    do: "unknown scenario id: #{inspect(id)}"

  defp format_error({:unknown_scenario, input}, _source),
    do: "unknown scenario or JSON input: #{inspect(input)}"

  defp format_error({:read_failed, path, reason}, _source),
    do: "cannot read scenario file #{path}: #{inspect(reason)}"

  defp format_error({:invalid_json, _err}, _source), do: "the input is not valid scenario JSON"
  defp format_error(:missing_format, _source), do: "the input is missing a format version"

  defp format_error({:unsupported_format, version}, _source),
    do: "format version #{version} is not supported"

  defp format_error({:invalid_field, field}, _source), do: "the field \"#{field}\" is invalid"

  defp format_error({:invalid_origin, origin}, _source),
    do: "origin node #{origin} is not in the topology"

  defp format_error(reason, source), do: "cannot replay #{source}: #{inspect(reason)}"
end
