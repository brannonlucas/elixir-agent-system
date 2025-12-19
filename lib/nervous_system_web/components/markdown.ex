defmodule NervousSystemWeb.Markdown do
  @moduledoc """
  Markdown rendering helper for agent message content.
  """

  @doc """
  Convert markdown to safe HTML for rendering.

  Uses Earmark for parsing. Returns a Phoenix.HTML.safe tuple
  that can be rendered directly in HEEx templates.
  """
  def render(nil), do: ""
  def render(""), do: ""

  def render(markdown) do
    markdown
    |> Earmark.as_html!(code_class_prefix: "language-")
    |> Phoenix.HTML.raw()
  end
end
