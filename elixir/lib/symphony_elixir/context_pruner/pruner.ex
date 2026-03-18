defmodule SymphonyElixir.ContextPruner.Pruner do
  @moduledoc """
  Shared prune-service client for the direct `context-pruner` CLI.

  This keeps Symphony's runtime contract intentionally small while preserving
  the request and response semantics already verified against the Jeeves
  pruner service.
  """

  @default_timeout_ms 30_000
  @max_timeout_ms 300_000
  @min_timeout_ms 100

  @type config :: %{
          enabled: boolean(),
          timeout_ms: pos_integer(),
          url: String.t()
        }

  @spec config(map()) :: {config(), [String.t()]}
  def config(env \\ System.get_env()) when is_map(env) do
    url =
      env["PRUNER_URL"]
      |> fallback_url(env["JEEVES_PRUNER_URL"])

    {timeout_ms, warnings} = parse_timeout_ms(env["PRUNER_TIMEOUT_MS"])

    {
      %{
        enabled: url != "",
        timeout_ms: timeout_ms,
        url: url
      },
      warnings
    }
  end

  @spec prune(String.t(), String.t(), map()) :: {String.t(), [String.t()]}
  def prune(code, query, env \\ System.get_env())
      when is_binary(code) and is_binary(query) and is_map(env) do
    {config, warnings} = config(env)

    case config.enabled do
      false ->
        {code, warnings}

      true ->
        do_prune(code, query, config, warnings)
    end
  end

  defp do_prune(code, query, config, warnings) do
    case Application.ensure_all_started(:req) do
      {:ok, _started_apps} ->
        run_prune_request(code, query, config, warnings)

      {:error, reason} ->
        {code,
         warnings ++
           [
             "[context-pruner] Failed to start Req dependencies (#{format_reason(reason)}); falling back to original content."
           ]}
    end
  end

  defp run_prune_request(code, query, config, warnings) do
    case Req.post(config.url,
           connect_options: [timeout: config.timeout_ms],
           json: %{code: code, query: query},
           receive_timeout: config.timeout_ms,
           retry: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case extract_pruned_text(body) do
          {:ok, pruned_text} ->
            {pruned_text, warnings}

          :error ->
            {code,
             warnings ++
               [
                 "[context-pruner] Pruner response missing pruned_code/content/text string field; falling back to original content."
               ]}
        end

      {:ok, %Req.Response{status: status}} ->
        {code,
         warnings ++
           ["[context-pruner] Pruner returned HTTP #{status}; falling back to original content."]}

      {:error, reason} ->
        {code,
         warnings ++
           [
             "[context-pruner] Pruner call failed (#{format_reason(reason)}); falling back to original content."
           ]}
    end
  end

  defp extract_pruned_text(%{"pruned_code" => value}) when is_binary(value), do: {:ok, value}
  defp extract_pruned_text(%{"content" => value}) when is_binary(value), do: {:ok, value}
  defp extract_pruned_text(%{"text" => value}) when is_binary(value), do: {:ok, value}
  defp extract_pruned_text(%{pruned_code: value}) when is_binary(value), do: {:ok, value}
  defp extract_pruned_text(%{content: value}) when is_binary(value), do: {:ok, value}
  defp extract_pruned_text(%{text: value}) when is_binary(value), do: {:ok, value}
  defp extract_pruned_text(_body), do: :error

  defp fallback_url(nil, nil), do: ""
  defp fallback_url(url, _alias) when is_binary(url), do: String.trim(url)
  defp fallback_url(_, alias_url) when is_binary(alias_url), do: String.trim(alias_url)
  defp fallback_url(_, _), do: ""

  defp parse_timeout_ms(nil), do: {@default_timeout_ms, []}

  defp parse_timeout_ms(raw_timeout) when is_binary(raw_timeout) do
    trimmed = String.trim(raw_timeout)

    if trimmed == "" do
      {@default_timeout_ms, []}
    else
      case Integer.parse(trimmed) do
        {timeout_ms, ""} when timeout_ms < @min_timeout_ms ->
          {@min_timeout_ms,
           [
             "[context-pruner] PRUNER_TIMEOUT_MS (#{timeout_ms}) is below the minimum; clamped to #{@min_timeout_ms}ms."
           ]}

        {timeout_ms, ""} when timeout_ms > @max_timeout_ms ->
          {@max_timeout_ms,
           [
             "[context-pruner] PRUNER_TIMEOUT_MS (#{timeout_ms}) is above the maximum; clamped to #{@max_timeout_ms}ms."
           ]}

        {timeout_ms, ""} ->
          {timeout_ms, []}

        _ ->
          {@default_timeout_ms,
           [
             "[context-pruner] PRUNER_TIMEOUT_MS is not a valid integer (#{inspect(raw_timeout)}); using #{@default_timeout_ms}ms."
           ]}
      end
    end
  end

  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)
end
