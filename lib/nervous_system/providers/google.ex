defmodule NervousSystem.Providers.Google do
  @moduledoc """
  Google Gemini API provider implementation.

  Supports streaming responses via Server-Sent Events (SSE).
  """

  @behaviour NervousSystem.Provider

  @api_base "https://generativelanguage.googleapis.com/v1beta/models"

  @impl true
  def name, do: :google

  @impl true
  def default_model do
    config()[:default_model] || "gemini-2.0-flash"
  end

  @impl true
  def chat(messages, opts \\ []) do
    case api_key() do
      nil ->
        {:error, {:missing_api_key, "GEMINI_API_KEY not configured"}}

      key ->
        # Use || because Keyword.get returns nil if key exists with nil value
        model = Keyword.get(opts, :model) || default_model()
        system = Keyword.get(opts, :system)

        body = build_request_body(messages, system)
        url = "#{@api_base}/#{model}:generateContent?key=#{key}"

        case Req.post(url, json: body, receive_timeout: 120_000) do
          {:ok, %{status: 200, body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]}}} ->
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

  defp build_request_body(messages, system) do
    contents = format_messages(messages)
    body = %{contents: contents}

    if system do
      Map.put(body, :system_instruction, %{parts: [%{text: system}]})
    else
      body
    end
  end

  # Gemini uses "user" and "model" roles
  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: "assistant", content: content} ->
        %{"role" => "model", "parts" => [%{"text" => content}]}

      %{role: role, content: content} ->
        %{"role" => role, "parts" => [%{"text" => content}]}

      %{"role" => "assistant", "content" => content} ->
        %{"role" => "model", "parts" => [%{"text" => content}]}

      %{"role" => role, "content" => content} ->
        %{"role" => role, "parts" => [%{"text" => content}]}
    end)
  end

  defp api_key do
    config()[:api_key]
  end

  defp config do
    NervousSystem.Provider.get_config(:google)
  end
end
