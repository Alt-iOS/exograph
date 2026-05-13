import Config

config :volt,
  entry: "assets/web/app.ts",
  root: "assets",
  outdir: "priv/static/assets",
  target: :es2020,
  resolve_dirs: ["deps"],
  tailwind: [
    css: "assets/web/app.css",
    sources: [
      %{base: "lib/", pattern: "**/*.{ex,heex}"},
      %{base: "assets/", pattern: "**/*.{ts,css}"}
    ]
  ]

config :volt, :server,
  prefix: "/assets",
  watch_dirs: ["lib/", "assets/"]

config :phoenix, :json_library, Jason
