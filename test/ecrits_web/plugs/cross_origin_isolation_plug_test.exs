defmodule EcritsWeb.Plugs.CrossOriginIsolationPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias EcritsWeb.Plugs.CrossOriginIsolationPlug

  # Simulate a prior plug setting cache-control so these assertions prove the
  # WASM asset responses replace it with the no-cache policy.
  defp run(path) do
    conn =
      conn(:get, path)
      |> put_req_header("accept-encoding", "identity")
      |> put_resp_header("cache-control", "public")
      |> CrossOriginIsolationPlug.call([])

    if conn.halted do
      conn
    else
      send_resp(conn, 200, "")
    end
  end

  defp run_head(path, accept_encoding) do
    conn =
      conn(:head, path)
      |> put_req_header("accept-encoding", accept_encoding)
      |> put_resp_header("cache-control", "public")
      |> CrossOriginIsolationPlug.call([])

    if conn.halted do
      conn
    else
      send_resp(conn, 200, "")
    end
  end

  # The `/assets/rhwp/*` prefix (`rhwp.js` + `rhwp_bg.wasm` out of the deleted
  # `:ehwp` dep) is GONE with the legacy `Canvas.HwpPages` hook that fetched it —
  # rhwp-studio ships its own `rhwp_bg.wasm` inside its bundle, covered below.
  test "the retired HWP wasm prefix is no longer served" do
    for path <- ["/assets/rhwp/rhwp_bg.wasm", "/assets/rhwp/rhwp.js"] do
      conn = run(path)

      refute conn.halted, "expected #{path} to fall through, not be served"
      assert get_resp_header(conn, "content-type") == []
    end
  end

  test "the workspace page is isolated but its cache-control is left untouched" do
    conn = run("/workspace")

    assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
    assert get_resp_header(conn, "cache-control") == ["public"]
  end

  test "unrelated assets get neither isolation nor the revalidation override" do
    conn = run("/assets/js/app.js")

    assert get_resp_header(conn, "cross-origin-opener-policy") == []
    assert get_resp_header(conn, "cache-control") == ["public"]
  end

  describe "office WASM bundle" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      dist = Path.join(tmp_dir, "program")
      File.mkdir_p!(dist)
      File.write!(Path.join(dist, "soffice.js"), "var Module = {};")
      File.write!(Path.join(dist, "soffice.wasm"), <<0, 97, 115, 109>>)
      File.write!(Path.join(dist, "soffice.data"), "FS image")
      File.write!(Path.join(dist, "soffice.data.js.metadata"), ~s({"files":[]}))
      # A brotli scratch sibling: present on disk, never served (see below).
      File.write!(Path.join(dist, "soffice.wasm.br"), "not-a-wasm")
      File.write!(Path.join(dist, "unlisted.txt"), "secret")

      previous = Application.get_env(:ecrits, :office_wasm_dist)
      Application.put_env(:ecrits, :office_wasm_dist, dist)

      on_exit(fn ->
        if previous do
          Application.put_env(:ecrits, :office_wasm_dist, previous)
        else
          Application.delete_env(:ecrits, :office_wasm_dist)
        end
      end)

      :ok
    end

    test "office WASM artifacts are isolated AND forced to revalidate (no stale-mixed bundle)" do
      conn = run("/assets/office/soffice.wasm")

      assert conn.halted
      assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
      assert get_resp_header(conn, "cross-origin-embedder-policy") == ["require-corp"]
      # The matched glue/wasm/data set must never be served stale-mixed, so the
      # response overrides Plug.Static's `public` with `no-cache`.
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "the whole matched set is served with its real content types" do
      for {name, type} <- [
            {"soffice.js", "text/javascript; charset=utf-8"},
            {"soffice.wasm", "application/wasm"},
            {"soffice.data", "application/octet-stream"},
            {"soffice.data.js.metadata", "application/json; charset=utf-8"}
          ] do
        conn = run("/assets/office/" <> name)

        assert conn.halted, "expected #{name} to be served"
        assert get_resp_header(conn, "content-type") == [type]
      end
    end

    test "office WASM artifacts ignore optional brotli scratch siblings" do
      conn = run_head("/assets/office/soffice.wasm", "br")

      assert get_resp_header(conn, "content-encoding") == []
      assert get_resp_header(conn, "vary") == []
    end

    # Unlike the studio bundle (a whole build tree, confined by path), the office
    # set is an ALLOWLIST: the source is an `instdir/program` directory holding
    # hundreds of unrelated files, none of which the browser may fetch.
    test "serves only the four allowlisted files" do
      for path <- [
            "/assets/office/unlisted.txt",
            "/assets/office/soffice.wasm.br",
            "/assets/office/../../../etc/passwd"
          ] do
        conn = run(path)

        refute conn.halted, "expected #{path} to fall through, not be served"
        assert get_resp_header(conn, "content-type") == []
      end
    end

    # The bundle is build output installed by `mix assets.office_wasm` (or served
    # in place from OFFICE_WASM_DIST); on a machine with neither, the plug must
    # 404 through, not raise on the request path — the lesson from
    # `Application.app_dir/2` on the deleted `:libreofficex` dep.
    test "a missing bundle falls through instead of raising" do
      Application.put_env(:ecrits, :office_wasm_dist, "/nonexistent/office-wasm")

      conn = run("/assets/office/soffice.wasm")

      assert get_resp_header(conn, "content-type") == []
      assert get_resp_header(conn, "cache-control") == ["public"]
      # Isolation is path-based, so it still applies — a 404 for the engine must
      # not silently un-isolate the page that was going to embed it.
      assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
    end
  end

  describe "rhwp-studio bundle" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      dist = Path.join(tmp_dir, "dist")
      File.mkdir_p!(Path.join(dist, "assets"))
      File.write!(Path.join(dist, "index.html"), "<!doctype html><title>studio</title>")
      File.write!(Path.join(dist, "assets/index-abc.js"), "export default 1;")
      File.write!(Path.join(dist, "assets/rhwp_bg-abc.wasm"), <<0, 97, 115, 109>>)
      File.write!(Path.join(tmp_dir, "outside.txt"), "secret")

      previous = Application.get_env(:ecrits, :rhwp_studio_dist)
      Application.put_env(:ecrits, :rhwp_studio_dist, dist)

      on_exit(fn ->
        if previous do
          Application.put_env(:ecrits, :rhwp_studio_dist, previous)
        else
          Application.delete_env(:ecrits, :rhwp_studio_dist)
        end
      end)

      :ok
    end

    test "serves the entry point, and the bare prefix resolves to it" do
      for path <- ["/rhwp-studio", "/rhwp-studio/", "/rhwp-studio/index.html"] do
        conn = run(path)

        assert conn.halted, "expected #{path} to be served by the plug"
        assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
      end
    end

    test "serves nested bundle assets with their real content types" do
      assert get_resp_header(run("/rhwp-studio/assets/index-abc.js"), "content-type") ==
               ["text/javascript; charset=utf-8"]

      assert get_resp_header(run("/rhwp-studio/assets/rhwp_bg-abc.wasm"), "content-type") ==
               ["application/wasm"]
    end

    # /workspace frames this bundle under COEP require-corp, and a require-corp
    # document may only frame responses that declare COEP themselves.
    test "studio responses carry the cross-origin isolation headers" do
      conn = run("/rhwp-studio/index.html")

      assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
      assert get_resp_header(conn, "cross-origin-embedder-policy") == ["require-corp"]
      assert get_resp_header(conn, "cross-origin-resource-policy") == ["same-origin"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "refuses to escape the bundle root" do
      for path <- [
            "/rhwp-studio/../outside.txt",
            "/rhwp-studio/assets/../../outside.txt",
            "/rhwp-studio/%2e%2e/outside.txt"
          ] do
        conn = run(path)

        refute conn.halted, "expected #{path} to fall through, not be served"
        assert get_resp_header(conn, "content-type") == []
      end
    end

    # The bundle is build output installed by `mix assets.rhwp_studio`; on a
    # machine that never ran it the plug must 404 through, not raise on the
    # request path (the lesson from `Application.app_dir/2` on a deleted dep).
    test "a missing bundle falls through instead of raising" do
      Application.put_env(:ecrits, :rhwp_studio_dist, "/nonexistent/rhwp-studio")

      conn = run("/rhwp-studio/index.html")

      assert get_resp_header(conn, "content-type") == []
      assert get_resp_header(conn, "cache-control") == ["public"]
    end
  end
end
