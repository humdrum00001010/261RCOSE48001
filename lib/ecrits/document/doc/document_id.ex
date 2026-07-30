defmodule Ecrits.Doc.DocumentId do
  @moduledoc """
  The document id scheme — `d_<kind>_<16 url-base64 chars of
  sha256("<kind>:<canonical path>")>` — and nothing else.

  TWO independent registries derive this id and must keep agreeing on it byte
  for byte: `Ecrits.Workspace.Session`'s viewer table is keyed by it, and
  `Ecrits.Doc.Projection.document_id/1` re-derives it so `DocFs.readdir` can ask
  "does this file have a viewer?". A one-byte change would not fail anywhere —
  the viewer lookup would simply miss, and every document would silently vanish
  from the mount. That is why the derivation lives alone in a pure module
  instead of inside whichever registry happens to need it.

  Lifted verbatim from `Ecrits.Doc.Pool.document_id_for/2` when the Pool was
  deleted (2026-07-29); the Pool could hold no document, but its id scheme was
  never about the Pool.
  """

  alias Ecrits.Fuse.DocMount

  @type t :: String.t()

  @doc """
  The stable document id for `path` + `kind`.

      iex> Ecrits.Doc.DocumentId.for_path("/tmp/ecrits-id/report.hwp", :hwp)
      "d_hwp_OkOqLkVKElx5VRpy"

  The same file addressed through `/tmp` or `/private/tmp` yields ONE id, so a
  viewer attached under either spelling is still found.
  """
  @spec for_path(String.t(), atom()) :: t()
  def for_path(path, kind) do
    path = canonical_path(path)

    hash =
      :crypto.hash(:sha256, "#{kind}:#{path}")
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 16)

    "d_#{kind}_#{hash}"
  end

  # Only an ABSOLUTE path names a file on disk, so only that form is
  # canonicalised through the mount's root rewriting. A relative path is not a
  # filesystem identity and is hashed as given.
  defp canonical_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path = Path.expand(path)
      Path.join(DocMount.canonical_root(Path.dirname(path)), Path.basename(path))
    else
      path
    end
  end
end
