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
    require Logger
    caller = self()

    Task.async(fn ->
      case api_key() do
        nil ->
          send(caller, {:stream_error, {:missing_api_key, "GEMINI_API_KEY not configured"}})
          ""

        key ->
          model = Keyword.get(opts, :model) || default_model()
          system = Keyword.get(opts, :system)

          body = build_request_body(messages, system)
          # Use streamGenerateContent endpoint for streaming
          url = "#{@api_base}/#{model}:streamGenerateContent?key=#{key}&alt=sse"

          # Use process dictionary to track streaming state
          Process.put(:stream_buffer, "")
          Process.put(:stream_response, "")

          result =
            Req.post(url,
              json: body,
              receive_timeout: 120_000,
              into: fn {:data, chunk}, {req, resp} ->
                buffer = Process.get(:stream_buffer, "")
                full_response = Process.get(:stream_response, "")

                # Process SSE data and extract text deltas
                {new_buffer, texts} = parse_sse_events(buffer <> chunk)
                new_full_response = full_response <> Enum.join(texts, "")

                Process.put(:stream_buffer, new_buffer)
                Process.put(:stream_response, new_full_response)

                # Send each text chunk to the caller
                Enum.each(texts, fn text ->
                  if text != "", do: send(caller, {:stream_chunk, text})
                end)

                {:cont, {req, resp}}
              end
            )

          full_response = Process.get(:stream_response, "")

          case result do
            {:ok, %{status: 200}} ->
              send(caller, {:stream_done, full_response})
              full_response

            {:ok, %{status: status, body: resp_body}} ->
              Logger.error("🔷 GEMINI error: status #{status}, body: #{inspect(resp_body)}")
              send(caller, {:stream_error, {:api_error, status, resp_body}})
              ""

            {:error, reason} ->
              Logger.error("🔷 GEMINI error: #{inspect(reason)}")
              send(caller, {:stream_error, reason})
              ""
          end
      end
    end)
  end

  # Parse SSE events from raw data, returning remaining buffer and extracted texts
  defp parse_sse_events(data) do
    # SSE events can be separated by \r\n\r\n (CRLF) or \n\n (LF)
    # Gemini uses CRLF, so we normalize first
    normalized = String.replace(data, "\r\n", "\n")
    parts = String.split(normalized, "\n\n", trim: false)

    case parts do
      [single] ->
        # No complete event yet, keep buffering
        {single, []}

      events ->
        # Last part may be incomplete
        {buffer, complete} = List.pop_at(events, -1)
        texts = Enum.flat_map(complete, &extract_text_from_event/1)
        {buffer || "", texts}
    end
  end

  # Extract text content from an SSE event (Gemini format)
  defp extract_text_from_event(event) do
    event
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.flat_map(fn line ->
      json = String.trim_leading(line, "data: ")

      case Jason.decode(json) do
        {:ok, %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]}} ->
          [text]

        _ ->
          []
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
