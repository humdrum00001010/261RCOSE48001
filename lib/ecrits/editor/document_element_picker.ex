defmodule Ecrits.DocumentElementPicker do
  @moduledoc """
  Embedded state model for document-element picking.

  Picks arrive from the canvas that hit-tested the click, via
  `ecrits:document-element-picker.pick-toggled`. Both engine canvases dispatch
  it, by different routes:

    * **office** (LibreOffice WASM) hit-tests the click in the host document and
      dispatches directly;
    * **hwp/hwpx** render inside the rhwp-studio iframe, which never hears a
      host DOM event. The click is hit-tested by studio's own engine and pushed
      back over embed RPC's `rhwp-event{selection}` (`host-events-v1`);
      `Canvas.RhwpStudio` lowers that to a `Doc.Rhwp.Ref` string and dispatches
      the same event. The ref an agent receives is the one `doc.edit` accepts.

  Markdown has no element canvas, so the toggle is not offered there. See
  `EditorSurface.host_picker_chrome?/1`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.DocumentElementPicker.Pick
  alias __MODULE__.Transition

  @primary_key false
  @max_picks 32

  embedded_schema do
    field :enabled?, :boolean, default: false
    embeds_many :picks, Pick, on_replace: :delete
  end

  def new(attrs \\ %{}), do: apply_attrs(%__MODULE__{}, attrs)

  def changeset(%__MODULE__{} = picker, attrs) when is_map(attrs) do
    picker
    |> cast(attrs, [:enabled?])
    |> cast_embed(:picks, with: &Pick.changeset/2)
    |> validate_length(:picks, max: @max_picks)
  end

  def build_pick(attrs) when is_map(attrs), do: Pick.build(attrs)

  def encode(%__MODULE__{} = picker) do
    picks =
      Enum.map(picker.picks, fn pick ->
        pick
        |> Map.from_struct()
        |> Map.take([:document, :backend, :format, :type, :ref, :text, :hint, :ir, :rects])
      end)

    Jason.encode!(%{enabled: picker.enabled?, picks: picks})
  end

  defdelegate toggle(picker), to: Transition
  defdelegate put_enabled(picker, enabled?), to: Transition
  defdelegate toggle_pick(picker, attrs), to: Transition
  defdelegate remove_pick(picker, key), to: Transition
  defdelegate clear(picker), to: Transition
  defdelegate compact_picks(picks), to: Transition
  defdelegate compact_picks(picker, implicit_picks), to: Transition
  defdelegate pick_key(pick), to: Transition

  defp apply_attrs(picker, attrs) do
    changeset = changeset(picker, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: picker
  end
end
