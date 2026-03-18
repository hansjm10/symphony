defmodule SymphonyElixir.HostShellTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HostShell

  test "family detects windows and posix hosts" do
    assert HostShell.family({:win32, :nt}) == :windows
    assert HostShell.family({:unix, :linux}) == :posix
  end

  test "stderr redirect uses shell-appropriate quoting" do
    assert HostShell.stderr_redirect_command(
             %{family: :posix},
             "printf 'alpha'",
             "/tmp/context-pruner stderr"
           ) == "( printf 'alpha' ) 2>'/tmp/context-pruner stderr'"

    assert HostShell.stderr_redirect_command(
             %{family: :windows},
             "Write-Output alpha",
             "C:\\Temp\\context-pruner stderr.txt"
           ) == "& { Write-Output alpha } 2> 'C:\\Temp\\context-pruner stderr.txt'"
  end
end
