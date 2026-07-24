# Exfuse Workspace Filesystem Ownership

## Goal

Make Exfuse the only generic filesystem authority used by ecrits.

Exfuse must provide:

- one filesystem runtime and operation DSL;
- a real directory-backed filesystem;
- an in-memory filesystem for deterministic tests;
- one event-subscription contract shared by both implementations;
- shared ownership of native host watchers.

Ecrits must consume that boundary without implementing another path, read,
write, listing, atomic-write, watcher, or fake-filesystem layer. Workspace UI
events belong to `WorkspaceLive`; agent session processes do not participate in
filesystem notification delivery.

The cleanup also reduces the immediate contents of `lib/ecrits` to six
ownership directories. Moving source files must not rename public Elixir
modules merely to mirror paths.

## Existing Boundary

Exfuse already has one logical filesystem runtime:

- `Exfuse.Fs` defines the operation contract;
- `Exfuse.Fs.Dsl` compiles routed operation handlers;
- `Exfuse.Fs.Runtime` owns one logical filesystem and its file processes;
- `Exfuse.mount/3` exposes that runtime through FSKit or FUSE.

The new host and memory filesystems extend this runtime. A second filesystem
abstraction, protocol, or DSL must not be introduced.

Today ecrits separately owns:

- safe path resolution in `Ecrits.Path`;
- host reads, writes, listing, and atomic writes in `Ecrits.FS`;
- watcher startup and event relay in `Ecrits.Workspace.Session`;
- file-event filtering, debounce, and tree rebuilding in `WorkspaceLive`;
- application-specific document projection in `Ecrits.Fuse`.

The first three responsibilities move behind Exfuse. The LiveView keeps only
UI policy. The document projection remains ecrits application code because it
depends on ecrits document semantics, but it uses Exfuse rather than defining a
generic filesystem layer.

## Exfuse API

### Standard filesystem modules

Exfuse supplies two modules implementing the existing `Exfuse.Fs` contract:

- `Exfuse.Fs.Real` maps the operation vocabulary to a configured host
  directory.
- `Exfuse.Fs.Memory` stores the same directory, file, symlink, attributes, and
  byte semantics in process-owned memory.

Both are started through the existing runtime:

```elixir
{:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Real, root: "/workspace")
{:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Memory, files: %{"/README.md" => "hello"})
```

The `init_arg` remains the backend configuration. Runtime options remain the
third argument to `start_fs/3`.

### Application-side operations

`Exfuse.Fs` exposes client functions over the same routed operations used by
native mounts:

```elixir
Exfuse.Fs.list(fs, "/")
Exfuse.Fs.stat(fs, "/docs")
Exfuse.Fs.read(fs, "/docs/a.md")
Exfuse.Fs.write(fs, "/docs/a.md", bytes)
Exfuse.Fs.mkdir(fs, "/docs")
Exfuse.Fs.remove(fs, "/docs/a.md")
Exfuse.Fs.rename(fs, "/old", "/new")
Exfuse.Fs.subscribe(fs)
```

These functions dispatch through the root file process. They do not bypass the
DSL with direct calls to `File`.

`write/4` is atomic by default. Its implementation is expressed in terms of
create, write, flush, release, and rename so Real, Memory, and custom routed
filesystems share the same visible behavior.

### Path contract

Public client paths are root-relative slash paths. Exfuse canonicalizes them
before dispatch and rejects:

- `..` traversal;
- NUL bytes;
- paths outside the configured real root;
- traversal through symlinks beneath a real root.

The real backend converts a canonical Exfuse path to a host path only inside
the backend. No ecrits caller joins a workspace root to user input.

Application-specific exclusions such as `.ecrits` are configured as path
filters when the filesystem starts. Exfuse owns enforcement; ecrits owns the
policy value.

## File Events

### Shared subscription contract

The caller subscribes directly to the logical filesystem:

```elixir
:ok = Exfuse.Fs.subscribe(fs)
```

The runtime monitors every subscriber and removes it on `:DOWN`. A subscriber
receives:

```elixir
{:file_event, fs, {relative_path, actions}}
{:file_event, fs, :stop}
```

Paths are canonical and relative to the logical filesystem. Actions use the
existing `file_system` vocabulary such as `:created`, `:modified`, `:removed`,
and `:renamed`.

### Real backend

One `FileSystem.Worker` is started per real logical filesystem and owned by the
Exfuse runtime. The runtime is its sole `FileSystem` subscriber and fans
normalized events out to logical-filesystem subscribers.

Exfuse, not a LiveView or session, owns the native worker so multiple browser
tabs share one macOS listener or Linux inotify process.

### Memory backend

Successful mutating operations emit the same messages after the mutation is
visible to subsequent reads. Tests therefore observe the same ordering and
payload shape without touching disk or synthesizing private messages.

### WorkspaceLive

On connected mount, `WorkspaceLive` subscribes to the workspace filesystem.
It handles only events whose filesystem PID matches the mounted workspace.

The LiveView owns:

- ignoring UI-irrelevant names;
- the 150 millisecond refresh debounce;
- rebuilding `FileTree` state;
- reconciling open tabs after removals.

It does not start or stop native watchers. It does not publish filesystem
events through Phoenix PubSub. Chat rail and agent session state do not
participate.

The observed target flow is:

```text
native backend
  -> FileSystem.Worker
  -> Exfuse.Fs.Runtime
  -> WorkspaceLive
  -> debounce
  -> Exfuse.Fs.list
  -> FileTree.put_nodes
```

## Ecrits Migration

`Ecrits.Workspace` becomes a small domain wrapper containing the Exfuse
filesystem PID and display root. Its read, write, and list functions delegate
to `Exfuse.Fs`.

The migration deletes:

- `Ecrits.FS`;
- `Ecrits.Path`;
- `Workspace.Session.subscribe_file_events/1`;
- `Workspace.Session` watcher state, startup, termination, and handlers;
- the filesystem PubSub topic and broadcasts;
- stale per-LiveView watcher compatibility handlers;
- tests that assert session-owned watcher behavior.

Tests of workspace semantics use `Exfuse.Fs.Memory`. Separate integration tests
exercise the real backend, external host writes, and the native watcher.

`Ecrits.Fuse.DocFs`, `OpenDocs`, and `DocMount` remain application adapters
until their document-specific naming is cleaned up. They must use the Exfuse
API and must not duplicate generic path or host filesystem helpers.

## Source Layout

After behavioral migration, `lib/ecrits` contains these six immediate
directories:

1. `agent/` — ACP integration, durable agent schemas, configuration, and
   prompts.
2. `document/` — document runtime, engine adapters, edit operations, metadata,
   semantic marks, snapshots, and document VFS adapters.
3. `editor/` — canvas, preview, search, picker, toolbar, Markdown, scrolling,
   and other editor state.
4. `workspace/` — workspace domain, file tree, layout, mount state, handoff,
   durable sessions, and turn ownership.
5. `runtime/` — application callback, supervision, configuration, and request
   context.
6. `integrations/` — external service clients such as the legal MCP client.

Existing module names remain stable during the physical move. For example,
`Ecrits.AcpAgent` may live under `lib/ecrits/agent/acp_agent.ex`; file placement
does not require an `Ecrits.Agent.AcpAgent` compatibility rename.

No forwarding modules are added solely to preserve old source paths. Tests that
read source by path are updated to the new authoritative location.

## Error Handling and Lifecycle

Filesystem functions return `{:ok, value}` or `{:error, reason}`. Expected
POSIX failures remain atoms. Invalid public paths return a bounded Exfuse path
error before reaching a backend.

If a real watcher exits, the logical filesystem sends `{:file_event, fs,
:stop}` and attempts one supervised restart. Subscribers remain registered.
Repeated restart failure leaves filesystem operations available but reports the
watcher failure through runtime status and logs.

Stopping a logical filesystem stops its watcher, sends the stop event, closes
file processes, and unmounts native mounts. Subscriber monitors and memory
backend state are released with the runtime process.

## Testing

Development follows a red-green sequence:

1. Add Exfuse contract tests that run unchanged against Real and Memory.
2. Test canonical paths, traversal rejection, symlink rejection, recursive
   listing, reads, atomic writes, rename, removal, and error parity.
3. Test direct subscriptions, subscriber cleanup, mutation ordering, external
   real-directory writes, and one watcher shared by multiple subscribers.
4. Migrate `Ecrits.Workspace` tests to Memory.
5. Test `WorkspaceLive` with real subscription messages rather than Session or
   PubSub helpers.
6. Trace a real add and removal under the mounted workspace with `:dbg`.
7. Confirm multiple LiveViews share one Exfuse runtime and native watcher.
8. Run Exfuse `mix test`, push Exfuse, update ecrits with its project-defined
   dependency update command, restart for changed dependency code, and run
   `mix precommit`.

The live trace must prove:

- the external file exists on disk;
- FileSystem reports the event;
- Exfuse routes it directly to `WorkspaceLive`;
- the file enters and leaves live `FileTree` state;
- no `Workspace.Session` or Phoenix PubSub hop occurs;
- all probe files and debugger sessions are cleaned up.

## Migration Order

1. Add Exfuse client operations, Real, Memory, and shared subscription tests.
2. Add real watcher ownership and event parity.
3. Push Exfuse and update the ecrits dependency.
4. Change `Ecrits.Workspace` to use Exfuse and migrate its tests to Memory.
5. Move subscription and event handling from Session to `WorkspaceLive`.
6. Delete `Ecrits.FS`, `Ecrits.Path`, and obsolete routing code.
7. Verify the live real-file flow.
8. Physically consolidate `lib/ecrits` into the six ownership directories.
9. Update source-path assertions and run the complete project gate.

At no migration point may two generic filesystem authorities remain active.

## Completion Criteria

The work is complete only when:

- Exfuse Real and Memory pass the same operation contract;
- both implementations emit the same file-event contract;
- one real filesystem has one native watcher regardless of LiveView count;
- `WorkspaceLive` subscribes directly to Exfuse;
- Session and Phoenix PubSub are absent from filesystem event delivery;
- ecrits contains no generic FS or path implementation;
- application-specific document projection uses Exfuse without generic
  duplication;
- `lib/ecrits` has no more than eight immediate entries and the intended result
  has six;
- focused Exfuse and ecrits tests pass;
- the real add/remove runtime trace passes;
- `mix precommit` passes.
