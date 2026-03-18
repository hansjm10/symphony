defmodule SymphonyElixir.ContextPruner.CLITest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ContextPruner.CLI

  setup do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "context-pruner-cli-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temp_dir)

    previous_env = %{
      "CODEX_SESSION_ID" => System.get_env("CODEX_SESSION_ID"),
      "CONTEXT_PRUNER_ALLOWED_GLOBS" => System.get_env("CONTEXT_PRUNER_ALLOWED_GLOBS"),
      "CONTEXT_PRUNER_ALLOWED_PATHS" => System.get_env("CONTEXT_PRUNER_ALLOWED_PATHS"),
      "CONTEXT_PRUNER_ALLOWED_ROOTS" => System.get_env("CONTEXT_PRUNER_ALLOWED_ROOTS"),
      "CONTEXT_PRUNER_BACKEND" => System.get_env("CONTEXT_PRUNER_BACKEND"),
      "CONTEXT_PRUNER_CWD" => System.get_env("CONTEXT_PRUNER_CWD"),
      "CONTEXT_PRUNER_CODEX_AUTH_FILE" => System.get_env("CONTEXT_PRUNER_CODEX_AUTH_FILE"),
      "CONTEXT_PRUNER_CODEX_BIN" => System.get_env("CONTEXT_PRUNER_CODEX_BIN"),
      "CONTEXT_PRUNER_CODEX_ENV_PASSTHROUGH" => System.get_env("CONTEXT_PRUNER_CODEX_ENV_PASSTHROUGH"),
      "CONTEXT_PRUNER_MODEL" => System.get_env("CONTEXT_PRUNER_MODEL"),
      "CONTEXT_PRUNER_REASONING_EFFORT" => System.get_env("CONTEXT_PRUNER_REASONING_EFFORT"),
      "JEEVES_PRUNER_URL" => System.get_env("JEEVES_PRUNER_URL"),
      "PRUNER_TIMEOUT_MS" => System.get_env("PRUNER_TIMEOUT_MS"),
      "PRUNER_URL" => System.get_env("PRUNER_URL")
    }

    System.delete_env("CODEX_SESSION_ID")
    System.delete_env("CONTEXT_PRUNER_ALLOWED_GLOBS")
    System.delete_env("CONTEXT_PRUNER_ALLOWED_PATHS")
    System.delete_env("CONTEXT_PRUNER_ALLOWED_ROOTS")
    System.delete_env("CONTEXT_PRUNER_BACKEND")
    System.put_env("CONTEXT_PRUNER_CWD", temp_dir)
    System.delete_env("CONTEXT_PRUNER_CODEX_AUTH_FILE")
    System.delete_env("CONTEXT_PRUNER_CODEX_BIN")
    System.delete_env("CONTEXT_PRUNER_CODEX_ENV_PASSTHROUGH")
    System.delete_env("CONTEXT_PRUNER_MODEL")
    System.delete_env("CONTEXT_PRUNER_REASONING_EFFORT")
    System.delete_env("JEEVES_PRUNER_URL")
    System.delete_env("PRUNER_TIMEOUT_MS")
    System.delete_env("PRUNER_URL")

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  test "lookup returns full file contents when PRUNER_URL is unset", %{temp_dir: temp_dir} do
    file_path = Path.join(temp_dir, "sample.txt")
    File.write!(file_path, "alpha\nbeta\n")

    assert %{exit_code: 0, stderr: "", stdout: "alpha\nbeta\n"} =
             CLI.evaluate(["lookup", "--query", "Where is beta?", "--file-path", "sample.txt"])
  end

  test "lookup supports focused file windows", %{temp_dir: temp_dir} do
    file_path = Path.join(temp_dir, "sample.txt")
    File.write!(file_path, "alpha\nbeta\ngamma\ndelta\n")

    assert %{exit_code: 0, stdout: "2: beta\n3: gamma\n"} =
             CLI.evaluate([
               "lookup",
               "--query",
               "Keep only the middle lines.",
               "--file-path",
               file_path,
               "--start-line",
               "2",
               "--end-line",
               "3"
             ])
  end

  test "lookup requires a query" do
    result = CLI.evaluate(["lookup", "--file-path", "sample.txt"])

    assert result.exit_code == 2
    assert result.stderr =~ "--query is required."
    assert result.stdout == ""
  end

  test "lookup returns an error when the file is missing" do
    result = CLI.evaluate(["lookup", "--query", "Read this file.", "--file-path", "missing.txt"])

    assert result.exit_code == 1
    assert result.stderr =~ "Error reading file:"
    assert result.stdout == ""
  end

  test "lookup command mode returns stdout for successful commands" do
    result = CLI.evaluate(["lookup", "--query", "Keep alpha.", "--command", "printf 'alpha'"])

    assert result.exit_code == 0
    assert result.stderr == ""
    assert result.stdout == "alpha"
  end

  test "lookup command mode preserves stderr formatting and child exit codes" do
    result =
      CLI.evaluate([
        "lookup",
        "--query",
        "Summarize the command output.",
        "--command",
        "printf 'alpha'; printf 'beta' >&2; exit 7"
      ])

    assert result.exit_code == 7
    assert result.stderr == ""
    assert result.stdout =~ "alpha"
    assert result.stdout =~ "[stderr]\nbeta"
    assert result.stdout =~ "[exit code: 7]"
  end

  test "lookup grep mode returns bounded recursive matches with truncation", %{temp_dir: temp_dir} do
    File.write!(Path.join(temp_dir, "a.txt"), "zero\nbeta-one\none\nbeta-two\ntwo\n")

    result =
      CLI.evaluate([
        "lookup",
        "--query",
        "Keep only beta matches.",
        "--pattern",
        "beta",
        "--path",
        temp_dir,
        "--context-lines",
        "1",
        "--max-matches",
        "3"
      ])

    assert result.exit_code == 0
    assert result.stderr == ""
    assert result.stdout =~ "a.txt-1-zero"
    assert result.stdout =~ "a.txt:2:beta-one"
    assert result.stdout =~ "(truncated 2 lines)"
  end

  test "lookup grep mode returns exit code 1 when there are no matches", %{temp_dir: temp_dir} do
    File.write!(Path.join(temp_dir, "a.txt"), "alpha\nbeta\n")

    result =
      CLI.evaluate([
        "lookup",
        "--query",
        "Keep only gamma mentions.",
        "--pattern",
        "gamma",
        "--path",
        temp_dir
      ])

    assert result.exit_code == 1
    assert result.stderr == ""
    assert result.stdout == "(no matches found)"
  end

  test "lookup grep mode requires an explicit path", %{temp_dir: temp_dir} do
    File.write!(Path.join(temp_dir, "a.txt"), "alpha\nbeta\n")

    result =
      CLI.evaluate([
        "lookup",
        "--query",
        "Keep only beta mentions.",
        "--pattern",
        "beta"
      ])

    assert result.exit_code == 2
    assert result.stderr =~ "--path is required with --pattern"
    assert result.stdout == ""
  end

  test "lookup grep mode returns exit code 2 for invalid regular expressions", %{temp_dir: temp_dir} do
    File.write!(Path.join(temp_dir, "a.txt"), "alpha\nbeta\n")

    result =
      CLI.evaluate([
        "lookup",
        "--query",
        "Keep only invalid regex output.",
        "--pattern",
        "[",
        "--path",
        temp_dir
      ])

    assert result.exit_code == 2
    assert result.stderr =~ "Error:"
    assert result.stdout == ""
  end

  test "deprecated subcommands return migration guidance" do
    for subcommand <- ["read", "grep", "bash"] do
      result = CLI.evaluate([subcommand, "--help"])

      assert result.exit_code == 2
      assert result.stderr =~ "deprecated"
      assert result.stderr =~ "context-pruner lookup --query"
    end
  end

  test "lookup pruning sends the verified request shape and accepts pruned_code", %{
    temp_dir: temp_dir
  } do
    File.write!(Path.join(temp_dir, "sample.txt"), "function alpha() {}\nfunction beta() {}\n")

    with_pruner_server(200, %{"pruned_code" => "function beta() {}"}, fn pruner_url ->
      System.put_env("PRUNER_URL", pruner_url)

      result =
        CLI.evaluate([
          "lookup",
          "--query",
          "What mentions beta?",
          "--file-path",
          "sample.txt"
        ])

      assert result.exit_code == 0
      assert result.stderr == ""
      assert result.stdout == "function beta() {}"

      assert_receive {:pruner_request, request_body}, 1_000

      assert %{
               "code" => "function alpha() {}\nfunction beta() {}\n",
               "query" => "What mentions beta?"
             } = Jason.decode!(request_body)
    end)
  end

  test "lookup pruning falls back to original output when the remote service fails" do
    with_pruner_server(500, %{"error" => "boom"}, fn pruner_url ->
      System.put_env("PRUNER_URL", pruner_url)

      result =
        CLI.evaluate([
          "lookup",
          "--query",
          "Where is alpha?",
          "--command",
          "printf 'alpha'"
        ])

      assert result.exit_code == 0
      assert result.stdout == "alpha"
      assert result.stderr =~ "Pruner returned HTTP 500"
    end)
  end

  test "lookup supports blank-state codex pruning with bounded file windows", %{temp_dir: temp_dir} do
    File.write!(Path.join(temp_dir, "sample.txt"), "function alpha() {}\nfunction beta() {}\n")
    System.put_env("CODEX_SESSION_ID", "parent-session-123")

    with_fake_codex(fn codex_bin, trace_file ->
      auth_file = Path.join(temp_dir, "auth.json")
      File.write!(auth_file, ~s({"token":"test"}))

      System.put_env("CONTEXT_PRUNER_ALLOWED_ROOTS", temp_dir)
      System.put_env("CONTEXT_PRUNER_BACKEND", "codex")
      System.put_env("CONTEXT_PRUNER_CODEX_AUTH_FILE", auth_file)
      System.put_env("CONTEXT_PRUNER_CODEX_BIN", codex_bin)
      System.put_env("CONTEXT_PRUNER_MODEL", "gpt-5.3-codex-spark")

      result =
        CLI.evaluate([
          "lookup",
          "--query",
          "Keep only beta.",
          "--file-path",
          "sample.txt",
          "--start-line",
          "1",
          "--end-line",
          "2"
        ])

      assert result.exit_code == 0
      assert result.stderr == ""
      assert result.stdout == "function beta() {}"

      trace = File.read!(trace_file)
      assert trace =~ "--ephemeral"
      assert trace =~ "--skip-git-repo-check"
      assert trace =~ "--sandbox read-only"
      assert trace =~ "--model gpt-5.3-codex-spark"
      assert trace =~ "model_reasoning_effort=low"
      assert trace =~ "Keep only beta."
      assert trace =~ "1: function alpha() {}"
      assert trace =~ "2: function beta() {}"
      refute trace =~ "parent-session-123"
      refute trace =~ "CONTEXT_PRUNER_CWD=#{temp_dir}"
      refute trace =~ "HOME=/home/"
      refute trace =~ "PWD=#{temp_dir}"
      assert trace =~ "AUTH_FILE_PRESENT=yes"
      assert trace =~ "SESSIONS_DIR_PRESENT=no"
    end)
  end

  test "lookup rejects command sources when the codex backend is enabled" do
    System.put_env("CONTEXT_PRUNER_BACKEND", "codex")

    result =
      CLI.evaluate([
        "lookup",
        "--query",
        "Summarize alpha.",
        "--command",
        "printf 'alpha'"
      ])

    assert result.exit_code == 2
    assert result.stderr =~ "disabled when `CONTEXT_PRUNER_BACKEND=codex`"
    assert result.stdout == ""
  end

  test "lookup requires an explicit read window when the codex backend is enabled", %{
    temp_dir: temp_dir
  } do
    File.write!(Path.join(temp_dir, "sample.txt"), "alpha\nbeta\n")
    System.put_env("CONTEXT_PRUNER_BACKEND", "codex")

    result =
      CLI.evaluate([
        "lookup",
        "--query",
        "Keep only beta.",
        "--file-path",
        "sample.txt"
      ])

    assert result.exit_code == 2
    assert result.stderr =~ "require `--start-line/--end-line` or `--around-line/--radius`"
    assert result.stdout == ""
  end

  test "lookup rejects file paths outside the configured scope before codex execution", %{
    temp_dir: temp_dir
  } do
    outside_root =
      Path.join(
        System.tmp_dir!(),
        "context-pruner-outside-scope-#{System.unique_integer([:positive])}"
      )

    try do
      outside_file = Path.join(outside_root, "sample.txt")
      File.mkdir_p!(outside_root)
      File.write!(outside_file, "alpha\nbeta\n")

      with_fake_codex(fn codex_bin, trace_file ->
        System.put_env("CONTEXT_PRUNER_ALLOWED_ROOTS", temp_dir)
        System.put_env("CONTEXT_PRUNER_BACKEND", "codex")
        System.put_env("CONTEXT_PRUNER_CODEX_BIN", codex_bin)

        result =
          CLI.evaluate([
            "lookup",
            "--query",
            "Keep only beta.",
            "--file-path",
            outside_file,
            "--start-line",
            "1",
            "--end-line",
            "2"
          ])

        assert result.exit_code == 1
        assert result.stderr =~ "outside the configured context-pruner scope"
        assert result.stdout == ""
        refute File.exists?(trace_file)
      end)
    after
      File.rm_rf(outside_root)
    end
  end

  defp with_pruner_server(status, response_body, fun) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listener)
    parent = self()

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        %{body: request_body} = read_http_request(socket)
        send(parent, {:pruner_request, request_body})

        response_json = Jason.encode!(response_body)

        status_text =
          case status do
            200 -> "OK"
            500 -> "Internal Server Error"
            _ -> "Response"
          end

        response =
          [
            "HTTP/1.1 ",
            Integer.to_string(status),
            " ",
            status_text,
            "\r\ncontent-type: application/json\r\ncontent-length: ",
            Integer.to_string(byte_size(response_json)),
            "\r\nconnection: close\r\n\r\n",
            response_json
          ]
          |> IO.iodata_to_binary()

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    try do
      fun.("http://127.0.0.1:#{port}/prune")
    after
      Task.await(task, 1_000)
    end
  end

  defp read_http_request(socket, acc \\ "") do
    case :binary.match(acc, "\r\n\r\n") do
      {headers_end, _length} ->
        header_size = headers_end + 4
        headers = binary_part(acc, 0, header_size)
        body = binary_part(acc, header_size, byte_size(acc) - header_size)
        content_length = parse_content_length(headers)

        if byte_size(body) >= content_length do
          %{body: binary_part(body, 0, content_length), headers: headers}
        else
          {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
          read_http_request(socket, acc <> chunk)
        end

      :nomatch ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
        read_http_request(socket, acc <> chunk)
    end
  end

  defp parse_content_length(headers) do
    headers
    |> String.split("\r\n", trim: true)
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          maybe_content_length_header(name, value)

        _ ->
          nil
      end
    end)
  end

  defp maybe_content_length_header(name, value) do
    if String.downcase(name) == "content-length" do
      value |> String.trim() |> String.to_integer()
    end
  end

  defp with_fake_codex(fun) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "context-pruner-fake-codex-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    codex_bin = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "trace.txt")

    File.write!(codex_bin, """
    #!/bin/sh
    trace_file="#{trace_file}"
    all_args="$*"
    output_path=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o|--output-last-message)
          output_path="$2"
          shift 2
          ;;
        --output-schema)
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    prompt="$(cat)"

    {
      printf 'PWD=%s\\n' "$(pwd)"
      printf 'HOME=%s\\n' "${HOME:-}"
      printf 'CODEX_SESSION_ID=%s\\n' "${CODEX_SESSION_ID:-}"
      printf 'CONTEXT_PRUNER_CWD=%s\\n' "${CONTEXT_PRUNER_CWD:-}"
      if [ -f "$HOME/.codex/auth.json" ]; then auth_present=yes; else auth_present=no; fi
      if [ -d "$HOME/.codex/sessions" ]; then sessions_present=yes; else sessions_present=no; fi
      printf 'AUTH_FILE_PRESENT=%s\\n' "$auth_present"
      printf 'SESSIONS_DIR_PRESENT=%s\\n' "$sessions_present"
      printf 'ARGS=%s\\n' "$all_args"
      printf 'PROMPT<<EOF\\n%s\\nEOF\\n' "$prompt"
    } > "$trace_file"

    printf '%s' '{"pruned_text":"function beta() {}"}' > "$output_path"
    """)

    File.chmod!(codex_bin, 0o755)

    try do
      fun.(codex_bin, trace_file)
    after
      File.rm_rf(test_root)
    end
  end
end
