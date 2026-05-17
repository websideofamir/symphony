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
      %{repo: repo} = project_route when is_binary(repo) and repo != "" ->
        workflow_ref = Config.issue_group_workflow_ref(issue, settings)

        with {:ok, repo_root} <- Workspace.ensure_local_repo_cache(project_route, settings),
              {:ok, workflow_path} <- Config.resolve_project_workflow_path(repo_root, workflow_ref),
              {:ok, workflow} <- ProjectWorkflow.load(workflow_path) do
          effective_settings = merge_settings(settings, project_route, workflow)

          {:ok,
           %__MODULE__{
             mode: :global,
             project_route: project_route,
              workflow_path: workflow_path,
             workflow: workflow,
             settings: effective_settings,
             prompt_template: prompt_template(workflow.prompt_template)
            }}
        end

      %{slug: slug} ->
        {:error, {:missing_project_repo, slug}}

      nil ->
        {:error, {:missing_project_route, project_slug(issue)}}
    end
  end

  defp resolve_legacy(issue, settings_override) do
    default_workflow_path = Workflow.workflow_file_path()
    settings = settings_override || Config.settings!()

    workflow_path =
      if Config.configured_issue_group_for_issue?(issue, settings) do
        issue
        |> Config.issue_group_workflow_ref(settings)
        |> Path.expand(Path.dirname(default_workflow_path))
      else
        default_workflow_path
      end

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
    updated_agent = Map.put(settings.agent, :backend, project_route.backend || settings.agent.backend)

    %{
      settings
      | agent: updated_agent,
        hooks: merge_struct_fields(settings.hooks, workflow.hooks, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms])
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

  defp project_slug(%{project_slug: project_slug}) when is_binary(project_slug), do: project_slug
  defp project_slug(%{"project_slug" => project_slug}) when is_binary(project_slug), do: project_slug
  defp project_slug(_issue), do: nil
end
