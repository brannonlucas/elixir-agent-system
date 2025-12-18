defmodule NervousSystem.Provider do
  @moduledoc """
  Behaviour defining the contract for LLM providers.

  Each provider (Anthropic, OpenAI, Google) implements this behaviour,
  allowing the Agent system to interact with different LLMs uniformly.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type stream_chunk :: {:chunk, String.t()} | {:done, String.t()} | {:error, term()}

  @doc """
  Send a chat completion request and return the full response.
  """
  @callback chat(messages :: [message()], opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Stream a chat completion, sending chunks to the caller process.
  Returns a Task that can be awaited or monitored.

  The caller will receive messages in the form:
  - {:stream_chunk, chunk_text}
  - {:stream_done, full_response}
  - {:stream_error, reason}
  """
  @callback stream(messages :: [message()], opts :: keyword()) :: Task.t()

  @doc """
  Get the provider name as an atom.
  """
  @callback name() :: atom()

  @doc """
  Get the default model for this provider.
  """
  @callback default_model() :: String.t()

  # Helper to get provider config
  def get_config(provider) do
    Application.get_env(:nervous_system, :llm_providers)[provider] || []
  end
end
