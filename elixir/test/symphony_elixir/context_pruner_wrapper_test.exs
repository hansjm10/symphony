defmodule SymphonyElixir.ContextPrunerWrapperTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../..", __DIR__)

  test "mix task help output is available" do
    {output, status} =
      System.cmd("mix", ["context_pruner", "help", "lookup"],
        cd: Path.join(@repo_root, "elixir"),
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "context-pruner lookup --query <query>"
  end

  test "PowerShell wrapper help output is available" do
    executable = System.find_executable("pwsh") || System.find_executable("powershell")
    assert is_binary(executable)

    {output, status} =
      System.cmd(
        executable,
        [
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          Path.join(@repo_root, "context-pruner.ps1"),
          "help",
          "lookup"
        ],
        cd: @repo_root,
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "context-pruner lookup --query <query>"
  end

  test "cmd wrapper help output is available" do
    executable = System.find_executable("cmd")
    assert is_binary(executable)

    {output, status} =
      System.cmd(
        executable,
        ["/c", Path.join(@repo_root, "context-pruner.cmd"), "help", "lookup"],
        cd: @repo_root,
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "context-pruner lookup --query <query>"
  end

  test "bash wrapper help output is available" do
    executable = System.find_executable("bash")
    assert is_binary(executable)

    {output, status} =
      System.cmd(
        executable,
        ["./context-pruner", "help", "lookup"],
        cd: @repo_root,
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "context-pruner lookup --query <query>"
  end
end
