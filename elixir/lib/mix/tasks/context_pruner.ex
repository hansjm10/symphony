defmodule Mix.Tasks.ContextPruner do
  use Mix.Task

  @shortdoc "Run the context-pruner CLI from Mix"

  @moduledoc """
  Runs the `context-pruner` CLI through Mix.

  Usage:

      mix context_pruner lookup --query "Keep beta." --file-path README.md
      mix context_pruner help lookup
  """

  alias SymphonyElixir.ContextPruner.CLI

  @impl Mix.Task
  def run(args) do
    result = CLI.evaluate(args)

    if result.stdout != "" do
      IO.write(result.stdout)
    end

    if result.stderr != "" do
      IO.write(:stderr, result.stderr)
    end

    if result.exit_code != 0 do
      System.stop(result.exit_code)
    end
  end
end
