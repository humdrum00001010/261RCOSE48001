defmodule Ecrits.Supervision do
  @moduledoc """
  Declarative application supervision topology.

  `Ecrits.Application` owns startup policy; this module owns the runtime
  grouping and child-spec order. Keep leaf child IDs stable unless the caller
  code that restarts those children is moved to the same abstraction.

  This tree is the app's runtime map:

    * platform services make the BEAM/Phoenix host usable;
    * document services own cross-cutting document materialization;
    * local document runtime owns open workspace-document sessions;
    * local agent runtime owns ACP sessions and the agent-visible MCP tool loop.

  The important boundary is that LiveViews should not own document truth. A
  LiveView mounts a document session and renders it; supervised document
  processes own versions, snapshots, and agent-addressable identity. Agents
  should reach documents through the local agent runtime and `doc.*` tools, not
  by bypassing the editor with raw filesystem access.
  """

  @type child_group :: {atom(), [Supervisor.child_spec()]}

  @spec children(keyword()) :: [Supervisor.child_spec()]
  def children(opts \\ []) do
    opts
    |> child_groups()
    |> Enum.flat_map(fn {_group, children} -> children end)
  end

  @spec child_groups(keyword()) :: [child_group()]
  def child_groups(_opts \\ []) do
    [
      # Host/runtime substrate. These must be available before app-specific
      # workers publish, subscribe, or make HTTP calls.
      {:platform, platform_children()},
      {:http_clients, http_client_children()},
      # Format/runtime services that are shared by user editing and agent edits.
      {:document_services, document_service_children()},
      # Phoenix endpoint starts after shared services so LiveViews can mount
      # document and agent sessions immediately.
      {:web, web_children()},
      # Local editor runtimes: document sessions first, ACP/agent sessions after,
      # because agents bind to the active document session by id.
      {:document_runtime, document_runtime_children()},
      {:agent_runtime, agent_runtime_children()}
    ]
  end

  @spec child_ids(keyword()) :: [term()]
  def child_ids(opts \\ []) do
    opts
    |> children()
    |> Enum.map(&Supervisor.child_spec(&1, []).id)
  end

  defp platform_children do
    [
      EcritsWeb.Telemetry,
      {Phoenix.PubSub, name: Ecrits.PubSub},
      {DNSCluster, query: Application.get_env(:ecrits, :dns_cluster_query) || :ignore}
    ]
  end

  defp http_client_children do
    [
      {Finch, name: Swoosh.Finch},
      # OpenAI streaming should not reuse sockets past the edge keepalive window.
      {Finch,
       name: Ecrits.Finch.OpenAI,
       pools: %{
         :default => [size: 10, count: 1, conn_max_idle_time: 30_000]
       }}
    ]
  end

  defp document_service_children do
    [
      # ECRITS OWNS EXFUSE (2026-07-27). It used to start its own application
      # root, making it a PEER of this tree rather than a child — so nothing here
      # could shut it down, `Exfuse.Mount.terminate/2` never ran on an orderly
      # stop, and every dev-server restart leaked its OS mounts. 148 orphans
      # accumulated that way, one over `$HOME/.ecrits`, which shadowed the
      # workspace handoff store read-only and surfaced as
      # `{:store_write_failed, :erofs}`.
      #
      # FIRST on purpose. Startup order is irrelevant — nothing mounts at boot;
      # the first mount happens when a workspace LiveView mounts. Children
      # terminate in REVERSE order, so first here means this stops LAST, after
      # everything that owns a mount has already torn it down.
      # See docs/plans/2026-07-27-exfuse-ownership-simplification.md.
      Exfuse.Supervisor,
      Ecrits.RhwpSnapshot.Materializer,
      # REMOVED 2026-07-26 with :libreofficex — Ecrits.Doc.Office.Instance was the
      # serializing governor for the in-process LibreOffice UNO NIF. There is no
      # in-process LO any more; office authority is the browser engine reached via
      # Workspace.Session.viewer/2. See the DocLang migration plan.
      # Durable chat-rail preview snapshots are persisted after an FSKit
      # callback returns. Keeping those workers supervised prevents mounted
      # File.rename callers from waiting on their own file_server-owned vnode.
      {Task.Supervisor, name: Ecrits.Doc.PreviewTaskSupervisor},
      # A browser-backed VFS edit must keep one stable process identity from
      # vfs_write through the durable source replace and vfs_commit. In
      # particular, the ACP request process may be cancelled after the source
      # replace; an unlinked supervised coordinator still completes the browser
      # commit (or restores and rolls back) before releasing the turn fence.
      {Task.Supervisor, name: Ecrits.Doc.BrowserTransactionSupervisor},
      # REMOVED 2026-07-29 — Ecrits.Doc.Pool was the server-side Editor registry.
      # It could not start an Editor for any kind once the engine deps went, so
      # every lookup answered empty; the browser WASM engine owns the document.
      # See docs/plans/2026-07-28-client-owns-document.md.
      # Per-workspace ETS for the document VFS (Ecrits.Fuse.*): the write-staging,
      # committed-projection and canonical-echo lifecycle `Ecrits.Fuse.DocFs`
      # commits through. Its open-SET half is no longer populated — the mount
      # derives its listing — and dies with the module in step 4 of
      # docs/plans/2026-07-28-client-owns-document.md.
      Ecrits.Fuse.OpenDocs,
      # One supervised worker per in-flight document patch, keyed by `edit_id`.
      # A patch's accumulated partial state is bound to the PATCH, not to a
      # socket: it survives a browser refresh and N tabs observe the same
      # process. Deliberately NOT a nested LiveView. See "Layer 1.5" in
      # docs/plans/2026-07-26-doclang-engine-migration.md.
      {Registry, keys: :unique, name: Ecrits.Doc.EditSessionRegistry},
      Ecrits.Doc.EditSessionSupervisor
    ]
  end

  defp web_children do
    [
      EcritsWeb.Endpoint
    ]
  end

  defp document_runtime_children do
    [
      {Registry, keys: :unique, name: Ecrits.Document.Registry},
      Ecrits.Document.Supervisor
    ]
  end

  defp agent_runtime_children do
    [
      Ecrits.WorkspaceHandoff,
      {Registry, keys: :unique, name: Ecrits.AcpAgent.SessionRegistry},
      Ecrits.AcpAgent.SessionSupervisor,
      # Per-workspace Session directory (keyed by canonical path, cookieless).
      # Durable: survives the workspace LiveView dying / a browser refresh, so
      # re-attaching by path returns the same foreground agent (same provider
      # thread + transcript + title). Replaces the cookie `ws_id` + ShellStore.
      {Registry, keys: :unique, name: Ecrits.Workspace.SessionRegistry},
      Ecrits.Workspace.SessionSupervisor
    ]
  end
end
