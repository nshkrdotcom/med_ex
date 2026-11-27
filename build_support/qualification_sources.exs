Code.require_file("qualification_receipt.exs", __DIR__)

defmodule MedEx.Build.QualificationSources do
  @moduledoc false
  alias MedEx.Build.QualificationReceipt, as: Receipt

  @apps ~w(med_ex med_ex_opus med_ex_rtc)
  # Generated outputs are omitted only at Mix project roots. In particular,
  # a source directory named lib/deps is still part of the observed input.
  # The caller separately records active consumer locks under _build contexts.
  @outputs ~w(_build deps .weld .blitz doc tmp erl_crash.dump)
  @native ~w(CC CXX CPPFLAGS CFLAGS CXXFLAGS LDFLAGS AR RANLIB ERL_COMPILER_OPTIONS MAKEFLAGS
             MIX_REBAR3 CMAKE_TOOLCHAIN_FILE PKG_CONFIG_PATH MED_EX_OPUS_TARBALL
             MED_EX_OPUS_CONFIGURE_FLAGS XDG_CACHE_HOME)

  def selected(repo), do: selected(repo, System.get_env())

  @doc false
  def selected(repo, environment) when is_binary(repo) and is_map(environment) do
    repo = Path.expand(repo)
    {selector, choices} = choices(repo)

    sources =
      choices
      |> Enum.sort()
      |> Enum.map(fn
        {app, %{"path" => path} = choice} when map_size(choice) == 1 and is_binary(path) ->
          unless valid_path?(path), do: raise(ArgumentError, "Invalid selected source path")
          path = Path.expand(path, repo)

          unless File.regular?(Path.join(path, "mix.exs")),
            do: raise(ArgumentError, "Selected source has no Mix project: #{path}")

          {app, path, path(path)}

        {app, choice} when is_map(choice) ->
          if Map.has_key?(choice, "path"),
            do: raise(ArgumentError, "Selected path cannot have other source options")

          # Git selections pin an exact revision; registry selections are bound
          # by the caller's active consumer locks and registry trust identity.
          {app, choice}

        _ ->
          raise ArgumentError, "A source selection must be an object"
      end)

    Receipt.fingerprint({1, selector, sources, native_inputs(environment)})
  end

  @doc false
  def path(path) when is_binary(path),
    do: path |> entry(MapSet.new()) |> Receipt.fingerprint()

  defp choices(repo) do
    selector = Path.join(repo, ".mix_sources.json")

    case File.lstat(selector) do
      {:error, :enoent} ->
        {:default, %{}}

      {:ok, %{type: :regular}} ->
        bytes = File.read!(selector)

        decoders = [
          object_start: fn _ -> %{} end,
          object_push: &unique_key!/3,
          object_finish: fn object, parent -> {object, parent} end
        ]

        case JSON.decode(bytes, nil, decoders) do
          {choices, nil, rest} when is_map(choices) ->
            unless String.trim(rest) == "" and Enum.all?(Map.keys(choices), &(&1 in @apps)),
              do: raise(ArgumentError, "Invalid selected source inventory")

            {Receipt.sha256(bytes), choices}

          _ ->
            raise ArgumentError, "Source selector must contain one JSON object"
        end

      _ ->
        raise ArgumentError, "Source selector must be a regular file"
    end
  end

  defp unique_key!(key, value, object) do
    if Map.has_key?(object, key), do: raise(ArgumentError, "Duplicate source selector key")
    Map.put(object, key, value)
  end

  defp valid_path?(path),
    do: path != "" and String.trim(path) == path and not String.contains?(path, [<<0>>, "\n", "\r"])

  defp entry(path, ancestors) do
    case File.lstat!(path) do
      %{type: :regular} = stat ->
        regular(path, stat)

      %{type: :directory} = stat ->
        directory(path, stat, ancestors)

      %{type: :symlink} ->
        # Read through the observed path. Lexically expanding a link target can
        # change POSIX traversal of symlinks followed by '..'. Directory links
        # in Weld live projections must include every reached source byte.
        target = File.read_link!(path)

        content =
          case File.stat!(path) do
            %{type: :regular} = stat -> regular(path, stat)
            %{type: :directory} = stat -> directory(path, stat, ancestors)
            _ -> raise ArgumentError, "Selected source link has an unsafe target: #{path}"
          end

        {:symlink, target, content}

      _ ->
        raise ArgumentError, "Selected source has an unsafe input: #{path}"
    end
  end

  defp regular(path, stat),
    do: {:file, Bitwise.band(stat.mode, 0o111), Receipt.sha256(File.read!(path))}

  defp directory(path, stat, ancestors) do
    identity = {stat.major_device, stat.minor_device, stat.inode}

    if MapSet.member?(ancestors, identity),
      do: raise(ArgumentError, "Selected source contains a directory cycle: #{path}")

    ancestors = MapSet.put(ancestors, identity)
    project? = File.regular?(Path.join(path, "mix.exs"))

    entries =
      path
      |> File.ls!()
      |> Enum.reject(&(&1 == ".git" or (project? and &1 in @outputs)))
      |> Enum.sort()
      |> Enum.map(&{&1, entry(Path.join(path, &1), ancestors)})

    {:directory, Bitwise.band(stat.mode, 0o111), entries}
  end

  defp native_inputs(environment) do
    archive =
      case Map.get(environment, "MED_EX_OPUS_TARBALL") do
        value when value in [nil, ""] ->
          nil

        path when is_binary(path) ->
          unless Path.type(path) == :absolute and
                   match?({:ok, %{type: :regular}}, File.lstat(path)),
            do: raise(ArgumentError, "Native source archive must be an absolute regular file")

          {path, Receipt.sha256(File.read!(path))}
      end

    {Enum.map(@native, &{&1, Map.get(environment, &1)}), archive}
  end
end
