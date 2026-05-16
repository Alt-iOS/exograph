# Web UI

Exograph includes an embedded web interface powered by Phoenix LiveView and Monaco Editor.

## Starting

    mix exograph.web --prefix exograph --port 4200

Options:
- `--repo` — Ecto repo module (uses built-in if omitted)
- `--prefix` — table prefix (default: `exograph`)
- `--port` — HTTP port (default: `4200`)
- `--database-url` — Postgres URL (or set `EXOGRAPH_DATABASE_URL`)

## Search Modes

**Structural** (default) — ExAST pattern matching:

    from(f in Fragment,
      where: matches(f, "def handle_call(_, _, _) do ... end"),
      limit: 20
    )

**Text** — full-text search in source code:

    TODO
    deprecated
    GenServer

Toggle between modes with the Structural/Text buttons in the header.

## Editor Features

- Elixir syntax highlighting (Monaco built-in)
- Autocompletion for DSL macros (`from`, `matches`, `contains`), sources (`Fragment`, `Definition`), and field access
- Auto-closing brackets and quotes
- Format button (Cmd+Enter to run, Format button to reformat)
- Error diagnostics with red underlines on the error line

## Results

Results are grouped by package, then by file:
- Package headers link to hex.pm and are collapsible
- File paths link to hex.pm package version
- Code previews show syntax-highlighted context around the match
- "Load more" button for pagination

## Dependencies

The web UI requires optional dependencies:

    {:phoenix, "~> 1.8"},
    {:phoenix_html, "~> 4.1"},
    {:phoenix_live_view, "~> 1.1"},
    {:volt, "~> 0.11.1"},
    {:bandit, "~> 1.5"},
    {:makeup, "~> 1.0"},
    {:makeup_elixir, "~> 1.0"},
    {:phoenix_iconify, "~> 0.1"}
