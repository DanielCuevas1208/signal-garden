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
          context: MapSet.t()
        }

  @spec new() :: t()
  def new, do: %{entries: %{}, context: MapSet.new()}

  @spec write(t(), dot(), value()) :: t()
  def write(%{entries: entries, context: context}, dot, value) do
    context = context |> MapSet.union(MapSet.new(Map.keys(entries))) |> MapSet.put(dot)
    %{entries: %{dot => value}, context: context}
  end

  @spec merge(t(), t()) :: t()
  def merge(left, right) do
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

    %{entries: entries, context: MapSet.union(left.context, right.context)}
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
end
