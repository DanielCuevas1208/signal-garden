defmodule SignalGarden.Sim.Scenario do
  @moduledoc """
  A self-contained description of one simulation run.

  A scenario fixes the topology, the seed, the node that originates a new
  value, and the network conditions. Two runs of the same scenario produce
  the same event trace, the same convergence time, and the same history.

  The `mode` field selects the payload the nodes gossip about:

    * `:rumor` - a single value with a version, seeded by the origin node
    * `:counter` - a grow-only counter, grown by increment fault actions
    * `:set` - a grow-only set, grown by add fault actions
    * `:orset` - an observed-remove set, changed by add and remove fault actions
    * `:register` - a last-writer-wins register, written by write fault actions
    * `:map` - a last-writer-wins map, written by put fault actions

  Counter mode swaps the rumor for a G-Counter CRDT. Each node keeps one cell
  per node id and merges peer state with element-wise max. The counter total
  is the sum of the cells, and every node converges to the same total.

  Set mode swaps the rumor for a G-Set CRDT. Each node keeps a set of elements
  and merges peer state with set union. Every node converges to the same
  collection, so a membership list or a tag cloud spreads through the network.

  OR-set mode swaps the rumor for an observed-remove set. Each node stores
  every element with two tag sets, one for adds and one for removes. An add
  creates a fresh unique tag, and a remove moves every known tag into the
  removed set. On merge the receiver unions both tag sets, so a removed
  member never comes back. A roster or a shared shopping list spreads through
  the network and lets members join and leave.

  Register mode swaps the rumor for an LWW register CRDT. Each node keeps one
  value and the version of the write that produced it. On merge the receiver
  keeps the higher version, so the newest write wins everywhere. A status
  line or a banner spreads through the network and overwrites itself.

  Map mode swaps the rumor for an LWW map CRDT. Each node keeps a map of
  keys, where every key is an independent LWW register. On merge the receiver
  keeps the higher version for each key, so the newest write wins per key. A
  service board or a settings map spreads through the network and updates
  itself one key at a time.
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
            map_keys: [],
            mode: :rumor

  @type mode :: :rumor | :counter | :set | :orset | :register | :map

  @type partition_change ::
          {:merge, :all}
          | {:assign, pos_integer(), integer()}
          | {:cut, {pos_integer(), pos_integer()}}
          | {:cut_link, {pos_integer(), pos_integer()}}
          | {:heal_link, {pos_integer(), pos_integer()}}
          | {:crash, pos_integer()}
          | {:restart, pos_integer()}
          | {:increment, pos_integer(), pos_integer()}
          | {:add, pos_integer(), binary() | number()}
          | {:remove, pos_integer(), binary() | number()}
          | {:write, pos_integer(), binary() | number()}
          | {:put, pos_integer(), binary(), binary() | number()}
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
          map_keys: [String.t()],
          mode: mode()
        }
end
