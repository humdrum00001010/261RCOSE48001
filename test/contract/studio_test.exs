defmodule Contract.StudioTest do
  use Contract.DataCase, async: false

  import Mox

  alias Contract.Action
  alias Contract.IO.R2Stub
  alias Contract.Runtime
  alias Contract.Studio
  alias Contract.Studio.State

  setup :set_mox_from_context
  setup :verify_on_exit!

  @ctx %Contract.Context{}

  setup do
    R2Stub.setup()
    R2Stub.reset()

    original_drivers = Application.get_env(:contract, :io_drivers, [])

    Application.put_env(
      :contract,
      :io_drivers,
      Keyword.put(original_drivers, :r2, R2Stub)
    )

    on_exit(fn -> Application.put_env(:contract, :io_drivers, original_drivers) end)
    :ok
  end

  describe "load/2" do
    test "returns :no_document mode when no document_id in params" do
      assert {:ok, {%State{mode: :no_document} = state, projection}} =
               Studio.load(@ctx, %{})

      assert state.selected_document_id == nil
      assert state.last_seen_revision == 0
      assert projection.nodes == %{}
    end

    test "loads matter_id from string-keyed params" do
      matter_id = Ecto.UUID.generate()
      {:ok, {state, _}} = Studio.load(@ctx, %{"matter_id" => matter_id})
      assert state.matter_id == matter_id
    end

    test "loads matter_id from atom-keyed params" do
      matter_id = Ecto.UUID.generate()
      {:ok, {state, _}} = Studio.load(@ctx, %{matter_id: matter_id})
      assert state.matter_id == matter_id
    end

    test "loads a document and stamps revision when document_id present" do
      doc = Ecto.UUID.generate()
      :ok = create_doc(doc)

      assert {:ok, {%State{} = state, _projection}} =
               Studio.load(@ctx, %{"document_id" => doc})

      assert state.selected_document_id == doc
      assert state.last_seen_revision >= 1
      assert state.mode in [:editing, :briefing]
    end

    test "ignores empty-string ids" do
      assert {:ok, {%State{mode: :no_document, selected_document_id: nil}, _}} =
               Studio.load(@ctx, %{"document_id" => "", "matter_id" => ""})
    end

    test "returns :error for non-map params" do
      assert {:error, :invalid_params} = Studio.load(@ctx, :not_a_map)
    end
  end

  describe "reload/2" do
    test "returns the input state unchanged when no document is selected" do
      state = %State{mode: :no_document}
      assert {:ok, {^state, projection}} = Studio.reload(@ctx, state)
      assert projection.nodes == %{}
    end

    test "refreshes last_seen_revision from Runtime.load" do
      doc = Ecto.UUID.generate()
      :ok = create_doc(doc)

      state = %State{selected_document_id: doc, last_seen_revision: 0, mode: :editing}
      {:ok, {new_state, _}} = Studio.reload(@ctx, state)

      assert new_state.last_seen_revision >= 1
    end
  end

  describe "select_document/3" do
    test "clears selection when nil" do
      state = %State{selected_document_id: "old", mode: :editing, last_seen_revision: 5}
      assert {:ok, {new_state, _}} = Studio.select_document(@ctx, state, nil)
      assert new_state.selected_document_id == nil
      assert new_state.mode == :no_document
      assert new_state.last_seen_revision == 0
    end

    test "loads new document and resets node selection" do
      doc = Ecto.UUID.generate()
      :ok = create_doc(doc)

      state = %State{selected_node_id: "old-node", mode: :no_document}

      {:ok, {new_state, _}} = Studio.select_document(@ctx, state, doc)
      assert new_state.selected_document_id == doc
      assert new_state.selected_node_id == nil
      assert new_state.last_seen_revision >= 1
    end
  end

  describe "submit/3" do
    test "routes :create_document through Runtime and returns state unchanged" do
      doc = Ecto.UUID.generate()

      action = %Action{
        kind: :create_document,
        document_id: doc,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 0,
        idempotency_key: "studio-create-1",
        payload: %{"title" => "S", "type_key" => "nda"}
      }

      state = %State{selected_document_id: doc, last_seen_revision: 0, mode: :briefing}
      assert {:ok, %State{} = new_state} = Studio.submit(@ctx, state, action)
      # Mode/state in the LV is only updated via PubSub. submit returns the
      # state untouched on a successful append.
      assert new_state.selected_document_id == state.selected_document_id
    end

    test "returns {:error, _} when Runtime rejects the action" do
      action = %Action{kind: :open_document, actor_type: :user}
      state = %State{mode: :no_document}

      assert {:error, :missing_document_id} = Studio.submit(@ctx, state, action)
    end
  end

  describe "sync/3" do
    test "returns no-op when no document selected" do
      state = %State{selected_document_id: nil, last_seen_revision: 0, mode: :no_document}
      assert {:ok, {^state, []}} = Studio.sync(@ctx, state, 0)
    end

    test "returns missed changes from revision and bumps last_seen_revision" do
      doc = Ecto.UUID.generate()
      :ok = create_doc(doc)

      state = %State{selected_document_id: doc, last_seen_revision: 0, mode: :briefing}
      {:ok, {new_state, changes}} = Studio.sync(@ctx, state, 0)

      assert length(changes) >= 1
      assert new_state.last_seen_revision >= 1
    end
  end

  describe "subscribe/2" do
    test "no-op when both selected_document_id and agent_run_id are nil" do
      assert :ok = Studio.subscribe(@ctx, %State{mode: :no_document})
    end

    test "subscribes the caller to the document PubSub topic" do
      doc = Ecto.UUID.generate()
      state = %State{selected_document_id: doc, mode: :briefing}

      assert :ok = Studio.subscribe(@ctx, state)

      # broadcasting on the doc topic should reach us
      Phoenix.PubSub.broadcast(
        Contract.PubSub,
        Contract.Store.pubsub_topic(doc),
        {:probe, doc}
      )

      assert_receive {:probe, ^doc}, 500
    end

    test "subscribes to agent topic when agent_run_id present" do
      run = Ecto.UUID.generate()
      state = %State{agent_run_id: run, mode: :editing}

      assert :ok = Studio.subscribe(@ctx, state)
      Phoenix.PubSub.broadcast(Contract.PubSub, "agent:" <> run, {:agent_probe, run})
      assert_receive {:agent_probe, ^run}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp create_doc(doc) do
    action = %Action{
      kind: :create_document,
      document_id: doc,
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: 0,
      idempotency_key: "studio-create-#{doc}",
      payload: %{"title" => "Doc", "type_key" => "nda"}
    }

    {:ok, _} = Runtime.apply(@ctx, action)
    :ok
  end
end
