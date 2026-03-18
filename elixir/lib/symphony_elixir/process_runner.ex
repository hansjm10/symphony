defmodule SymphonyElixir.ProcessRunner do
  @moduledoc false

  @spec run(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    if hide_windows_console?(opts) do
      run_hidden(executable, args, opts)
    else
      System.cmd(executable, args, Keyword.drop(opts, [:windows_hide]))
    end
  end

  defp hide_windows_console?(opts) do
    Keyword.get(opts, :windows_hide, true) and match?({:win32, _}, :os.type())
  end

  defp run_hidden(executable, args, opts) do
    port_opts =
      [
        :binary,
        :exit_status,
        :hide,
        args: Enum.map(args, &String.to_charlist/1)
      ]
      |> maybe_put_cd(Keyword.get(opts, :cd))
      |> maybe_put_env(Keyword.get(opts, :env))
      |> maybe_put_stderr_to_stdout(Keyword.get(opts, :stderr_to_stdout, false))

    port = Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)
    collect_output(port, [])
  end

  defp maybe_put_cd(port_opts, nil), do: port_opts

  defp maybe_put_cd(port_opts, cd) when is_binary(cd) do
    Keyword.put(port_opts, :cd, String.to_charlist(cd))
  end

  defp maybe_put_env(port_opts, nil), do: port_opts

  defp maybe_put_env(port_opts, env) when is_list(env) do
    normalized_env =
      Enum.map(env, fn
        {key, nil} -> {to_charlist(key), false}
        {key, false} -> {to_charlist(key), false}
        {key, value} -> {to_charlist(key), to_charlist(value)}
      end)

    Keyword.put(port_opts, :env, normalized_env)
  end

  defp maybe_put_stderr_to_stdout(port_opts, true), do: [:stderr_to_stdout | port_opts]
  defp maybe_put_stderr_to_stdout(port_opts, _), do: port_opts

  defp collect_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, [data | acc])

      {^port, {:exit_status, status}} ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
    end
  end
end
