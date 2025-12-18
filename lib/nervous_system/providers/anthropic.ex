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
      case api_key() do
        nil ->
          send(caller, {:stream_error, {:missing_api_key, "ANTHROPIC_API_KEY not configured"}})
          ""

        key ->
          model = Keyword.get(opts, :model) || default_model()
          system = Keyword.get(opts, :system)
          max_tokens = Keyword.get(opts, :max_tokens, 4096)

          body =
            %{
              model: model,
              max_tokens: max_tokens,
              stream: true,
              messages: format_messages(messages)
            }
            |> maybe_add_system(system)

          # Use process dictionary to track streaming state
          Process.put(:stream_buffer, "")
          Process.put(:stream_response, "")

          result =
            Req.post(@api_url,
              json: body,
              headers: headers(key),
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

            {:ok, %{status: status, body: body}} ->
              send(caller, {:stream_error, {:api_error, status, body}})
              ""

            {:error, reason} ->
              send(caller, {:stream_error, reason})
              ""
          end
      end
    end)
  end

  # Parse SSE events from raw data, returning remaining buffer and extracted texts
  defp parse_sse_events(data) do
    # SSE events are separated by double newlines
    parts = String.split(data, "\n\n", trim: false)

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

  # Extract text content from an SSE event
  defp extract_text_from_event(event) do
    event
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.flat_map(fn line ->
      json = String.trim_leading(line, "data: ")

      case Jason.decode(json) do
        {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => text}}} ->
          [text]

        _ ->
          []
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
