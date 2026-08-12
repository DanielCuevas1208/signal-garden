defmodule SignalGarden.Sim.MultiValueRegister do
  @moduledoc """
  State-based multi-value register semantics.

  A write carries a causal context and a fresh dot. It replaces values the
  writer has observed. Concurrent values stay visible until a later write
  observes them.
  """

  @type dot :: {pos_integer(), pos_integer()}
  @type value :: binary() | number()
  @type t :: %{
          entries: map(),
          context: MapSet.t(),
          history: map()
        }

  @type timeline_entry :: %{
          node: pos_integer(),
          sequence: pos_integer(),
          value: value(),
          observed: [dot()],
          observed_by: [dot()],
          visible: boolean()
        }

  @spec new() :: t()
  def new, do: %{entries: %{}, context: MapSet.new(), history: %{}}

  @spec write(t(), dot(), value()) :: t()
  def write(state, dot, value) do
    %{entries: entries, context: context, history: history} = normalize(state)
    observed = MapSet.union(context, MapSet.new(Map.keys(entries)))
    next_context = MapSet.put(observed, dot)

    next_history = Map.put(history, dot, %{value: value, observed: observed})

    %{entries: %{dot => value}, context: next_context, history: next_history}
  end

  @spec merge(t(), t()) :: t()
  def merge(left, right) do
    left = normalize(left)
    right = normalize(right)

    entries =
      left.entries
      |> Map.merge(right.entries)
      |> Enum.reduce(%{}, fn {dot, value}, acc ->
        cond do
          Map.has_key?(left.entries, dot) and Map.has_key?(right.entries, dot) ->
            Map.put(acc, dot, value)

          Map.has_key?(left.entries, dot) and not MapSet.member?(right.context, dot) ->
            Map.put(acc, dot, value)

          Map.has_key?(right.entries, dot) and not MapSet.member?(left.context, dot) ->
            Map.put(acc, dot, value)

          true ->
            acc
        end
      end)

    %{
      entries: entries,
      context: MapSet.union(left.context, right.context),
      history: Map.merge(left.history, right.history)
    }
  end

  @spec values(t()) :: [value()]
  def values(%{entries: entries}) do
    entries
    |> Map.values()
    |> Enum.uniq()
    |> Enum.sort_by(fn value -> {to_string(value), inspect(value)} end)
  end

  @spec conflict_count(t()) :: non_neg_integer()
  def conflict_count(%{entries: entries}), do: map_size(entries)

  @doc ~S(Return every known write with its causal observations and current visibility.)
  @spec timeline(t()) :: [timeline_entry()]
  def timeline(state) do
    %{entries: entries, history: history} = normalize(state)

    history
    |> Enum.map(fn {{node, sequence} = dot, %{value: value, observed: observed}} ->
      observed_by =
        history
        |> Enum.filter(fn {other_dot, %{observed: other_observed}} ->
          other_dot != dot and MapSet.member?(other_observed, dot)
        end)
        |> Enum.map(&elem(&1, 0))
        |> sort_dots()

      %{
        node: node,
        sequence: sequence,
        value: value,
        observed: observed |> MapSet.to_list() |> sort_dots(),
        observed_by: observed_by,
        visible: Map.has_key?(entries, dot)
      }
    end)
    |> Enum.sort_by(fn %{sequence: sequence, node: node} -> {sequence, node} end)
  end

  defp normalize(%{entries: entries, context: context} = state) do
    %{entries: entries, context: context, history: Map.get(state, :history, %{})}
  end

  defp sort_dots(dots), do: Enum.sort_by(dots, fn {node, sequence} -> {sequence, node} end)
end
