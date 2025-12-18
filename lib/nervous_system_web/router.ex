defmodule NervousSystemWeb.Router do
  use NervousSystemWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NervousSystemWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NervousSystemWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Deliberation rooms
    live "/room", RoomLive, :new
    live "/room/:id", RoomLive, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", NervousSystemWeb do
  #   pipe_through :api
  # end
end
