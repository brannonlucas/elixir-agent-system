defmodule NervousSystem.Providers.OpenAI do
  @moduledoc """
  OpenAI GPT API provider implementation.

  Supports streaming responses via Server-Sent Events (SSE).
  """

  @behaviour NervousSystem.Provider

  @api_url "https://api.openai.com/v1/chat/completions"

  @impl true
  def name, do: :openai

  @impl true
  def default_model do
    config()[:default_model] || "gpt-4o"
  end

  @impl true
  def chat(messages, opts \\ []) do
    case api_key() do
      nil ->
        {:error, {:missing_api_key, "OPENAI_API_KEY not configured"}}

      key ->
        # Use || because Keyword.get returns nil if key exists with nil value
        model = Keyword.get(opts, :model) || default_model()
        system = Keyword.get(opts, :system)
        max_tokens = Keyword.get(opts, :max_tokens, 4096)

        formatted_messages = format_messages(messages, system)

        body = %{
          model: model,
          max_tokens: max_tokens,
          messages: formatted_messages
        }

        case Req.post(@api_url, json: body, headers: headers(key), receive_timeout: 120_000) do
          {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
            {:ok, text}

          {:ok, %{status: status, body: body}} ->
            {:error, {:api_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def stream(messages, opts \\ []) do
    caller = self()

    Task.async(fn ->
      case chat(messages, opts) do
        {:ok, response} ->
          send(caller, {:stream_chunk, response})
          send(caller, {:stream_done, response})
          response

        {:error, reason} ->
          send(caller, {:stream_error, reason})
          ""
      end
    end)
  end

  # OpenAI uses system messages in the messages array
  defp format_messages(messages, nil), do: format_messages_only(messages)

  defp format_messages(messages, system) do
    [%{"role" => "system", "content" => system} | format_messages_only(messages)]
  end

  defp format_messages_only(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} -> %{"role" => role, "content" => content}
      msg when is_map(msg) -> msg
    end)
  end

  defp api_key do
    config()[:api_key]
  end

  defp headers(api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]
  end

  defp config do
    NervousSystem.Provider.get_config(:openai)
  end
end
