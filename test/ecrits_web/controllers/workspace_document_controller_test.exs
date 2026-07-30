defmodule EcritsWeb.WorkspaceDocumentControllerTest do
  use EcritsWeb.ConnCase, async: true

  alias Ecrits.Document
  alias EcritsWeb.DocumentUrl
  alias Ecrits.Document.PreviewSnapshot

  # The retired endpoint was `get "/document-bytes"`. Assert the PATH is gone;
  # POSTing proved nothing, since the router has no POST route for documents at
  # all and the controller was never reached.
  test "the retired /document-bytes path no longer routes" do
    assert Phoenix.Router.route_info(EcritsWeb.Router, "GET", "/document-bytes", "") == :error
  end

  # Regression: the snapshot route has no filename, so format comes from CONTENT.
  # Every OOXML file used to answer :unsupported_format and 404.
  test "detects office formats from content alone" do
    assert {:ok, "docx"} =
             Document.detect_format_from_bytes(File.read!("test/fixtures/office/table.docx"))

    assert {:ok, "pptx"} =
             Document.detect_format_from_bytes(File.read!("test/fixtures/office/slides.pptx"))

    assert {:ok, "hwpx"} =
             Document.detect_format_from_bytes(
               File.read!("test/fixtures/hwpx/real_contract.hwpx")
             )

    assert {:error, :unsupported_format} = Document.detect_format_from_bytes("not a document")
  end

  test "serves an office preview snapshot", %{conn: conn} do
    root = preview_root()
    File.mkdir_p!(root)
    relative_path = "deck.pptx"
    bytes = File.read!("test/fixtures/office/slides.pptx")
    File.write!(Path.join(root, relative_path), bytes)

    document_id = Document.id_for(root, relative_path)
    assert {:ok, snapshot} = PreviewSnapshot.put(document_id, bytes)

    on_exit(fn ->
      File.rm_rf(Path.join(root, relative_path))
      File.rm_rf(Path.dirname(PreviewSnapshot.path(document_id, snapshot.id)))
    end)

    assert response(get(conn, snapshot_url(root, relative_path, snapshot.id)), 200)
  end

  # Regression: a space in the filename used to 404. See EcritsWeb.DocumentUrl.
  test "serves a document whose name contains a space", %{conn: conn} do
    root = preview_root()
    File.mkdir_p!(root)
    name = "년간 보고서.hwpx"
    bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    File.write!(Path.join(root, name), bytes)
    on_exit(fn -> File.rm_rf(Path.join(root, name)) end)

    url =
      "/document/bytes/" <>
        URI.encode(name, &URI.char_unreserved?/1) <> "?" <> URI.encode_query(%{"path" => root})

    assert response(get(conn, url), 200) == bytes
  end

  # The builder and the router drifted apart once: the builder emitted
  # "/document/<path>" while the route was "/document/bytes/*document", so every
  # viewer 404'd — and the LiveView tests passed anyway, because they asserted a
  # SUBSTRING of the broken URL. So assert what the BUILDER produces actually
  # routes; asserting hand-written literals here would repeat the same mistake.
  test "every URL the builder produces resolves to a real route" do
    routed? = fn url ->
      %URI{path: path} = URI.parse(url)
      Phoenix.Router.route_info(EcritsWeb.Router, "GET", path, "") != :error
    end

    root = "/tmp/ws"

    built = [
      DocumentUrl.bytes(root, "report.hwpx"),
      DocumentUrl.bytes(root, "drafts/service.hwpx"),
      DocumentUrl.bytes(root, "년간 보고서.hwpx"),
      DocumentUrl.bytes(root, "drafts/년간 보고서.hwpx", 7),
      DocumentUrl.snapshot(root, "report.hwpx", String.duplicate("a", 64))
    ]

    for url <- built, do: assert(routed?.(url), "builder produced an unroutable URL: #{url}")

    # and the shape it used to emit must NOT route, or the assertion above is vacuous
    refute routed?.("/document/report.hwpx?path=#{root}")
  end

  # Traversal is REJECTED, not resolved: Workspace.normalize_path/1 ->
  # Exfuse.Fs.Path.canonical/1 refuses any ".." segment (and NUL, and absolute
  # paths). Rejecting beats normalising — a normalised path can still escape
  # through a symlink.
  #
  # The positive control is the point of this test. Without a REAL workspace
  # containing a REAL document, every case 404s at `File.dir?/1` in
  # `normalize_workspace_root/1`, long before any path handling — so the test
  # passes even if the controller does `Path.join(root, segments)`. It did
  # exactly that until 2026-07-28.
  test "refuses path traversal but serves a real document under the same root", %{conn: conn} do
    root = preview_root()
    File.mkdir_p!(Path.join(root, "drafts"))
    bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    File.write!(Path.join(root, "drafts/ok.hwpx"), bytes)
    on_exit(fn -> File.rm_rf(root) end)

    fetch = fn doc ->
      get(conn, "/document/bytes/" <> doc <> "?" <> URI.encode_query(%{"path" => root}))
    end

    # control: the guard is reachable and the happy path works
    assert response(fetch.("drafts/ok.hwpx"), 200) == bytes

    for doc <- [
          "../../etc/passwd",
          "drafts/../../../etc/passwd",
          "%2e%2e%2f%2e%2e%2fetc%2fpasswd",
          "drafts/%2e%2e%2f%2e%2e%2fetc%2fpasswd",
          ".ecrits/mount/secret.hwpx"
        ] do
      assert fetch.(doc).status in [400, 404], "traversal leaked for #{doc}"
    end
  end

  test "serves a document-bound preview snapshot repeatedly after the source changes", %{
    conn: conn
  } do
    root = preview_root()
    relative_path = "preview.hwpx"
    path = Path.join(root, relative_path)
    edit_time_bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    later_bytes = rezip_hwpx(edit_time_bytes, "later-version")

    File.mkdir_p!(root)
    File.write!(path, edit_time_bytes)

    document_id = Document.id_for(root, relative_path)
    assert {:ok, snapshot} = PreviewSnapshot.put(document_id, edit_time_bytes)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(Path.dirname(PreviewSnapshot.path(document_id, snapshot.id)))
    end)

    File.write!(path, later_bytes)

    url = snapshot_url(root, relative_path, snapshot.id)
    first = get(conn, url)

    assert response(first, 200) == edit_time_bytes

    assert get_resp_header(first, "cache-control") == [
             "private, max-age=31536000, immutable"
           ]

    assert get_resp_header(first, "etag") == [~s("#{snapshot.id}")]

    second = first |> recycle() |> get(url)
    assert response(second, 200) == edit_time_bytes

    live_url = "/document/bytes/" <> relative_path <> "?" <> URI.encode_query(%{"path" => root})

    current = second |> recycle() |> get(live_url)
    assert response(current, 200) == later_bytes

    File.rm!(path)
    refute File.exists?(path)

    after_source_delete = current |> recycle() |> get(url)
    assert response(after_source_delete, 200) == edit_time_bytes
  end

  test "does not serve one document's preview snapshot through another document path", %{
    conn: conn
  } do
    root = preview_root()
    bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    first_path = Path.join(root, "first.hwpx")
    other_path = Path.join(root, "other.hwpx")

    File.mkdir_p!(root)
    File.write!(first_path, bytes)
    File.write!(other_path, bytes)

    first_document_id = Document.id_for(root, "first.hwpx")
    assert {:ok, snapshot} = PreviewSnapshot.put(first_document_id, bytes)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(Path.dirname(PreviewSnapshot.path(first_document_id, snapshot.id)))
    end)

    wrong_document = get(conn, snapshot_url(root, "other.hwpx", snapshot.id))
    assert response(wrong_document, 404)

    replacement = if String.starts_with?(snapshot.id, "0"), do: "1", else: "0"
    tampered_id = replacement <> String.slice(snapshot.id, 1..-1//1)
    tampered = wrong_document |> recycle() |> get(snapshot_url(root, "first.hwpx", tampered_id))

    assert response(tampered, 404)
  end

  defp preview_root do
    Path.join(
      System.tmp_dir!(),
      "ecrits-preview-controller-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  # content-addressed: {document_id, sha256-of-bytes}. No root, no relative path,
  # no query string — which is what makes the response immutably cacheable.
  defp snapshot_url(root, relative_path, snapshot_id) do
    "/document/snapshot/" <> Document.id_for(root, relative_path) <> "/" <> snapshot_id
  end

  defp rezip_hwpx(bytes, marker) do
    assert {:ok, entries} = :zip.unzip(bytes, [:memory])

    entries =
      Enum.reject(entries, fn {name, _contents} -> name == ~c"preview-version.txt" end)

    assert {:ok, {_name, rewritten}} =
             :zip.create(
               ~c"preview-version.hwpx",
               entries ++ [{~c"preview-version.txt", marker}],
               [:memory]
             )

    rewritten
  end
end
