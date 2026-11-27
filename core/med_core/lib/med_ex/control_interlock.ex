defmodule MedEx.ControlInterlock do
  @moduledoc "Pure technical command decisions using explicit authority and application observations."
  alias MedEx.ContractRules, as: R
  @enforce_keys [:target, :boot_id, :current_epoch]
  defstruct @enforce_keys ++ [generation: 0, pending: nil, historical_unknown: [], frozen: false]
  @type t :: %__MODULE__{}
  @identity [:id, :fingerprint, :boot_id, :target, :generation, :expected_epoch, :value]

  def request(%__MODULE__{frozen: true}, _, _), do: {:error, :frozen}

  def request(%__MODULE__{pending: pending}, _, _) when not is_nil(pending),
    do: {:error, :mutation_in_flight}

  def request(%__MODULE__{} = state, command, watermarks)
      when is_map(command) and is_map(watermarks) do
    with :ok <- validate_request(state, command, watermarks) do
      pending = %{
        command: Map.take(command, @identity),
        phase: :requested,
        watermarks: watermarks
      }

      {:ok, %{state | pending: pending}, [{:persist_intent, pending.command, watermarks}]}
    end
  end

  def request(_, _, _), do: {:error, :invalid_command}

  defp validate_request(state, command, watermarks) do
    if command?(command) and watermarks?(watermarks),
      do: request_authority(state, command),
      else: {:error, :invalid_command}
  end

  defp request_authority(state, command) do
    cond do
      command.expired -> {:error, :expired}
      command.target != state.target -> {:error, :wrong_target}
      command.boot_id != state.boot_id -> {:error, :wrong_boot}
      command.generation != state.generation -> {:error, :stale_generation}
      command.expected_epoch != state.current_epoch -> {:error, :stale_configuration}
      length(state.historical_unknown) >= 256 -> {:error, :command_limit}
      true -> :ok
    end
  end

  def step(%__MODULE__{} = state, :freeze), do: {:ok, %{state | frozen: true}, []}
  def step(%__MODULE__{frozen: true}, _), do: {:error, :frozen}

  def step(
        %__MODULE__{pending: %{command: %{id: id} = command, phase: :requested} = pending} = state,
        {:intent_committed, id}
      ),
      do: {:ok, %{state | pending: %{pending | phase: :dispatched}}, [{:dispatch, command}]}

  def step(
        %__MODULE__{pending: %{command: %{id: id}, phase: :dispatched} = pending} = state,
        {:timeout, id}
      ) do
    {:ok, mark_unknown(state),
     [{:persist_transition, id, :outcome_unknown}, {:query_exact_result, pending.command}]}
  end

  def step(
        %__MODULE__{pending: %{command: command, phase: phase}} = state,
        {:historical_result, result}
      )
      when phase in [:dispatched, :outcome_unknown] and is_map(result) do
    if result?(command, result) do
      case result.outcome do
        :applied ->
          {:ok, %{state | pending: nil, current_epoch: result.epoch},
           [{:persist_applied, result}]}

        :rejected ->
          {:ok, %{state | pending: nil}, [{:persist_rejected, result}]}

        :outcome_unknown ->
          {:ok, mark_unknown(state), [{:persist_transition, command.id, :outcome_unknown}]}
      end
    else
      {:error, :conflicting_result}
    end
  end

  def step(
        %__MODULE__{pending: %{phase: :outcome_unknown}} = state,
        {:actual_state, target, boot, epoch, observed}
      ) do
    if target == state.target and boot == state.boot_id and R.uint?(epoch, 0xFFFFFFFE) and
         epoch >= state.current_epoch and is_map(observed) do
      # A present setting does not settle a historical pending command.
      {:ok, state,
       [{:persist_actual_state, target, boot, epoch, observed, :historical_boundary_unknown}]}
    else
      {:error, :conflicting_result}
    end
  end

  def step(%__MODULE__{} = state, {:boot_changed, boot, epoch}) do
    if R.id?(boot) and boot != state.boot_id and R.uint?(epoch, 0xFFFFFFFE) and
         (is_nil(state.pending) or length(state.historical_unknown) < 256) do
      facts =
        if state.pending,
          do: mark_unknown(state).historical_unknown,
          else: state.historical_unknown

      {:ok,
       %{state | boot_id: boot, current_epoch: epoch, pending: nil, historical_unknown: facts},
       [{:persist_device_boot, boot, epoch}]}
    else
      {:error, :invalid_boot}
    end
  end

  def step(_, _), do: {:error, :unexpected_event}

  defp mark_unknown(%{pending: %{phase: :outcome_unknown}} = state), do: state

  defp mark_unknown(%{pending: pending} = state) do
    fact = %{command: pending.command, from: pending.watermarks, until: :unknown}

    %{
      state
      | pending: %{pending | phase: :outcome_unknown},
        historical_unknown: [fact | state.historical_unknown]
    }
  end

  @doc "Exact cached application is historical proof; expiry only prevents a new application."
  def device_decide(ledger, command, actual_epoch) when is_map(ledger) and is_map(command) do
    if map_size(ledger) <= 256 and command?(command) and R.uint?(actual_epoch, 0xFFFFFFFE) do
      decide_from_ledger(ledger, command, actual_epoch)
    else
      {:error, :invalid_command}
    end
  end

  def device_decide(_, _, _), do: {:error, :invalid_command}

  defp decide_from_ledger(ledger, command, actual_epoch) do
    case Map.fetch(ledger, command.id) do
      {:ok, %{fingerprint: fingerprint, command: cached, result: result}} ->
        if fingerprint == command.fingerprint and cached == Map.take(command, @identity) and
             result?(cached, result),
           do: {:cached, result},
           else: {:error, :command_id_conflict}

      {:ok, _} ->
        {:error, :invalid_command_ledger}

      :error ->
        decide_new_command(ledger, command, actual_epoch)
    end
  end

  defp decide_new_command(ledger, command, actual_epoch) do
    cond do
      command.expired -> {:error, :expired}
      command.expected_epoch != actual_epoch -> {:error, :stale_configuration}
      map_size(ledger) == 256 -> {:error, :command_limit}
      true -> {:execute_and_persist_result, command}
    end
  end

  defp command?(command) do
    Enum.all?(@identity ++ [:expired], &Map.has_key?(command, &1)) and
      command_identity?(command) and command_value?(command)
  end

  defp command_identity?(command) do
    R.id?(command.id) and byte_size(command.id) <= 96 and R.digest?(command.fingerprint) and
      R.id?(command.boot_id) and R.id?(command.target)
  end

  defp command_value?(command) do
    R.uint?(command.generation, 0x7FFFFFFFFFFFFFFF) and
      R.uint?(command.expected_epoch, 0xFFFFFFFD) and R.scalar?(command.value) and
      is_boolean(command.expired)
  end

  defp watermarks?(map),
    do:
      map_size(map) <= 8 and
        Enum.all?(map, fn {k, v} ->
          (is_atom(k) or R.id?(k)) and R.uint?(v, 0xFFFFFFFFFFFFFFFF)
        end)

  defp result?(command, result) when is_map(result) do
    identity = [:id, :fingerprint, :boot_id, :target, :generation]
    exact = Enum.all?(identity, &(Map.fetch(command, &1) == Map.fetch(result, &1)))

    case result do
      %{outcome: :applied, epoch: epoch, application: %{observed_at: at, first_sample: first}} ->
        exact and applied_result?(command, epoch, at, first)

      %{outcome: :rejected, reason: reason} ->
        exact and R.id?(reason)

      %{outcome: :outcome_unknown} ->
        exact

      _ ->
        false
    end
  end

  defp result?(_, _), do: false

  defp applied_result?(command, epoch, at, first) do
    epoch == command.expected_epoch + 1 and R.uint?(at, 0xFFFFFFFFFFFFFFFF) and
      (first == :unknown or R.uint?(first, 0xFFFFFFFFFFFFFFFF))
  end
end
