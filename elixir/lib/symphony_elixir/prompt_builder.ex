defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    session_kind = Keyword.get(opts, :session_kind, :implementation)

    template =
      Workflow.current()
      |> prompt_template!(session_kind)
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "session_kind" => Config.session_kind_name(session_kind),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, workflow}, session_kind) when is_map(workflow) do
    workflow
    |> prompt_template_for(session_kind)
    |> default_prompt(session_kind)
  end

  defp prompt_template!({:error, reason}, _session_kind) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp prompt_template_for(%{review_prompt_template: prompt}, :codex_review), do: prompt
  defp prompt_template_for(%{prompt_template: prompt}, _session_kind), do: prompt
  defp prompt_template_for(_workflow, _session_kind), do: nil

  defp default_prompt(prompt, session_kind) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt(session_kind)
    else
      prompt
    end
  end

  defp default_prompt(_prompt, session_kind), do: Config.workflow_prompt(session_kind)
end
