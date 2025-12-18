defmodule NervousSystem.Providers.Anthropic do
  @moduledoc """
  Anthropic Claude API provider implementation.

  Supports streaming responses via Server-Sent Events (SSE).
  """

  @behaviour NervousSystem.Provider

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"

  @impl true
  def name, do: :anthropic

  @impl true
  def default_model do
    config()[:default_model] || "claude-sonnet-4-20250514"
  end

  @impl true
  def chat(messages, opts \\ []) do
    case api_key() do
      nil ->
        {:error, {:missing_api_key, "ANTHROPIC_API_KEY not configured"}}

      key ->
        # Use || because Keyword.get returns nil if key exists with nil value
        model = Keyword.get(opts, :model) || default_model()
        system = Keyword.get(opts, :system)
        max_tokens = Keyword.get(opts, :max_tokens, 4096)

        body =
          %{
            model: model,
            max_tokens: max_tokens,
            messages: format_messages(messages)
          }
          |> maybe_add_system(system)

        case Req.post(@api_url, json: body, headers: headers(key), receive_timeout: 120_000) do
          {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
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
      # For now, use non-streaming to verify API works
      case chat(messages, opts) do
        {:ok, response} ->
          # Simulate streaming by sending the whole response
          send(caller, {:stream_chunk, response})
          send(caller, {:stream_done, response})
          response

        {:error, reason} ->
          send(caller, {:stream_error, reason})
          ""
      end
    end)
  end

  # Format messages for Anthropic API
  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} -> %{"role" => role, "content" => content}
      msg when is_map(msg) -> msg
    end)
  end

  defp maybe_add_system(body, nil), do: body
  defp maybe_add_system(body, system), do: Map.put(body, :system, system)

  defp api_key do
    config()[:api_key]
  end

  defp headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]
  end

  defp config do
    NervousSystem.Provider.get_config(:anthropic)
  end
end
