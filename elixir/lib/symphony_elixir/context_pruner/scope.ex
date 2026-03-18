defmodule SymphonyElixir.ContextPruner.Scope do
  @moduledoc false

  @type t :: %{
          cwd: String.t(),
          allowed_globs: [String.t()],
          allowed_paths: [String.t()],
          allowed_roots: [String.t()]
        }

  @spec config(Path.t(), map()) :: t()
  def config(cwd, env \\ System.get_env()) when is_binary(cwd) and is_map(env) do
    expanded_cwd = Path.expand(cwd)

    %{
      cwd: expanded_cwd,
      allowed_globs: parse_glob_list(env["CONTEXT_PRUNER_ALLOWED_GLOBS"], expanded_cwd),
      allowed_paths: parse_path_list(env["CONTEXT_PRUNER_ALLOWED_PATHS"], expanded_cwd),
      allowed_roots: parse_path_list(env["CONTEXT_PRUNER_ALLOWED_ROOTS"], expanded_cwd)
    }
  end

  @spec constrained?(t()) :: boolean()
  def constrained?(scope) do
    scope.allowed_roots != [] or scope.allowed_paths != [] or scope.allowed_globs != []
  end

  @spec allowed?(Path.t(), t()) :: boolean()
  def allowed?(path, scope) when is_binary(path) do
    expanded_path = Path.expand(path)

    if constrained?(scope) do
      under_allowed_root?(expanded_path, scope.allowed_roots) or
        matches_allowed_path?(expanded_path, scope.allowed_paths) or
        matches_allowed_glob?(expanded_path, scope.allowed_globs)
    else
      true
    end
  end

  @spec allowed_files_within(Path.t(), t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def allowed_files_within(search_path, scope) when is_binary(search_path) do
    expanded_search_path = Path.expand(search_path)

    with {:ok, search_files} <- collect_files(expanded_search_path) do
      {:ok,
       search_files
       |> Enum.filter(&allowed?(&1, scope))
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  @spec violation_message(Path.t(), t()) :: String.t()
  def violation_message(path, scope) do
    allowed_fragments =
      [
        describe_entries("roots", scope.allowed_roots, scope.cwd),
        describe_entries("paths", scope.allowed_paths, scope.cwd),
        describe_entries("globs", scope.allowed_globs, scope.cwd)
      ]
      |> Enum.reject(&(&1 == nil))
      |> Enum.join("; ")

    "Path is outside the configured context-pruner scope: #{Path.expand(path)}. Allowed scope: #{allowed_fragments}"
  end

  defp parse_path_list(nil, _cwd), do: []

  defp parse_path_list(raw, cwd) when is_binary(raw) do
    raw
    |> split_csv()
    |> Enum.map(&Path.expand(&1, cwd))
  end

  defp parse_glob_list(nil, _cwd), do: []

  defp parse_glob_list(raw, cwd) when is_binary(raw) do
    raw
    |> split_csv()
    |> Enum.map(fn glob ->
      case Path.type(glob) do
        :absolute -> Path.expand(glob)
        _ -> Path.expand(glob, cwd)
      end
    end)
  end

  defp split_csv(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp under_allowed_root?(_path, []), do: false

  defp under_allowed_root?(path, roots) do
    Enum.any?(roots, &path_within?(&1, path))
  end

  defp matches_allowed_path?(_path, []), do: false

  defp matches_allowed_path?(path, allowed_paths) do
    Enum.any?(allowed_paths, &path_within?(&1, path))
  end

  defp matches_allowed_glob?(_path, []), do: false

  defp matches_allowed_glob?(path, allowed_globs) do
    Enum.any?(allowed_globs, fn glob ->
      glob
      |> Path.wildcard(match_dot: true)
      |> Enum.any?(&path_within?(&1, path))
    end)
  end

  defp path_within?(allowed_path, path) do
    expanded_allowed = Path.expand(allowed_path)
    expanded_path = Path.expand(path)

    expanded_path == expanded_allowed or
      String.starts_with?(expanded_path <> "/", expanded_allowed <> "/")
  end

  defp collect_files(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, []}

      {:ok, %File.Stat{type: :regular}} ->
        {:ok, [path]}

      {:ok, %File.Stat{type: :directory}} ->
        collect_directory_files(path)

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp collect_directory_files(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
          case collect_files(Path.join(path, entry)) do
            {:ok, files} -> {:cont, {:ok, acc ++ files}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp describe_entries(_label, [], _cwd), do: nil

  defp describe_entries(label, entries, cwd) do
    rendered =
      entries
      |> Enum.map(&display_path(&1, cwd))
      |> Enum.join(", ")

    "#{label}=#{rendered}"
  end

  defp display_path(path, cwd) do
    relative = Path.relative_to(path, cwd)

    cond do
      relative == path -> path
      String.starts_with?(relative, "..") -> path
      true -> relative
    end
  end
end
