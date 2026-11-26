defmodule MedEx.ControlInterlock do
  @moduledoc "Pure technical command transitions. All identity and time are supplied."
  @enforce_keys [:target, :boot_id, :current_epoch]
  defstruct @enforce_keys ++ [pending: nil, historical_unknown: []]

  @type command :: %{
          id: binary(),
          fingerprint: binary(),
          boot_id: binary(),
          expected_epoch: non_neg_integer(),
          value: term()
        }
  @type t :: %__MODULE__{
          target: binary(),
          boot_id: binary(),
          current_epoch: non_neg_integer(),
          pending: map() | nil,
          historical_unknown: [map()]
        }

  @spec request(t(), command(), map()) :: {:ok, t(), [term()]} | {:error, atom()}
  def request(%{pending: pending}, _command, _watermarks) when not is_nil(pending),
    do: {:error, :mutation_in_flight}

  def request(
        %__MODULE__{} = state,
        %{id: id, fingerprint: fp, boot_id: _, expected_epoch: e, value: _} = command,
        watermarks
      )
      when is_map(watermarks) do
    cond do
      not valid_request?(id, fp, e, watermarks) ->
        {:error, :invalid_command}

      Map.has_key?(command, :target) and command.target != state.target ->
        {:error, :wrong_target}

      command.boot_id != state.boot_id ->
        {:error, :wrong_boot}

      command.expected_epoch != state.current_epoch ->
        {:error, :stale_configuration}

      true ->
        pending = %{command: command, phase: :requested, watermarks: watermarks}
        {:ok, %{state | pending: pending}, [{:persist_intent, command, watermarks}]}
    end
  end

  def request(_, _, _), do: {:error, :invalid_command}

  defp valid_request?(id, fingerprint, epoch, watermarks) do
    alias MedEx.ContractRules

    ContractRules.id?(id) and ContractRules.id?(fingerprint) and
      ContractRules.uint?(epoch, 0xFFFFFFFD) and map_size(watermarks) <= 8 and
      Enum.all?(watermarks, fn {key, value} ->
        (is_atom(key) or ContractRules.id?(key)) and
          ContractRules.uint?(value, 0xFFFFFFFFFFFFFFFF)
      end)
  end

  @spec step(t(), term()) :: {:ok, t(), [term()]} | {:error, atom()}
  def step(
        %{pending: %{command: %{id: id} = command, phase: :requested} = pending} = state,
        {:intent_committed, id}
      ) do
    {:ok, %{state | pending: %{pending | phase: :dispatched}}, [{:dispatch, command}]}
  end

  def step(
        %{pending: %{command: %{id: id}, phase: :dispatched} = pending} = state,
        {:timeout, id}
      ) do
    uncertainty = %{command_id: id, from: pending.watermarks, until: :unknown}

    next = %{
      state
      | pending: %{pending | phase: :outcome_unknown},
        historical_unknown: [uncertainty | state.historical_unknown]
    }

    {:ok, next,
     [{:persist_transition, id, :outcome_unknown}, {:query_actual_state, state.target}]}
  end

  def step(
        %{pending: %{command: command, phase: phase}} = state,
        {:applied, id, fingerprint, boot, epoch, boundary}
      )
      when phase in [:dispatched, :outcome_unknown] do
    if {id, fingerprint, boot} == {command.id, command.fingerprint, state.boot_id} and
         epoch == command.expected_epoch + 1 do
      # Prior uncertainty is retained; a new factual boundary is separately recorded.
      next = %{state | pending: nil, current_epoch: epoch}
      {:ok, next, [{:persist_applied, id, epoch, boundary}]}
    else
      {:error, :conflicting_result}
    end
  end

  def step(%{pending: %{command: %{id: id}, phase: phase}} = state, {:rejected, id, reason})
      when phase in [:dispatched, :outcome_unknown],
      do: {:ok, %{state | pending: nil}, [{:persist_rejected, id, reason}]}

  # A current state read-back establishes the present configuration. It cannot
  # retrospectively place an unobserved transition on the waveform timeline.
  def step(
        %{pending: %{command: cmd, phase: :outcome_unknown}} = state,
        {:actual_state, target, boot, epoch, observed}
      ) do
    if target == state.target and boot == state.boot_id and
         MedEx.ContractRules.uint?(epoch, 0xFFFFFFFE) and epoch >= state.current_epoch do
      {:ok, %{state | pending: nil, current_epoch: epoch},
       [{:persist_actual_state, cmd.id, epoch, observed, :historical_boundary_unknown}]}
    else
      {:error, :conflicting_result}
    end
  end

  def step(%__MODULE__{} = state, {:boot_changed, new_boot, epoch}) do
    if MedEx.ContractRules.id?(new_boot) and new_boot != state.boot_id and
         MedEx.ContractRules.uint?(epoch, 0xFFFFFFFE) do
      {unknown, effects} =
        if state.pending do
          fact = %{
            command_id: state.pending.command.id,
            from: state.pending.watermarks,
            until: :unknown
          }

          {[fact | state.historical_unknown],
           [{:persist_transition, fact.command_id, :outcome_unknown}]}
        else
          {state.historical_unknown, []}
        end

      {:ok,
       %{
         state
         | boot_id: new_boot,
           current_epoch: epoch,
           pending: nil,
           historical_unknown: unknown
       }, effects ++ [{:persist_device_boot, new_boot, epoch}]}
    else
      {:error, :invalid_boot}
    end
  end

  def step(_state, _event), do: {:error, :unexpected_event}

  @doc "Device-side decision: durable cached identity is consulted BEFORE the expected epoch."
  def device_decide(ledger, command, actual_epoch) do
    case Map.fetch(ledger, command.id) do
      {:ok, %{fingerprint: fingerprint, result: result}}
      when fingerprint == command.fingerprint ->
        {:cached, result}

      {:ok, _} ->
        {:error, :command_id_conflict}

      :error when command.expected_epoch != actual_epoch ->
        {:error, :stale_configuration}

      :error ->
        {:execute_and_persist_result, command}
    end
  end
end
