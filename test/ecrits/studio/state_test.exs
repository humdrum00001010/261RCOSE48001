defmodule Ecrits.Studio.StateTest do
  @moduledoc """
  Tests for `Ecrits.Studio.State` — specifically the
  `recently_authored_agent` tracking that drives the agent typing-reveal
  animation on `Canvas.Editor`. Board task #121.
  """

  use ExUnit.Case, async: true

  alias Ecrits.Studio.State

  describe "mark_recently_authored/3" do
    test "stamps each node id with the supplied epoch ms" do
      state = %State{}
      now = 1_700_000_000_000

      stamped = State.mark_recently_authored(state, ["n-1", "n-2"], now)

      assert stamped.recently_authored_agent == %{"n-1" => now, "n-2" => now}
    end

    test "ignores non-binary node ids" do
      state = %State{}

      stamped = State.mark_recently_authored(state, ["n-1", nil, :atom, 42], 100)

      assert stamped.recently_authored_agent == %{"n-1" => 100}
    end

    test "merges fresh stamps onto existing ones (preserving non-stale entries)" do
      state = %State{recently_authored_agent: %{"old" => 100}}
      now = 100 + 100

      stamped = State.mark_recently_authored(state, ["new"], now)

      # "old" survives the prune (well under the 6s TTL away from `now`)
      # and "new" lands alongside.
      assert stamped.recently_authored_agent == %{"old" => 100, "new" => now}
    end

    test "drops entries older than the TTL before stamping" do
      ttl = State.recently_authored_ttl_ms()
      state = %State{recently_authored_agent: %{"stale" => 0}}
      now = ttl + 1_000

      stamped = State.mark_recently_authored(state, ["fresh"], now)

      assert stamped.recently_authored_agent == %{"fresh" => now}
    end
  end

  describe "prune_recently_authored/2" do
    test "keeps entries within the TTL" do
      ttl = State.recently_authored_ttl_ms()
      now = 10_000_000
      state = %State{recently_authored_agent: %{"a" => now, "b" => now - div(ttl, 2)}}

      pruned = State.prune_recently_authored(state, now)

      assert pruned.recently_authored_agent == %{"a" => now, "b" => now - div(ttl, 2)}
    end

    test "drops entries older than the TTL" do
      ttl = State.recently_authored_ttl_ms()
      now = 10_000_000
      state = %State{recently_authored_agent: %{"old" => now - ttl - 1, "fresh" => now}}

      pruned = State.prune_recently_authored(state, now)

      assert pruned.recently_authored_agent == %{"fresh" => now}
    end

    test "normalizes nil map to empty" do
      state = %State{recently_authored_agent: nil}
      pruned = State.prune_recently_authored(state, 1_000)
      assert pruned.recently_authored_agent == %{}
    end
  end

  describe "clear_recently_authored/2" do
    test "removes a single node id from the map" do
      state = %State{recently_authored_agent: %{"a" => 100, "b" => 200}}

      assert State.clear_recently_authored(state, "a").recently_authored_agent == %{"b" => 200}
    end

    test "is a noop when the id is absent" do
      state = %State{recently_authored_agent: %{"a" => 100}}

      assert State.clear_recently_authored(state, "nope").recently_authored_agent == %{
               "a" => 100
             }
    end

    test "is a noop when the map is unset" do
      state = %State{}
      assert State.clear_recently_authored(state, "any") == state
    end
  end
end
