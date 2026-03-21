defmodule SymphonyElixir.CodexConversation do
  @moduledoc """
  Builds a bounded, UI-friendly Codex conversation timeline from raw app-server updates.
  """

  @assistant_kinds ["assistant", "reasoning", "command", "tool", "file_change", "user", "session"]
  @max_text_chars 2_400
  @max_output_chars 1_600

  @spec append([map()], map()) :: [map()]
  def append(entries, update) when is_list(entries) and is_map(update) do
    case classify(update) do
      {:append_text, attrs, text} ->
        upsert_text_entry(entries, attrs, text)

      {:start, attrs} ->
        upsert_started_entry(entries, attrs)

      {:finish, attrs} ->
        upsert_finished_entry(entries, attrs)

      {:append_event, attrs} ->
        append_event_entry(entries, attrs)

      :ignore ->
        entries
    end
  end

  def append(entries, _update), do: entries

  defp classify(%{event: :session_started} = update) do
    attrs =
      base_attrs(update, "session", "Session started")
      |> Map.put(:status, "started")
      |> Map.put(:detail, update[:session_id])

    {:append_event, attrs}
  end

  defp classify(update) do
    payload = payload(update)
    method = map_get_any(payload, ["method", :method])

    cond do
      streaming_message_method?(method) ->
        classify_streaming_text(update, method)

      method in ["item/started", "codex/event/item_started"] ->
        classify_item_started(update, payload)

      method in ["item/completed", "codex/event/item_completed"] ->
        classify_item_completed(update, payload)

      method in ["item/tool/call"] ->
        classify_tool_call(update, payload)

      method in ["item/commandExecution/requestApproval", "execCommandApproval"] ->
        classify_command_request(update, payload)

      method == "codex/event/exec_command_begin" ->
        classify_exec_command_begin(update, payload)

      method == "codex/event/exec_command_end" ->
        classify_exec_command_end(update, payload)

      method in ["codex/event/agent_reasoning"] ->
        classify_reasoning_update(update, payload)

      update[:event] in [:tool_call_completed, :tool_call_failed, :unsupported_tool_call] ->
        classify_tool_event(update, payload)

      true ->
        :ignore
    end
  end

  defp classify_streaming_text(update, method) do
    kind = streaming_kind(method)
    text = extract_stream_text(payload(update))

    if kind in @assistant_kinds and is_binary(text) and String.trim(text) != "" do
      attrs =
        base_attrs(update, kind, default_title(kind))
        |> Map.put(:status, "streaming")

      {:append_text, attrs, text}
    else
      :ignore
    end
  end

  defp classify_item_started(update, payload) do
    with {:ok, attrs} <- item_attrs(update, payload) do
      {:start, Map.put(attrs, :status, "started")}
    end
  end

  defp classify_item_completed(update, payload) do
    with {:ok, attrs} <- item_attrs(update, payload) do
      {:finish, Map.put(attrs, :status, item_status(payload) || "completed")}
    end
  end

  defp classify_tool_call(update, payload) do
    tool_name = tool_name(payload)

    attrs =
      base_attrs(update, "tool", tool_name || "Dynamic tool")
      |> Map.put(:item_id, item_id(payload))
      |> Map.put(:status, "started")
      |> maybe_put(:detail, tool_name)

    {:start, attrs}
  end

  defp classify_tool_event(update, payload) do
    tool_name = tool_name(payload)

    attrs =
      base_attrs(update, "tool", tool_name || "Dynamic tool")
      |> Map.put(:item_id, item_id(payload))
      |> Map.put(
        :status,
        case update[:event] do
          :tool_call_completed -> "completed"
          :unsupported_tool_call -> "failed"
          _ -> "failed"
        end
      )
      |> maybe_put(:detail, tool_name)

    {:finish, attrs}
  end

  defp classify_command_request(update, payload) do
    command = extract_command(payload)

    attrs =
      base_attrs(update, "command", command || "Command execution")
      |> Map.put(:status, "started")
      |> maybe_put(:detail, command)

    {:start, attrs}
  end

  defp classify_exec_command_begin(update, payload) do
    command = extract_command(payload)

    attrs =
      base_attrs(update, "command", command || "Command execution")
      |> Map.put(:status, "started")
      |> maybe_put(:detail, command)

    {:start, attrs}
  end

  defp classify_exec_command_end(update, payload) do
    attrs =
      base_attrs(update, "command", extract_command(payload) || "Command execution")
      |> Map.put(:status, exec_command_end_status(payload))
      |> maybe_put(:detail, extract_command(payload))

    {:finish, attrs}
  end

  defp classify_reasoning_update(update, payload) do
    text = extract_reasoning_text(payload)

    if is_binary(text) and String.trim(text) != "" do
      attrs =
        base_attrs(update, "reasoning", "Reasoning")
        |> Map.put(:status, "streaming")

      {:append_text, attrs, text}
    else
      :ignore
    end
  end

  defp item_attrs(update, payload) do
    item =
      map_path(payload, ["params", "item"]) ||
        map_path(payload, [:params, :item]) ||
        map_path(payload, ["params", "msg", "payload"]) ||
        map_path(payload, [:params, :msg, :payload])

    kind = item && item_kind(item)

    if kind in @assistant_kinds do
      title =
        case kind do
          "command" -> extract_command(payload) || default_title(kind)
          "tool" -> tool_name(payload) || default_title(kind)
          _ -> default_title(kind)
        end

      {:ok,
       base_attrs(update, kind, title)
       |> Map.put(:item_id, map_get_any(item, ["id", :id]))
       |> maybe_put(:detail, item_detail(kind, payload))}
    else
      :ignore
    end
  end

  defp upsert_text_entry(entries, attrs, text) do
    case find_entry_index(entries, attrs, open_only: true) do
      nil ->
        entries ++ [new_entry(attrs, content_for_kind(attrs.kind, text))]

      index ->
        List.update_at(entries, index, fn entry ->
          entry
          |> Map.put(:status, "streaming")
          |> Map.put(:updated_at, attrs.at)
          |> maybe_put(:detail, attrs[:detail] || entry[:detail])
          |> Map.update(:content, content_for_kind(attrs.kind, text), &append_content(&1, text, attrs.kind))
        end)
    end
  end

  defp upsert_started_entry(entries, attrs) do
    case find_entry_index(entries, attrs, open_only: false) do
      nil ->
        entries ++ [new_entry(attrs, nil)]

      index ->
        List.update_at(entries, index, fn entry ->
          entry
          |> Map.put(:status, attrs.status)
          |> Map.put(:updated_at, attrs.at)
          |> maybe_put(:detail, attrs[:detail] || entry[:detail])
          |> maybe_put(:title, attrs[:title] || entry[:title])
        end)
    end
  end

  defp upsert_finished_entry(entries, attrs) do
    case find_entry_index(entries, attrs, open_only: true) || find_entry_index(entries, attrs, open_only: false) do
      nil ->
        entries ++ [new_entry(attrs, nil)]

      index ->
        List.update_at(entries, index, fn entry ->
          entry
          |> Map.put(:status, attrs.status)
          |> Map.put(:updated_at, attrs.at)
          |> maybe_put(:detail, attrs[:detail] || entry[:detail])
          |> maybe_put(:title, attrs[:title] || entry[:title])
        end)
    end
  end

  defp append_event_entry(entries, attrs) do
    entries ++ [new_entry(attrs, nil)]
  end

  defp new_entry(attrs, content) do
    %{
      id: System.unique_integer([:positive, :monotonic]),
      at: attrs.at,
      updated_at: attrs.at,
      session_id: attrs.session_id,
      item_id: attrs[:item_id],
      kind: attrs.kind,
      status: attrs.status,
      title: attrs.title,
      detail: attrs[:detail],
      content: content
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp find_entry_index(entries, attrs, opts) do
    open_only? = Keyword.get(opts, :open_only, false)

    entries
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {entry, index} ->
      if entry_matches?(entry, attrs, open_only?) do
        index
      end
    end)
  end

  defp entry_matches?(entry, attrs, open_only?) do
    session_match? = entry[:session_id] == attrs[:session_id]
    kind_match? = entry[:kind] == attrs[:kind]

    item_match? =
      cond do
        is_binary(attrs[:item_id]) and attrs[:item_id] != "" ->
          entry[:item_id] == attrs[:item_id]

        true ->
          true
      end

    status_match? = !open_only? or entry_open?(entry[:status])

    session_match? and kind_match? and item_match? and status_match?
  end

  defp entry_open?(status), do: status not in ["completed", "failed", "cancelled"]

  defp item_kind(item) do
    case map_get_any(item, ["type", :type]) do
      "userMessage" -> "user"
      "agentMessage" -> "assistant"
      "reasoning" -> "reasoning"
      "commandExecution" -> "command"
      "tool" -> "tool"
      "fileChange" -> "file_change"
      other when is_binary(other) -> other
      _ -> nil
    end
  end

  defp item_status(payload) do
    payload
    |> map_path(["params", "item", "status"])
    |> fallback_status(payload)
    |> normalize_status()
  end

  defp fallback_status(nil, payload) do
    map_path(payload, [:params, :item, :status]) ||
      map_path(payload, ["params", "msg", "status"]) ||
      map_path(payload, [:params, :msg, :status])
  end

  defp fallback_status(status, _payload), do: status

  defp normalize_status(status) when is_binary(status) do
    status
    |> String.downcase()
    |> String.replace("inprogress", "started")
    |> String.replace("running", "started")
  end

  defp normalize_status(_status), do: nil

  defp content_for_kind(kind, text) do
    append_content(nil, text, kind)
  end

  defp append_content(existing, text, kind) do
    merged =
      [existing, sanitize_text(text)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("")

    truncate_content(merged, kind)
  end

  defp truncate_content(content, kind) when is_binary(content) do
    max_chars =
      if kind in ["command", "file_change"] do
        @max_output_chars
      else
        @max_text_chars
      end

    if String.length(content) > max_chars do
      case kind do
        kind when kind in ["command", "file_change"] ->
          "...\n" <> String.slice(content, -max_chars, max_chars)

        _ ->
          String.slice(content, 0, max_chars) <> "\n..."
      end
    else
      content
    end
  end

  defp truncate_content(content, _kind), do: content

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\x1B./, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  defp sanitize_text(_text), do: nil

  defp default_title("assistant"), do: "Codex reply"
  defp default_title("reasoning"), do: "Reasoning"
  defp default_title("command"), do: "Command execution"
  defp default_title("tool"), do: "Dynamic tool"
  defp default_title("file_change"), do: "File changes"
  defp default_title("user"), do: "User prompt"
  defp default_title("session"), do: "Session"
  defp default_title(kind), do: kind

  defp item_detail("command", payload), do: extract_command(payload)
  defp item_detail("tool", payload), do: tool_name(payload)
  defp item_detail(_kind, _payload), do: nil

  defp exec_command_end_status(payload) do
    case map_path(payload, ["params", "msg", "payload", "exit_code"]) ||
           map_path(payload, [:params, :msg, :payload, :exit_code]) do
      0 -> "completed"
      nil -> "completed"
      _ -> "failed"
    end
  end

  defp streaming_message_method?(method) do
    method in [
      "item/agentMessage/delta",
      "item/reasoning/summaryTextDelta",
      "item/reasoning/summaryPartAdded",
      "item/reasoning/textDelta",
      "item/commandExecution/outputDelta",
      "item/fileChange/outputDelta",
      "codex/event/agent_message_delta",
      "codex/event/agent_message_content_delta",
      "codex/event/agent_reasoning_delta",
      "codex/event/reasoning_content_delta",
      "codex/event/exec_command_output_delta"
    ]
  end

  defp streaming_kind("item/agentMessage/delta"), do: "assistant"
  defp streaming_kind("codex/event/agent_message_delta"), do: "assistant"
  defp streaming_kind("codex/event/agent_message_content_delta"), do: "assistant"
  defp streaming_kind("item/reasoning/summaryTextDelta"), do: "reasoning"
  defp streaming_kind("item/reasoning/summaryPartAdded"), do: "reasoning"
  defp streaming_kind("item/reasoning/textDelta"), do: "reasoning"
  defp streaming_kind("codex/event/agent_reasoning_delta"), do: "reasoning"
  defp streaming_kind("codex/event/reasoning_content_delta"), do: "reasoning"
  defp streaming_kind("item/commandExecution/outputDelta"), do: "command"
  defp streaming_kind("codex/event/exec_command_output_delta"), do: "command"
  defp streaming_kind("item/fileChange/outputDelta"), do: "file_change"
  defp streaming_kind(_method), do: nil

  defp extract_stream_text(payload) do
    extract_first_path(payload, [
      ["params", "delta"],
      [:params, :delta],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "outputDelta"],
      [:params, :outputDelta],
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "msg", "content"],
      [:params, :msg, :content],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "payload", "textDelta"],
      [:params, :msg, :payload, :textDelta],
      ["params", "msg", "payload", "outputDelta"],
      [:params, :msg, :payload, :outputDelta],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content]
    ])
  end

  defp extract_reasoning_text(payload) do
    extract_first_path(payload, [
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "text"],
      [:params, :text],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text]
    ])
  end

  defp extract_command(payload) do
    payload
    |> extract_first_path([
      ["params", "parsedCmd"],
      [:params, :parsedCmd],
      ["params", "command"],
      [:params, :command],
      ["params", "cmd"],
      [:params, :cmd],
      ["params", "argv"],
      [:params, :argv],
      ["params", "args"],
      [:params, :args],
      ["params", "msg", "parsedCmd"],
      [:params, :msg, :parsedCmd],
      ["params", "msg", "payload", "parsedCmd"],
      [:params, :msg, :payload, :parsedCmd],
      ["params", "msg", "payload", "command"],
      [:params, :msg, :payload, :command]
    ])
    |> normalize_command()
  end

  defp normalize_command(%{} = command) do
    base = map_get_any(command, ["parsedCmd", :parsedCmd, "command", :command, "cmd", :cmd])
    args = map_get_any(command, ["args", :args, "argv", :argv])

    cond do
      is_binary(base) and is_list(args) and Enum.all?(args, &is_binary/1) ->
        normalize_command([base | args])

      is_binary(base) ->
        base

      true ->
        normalize_command(args)
    end
  end

  defp normalize_command(command) when is_binary(command) do
    command
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> normalize_command()
    end
  end

  defp normalize_command(_command), do: nil

  defp tool_name(payload) do
    extract_first_path(payload, [
      ["params", "tool"],
      [:params, :tool],
      ["params", "name"],
      [:params, :name],
      ["params", "msg", "tool"],
      [:params, :msg, :tool],
      ["params", "msg", "payload", "tool"],
      [:params, :msg, :payload, :tool],
      ["params", "msg", "payload", "name"],
      [:params, :msg, :payload, :name]
    ])
  end

  defp item_id(payload) do
    extract_first_path(payload, [
      ["id"],
      [:id],
      ["params", "item", "id"],
      [:params, :item, :id],
      ["params", "msg", "payload", "id"],
      [:params, :msg, :payload, :id]
    ])
  end

  defp base_attrs(update, kind, title) do
    %{
      at: update[:timestamp] || DateTime.utc_now(),
      session_id: update[:session_id],
      kind: kind,
      title: title
    }
  end

  defp payload(update) when is_map(update) do
    update[:payload] || update["payload"] || update
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp extract_first_path(map, paths) when is_map(map) and is_list(paths) do
    Enum.find_value(paths, &map_path(map, &1))
  end

  defp extract_first_path(_map, _paths), do: nil

  defp map_get_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_get_any(_map, _keys), do: nil

  defp map_path(map, [key]), do: map_get_any(map, [key])

  defp map_path(map, [key | rest]) do
    case map_get_any(map, [key]) do
      %{} = nested -> map_path(nested, rest)
      _ -> nil
    end
  end

  defp map_path(_map, _path), do: nil
end
