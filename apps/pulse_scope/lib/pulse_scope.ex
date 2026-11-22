defmodule PulseScope do
  @moduledoc """
  First vertical-slice clinical application on MedEx implementing Use Case #1
  (Remote Digital Stethoscope) and Use Case #4 (Remote Patient Monitoring).
  """

  alias PulseScope.ClinicalProfile

  @spec profile() :: module()
  def profile, do: ClinicalProfile
end
