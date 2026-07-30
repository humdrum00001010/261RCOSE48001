defmodule Ecrits.Doc.DocumentIdTest do
  @moduledoc """
  The id scheme is a CONTRACT between two registries that never talk to each
  other: `Ecrits.Workspace.Session` keys its viewer table by it, and
  `Ecrits.Doc.Projection.document_id/1` re-derives it for the doc VFS listing.
  A drift would not raise anywhere — the viewer lookup would just miss and every
  document would disappear from the mount — so the value is pinned literally.
  """
  use ExUnit.Case, async: true

  alias Ecrits.Doc.DocumentId

  doctest Ecrits.Doc.DocumentId

  test "the id is the exact value the deleted Ecrits.Doc.Pool.document_id_for/2 minted" do
    assert DocumentId.for_path("/private/tmp/ecrits-id/report.hwp", :hwp) ==
             "d_hwp_OkOqLkVKElx5VRpy"
  end

  test "kind is part of the hash, so one path is two documents" do
    refute DocumentId.for_path("/private/tmp/ecrits-id/report.hwp", :hwp) ==
             DocumentId.for_path("/private/tmp/ecrits-id/report.hwp", :hwpx)
  end

  test "an absolute path canonicalises through the mount root" do
    # macOS resolves /tmp/<dir> to /private/tmp/<dir>; a viewer attached under
    # either spelling must be found by the other.
    assert DocumentId.for_path("/tmp/ecrits-id/report.hwp", :hwp) ==
             DocumentId.for_path("/private/tmp/ecrits-id/report.hwp", :hwp)
  end

  test "a relative path is not a filesystem identity and is hashed as given" do
    refute DocumentId.for_path("report.hwp", :hwp) ==
             DocumentId.for_path(Path.join(File.cwd!(), "report.hwp"), :hwp)
  end
end
