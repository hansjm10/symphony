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
      "CONTEXT_PRUNER_CWD" => System.get_env("CONTEXT_PRUNER_CWD"),
      "JEEVES_PRUNER_URL" => System.get_env("JEEVES_PRUNER_URL"),
      "PRUNER_TIMEOUT_MS" => System.get_env("PRUNER_TIMEOUT_MS"),
      "PRUNER_URL" => System.get_env("PRUNER_URL")
    }

    System.put_env("CONTEXT_PRUNER_CWD", temp_dir)
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

  test "read returns full file contents", %{temp_dir: temp_dir} do
    file_path = Path.join(temp_dir, "sample.txt")
    File.write!(file_path, "alpha\nbeta\n")

    assert %{exit_code: 0, stderr: "", stdout: "alpha\nbeta\n"} =
             CLI.evaluate(["read", "--file-path", "sample.txt"])
  end

  test "read supports focused line windows", %{temp_dir: temp_dir} do
    file_path = Path.join(temp_dir, "sample.txt")
    File.write!(file_path, "alpha\nbeta\ngamma\ndelta\n")

    assert %{exit_code: 0, stdout: "2: beta\n3: gamma\n"} =
             CLI.evaluate(["read", "--file-path", file_path, "--start-line", "2", "--end-line", "3"])
  end

  test "read returns an error when the file is missing" do
    result = CLI.evaluate(["read", "--file-path", "missing.txt"])

    assert result.exit_code == 1
    assert result.stderr =~ "Error reading file:"
    assert result.stdout == ""
  end

  test "bash returns stdout for successful commands" do
    result = CLI.evaluate(["bash", "--command", "printf 'alpha'"])

    assert result.exit_code == 0
    assert result.stderr == ""
    assert result.stdout == "alpha"
  end

  test "bash preserves stderr formatting and child exit codes" do
    result =
      CLI.evaluate([
        "bash",
        "--command",
        "printf 'alpha'; printf 'beta' >&2; exit 7"
      ])

    assert result.exit_code == 7
    assert result.stderr == ""
    assert result.stdout =~ "alpha"
    assert result.stdout =~ "[stderr]\nbeta"
    assert result.stdout =~ "[exit code: 7]"
  end

  test "grep returns bounded recursive matches with truncation", %{temp_dir: temp_dir} do
    File.write!(Path.join(temp_dir, "a.txt"), "zero\nbeta-one\none\nbeta-two\ntwo\n")

    result =
      CLI.evaluate([
        "grep",
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

  test "grep returns exit code 1 when there are no matches", %{temp_dir: temp_dir} do
    File.write!(Path.join(temp_dir, "a.txt"), "alpha\nbeta\n")

    result =
      CLI.evaluate([
        "grep",
        "--pattern",
        "gamma",
        "--path",
        temp_dir
      ])

    assert result.exit_code == 1
    assert result.stderr == ""
    assert result.stdout == "(no matches found)"
  end

  test "grep returns exit code 2 for invalid regular expressions", %{temp_dir: temp_dir} do
    File.write!(Path.join(temp_dir, "a.txt"), "alpha\nbeta\n")

    result =
      CLI.evaluate([
        "grep",
        "--pattern",
        "[",
        "--path",
        temp_dir
      ])

    assert result.exit_code == 2
    assert result.stderr =~ "Error:"
    assert result.stdout == ""
  end

  test "focus pruning sends the verified request shape and accepts pruned_code", %{
    temp_dir: temp_dir
  } do
    File.write!(Path.join(temp_dir, "sample.txt"), "function alpha() {}\nfunction beta() {}\n")

    with_pruner_server(200, %{"pruned_code" => "function beta() {}"}, fn pruner_url ->
      System.put_env("PRUNER_URL", pruner_url)

      result =
        CLI.evaluate([
          "read",
          "--file-path",
          "sample.txt",
          "--focus",
          "What mentions beta?"
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

  test "focus pruning falls back to original output when the remote service fails" do
    with_pruner_server(500, %{"error" => "boom"}, fn pruner_url ->
      System.put_env("PRUNER_URL", pruner_url)

      result =
        CLI.evaluate([
          "bash",
          "--command",
          "printf 'alpha'",
          "--focus",
          "Where is alpha?"
        ])

      assert result.exit_code == 0
      assert result.stdout == "alpha"
      assert result.stderr =~ "Pruner returned HTTP 500"
    end)
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
end
