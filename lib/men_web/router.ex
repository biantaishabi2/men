defmodule MenWeb.Router do
  use MenWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MenWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MenWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/webhooks", MenWeb.Webhooks do
    pipe_through :api

    post "/feishu", FeishuController, :create
  end

  # Other scopes may use custom stacks.
  # scope "/api", MenWeb do
  #   pipe_through :api
  # end

  # Enable Swoosh mailbox preview in development
  if Application.compile_env(:men, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
