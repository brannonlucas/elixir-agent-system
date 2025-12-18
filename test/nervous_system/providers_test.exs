defmodule NervousSystem.ProvidersTest do
  use ExUnit.Case, async: true

  alias NervousSystem.Providers.{Anthropic, OpenAI, Google, Perplexity}

  # Provider tests verify configuration and structure
  # Full API integration tests require valid API keys

  describe "Anthropic provider" do
    test "module exists and has required functions" do
      # Verify module exports expected functions by calling them
      assert Anthropic.name() == :anthropic
      assert is_binary(Anthropic.default_model())
    end
  end

  describe "OpenAI provider" do
    test "module exists and has required functions" do
      assert OpenAI.name() == :openai
      assert is_binary(OpenAI.default_model())
    end
  end

  describe "Google provider" do
    test "module exists and has required functions" do
      assert Google.name() == :google
      assert is_binary(Google.default_model())
    end
  end

  describe "Perplexity provider" do
    test "module exists and has required functions" do
      assert Perplexity.name() == :perplexity
      assert is_binary(Perplexity.default_model())
    end
  end

  describe "Provider configuration" do
    test "LLM providers are configured in runtime" do
      config = Application.get_env(:nervous_system, :llm_providers) || []

      # Verify structure exists (values depend on env vars)
      assert is_list(config) or is_nil(config)
    end
  end
end
