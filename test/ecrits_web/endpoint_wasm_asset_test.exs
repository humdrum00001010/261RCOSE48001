defmodule EcritsWeb.EndpointWasmAssetTest do
  @moduledoc """
  Delivery of the browser engine bundles *through the endpoint*, not just through
  the plug in isolation — `CrossOriginIsolationPlug` is mounted ahead of
  `Plug.Static`, whose `:only` list does not include these prefixes, so a
  regression in the mount order would silently turn the engine into a 404 with
  every plug unit test still green.

  These used to read the bytes out of `Application.app_dir(:libreofficex, ...)`
  and `app_dir(:ehwp, ...)`. Both deps were deleted 2026-07-26; the office bundle
  now comes from `OFFICE_WASM_DIST` / `mix assets.office_wasm`, and the HWP
  `/assets/rhwp/*` prefix is gone entirely (rhwp-studio ships its own
  `rhwp_bg.wasm` inside its own bundle).
  """

  # Not async: the bundle location is application env, which is process-global.
  use EcritsWeb.ConnCase, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    dist = Path.join(tmp_dir, "program")
    File.mkdir_p!(dist)

    contents = %{
      "soffice.js" => "var Module = {};",
      "soffice.wasm" => <<0, 97, 115, 109, 1, 0, 0, 0>>,
      "soffice.data" => "FS image bytes",
      "soffice.data.js.metadata" => ~s({"files":[],"remote_package_size":14})
    }

    Enum.each(contents, fn {name, body} -> File.write!(Path.join(dist, name), body) end)

    previous = Application.get_env(:ecrits, :office_wasm_dist)
    Application.put_env(:ecrits, :office_wasm_dist, dist)

    on_exit(fn ->
      if previous do
        Application.put_env(:ecrits, :office_wasm_dist, previous)
      else
        Application.delete_env(:ecrits, :office_wasm_dist)
      end
    end)

    {:ok, contents: contents}
  end

  test "serves the office WASM set from the configured bundle dir", %{
    conn: conn,
    contents: contents
  } do
    for {name, body} <- contents do
      resp = get(conn, "/assets/office/" <> name)

      assert response(resp, 200) == body
      assert get_resp_header(resp, "cache-control") == ["no-cache"]
      assert get_resp_header(resp, "cross-origin-opener-policy") == ["same-origin"]
      assert get_resp_header(resp, "cross-origin-embedder-policy") == ["require-corp"]
    end
  end

  test "the retired HWP wasm prefix is not served", %{conn: conn} do
    for path <- ["/assets/rhwp/rhwp_bg.wasm", "/assets/rhwp/rhwp.js"] do
      resp = get(conn, path)

      assert resp.status == 404, "expected #{path} to 404, got #{resp.status}"
      # Nothing engine-shaped came back: no wasm body, no engine cache policy.
      refute get_resp_header(resp, "cache-control") == ["no-cache"]
      refute get_resp_header(resp, "content-type") == ["application/wasm"]
    end
  end
end
