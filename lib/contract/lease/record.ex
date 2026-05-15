defmodule Contract.Lease.Record do
  @moduledoc """
  Ecto schema for one row in the `leases` table.

  A lease guards which `Contract.Session` process is allowed to commit on
  behalf of a document. The `fencing_token` is a monotonically-increasing
  `bigserial` issued by Postgres; older sessions whose token no longer
  matches the current row are *fenced out* and must terminate. See SPEC.md
  §15.
  """

  use Ecto.Schema

  alias Contract.Types, as: T

  @type t :: %__MODULE__{
          document_id: T.document_id(),
          owner_ref: String.t(),
          fencing_token: integer(),
          expires_at: DateTime.t()
        }

  @primary_key {:document_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "leases" do
    field :owner_ref, :string
    field :fencing_token, :integer
    field :expires_at, :utc_datetime_usec
  end
end
