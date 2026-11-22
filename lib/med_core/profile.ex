defmodule MedCore.Profile do
  @moduledoc """
  Behaviour implemented by clinical product applications to compose MedEx
  transport archetypes, streams, inference hooks, and device control policies.
  """

  alias MedCore.StreamSpec

  @type topology :: :server_terminated | :sfu | :hybrid
  @type inference_hook :: {String.t(), module(), keyword()}

  @callback topology() :: topology()
  @callback streams() :: [StreamSpec.t()]
  @callback inference_hooks() :: [inference_hook()]
  @callback control_policy() :: module()
end
