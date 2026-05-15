defmodule Contract.ConfigTest do
  use ExUnit.Case, async: false

  alias Contract.Config

  describe "assert_loaded!/1" do
    test ":prod raises when a required key is missing" do
      key = "OPENAI_API_KEY"
      original = System.get_env(key)
      System.delete_env(key)

      try do
        assert_raise RuntimeError, ~r/missing required environment variables/, fn ->
          Config.assert_loaded!(:prod)
        end
      after
        if original, do: System.put_env(key, original)
      end
    end

    test ":dev returns :ok even when keys are missing" do
      key = "OPENAI_API_KEY"
      original = System.get_env(key)
      System.delete_env(key)

      try do
        # `capture_log` would swallow the warning; we just assert :ok.
        assert :ok = Config.assert_loaded!(:dev)
      after
        if original, do: System.put_env(key, original)
      end
    end

    test ":test returns :ok when keys are missing" do
      assert :ok = Config.assert_loaded!(:test)
    end
  end

  describe "required_keys/1" do
    test ":prod includes DATABASE_URL and SECRET_KEY_BASE" do
      keys = Config.required_keys(:prod)
      assert "DATABASE_URL" in keys
      assert "SECRET_KEY_BASE" in keys
      assert "OPENAI_API_KEY" in keys
      assert "R2_BUCKET" in keys
    end

    test ":dev/:test do not require DATABASE_URL or SECRET_KEY_BASE" do
      keys = Config.required_keys(:dev)
      refute "DATABASE_URL" in keys
      refute "SECRET_KEY_BASE" in keys
    end
  end
end
