defmodule SignalGarden.Sim.Scenario do
  @moduledoc """
  A self-contained description of one simulation run.

  A scenario fixes the topology, the seed, the node that originates a new
  value, and the network conditions. Two runs of the same scenario produce
  the same event trace, the same convergence time, and the same history.

  The `mode` field selects the payload the nodes gossip about:

    * `:rumor` - a single value with a version, seeded by the origin node
    * `:counter` - a grow-only counter, grown by increment fault actions

  Counter mode swaps the rumor for a G-Counter CRDT. Each node keeps one cell
  per node id and merges peer state with element-wise max. The counter total
  is the sum of the cells, and every node converges to the same total.
  """

  defstruct id: :line,
            name: "Line",
            description: "An eight node line.",
            seed: 1,
            topology: nil,
            origin: 1,
            latest_value: 100,
            delay_ms: {35, 70},
            drop_prob: 0.0,
            gossip_interval_ms: 90,
            partitions: %{},
            link_cuts: [],
            fault_schedule: [],
            mode: :rumor

  @type mode :: :rumor | :counter

  @type partition_change ::
          {:merge, :all}
          | {:assign, pos_integer(), integer()}
          | {:cut, {pos_integer(), pos_integer()}}
          | {:cut_link, {pos_integer(), pos_integer()}}
          | {:heal_link, {pos_integer(), pos_integer()}}
          | {:crash, pos_integer()}
          | {:restart, pos_integer()}
          | {:increment, pos_integer(), pos_integer()}
  @type fault ::
          %{at: non_neg_integer(), action: partition_change(), label: String.t()}

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          description: String.t(),
          seed: integer(),
          topology: SignalGarden.Sim.Topology.t(),
          origin: pos_integer(),
          latest_value: number(),
          delay_ms: {non_neg_integer(), non_neg_integer()} | non_neg_integer(),
          drop_prob: float(),
          gossip_interval_ms: non_neg_integer(),
          partitions: %{pos_integer() => integer()},
          link_cuts: [{pos_integer(), pos_integer()}],
          fault_schedule: [fault()],
          mode: mode()
        }
end
