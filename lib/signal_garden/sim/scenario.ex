defmodule SignalGarden.Sim.Scenario do
  @moduledoc """
  A self-contained description of one simulation run.

  A scenario fixes the topology, the seed, the node that originates a new
  value, and the network conditions. Two runs of the same scenario produce
  the same event trace, the same convergence time, and the same history.
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
            fault_schedule: []

  @type partition_change ::
          {:merge, :all}
          | {:assign, pos_integer(), integer()}
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
          fault_schedule: [fault()]
        }
end
