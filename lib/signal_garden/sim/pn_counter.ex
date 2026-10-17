defmodule SignalGarden.Sim.PNCounter do
  @moduledoc ~S(State-based positive-negative counter semantics.)

  @type node_id :: pos_integer()
  @type t :: %{
          positive: %{node_id() => non_neg_integer()},
          negative: %{node_id() => non_neg_integer()}
        }

  @doc ~S(Create an empty counter.)
  @spec new() :: t()
  def new, do: %{positive: %{}, negative: %{}}

  @doc ~S(Apply a signed adjustment to the cell owned by node.)
  @spec adjust(t(), node_id(), integer()) :: t()
  def adjust(state, node, amount) when amount > 0 do
    %{state | positive: Map.update(state.positive, node, amount, &(&1 + amount))}
  end

  def adjust(state, _node, 0), do: state

  def adjust(state, node, amount) when amount < 0 do
    amount = abs(amount)
    %{state | negative: Map.update(state.negative, node, amount, &(&1 + amount))}
  end

  @doc ~S(Merge two counters with element-wise maximums.)
  @spec merge(t(), t()) :: t()
  def merge(left, right) do
    %{
      positive: merge_cells(left.positive, right.positive),
      negative: merge_cells(left.negative, right.negative)
    }
  end

  @doc ~S(Return the signed value represented by a counter.)
  @spec value(t()) :: integer()
  def value(state), do: sum(state.positive) - sum(state.negative)

  @doc ~S(Return true when both counters carry the same replicated cells.)
  @spec equivalent?(t(), t()) :: boolean()
  def equivalent?(left, right), do: left == right

  defp merge_cells(left, right) do
    Map.merge(left, right, fn _node, a, b -> max(a, b) end)
  end

  defp sum(cells), do: cells |> Map.values() |> Enum.sum()
end
