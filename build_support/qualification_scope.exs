Code.require_file("qualification_receipt.exs", __DIR__)

defmodule MedEx.Build.QualificationScope do
  @moduledoc false
  alias MedEx.Build.QualificationReceipt, as: Receipt
  @profiles [:base, :opus, :rtc, :both]

  def changed(root, base) do
    changed = Receipt.git!(root, ["diff", "--name-only", "-z", "--no-renames", base, "--"])
    untracked = Receipt.git!(root, ["ls-files", "-z", "--others", "--exclude-standard"])

    (String.split(changed, <<0>>, trim: true) ++ String.split(untracked, <<0>>, trim: true))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def medex(paths) do
    Enum.reduce(
      paths,
      %{profiles: [], architecture: false, packaging: false, docs: false},
      fn path, acc ->
        {profiles, architecture, packaging, docs} = classify(path)

        %{
          profiles: Enum.filter(@profiles, &(&1 in acc.profiles or &1 in profiles)),
          architecture: acc.architecture or architecture,
          packaging: acc.packaging or packaging,
          docs: acc.docs or docs
        }
      end
    )
  end

  defp classify("guides/" <> _), do: {[], false, true, true}

  defp classify(path) when path in ["README.md", "CHANGELOG.md", "LICENSE"],
    do: {[], false, true, true}

  defp classify("extensions/med_ex_opus/" <> file), do: provider([:opus, :both], file)
  defp classify("extensions/med_ex_rtc/" <> file), do: provider([:rtc, :both], file)
  defp classify("core/" <> _), do: {@profiles, true, true, false}
  defp classify("priv/" <> _), do: {@profiles, true, true, false}
  defp classify("test/" <> _), do: {@profiles, true, false, false}
  defp classify(_), do: {@profiles, true, true, true}

  defp provider(profiles, file) do
    docs = Path.extname(file) == ".md"

    {if(docs, do: [], else: profiles), false, docs or not String.starts_with?(file, "test/"),
     docs}
  end
end
