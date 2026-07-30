defmodule Ecrits.Doc.ToolsTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Tools
  alias Ecrits.Workspace.Session

  setup do
    prev = Application.get_env(:ehwp, :runtime)

    # A unique per-test workspace path keys the `Workspace.Session` that holds
    # per-agent ownership (invariant 2) and the viewer registry every doc.* call
    # routes through. Started lazily by those calls; killed on exit.
    path = Path.join(System.tmp_dir!(), "ws_tools_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if pid = Session.whereis(path), do: Process.exit(pid, :kill)
      restore(:ehwp, :runtime, prev)
    end)

    {:ok, path: path}
  end

  # A context with no `:session_path`: no workspace Session, so no viewer, so no
  # routable document — the baseline the catalog/validation tests want.
  defp ctx, do: %{}

  describe "tool catalog" do
    test "exposes the common doc.* surface with schemas and risk levels" do
      names = Tools.tools() |> Enum.map(&(&1["namespace"] <> "." <> &1["name"]))

      for n <- ~w(doc.context doc.list doc.open doc.create doc.read doc.find
                  doc.get doc.set doc.edit doc.save doc.render) do
        assert n in names, "expected #{n} in tool catalog"
      end

      # Eleven tools: the original doc.* surface plus doc.render. The former
      # doc.inspect and doc.apply_style are folded into doc.get / doc.set, and
      # the mount-control pair doc.open_doc/doc.close_doc is gone — the mount
      # DERIVES its listing, so nothing has to be told to populate it.
      assert "doc.read_table" not in names
      assert "doc.inspect" not in names
      assert "doc.apply_style" not in names
      assert "doc.open_doc" not in names
      assert "doc.close_doc" not in names
      assert length(names) == 11

      find_schema = Enum.find(Tools.tools(), &(&1["name"] == "find"))["inputSchema"]
      assert "formula_cell" in get_in(find_schema, ["properties", "type", "enum"])

      create_tool = Enum.find(Tools.tools(), &(&1["name"] == "create"))
      assert create_tool["description"] =~ "doc.open never creates files"
      assert create_tool["description"] =~ "explicitly asks for a new/output document"
      assert create_tool["description"] =~ "never for read-only read/inspect/summarize tasks"
      assert create_tool["annotations"] == %{"readOnlyHint" => false}

      for tool <- Tools.tools() do
        assert is_map(tool["inputSchema"])
        assert tool["risk"] in ["read", "write"]
      end
    end

    test "MCP initialization does not inject authoring recipes" do
      {:ok, state} = Ecrits.Doc.MCPServer.init([])

      assert {:ok, initialized, _state} = Ecrits.Doc.MCPServer.handle_initialize(%{}, state)
      refute Map.has_key?(initialized, :instructions)
    end

    test "read tools are read risk, write tools are write risk" do
      by_name = Map.new(Tools.tools(), &{&1["namespace"] <> "." <> &1["name"], &1["risk"]})
      assert by_name["doc.read"] == "read"
      assert by_name["doc.find"] == "read"
      assert by_name["doc.list"] == "read"
      assert by_name["doc.set"] == "write"
      assert by_name["doc.edit"] == "write"
      assert by_name["doc.save"] == "write"
    end

    test "doc.edit insert_picture schema exposes image source and sizing fields" do
      edit = Enum.find(Tools.tools(), &(&1["namespace"] <> "." <> &1["name"] == "doc.edit"))
      props = get_in(edit, ["inputSchema", "properties", "op", "properties"])

      assert props["src"]["type"] == "string"
      assert props["src"]["description"] =~ "insert_picture"
      assert props["ref"]["description"] =~ "sheet[Sheet1]/cell[A1]"
      assert props["width"]["description"] =~ "insert_picture"
      assert props["height"]["description"] =~ "insert_picture"
      assert props["w"]["description"] =~ "insert_picture"
      assert props["h"]["description"] =~ "insert_picture"
      assert props["name"]["description"] =~ "XLSX"
    end
  end

  describe "doc.create {from} — clone a template" do
    test "an unknown template (not an open id, not a file) is a structured error" do
      assert {:error, %{"error" => "template_not_found", "from" => "/no/such/template.hwp"}} =
               Tools.call(ctx(), "doc.create", %{
                 "path" => Path.join(System.tmp_dir!(), "x.hwp"),
                 "from" => "/no/such/template.hwp"
               })
    end

    test "blank create infers Office kind from .pptx path instead of writing HWP bytes" do
      path = Path.join(System.tmp_dir!(), "scratch_#{System.unique_integer()}.pptx")
      File.rm(path)
      on_exit(fn -> File.rm(path) end)

      # A no-deck .pptx create routes to the Office factory-blank path (the
      # IR-direct from-scratch authoring seed), never the HWP engine. With the
      # UNO arm built it yields a real blank pptx on disk; without it, a
      # structured office create error — in neither case HWP bytes.
      case Tools.call(ctx(), "doc.create", %{"path" => path}) do
        {:ok, %{"kind" => "pptx", "path" => ^path}} ->
          assert {:ok, "PK" <> _} = File.read(path)

        {:error, %{"error" => err}} ->
          assert err =~ "create_failed" or err =~ "create_unsupported"
          refute File.exists?(path)
      end
    end

    test "the create tool schema advertises the `from` clone param" do
      create = Enum.find(Tools.tools(), &(&1["name"] == "create"))
      assert Map.has_key?(create["inputSchema"]["properties"], "from")
      assert create["description"] =~ "clones"
    end
  end

  describe "path-first document arg — a path works open, closed, or never opened (#34)" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "ws_pathfirst_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "drafts"))
      File.write!(Path.join(root, "drafts/retainer.hwp"), "fake-hwp-bytes")
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, root: root}
    end

    test "a path outside the workspace root is refused, not auto-opened", %{root: root} do
      ctx = ctx() |> Map.put(:session_path, root)

      outside = Path.join(System.tmp_dir!(), "outside_#{System.unique_integer([:positive])}.hwp")
      File.write!(outside, "x")
      on_exit(fn -> File.rm(outside) end)

      assert {:error, %{"error" => "document_not_found"}} =
               Tools.call(ctx, "doc.read", %{"document" => outside, "ref" => "hwp:s0/p0/c0+0"})
    end

    test "a non-document file extension is not auto-opened", %{root: root} do
      ctx = ctx() |> Map.put(:session_path, root)
      File.write!(Path.join(root, "notes.txt"), "plain text")

      assert {:error, %{"error" => "document_not_found"}} =
               Tools.call(ctx, "doc.read", %{"document" => "notes.txt", "ref" => "hwp:s0/p0/c0+0"})
    end
  end

  describe "doc.read anchor-neighborhood surface" do
    test "the read tool schema has no paging knobs" do
      read = Enum.find(Tools.tools(), &(&1["name"] == "read"))
      props = read["inputSchema"]["properties"]

      assert read["inputSchema"]["required"] == ["document", "ref"]
      assert props |> Map.keys() |> Enum.sort() == ["document", "include", "nearby", "ref"]
    end
  end

  describe "doc.context — current document" do
    test "falls back to the explicit current document path" do
      assert {:ok, ctx_result} =
               Tools.call(
                 %{
                   agent_id: "fg",
                   active_doc: nil,
                   document_path: "drafts/current.hwpx"
                 },
                 "doc.context",
                 %{}
               )

      assert Map.keys(ctx_result) == ["current_document"]

      assert ctx_result["current_document"] == %{
               "document" => "drafts/current.hwpx",
               "name" => "current.hwpx",
               "kind" => "hwpx",
               "path" => "drafts/current.hwpx",
               "backing" => nil,
               "active" => true
             }
    end

    test "context + get are exposed in the tool catalog as read tools" do
      by_name = Map.new(Tools.tools(), &{&1["namespace"] <> "." <> &1["name"], &1["risk"]})
      assert by_name["doc.context"] == "read"
      assert by_name["doc.get"] == "read"
    end
  end

  # Per-agent MCP isolation + the open/ownership invariants. An "agent context" is
  # a ctx map carrying `:agent_id` + `:active_doc` + `:session_path` (the
  # workspace `Session` that holds both ownership and the viewer registry); an
  # empty ctx has neither, so nothing routes.
  describe "per-agent context (isolation + invariants)" do
    test "unknown document" do
      # #32: the miss is structured — it names the unknown id and carries the
      # open-document catalog so the agent self-corrects without doc.context.
      assert {:error,
              %{"error" => "document_not_found", "document" => "ghost", "open_documents" => []}} =
               Tools.call(ctx(), "doc.read", %{"document" => "ghost", "ref" => "ghost-ref"})
    end

    test "missing required document arg" do
      assert {:error, _} = Tools.call(ctx(), "doc.read", %{})
    end
  end

  # Access-control guards (security review #1): the doc.* tools run server-side
  # and bypass the agent CLI sandbox, so they must honour the workspace access
  # setting themselves. `read_only: true` ⟺ the agent's sandbox == "read-only";
  # `session_path` is the workspace root that confines caller-supplied paths.
  describe "access control: read-only session" do
    # ctx mirroring a read-only agent (session_path set, read_only true).
    defp ro_ctx(root),
      do: %{
        agent_id: "ro",
        instance_id: "ro-instance",
        turn_id: "ro-turn",
        session_path: root,
        read_only: true
      }

    setup do
      root = Path.join(System.tmp_dir!(), "ws_ac_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root}
    end

    test "refuses doc.create with a read_only error", %{root: root} do
      assert {:error, %{"error" => "read_only", "message" => msg}} =
               Tools.call(ro_ctx(root), "doc.create", %{
                 "path" => Path.join(root, "new.hwp")
               })

      assert msg =~ "read-only"
    end

    test "refuses doc.set with a read_only error", %{root: root} do
      assert {:error, %{"error" => "read_only"}} =
               Tools.call(ro_ctx(root), "doc.set", %{
                 "ref" => "hwp:foo",
                 "props" => %{"bold" => true}
               })
    end
  end

  describe "access control: workspace path confinement" do
    setup do
      root = Path.join(System.tmp_dir!(), "ws_pc_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root}
    end

    defp ws_ctx(root),
      do: %{
        agent_id: "ws",
        instance_id: "ws-instance",
        turn_id: "ws-turn",
        session_path: root,
        read_only: false
      }

    test "doc.create OUTSIDE the workspace root is refused", %{root: root} do
      outside = Path.join(System.tmp_dir!(), "outside_#{System.unique_integer([:positive])}.hwp")

      assert {:error, %{"error" => "outside_workspace", "workspace_root" => reported}} =
               Tools.call(ws_ctx(root), "doc.create", %{"path" => outside})

      assert reported == Path.expand(root)
      refute File.exists?(outside)
    end

    test "a `..`-escape path is refused even if it lexically starts with the root",
         %{root: root} do
      # `<root>/../<sibling>` expands OUTSIDE root — the guard must expand before
      # comparing, not do a raw prefix check.
      escape = Path.join(root, "../escape_#{System.unique_integer([:positive])}.hwp")

      assert {:error, %{"error" => "outside_workspace"}} =
               Tools.call(ws_ctx(root), "doc.create", %{"path" => escape})

      refute File.exists?(Path.expand(escape))
    end

    test "doc.open OUTSIDE the workspace root is refused", %{root: root} do
      outside =
        Path.join(System.tmp_dir!(), "outside_open_#{System.unique_integer([:positive])}.hwp")

      File.write!(outside, "x")
      on_exit(fn -> File.rm_rf(outside) end)

      assert {:error, %{"error" => "outside_workspace"}} =
               Tools.call(ws_ctx(root), "doc.open", %{"path" => outside})
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
