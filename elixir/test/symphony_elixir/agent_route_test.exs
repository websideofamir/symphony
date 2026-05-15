defmodule SymphonyElixir.AgentRouteTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRoute

  test "unlabeled issue uses configured fallback backend and effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "claude",
      default_effort: "medium"
    )

    route = AgentRoute.resolve(issue_fixture([]))

    assert route.backend == "claude"
    assert route.effort == "medium"
    assert route.warnings == []
  end

  test "backend labels override the configured fallback backend" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "codex")

    assert AgentRoute.resolve(issue_fixture(["codex"])).backend == "codex"
    assert AgentRoute.resolve(issue_fixture(["claude"])).backend == "claude"
    assert AgentRoute.resolve(issue_fixture(["opencode"])).backend == "opencode"
  end

  test "thinking labels override the configured fallback effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      default_effort: "low"
    )

    assert AgentRoute.resolve(issue_fixture(["thinking/high"])).effort == "high"
    assert AgentRoute.resolve(issue_fixture(["thinking/xhigh"])).effort == "xhigh"
    assert AgentRoute.resolve(issue_fixture(["THINKING/MAX"])).effort == "max"
  end

  test "grouped agent labels select the OpenCode agent" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "opencode")

    route = AgentRoute.resolve(issue_fixture(["agent/review"]))

    assert route.backend == "opencode"
    assert route.opencode_agent == "review"
    assert route.warnings == []
  end

  test "agent labels are case-insensitive and ignore blank agent names" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "opencode")

    route = AgentRoute.resolve(issue_fixture(["AGENT/Review", "agent/", "agent:"]))

    assert route.backend == "opencode"
    assert route.opencode_agent == "review"
    assert route.warnings == []
  end

  test "legacy colon agent labels still select the OpenCode agent" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "opencode")

    route = AgentRoute.resolve(issue_fixture(["agent:review"]))

    assert route.backend == "opencode"
    assert route.opencode_agent == "review"
    assert route.warnings == []
  end

  test "agent labels are ignored for non-OpenCode backends" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "codex")

    route = AgentRoute.resolve(issue_fixture(["agent/review"]))

    assert route.backend == "codex"
    assert route.opencode_agent == nil
    assert route.warnings == []
  end

  test "conflicting agent labels warn and fall back to configured OpenCode agent" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "opencode")

    route = AgentRoute.resolve(issue_fixture(["agent/review", "agent:build"]))

    assert route.backend == "opencode"
    assert route.opencode_agent == nil

    assert route.warnings == [
             "multiple OpenCode agent labels (review, build) found; falling back to configured opencode.agent"
           ]
  end

  test "issue state default agent is used for OpenCode when no agent label is present" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "opencode",
      default_agents_by_state: %{"Todo" => "build", "Address Feedback" => "review"}
    )

    todo_route = AgentRoute.resolve(%{issue_fixture([]) | state: "Todo"})
    feedback_route = AgentRoute.resolve(%{issue_fixture([]) | state: "Address Feedback"})

    assert todo_route.opencode_agent == "build"
    assert feedback_route.opencode_agent == "review"
  end

  test "agent labels override issue state default agent" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "opencode",
      default_agents_by_state: %{"Todo" => "build"}
    )

    route = AgentRoute.resolve(issue_fixture(["agent/review"]))

    assert route.opencode_agent == "review"
  end

  test "conflicting agent labels fall back to issue state default agent when configured" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "opencode",
      default_agents_by_state: %{"Todo" => "build"}
    )

    route = AgentRoute.resolve(issue_fixture(["agent/review", "agent:triage"]))

    assert route.opencode_agent == "build"

    assert route.warnings == [
             "multiple OpenCode agent labels (review, triage) found; falling back to state default OpenCode agent build"
           ]
  end

  test "legacy effort labels still resolve for compatibility" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      default_effort: "low"
    )

    assert AgentRoute.resolve(issue_fixture(["effort/high"])).effort == "high"
    assert AgentRoute.resolve(issue_fixture(["effort/xhigh"])).effort == "xhigh"
    assert AgentRoute.resolve(issue_fixture(["EFFORT/MAX"])).effort == "max"
  end

  test "xhigh maps per-provider: native on claude, collapses to top on codex/opencode" do
    assert AgentRoute.claude_effort("xhigh") == "xhigh"
    assert AgentRoute.claude_effort("max") == "max"

    assert AgentRoute.codex_effort("xhigh") == "xhigh"
    assert AgentRoute.codex_effort("max") == "xhigh"

    assert AgentRoute.opencode_variant("xhigh") == "max"
    assert AgentRoute.opencode_variant("max") == "max"
  end

  test "conflicting backend labels warn and fall back to the configured backend" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "claude")

    route = AgentRoute.resolve(issue_fixture(["codex", "claude"]))

    assert route.backend == "claude"
    assert route.effort == nil

    assert route.warnings == [
             "multiple backend labels (codex, claude) found; falling back to default backend claude"
           ]
  end

  test "conflicting thinking labels warn and fall back to configured effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      default_effort: "medium"
    )

    route = AgentRoute.resolve(issue_fixture(["thinking/low", "thinking/max"]))

    assert route.backend == "codex"
    assert route.effort == "medium"

    assert route.warnings == [
             "multiple thinking labels (low, max) found; falling back to default effort medium"
           ]
  end

  defp issue_fixture(labels) do
    %Issue{
      id: "issue-route",
      identifier: "MT-ROUTE",
      title: "Route test",
      description: "Route from labels",
      state: "Todo",
      url: "https://example.org/issues/MT-ROUTE",
      labels: labels
    }
  end
end
