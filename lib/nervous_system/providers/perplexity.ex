defmodule NervousSystem.Providers.Perplexity do
  @moduledoc """
  Perplexity AI provider implementation.

  Specialized for research queries with citations.
  Uses the Sonar model which has real-time web search built in.
  """

  @behaviour NervousSystem.Provider

  @api_url "https://api.perplexity.ai/chat/completions"

  @impl true
  def name, do: :perplexity

  @impl true
  def default_model do
    config()[:default_model] || "sonar"
  end

  @impl true
  def chat(messages, opts \\ []) do
    case api_key() do
      nil ->
        {:error, {:missing_api_key, "PERPLEXITY_API_KEY not configured"}}

      key ->
        model = Keyword.get(opts, :model) || default_model()
        system = Keyword.get(opts, :system)

        formatted_messages = format_messages(messages, system)

        body = %{
          model: model,
          messages: formatted_messages,
          return_citations: true
        }

        case Req.post(@api_url, json: body, headers: headers(key), receive_timeout: 120_000) do
          {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]} = resp_body}} ->
            # Include citations if available
            citations = get_in(resp_body, ["citations"]) || []
            if length(citations) > 0 do
              citation_text = format_citations(citations)
              {:ok, text <> "\n\n" <> citation_text}
            else
              {:ok, text}
            end

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
          send(caller, {:stream_error, {:missing_api_key, "PERPLEXITY_API_KEY not configured"}})
          ""

        key ->
          model = Keyword.get(opts, :model) || default_model()
          system = Keyword.get(opts, :system)

          formatted_messages = format_messages(messages, system)

          body = %{
            model: model,
            stream: true,
            return_citations: true,
            messages: formatted_messages
          }

          # Use process dictionary to track streaming state
          Process.put(:stream_buffer, "")
          Process.put(:stream_response, "")
          Process.put(:stream_citations, [])

          require Logger
          Logger.debug("🔬 PERPLEXITY: Starting stream request")

          result =
            Req.post(@api_url,
              json: body,
              headers: headers(key),
              receive_timeout: 120_000,
              into: fn {:data, chunk}, {req, resp} ->
                Logger.debug("🔬 PERPLEXITY: Received chunk of #{byte_size(chunk)} bytes")
                # Log first chunk sample to see format
                if Process.get(:stream_response, "") == "" do
                  Logger.debug("🔬 PERPLEXITY: First chunk sample: #{String.slice(chunk, 0, 500)}")
                end
                buffer = Process.get(:stream_buffer, "")
                full_response = Process.get(:stream_response, "")
                citations = Process.get(:stream_citations, [])

                # Process SSE data and extract text deltas
                {new_buffer, texts, new_citations} = parse_sse_events(buffer <> chunk)
                new_full_response = full_response <> Enum.join(texts, "")
                all_citations = citations ++ new_citations

                Logger.debug("🔬 PERPLEXITY: Extracted #{length(texts)} text chunks, response now #{byte_size(new_full_response)} bytes")

                Process.put(:stream_buffer, new_buffer)
                Process.put(:stream_response, new_full_response)
                Process.put(:stream_citations, all_citations)

                # Send each text chunk to the caller
                Enum.each(texts, fn text ->
                  if text != "", do: send(caller, {:stream_chunk, text})
                end)

                {:cont, {req, resp}}
              end
            )

          Logger.debug("🔬 PERPLEXITY: Request complete, result status: #{inspect(elem(result, 0))}")

          full_response = Process.get(:stream_response, "")
          citations = Process.get(:stream_citations, [])

          case result do
            {:ok, %{status: 200}} ->
              # Append citations to the response if available
              final_response =
                if length(citations) > 0 do
                  citation_text = format_citations(Enum.uniq(citations))
                  full_response <> "\n\n" <> citation_text
                else
                  full_response
                end

              send(caller, {:stream_done, final_response})
              final_response

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

  # Parse SSE events from raw data, returning remaining buffer, extracted texts, and citations
  defp parse_sse_events(data) do
    # SSE events are separated by double newlines
    parts = String.split(data, "\n\n", trim: false)

    case parts do
      [single] ->
        # No complete event yet, keep buffering
        {single, [], []}

      events ->
        # Last part may be incomplete
        {buffer, complete} = List.pop_at(events, -1)
        {texts, citations} = extract_content_from_events(complete)
        {buffer || "", texts, citations}
    end
  end

  # Extract text content and citations from SSE events (Perplexity uses OpenAI-like format)
  defp extract_content_from_events(events) do
    Enum.reduce(events, {[], []}, fn event, {texts_acc, citations_acc} ->
      {texts, citations} = extract_from_event(event)
      {texts_acc ++ texts, citations_acc ++ citations}
    end)
  end

  defp extract_from_event(event) do
    event
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.reduce({[], []}, fn line, {texts, citations} ->
      json = String.trim_leading(line, "data: ")

      # Perplexity sends "[DONE]" as final message
      if json == "[DONE]" do
        {texts, citations}
      else
        case Jason.decode(json) do
          {:ok, %{"choices" => [%{"delta" => %{"content" => text}} | _]} = data} ->
            # Extract citations if present in this chunk
            new_citations = Map.get(data, "citations", [])
            {texts ++ [text], citations ++ new_citations}

          _ ->
            {texts, citations}
        end
      end
    end)
  end

  defp format_messages(messages, nil), do: format_messages_only(messages)

  defp format_messages(messages, system) do
    [%{"role" => "system", "content" => system} | format_messages_only(messages)]
  end

  defp format_messages_only(messages) do
    # Perplexity requires strict user/assistant alternation
    # AND must start with a user message after system prompt
    messages
    |> Enum.map(fn
      %{role: role, content: content} -> %{"role" => to_string(role), "content" => content}
      %{"role" => role, "content" => content} -> %{"role" => role, "content" => content}
      msg -> msg
    end)
    |> merge_consecutive_roles()
    |> ensure_starts_with_user()
    |> ensure_strict_alternation()
  end

  # Merge consecutive messages with the same role into a single message
  defp merge_consecutive_roles(messages) do
    messages
    |> Enum.reduce([], fn msg, acc ->
      current_role = msg["role"]

      case acc do
        [] ->
          [msg]

        [%{"role" => ^current_role, "content" => prev_content} | rest] ->
          # Merge with previous message of same role
          [%{"role" => current_role, "content" => prev_content <> "\n\n---\n\n" <> msg["content"]} | rest]

        _ ->
          [msg | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Perplexity requires first message to be user role
  defp ensure_starts_with_user([]) do
    [%{"role" => "user", "content" => "Please respond."}]
  end

  defp ensure_starts_with_user([%{"role" => "assistant"} = first | rest]) do
    # Prepend a user message that references the context
    [%{"role" => "user", "content" => "Here is the discussion context:"}, first | rest]
  end

  defp ensure_starts_with_user(messages), do: messages

  # Ensure strict user/assistant alternation by inserting bridge messages
  defp ensure_strict_alternation(messages) do
    messages
    |> Enum.reduce([], fn msg, acc ->
      case acc do
        [] ->
          [msg]

        [%{"role" => prev_role} | _] ->
          current_role = msg["role"]
          if prev_role == current_role do
            # Insert a bridge message of the opposite role
            bridge_role = if current_role == "user", do: "assistant", else: "user"
            bridge = %{"role" => bridge_role, "content" => "[Continuing...]"}
            [msg, bridge | acc]
          else
            [msg | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp format_citations(citations) do
    citations
    |> Enum.with_index(1)
    |> Enum.map(fn {url, idx} -> "[#{idx}] #{url}" end)
    |> Enum.join("\n")
    |> then(&("Sources:\n" <> &1))
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
    NervousSystem.Provider.get_config(:perplexity)
  end
end
