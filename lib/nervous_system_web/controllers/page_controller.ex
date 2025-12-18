defmodule NervousSystemWeb.PageController do
  use NervousSystemWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
