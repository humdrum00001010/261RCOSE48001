defmodule Ecrits.SupervisionTest do
  use ExUnit.Case, async: true

  test "groups application children by runtime area" do
    assert Enum.map(Ecrits.Supervision.child_groups(), fn {group, _children} -> group end) == [
             :platform,
             :http_clients,
             :document_services,
             :web,
             :document_runtime,
             :agent_runtime
           ]
  end

  test "keeps root child ids stable for restart paths" do
    assert Ecrits.Supervision.child_ids() == [
             EcritsWeb.Telemetry,
             Phoenix.PubSub.Supervisor,
             DNSCluster,
             Swoosh.Finch,
             Ecrits.Finch.OpenAI,
             # ecrits owns exfuse as of 2026-07-27 — FIRST of the document
             # services so it terminates LAST, after the things holding mounts.
             Exfuse.Supervisor,
             Ecrits.RhwpSnapshot.Materializer,
             Ecrits.Doc.PreviewTaskSupervisor,
             Ecrits.Doc.BrowserTransactionSupervisor,
             Ecrits.Fuse.OpenDocs,
             Ecrits.Doc.EditSessionRegistry,
             Ecrits.Doc.EditSessionSupervisor,
             EcritsWeb.Endpoint,
             Ecrits.Document.Registry,
             Ecrits.Document.Supervisor,
             Ecrits.WorkspaceHandoff,
             Ecrits.AcpAgent.SessionRegistry,
             Ecrits.AcpAgent.SessionSupervisor,
             Ecrits.Workspace.SessionRegistry,
             Ecrits.Workspace.SessionSupervisor
           ]
  end
end
