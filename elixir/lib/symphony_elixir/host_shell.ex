defmodule SymphonyElixir.HostShell do
  @moduledoc false

  @type family :: :posix | :windows
  @type shell_command :: String.t() | map()
  @type shell_config :: %{
          family: family(),
          command_name: String.t(),
          executable: String.t(),
          args_prefix: [String.t()]
        }

  @spec family() :: family()
  def family, do: family(:os.type())

  @spec family({atom(), atom()}) :: family()
  def family({:win32, _}), do: :windows
  def family(_), do: :posix

  @spec resolve_local(keyword()) :: {:ok, shell_config()} | {:error, String.t(), pos_integer()}
  def resolve_local(opts \\ []) do
    requested_family = Keyword.get(opts, :family, family(Keyword.get(opts, :os_type, :os.type())))

    case requested_family do
      :windows ->
        case find_first_executable(["pwsh", "powershell"]) do
          nil ->
            {:error, "No usable PowerShell executable was found on this host.", 127}

          {name, executable} ->
            {:ok,
             %{
               family: :windows,
               command_name: name,
               executable: executable,
               args_prefix: ["-NoProfile", "-Command"]
             }}
        end

      :posix ->
        case find_first_executable(["bash", "sh"]) do
          nil ->
            {:error, "No usable POSIX shell was found on this host.", 127}

          {name, executable} ->
            {:ok,
             %{
               family: :posix,
               command_name: name,
               executable: executable,
               args_prefix: ["-lc"]
             }}
        end
    end
  end

  @doc false
  @spec resolve_local_command(shell_command(), keyword()) ::
          {:ok, shell_config(), String.t()} | {:error, String.t(), pos_integer()}
  def resolve_local_command(command, opts \\ []) do
    requested_family = Keyword.get(opts, :family, family(Keyword.get(opts, :os_type, :os.type())))
    label = Keyword.get(opts, :label, "command")

    with {:ok, shell} <- resolve_local(family: requested_family),
         {:ok, resolved_command} <-
           resolve_command_for_family(command, requested_family, label, :local) do
      {:ok, shell, resolved_command}
    end
  end

  @doc false
  @spec resolve_remote_posix_command(shell_command(), keyword()) ::
          {:ok, String.t()} | {:error, String.t(), pos_integer()}
  def resolve_remote_posix_command(command, opts \\ []) do
    label = Keyword.get(opts, :label, "command")
    resolve_command_for_family(command, :posix, label, :remote)
  end

  @spec stderr_redirect_command(shell_config(), String.t(), Path.t()) :: String.t()
  def stderr_redirect_command(%{family: :windows}, command, stderr_path) do
    "& { #{command} } 2> #{powershell_escape(stderr_path)}"
  end

  def stderr_redirect_command(%{family: :posix}, command, stderr_path) do
    "( #{command} ) 2>#{posix_escape(stderr_path)}"
  end

  @spec posix_escape(String.t()) :: String.t()
  def posix_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  @spec powershell_escape(String.t()) :: String.t()
  def powershell_escape(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp find_first_executable(names) do
    Enum.find_value(names, fn name ->
      case System.find_executable(name) do
        nil -> nil
        executable -> {name, executable}
      end
    end)
  end

  defp resolve_command_for_family(command, _family, _label, _scope) when is_binary(command), do: {:ok, command}

  defp resolve_command_for_family(command, family, label, scope) when is_map(command) do
    case Enum.find_value(command_lookup_keys(family), &command_map_value(command, &1)) do
      resolved_command when is_binary(resolved_command) ->
        {:ok, resolved_command}

      _ ->
        {:error, missing_command_message(label, family, scope), 127}
    end
  end

  defp resolve_command_for_family(_command, _family, label, _scope) do
    {:error, "#{label} must be a string or shell map.", 127}
  end

  defp command_lookup_keys(:windows), do: ["pwsh", "windows"]
  defp command_lookup_keys(:posix), do: ["sh", "posix"]

  defp command_map_value(command, key) when is_map(command) do
    atom_key =
      case key do
        "sh" -> :sh
        "pwsh" -> :pwsh
        "posix" -> :posix
        "windows" -> :windows
      end

    Map.get(command, key) || Map.get(command, atom_key)
  end

  defp missing_command_message(label, :windows, :local) do
    "#{label} does not define a pwsh/windows command for this host."
  end

  defp missing_command_message(label, :posix, :local) do
    "#{label} does not define a sh/posix command for this host."
  end

  defp missing_command_message(label, :posix, :remote) do
    "#{label} does not define a sh/posix command for remote execution."
  end
end
