defmodule SymphonyElixir.ContextPruner.CLI do
  @moduledoc """
  Direct shell-facing `context-pruner` CLI.

  The command surface is intentionally small and adapts the validated Jeeves
  `mcp-pruner` semantics into Symphony-native Elixir code without requiring the
  old repository at runtime.
  """

  alias SymphonyElixir.ContextPruner.Pruner

  @default_max_matches 200
  @default_radius 20
  @max_context_lines 50
  @max_max_matches 1000

  @type result :: %{
          exit_code: non_neg_integer(),
          stderr: String.t(),
          stdout: String.t()
        }

  @spec main([String.t()]) :: no_return()
  def main(argv) when is_list(argv) do
    %{exit_code: exit_code, stderr: stderr, stdout: stdout} = evaluate(argv)

    if stdout != "" do
      IO.binwrite(stdout)
      maybe_write_trailing_newline(:stdio, stdout)
    end

    if stderr != "" do
      IO.binwrite(:stderr, stderr)
      maybe_write_trailing_newline(:stderr, stderr)
    end

    System.halt(exit_code)
  end

  @spec evaluate([String.t()]) :: result()
  def evaluate(argv) when is_list(argv) do
    case argv do
      [] ->
        usage_error("A subcommand is required.")

      ["--help"] ->
        success(usage())

      ["help"] ->
        success(usage())

      ["help", subcommand] ->
        subcommand_help(subcommand)

      ["read" | rest] ->
        evaluate_read(rest)

      ["grep" | rest] ->
        evaluate_grep(rest)

      ["bash" | rest] ->
        evaluate_bash(rest)

      [subcommand | _rest] ->
        usage_error("Unknown subcommand: #{subcommand}")
    end
  end

  defp evaluate_read(argv) do
    {opts, positionals, invalid} =
      OptionParser.parse(argv,
        strict: [
          around_line: :integer,
          end_line: :integer,
          file_path: :string,
          focus: :string,
          help: :boolean,
          radius: :integer,
          start_line: :integer
        ]
      )

    cond do
      Keyword.get(opts, :help, false) ->
        success(read_usage())

      invalid != [] or positionals != [] ->
        command_error(read_usage(), 2, invalid_arguments_message(positionals, invalid))

      true ->
        with {:ok, file_path} <- require_string_option(opts, :file_path, "--file-path is required."),
             :ok <- validate_read_window(opts),
             {:ok, content} <- read_file_content(file_path, opts) do
          {stdout, warnings} = maybe_prune(content, Keyword.get(opts, :focus))
          build_result(stdout, warnings, 0)
        else
          {:error, message} ->
            %{exit_code: 1, stderr: message, stdout: ""}
        end
    end
  end

  defp evaluate_grep(argv) do
    {opts, positionals, invalid} =
      OptionParser.parse(argv,
        strict: [
          context_lines: :integer,
          focus: :string,
          help: :boolean,
          max_matches: :integer,
          path: :string,
          pattern: :string
        ]
      )

    cond do
      Keyword.get(opts, :help, false) ->
        success(grep_usage())

      invalid != [] or positionals != [] ->
        command_error(grep_usage(), 2, invalid_arguments_message(positionals, invalid))

      true ->
        with {:ok, pattern} <- require_string_option(opts, :pattern, "--pattern is required."),
             :ok <- validate_grep_bounds(opts),
             {:ok, regex} <- compile_regex(pattern) do
          regex
          |> grep(opts)
          |> finalize_grep_result(Keyword.get(opts, :focus))
        else
          {:error, message} ->
            %{exit_code: 2, stderr: message, stdout: ""}
        end
    end
  end

  defp evaluate_bash(argv) do
    {opts, positionals, invalid} =
      OptionParser.parse(argv,
        strict: [
          command: :string,
          focus: :string,
          help: :boolean
        ]
      )

    cond do
      Keyword.get(opts, :help, false) ->
        success(bash_usage())

      invalid != [] or positionals != [] ->
        command_error(bash_usage(), 2, invalid_arguments_message(positionals, invalid))

      true ->
        case require_string_option(opts, :command, "--command is required.") do
          {:ok, command} ->
            execute_bash(command, Keyword.get(opts, :focus))

          {:error, message} ->
            %{exit_code: 2, stderr: message, stdout: ""}
        end
    end
  end

  defp read_file_content(file_path, opts) do
    resolved_path = resolve_path(file_path)

    case File.read(resolved_path) do
      {:ok, content} ->
        {:ok, maybe_window_file_content(content, opts)}

      {:error, reason} ->
        {:error, "Error reading file: #{resolved_path}: #{:file.format_error(reason)}"}
    end
  end

  defp maybe_window_file_content(content, opts) do
    start_line = Keyword.get(opts, :start_line)
    end_line = Keyword.get(opts, :end_line)
    around_line = Keyword.get(opts, :around_line)

    cond do
      is_integer(start_line) and is_integer(end_line) ->
        content
        |> split_file_lines()
        |> render_line_window(start_line, end_line)

      is_integer(around_line) ->
        radius = Keyword.get(opts, :radius, @default_radius)

        content
        |> split_file_lines()
        |> render_line_window(max(1, around_line - radius), around_line + radius)

      true ->
        content
    end
  end

  defp split_file_lines(content) do
    content
    |> String.split(~r/\r\n|\n|\r/, trim: false)
    |> drop_trailing_empty_line()
  end

  defp render_line_window(lines, start_line, end_line) do
    bounded_start = max(start_line, 1)
    bounded_end = min(end_line, length(lines))

    if lines == [] or bounded_start > bounded_end do
      "(no lines in range)"
    else
      bounded_start..bounded_end
      |> Enum.map_join("\n", fn line_no -> "#{line_no}: #{Enum.at(lines, line_no - 1, "")}" end)
      |> Kernel.<>("\n")
    end
  end

  defp grep(regex, opts) do
    cwd = current_working_directory()
    context_lines = Keyword.get(opts, :context_lines, 0)
    max_matches = Keyword.get(opts, :max_matches, @default_max_matches)
    search_path = resolve_path(Keyword.get(opts, :path, "."))

    with {:ok, files} <- collect_files(search_path) do
      {outputs, errors} =
        Enum.reduce(files, {[], []}, fn file_path, acc ->
          accumulate_grep_result(file_path, regex, cwd, context_lines, acc)
        end)

      build_grep_result(outputs, errors, max_matches)
    end
  end

  defp grep_file(file_path, regex, cwd, context_lines) do
    case File.read(file_path) do
      {:ok, content} ->
        format_grep_matches(content, regex, cwd, file_path, context_lines)

      {:error, reason} ->
        {:error, "#{display_path(cwd, file_path)}: #{:file.format_error(reason)}"}
    end
  end

  defp build_grep_result([], [], _max_matches) do
    %{exit_code: 1, stderr: "", stdout: "(no matches found)"}
  end

  defp build_grep_result(lines, errors, max_matches) do
    {stdout, _truncated_line_count} = truncate_lines(lines, max_matches)

    exit_code =
      case errors do
        [] -> 0
        _ -> 2
      end

    %{
      exit_code: exit_code,
      stderr: Enum.join(errors, "\n"),
      stdout: stdout
    }
  end

  defp matched_line_indexes(lines, regex) do
    lines
    |> Enum.with_index()
    |> Enum.reduce([], fn {line, index}, acc ->
      case Regex.match?(regex, line) do
        true -> acc ++ [index]
        false -> acc
      end
    end)
  end

  defp format_match_lines(display_path, lines, matches) do
    Enum.map(matches, fn index ->
      "#{display_path}:#{index + 1}:#{Enum.at(lines, index, "")}"
    end)
  end

  defp format_context_lines(display_path, lines, matches, context_lines) do
    ranges =
      Enum.reduce(matches, [], fn index, acc ->
        merge_context_range(acc, index, context_lines, length(lines))
      end)
      |> Enum.reverse()

    ranges
    |> Enum.with_index()
    |> Enum.flat_map(fn {range, index} ->
      render_context_range(display_path, lines, range, index, length(ranges))
    end)
  end

  defp truncate_lines(lines, max_matches) do
    case length(lines) <= max_matches do
      true ->
        {Enum.join(lines, "\n"), 0}

      false ->
        kept_lines = Enum.take(lines, max_matches)
        truncated_line_count = length(lines) - max_matches

        {Enum.join(kept_lines ++ ["(truncated #{truncated_line_count} lines)"], "\n"), truncated_line_count}
    end
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

  defp execute_bash(command, focus) do
    with {:ok, shell} <- resolve_shell(),
         {:ok, stdout, stderr, exit_code} <- run_shell_command(shell, command) do
      rendered_output = format_bash_output(stdout, stderr, exit_code)

      {pruned_output, warnings} =
        case rendered_output do
          "(no output)" -> {rendered_output, []}
          _ -> maybe_prune(rendered_output, focus)
        end

      build_result(pruned_output, warnings, exit_code)
    else
      {:error, message, exit_code} ->
        %{exit_code: exit_code, stderr: message, stdout: ""}
    end
  end

  defp resolve_shell do
    case System.find_executable("bash") || System.find_executable("sh") do
      nil ->
        {:error, "No usable shell was found on this host.", 127}

      shell ->
        {:ok, shell}
    end
  end

  defp run_shell_command(shell, command) do
    stderr_path =
      Path.join(
        System.tmp_dir!(),
        "context-pruner-stderr-#{System.unique_integer([:positive])}"
      )

    wrapped_command = "( #{command} ) 2>#{shell_escape(stderr_path)}"
    File.write!(stderr_path, "")

    try do
      {stdout, exit_code} = System.cmd(shell, ["-lc", wrapped_command], cd: current_working_directory())
      stderr = read_temp_output(stderr_path)
      {:ok, stdout, stderr, exit_code}
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        {:error, "Error executing command: #{Exception.message(error)}", 1}
    after
      File.rm(stderr_path)
    end
  end

  defp format_bash_output(stdout, stderr, exit_code) do
    parts =
      []
      |> maybe_append(stdout != "", stdout)
      |> maybe_append(stderr != "", "[stderr]\n" <> stderr)
      |> maybe_append(exit_code != 0, "[exit code: #{exit_code}]")

    case parts do
      [] -> "(no output)"
      _ -> Enum.join(parts, "\n")
    end
  end

  defp maybe_append(list, true, value), do: list ++ [value]
  defp maybe_append(list, false, _value), do: list

  defp maybe_prune(content, nil), do: {content, []}

  defp maybe_prune(content, focus) when is_binary(focus) do
    trimmed_focus = String.trim(focus)

    case trimmed_focus do
      "" -> {content, []}
      _ -> Pruner.prune(content, trimmed_focus)
    end
  end

  defp validate_read_window(opts) do
    start_line = Keyword.get(opts, :start_line)
    end_line = Keyword.get(opts, :end_line)
    around_line = Keyword.get(opts, :around_line)
    radius = Keyword.get(opts, :radius)

    [
      validate_radius_usage(radius, around_line),
      validate_window_combination(around_line, start_line, end_line),
      validate_range_pair(start_line, end_line),
      validate_minimum(start_line, 1, "--start-line must be at least 1."),
      validate_minimum(end_line, 1, "--end-line must be at least 1."),
      validate_range_order(start_line, end_line),
      validate_minimum(around_line, 1, "--around-line must be at least 1."),
      validate_minimum(radius, 0, "--radius must be 0 or greater.")
    ]
    |> first_error()
  end

  defp validate_grep_bounds(opts) do
    context_lines = Keyword.get(opts, :context_lines, 0)
    max_matches = Keyword.get(opts, :max_matches, @default_max_matches)

    cond do
      context_lines < 0 ->
        {:error, "--context-lines must be 0 or greater."}

      context_lines > @max_context_lines ->
        {:error, "--context-lines cannot exceed #{@max_context_lines}."}

      max_matches < 1 ->
        {:error, "--max-matches must be at least 1."}

      max_matches > @max_max_matches ->
        {:error, "--max-matches cannot exceed #{@max_max_matches}."}

      true ->
        :ok
    end
  end

  defp compile_regex(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        {:ok, regex}

      {:error, {reason, _at}} ->
        {:error, "Error: #{reason}"}
    end
  end

  defp require_string_option(opts, key, error_message) do
    case opts[key] do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if byte_size(trimmed) > 0 do
          {:ok, trimmed}
        else
          {:error, error_message}
        end

      _ ->
        {:error, error_message}
    end
  end

  defp resolve_path(path) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _ -> Path.expand(path, current_working_directory())
    end
  end

  defp display_path(cwd, file_path) do
    relative = Path.relative_to(file_path, cwd)

    cond do
      relative == file_path ->
        normalize_path(file_path)

      String.starts_with?(relative, "..") ->
        normalize_path(file_path)

      true ->
        normalize_path(relative)
    end
  end

  defp normalize_path(path), do: String.replace(path, "\\", "/")

  defp read_temp_output(path) do
    case File.read(path) do
      {:ok, output} -> output
      {:error, _reason} -> ""
    end
  end

  defp current_working_directory do
    case System.get_env("CONTEXT_PRUNER_CWD") do
      nil -> File.cwd!()
      "" -> File.cwd!()
      cwd -> cwd
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp invalid_arguments_message(positionals, invalid) do
    invalid_message =
      invalid
      |> Enum.map_join("\n", fn
        {option, nil} -> "Unknown option: #{option}"
        {option, _value} -> "Invalid value for #{option}"
      end)

    positional_message =
      case positionals do
        [] -> ""
        _ -> "Unexpected positional arguments: #{Enum.join(positionals, " ")}"
      end

    [invalid_message, positional_message]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp accumulate_grep_result(file_path, regex, cwd, context_lines, {output_acc, error_acc}) do
    case grep_file(file_path, regex, cwd, context_lines) do
      {:ok, []} ->
        {output_acc, error_acc}

      {:ok, lines} ->
        {output_acc ++ lines, error_acc}

      {:error, message} ->
        {output_acc, error_acc ++ [message]}
    end
  end

  defp format_grep_matches(content, regex, cwd, file_path, context_lines) do
    lines = split_file_lines(content)
    matches = matched_line_indexes(lines, regex)

    if matches == [] do
      {:ok, []}
    else
      display_path = display_path(cwd, file_path)
      {:ok, grep_output_lines(display_path, lines, matches, context_lines)}
    end
  end

  defp grep_output_lines(display_path, lines, matches, 0) do
    format_match_lines(display_path, lines, matches)
  end

  defp grep_output_lines(display_path, lines, matches, context_lines) do
    format_context_lines(display_path, lines, matches, context_lines)
  end

  defp finalize_grep_result(%{exit_code: 0, stderr: stderr, stdout: stdout}, focus) do
    {pruned_stdout, warnings} = maybe_prune(stdout, focus)
    build_result(pruned_stdout, split_lines(stderr) ++ warnings, 0)
  end

  defp finalize_grep_result(result, _focus), do: result

  defp merge_context_range(acc, index, context_lines, line_count) do
    start_line = max(index - context_lines, 0)
    end_line = min(index + context_lines, line_count - 1)
    new_range = %{end_line: end_line, match_lines: MapSet.new([index]), start_line: start_line}

    case acc do
      [%{end_line: last_end} = last_range | rest] when start_line <= last_end + 1 ->
        [extend_context_range(last_range, new_range) | rest]

      _ ->
        [new_range | acc]
    end
  end

  defp extend_context_range(last_range, new_range) do
    %{
      end_line: max(last_range.end_line, new_range.end_line),
      match_lines: MapSet.union(last_range.match_lines, new_range.match_lines),
      start_line: last_range.start_line
    }
  end

  defp render_context_range(display_path, lines, range, index, range_count) do
    rendered =
      Enum.map(range.start_line..range.end_line, fn line_index ->
        render_context_line(display_path, lines, range.match_lines, line_index)
      end)

    append_range_separator(rendered, index, range_count)
  end

  defp render_context_line(display_path, lines, match_lines, line_index) do
    separator = if MapSet.member?(match_lines, line_index), do: ":", else: "-"
    "#{display_path}#{separator}#{line_index + 1}#{separator}#{Enum.at(lines, line_index, "")}"
  end

  defp append_range_separator(rendered, index, range_count) when index < range_count - 1,
    do: rendered ++ ["--"]

  defp append_range_separator(rendered, _index, _range_count), do: rendered

  defp collect_directory_files(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
          merge_collected_files(acc, collect_files(Path.join(path, entry)))
        end)

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp merge_collected_files(acc, {:ok, files}), do: {:cont, {:ok, acc ++ files}}
  defp merge_collected_files(_acc, {:error, reason}), do: {:halt, {:error, reason}}

  defp validate_radius_usage(radius, around_line)
       when is_integer(radius) and not is_integer(around_line),
       do: {:error, "--radius requires --around-line."}

  defp validate_radius_usage(_radius, _around_line), do: :ok

  defp validate_window_combination(around_line, start_line, end_line)
       when is_integer(around_line) and (is_integer(start_line) or is_integer(end_line)),
       do: {:error, "--around-line cannot be combined with --start-line/--end-line."}

  defp validate_window_combination(_around_line, _start_line, _end_line), do: :ok

  defp validate_range_pair(start_line, end_line) when is_integer(start_line) != is_integer(end_line),
    do: {:error, "--start-line and --end-line must be provided together."}

  defp validate_range_pair(_start_line, _end_line), do: :ok

  defp validate_minimum(value, minimum, error_message) when is_integer(value) and value < minimum,
    do: {:error, error_message}

  defp validate_minimum(_value, _minimum, _error_message), do: :ok

  defp validate_range_order(start_line, end_line)
       when is_integer(start_line) and is_integer(end_line) and start_line > end_line,
       do: {:error, "--start-line cannot be greater than --end-line."}

  defp validate_range_order(_start_line, _end_line), do: :ok

  defp first_error(results) do
    Enum.find(results, :ok, &match?({:error, _message}, &1))
  end

  defp subcommand_help("read"), do: success(read_usage())
  defp subcommand_help("grep"), do: success(grep_usage())
  defp subcommand_help("bash"), do: success(bash_usage())
  defp subcommand_help(subcommand), do: usage_error("Unknown subcommand: #{subcommand}")

  defp usage_error(message), do: command_error(usage(), 2, message)

  defp command_error(usage_text, exit_code, message) do
    %{
      exit_code: exit_code,
      stderr: [message, usage_text] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n"),
      stdout: ""
    }
  end

  defp success(stdout), do: %{exit_code: 0, stderr: "", stdout: stdout}

  defp build_result(stdout, warnings, exit_code) do
    %{
      exit_code: exit_code,
      stderr: Enum.join(split_lines(warnings), "\n"),
      stdout: stdout
    }
  end

  defp split_lines(lines) when is_list(lines), do: Enum.reject(lines, &(&1 == ""))
  defp split_lines(value) when is_binary(value), do: Enum.reject([value], &(&1 == ""))

  defp maybe_write_trailing_newline(device, content) do
    if !String.ends_with?(content, "\n") do
      IO.binwrite(device, "\n")
    end
  end

  defp drop_trailing_empty_line([]), do: []

  defp drop_trailing_empty_line(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _ -> lines
    end
  end

  defp usage do
    """
    Usage:
      context-pruner read --file-path <path> [--start-line <n> --end-line <n> | --around-line <n> --radius <n>] [--focus <query>]
      context-pruner grep --pattern <regex> [--path <path>] [--context-lines <n>] [--max-matches <n>] [--focus <query>]
      context-pruner bash --command <shell-command> [--focus <query>]
    """
  end

  defp read_usage do
    """
    Usage:
      context-pruner read --file-path <path> [--start-line <n> --end-line <n>]
      context-pruner read --file-path <path> [--around-line <n> --radius <n>]

    Options:
      --file-path <path>    File to read, relative to the current working directory when not absolute.
      --start-line <n>      1-based inclusive start line for focused reads.
      --end-line <n>        1-based inclusive end line for focused reads.
      --around-line <n>     1-based anchor line for around/radius reads.
      --radius <n>          Context radius used with --around-line. Default: #{@default_radius}
      --focus <query>       Optional prune query sent as { code, query } to the configured pruner service.
    """
  end

  defp grep_usage do
    """
    Usage:
      context-pruner grep --pattern <regex> [--path <path>] [--context-lines <n>] [--max-matches <n>] [--focus <query>]

    Options:
      --pattern <regex>     Regular expression to search for.
      --path <path>         File or directory to search. Default: current directory.
      --context-lines <n>   Number of surrounding lines to include. Max: #{@max_context_lines}
      --max-matches <n>     Maximum output lines before truncation. Default: #{@default_max_matches}
      --focus <query>       Optional prune query sent as { code, query } to the configured pruner service.
    """
  end

  defp bash_usage do
    """
    Usage:
      context-pruner bash --command <shell-command> [--focus <query>]

    Options:
      --command <command>   Shell command to execute in the current working directory.
      --focus <query>       Optional prune query sent as { code, query } to the configured pruner service.
    """
  end
end
