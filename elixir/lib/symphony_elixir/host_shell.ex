defmodule SymphonyElixir.HostShell do
  @moduledoc false

  @type family :: :posix | :windows
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
end
