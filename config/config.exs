# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :signal_garden,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :signal_garden, SignalGardenWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SignalGardenWeb.ErrorHTML, json: SignalGardenWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SignalGarden.PubSub,
  live_view: [signing_salt: "Lz61rWhf"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Signal Garden simulation defaults. The Engine reads these on boot and
# whenever a scenario is reset, but the LiveView can override them at runtime.
config :signal_garden, :sim,
  frame_ms: 60,
  burst: 6,
  log_size: 80

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  signal_garden: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  signal_garden: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Colocated asset symlinks need admin rights on Windows. The garden uses
# an external hook instead, so silence the harmless warning.
config :phoenix_live_view, :colocated_assets, disable_symlink_warning: true

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
