defmodule SymphonyElixir.IssueConfig do
  @moduledoc """
  Resolves the effective workflow and per-issue settings for a Linear issue.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ProjectWorkflow
  alias SymphonyElixir.Workspace
  alias SymphonyElixir.Workflow

  defstruct [
    :mode,
    :project_route,
    :workflow_path,
    :workflow,
    :settings,
    :prompt_template
  ]

  @type t :: %__MODULE__{
          mode: :legacy | :global,
          project_route: map() | nil,
          workflow_path: Path.t() | nil,
          workflow: map(),
          settings: Schema.t(),
          prompt_template: String.t()
        }

  @spec workflow_path_for_issue(Path.t(), map()) :: Path.t()
  def workflow_path_for_issue(workflow_path, issue) when is_binary(workflow_path) and is_map(issue) do
    case issue_workflow_path(workflow_path, issue) do
      path when is_binary(path) -> path
      _ -> workflow_path
    end
  end

  @spec resolve(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(issue, opts \\ []) when is_map(issue) do
    settings = Keyword.get(opts, :settings)

    case Config.startup_mode() do
      :global ->
        resolve_global(issue, settings || Config.settings!())

      _ ->
        resolve_legacy(issue, settings)
    end
  end

  defp resolve_global(issue, %Schema{} = settings) do
    case Config.linear_project_route(issue, settings) do
      %{workflow: workflow_ref} = project_route when is_binary(workflow_ref) and workflow_ref != "" ->
        with {:ok, repo_root} <- Workspace.ensure_local_repo_cache(project_route, settings),
             {:ok, workflow_path} <- Config.resolve_project_workflow_path(repo_root, workflow_ref),
             selected_workflow_path <- workflow_path_for_issue(workflow_path, issue),
             {:ok, workflow} <- ProjectWorkflow.load(selected_workflow_path) do
          effective_settings = merge_settings(settings, project_route, workflow)

          {:ok,
           %__MODULE__{
             mode: :global,
             project_route: project_route,
             workflow_path: selected_workflow_path,
             workflow: workflow,
             settings: effective_settings,
             prompt_template: prompt_template(workflow.prompt_template)
           }}
        end

      %{slug: slug} ->
        {:error, {:missing_project_workflow, slug}}

      nil ->
        {:error, {:missing_project_route, project_slug(issue)}}
    end
  end

  defp resolve_legacy(issue, settings_override) do
    default_workflow_path = Workflow.workflow_file_path()
    workflow_path = workflow_path_for_issue(default_workflow_path, issue)

    workflow_result =
      if workflow_path == default_workflow_path,
        do: Workflow.current(),
        else: Workflow.load(workflow_path)

    with {:ok, workflow} <- workflow_result,
         {:ok, settings} <- legacy_settings(workflow, workflow_path, default_workflow_path, settings_override) do
      {:ok,
       %__MODULE__{
         mode: :legacy,
         project_route: Config.linear_project_route(issue, settings),
         workflow_path: workflow_path,
         workflow: workflow,
         settings: settings,
         prompt_template: prompt_template(workflow.prompt_template)
       }}
    end
  end

  defp legacy_settings(_workflow, workflow_path, default_workflow_path, %Schema{} = settings)
       when workflow_path == default_workflow_path do
    {:ok, settings}
  end

  defp legacy_settings(workflow, workflow_path, _default_workflow_path, _settings_override) do
    Schema.parse(workflow.config,
      mode: :legacy,
      base_dir: Path.dirname(workflow_path)
    )
  end

  defp merge_settings(%Schema{} = settings, project_route, workflow) do
    updated_agent =
      settings.agent
      |> merge_struct_fields(workflow.agent, [
        :backend,
        :default_effort,
        :max_concurrent_agents,
        :max_turns,
        :max_retry_backoff_ms,
        :max_concurrent_agents_by_state
      ])
      |> Map.put(:backend, project_route.backend || workflow.agent.backend || settings.agent.backend)

    %{
      settings
      | agent: updated_agent,
        hooks: merge_struct_fields(settings.hooks, workflow.hooks, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms]),
        codex:
          merge_struct_fields(settings.codex, workflow.codex, [
            :command,
            :approval_policy,
            :thread_sandbox,
            :turn_sandbox_policy,
            :turn_timeout_ms,
            :read_timeout_ms,
            :stall_timeout_ms
          ]),
        opencode:
          merge_struct_fields(settings.opencode, workflow.opencode, [
            :command,
            :agent,
            :model,
            :turn_timeout_ms,
            :read_timeout_ms,
            :stall_timeout_ms
          ]),
        claude:
          merge_struct_fields(settings.claude, workflow.claude, [
            :command,
            :model,
            :permission_mode,
            :turn_timeout_ms,
            :read_timeout_ms,
            :stall_timeout_ms
          ])
    }
  end

  defp merge_struct_fields(base, overrides, fields) when is_list(fields) do
    Enum.reduce(fields, base, fn field, acc ->
      case Map.get(overrides, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp prompt_template(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.default_prompt_template()
    else
      prompt
    end
  end

  defp prompt_template(_prompt), do: Config.default_prompt_template()

  defp issue_workflow_path(workflow_path, %{state: state}) when is_binary(state) do
    suffix = workflow_state_suffix(state)

    cond do
      suffix == "" ->
        nil

      true ->
        candidate = Path.join(Path.dirname(workflow_path), "WORKFLOW_#{suffix}.md")
        if File.regular?(candidate), do: candidate
    end
  end

  defp issue_workflow_path(workflow_path, %{"state" => state}) when is_binary(state) do
    issue_workflow_path(workflow_path, %{state: state})
  end

  defp issue_workflow_path(_workflow_path, _issue), do: nil

  defp workflow_state_suffix(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp project_slug(%{project_slug: project_slug}) when is_binary(project_slug), do: project_slug
  defp project_slug(%{"project_slug" => project_slug}) when is_binary(project_slug), do: project_slug
  defp project_slug(_issue), do: nil
end
