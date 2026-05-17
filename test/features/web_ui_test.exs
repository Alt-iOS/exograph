defmodule Exograph.Features.WebUITest do
  use Exograph.FeatureCase

  @moduletag :feature

  defp wait_for_monaco(conn) do
    conn
    |> visit("/")
    |> assert_has("body .phx-connected")
    |> evaluate(
      "() => new Promise(r => { const c = () => document.querySelector('#editor')?._monacoEditor ? r(true) : setTimeout(c, 100); c(); })",
      is_function: true
    )
  end

  defp set_editor(conn, value) do
    escaped = String.replace(value, "'", "\\'")

    evaluate(
      conn,
      "() => { document.querySelector('#editor')._monacoEditor.setValue('#{escaped}'); }",
      is_function: true
    )
  end

  defp get_editor(conn, assert_fn) do
    evaluate(
      conn,
      "() => document.querySelector('#editor')._monacoEditor.getValue()",
      [is_function: true],
      fn value -> assert_fn.(value) end
    )
  end

  test "shows editor and example cards on load", %{conn: conn} do
    conn
    |> visit("/")
    |> assert_has("button", text: "Run")
    |> assert_has("button", text: "Format")
    |> assert_has("button", text: "Pattern search")
    |> assert_has("button", text: "GenServer callbacks")
  end

  test "clicking example populates editor", %{conn: conn} do
    conn
    |> wait_for_monaco()
    |> click_button("Pattern search")
    |> evaluate("() => new Promise(r => setTimeout(r, 300))", is_function: true)
    |> get_editor(fn value -> assert value =~ "Repo.get!" end)
  end

  test "format button reformats query", %{conn: conn} do
    conn
    |> wait_for_monaco()
    |> set_editor(
      ~s|from(f in Fragment, join: r in assoc(f, :references), where: r.qualified_name == "Enum.map/2", where: f.kind == :def, limit: 20)|
    )
    |> click_button("Format")
    |> evaluate("() => new Promise(r => setTimeout(r, 300))", is_function: true)
    |> get_editor(fn value -> assert value =~ "\n" end)
  end

  test "error shows diagnostics", %{conn: conn} do
    conn
    |> wait_for_monaco()
    |> set_editor("from(f in Fragment")
    |> click_button("Run")
    |> assert_has("div", text: "missing terminator")
  end

  test "rejects dangerous code", %{conn: conn} do
    conn
    |> wait_for_monaco()
    |> set_editor(~s|System.cmd("ls", [])|)
    |> click_button("Run")
    |> assert_has("div", text: "Expected from")
  end

  test "text search mode works", %{conn: conn} do
    conn
    |> wait_for_monaco()
    |> click("button[phx-value-mode='text']")
    |> set_editor("GenServer")
    |> click_button("Run")
    |> assert_has("span", text: "results")
  end

  test "structural/text toggle switches modes", %{conn: conn} do
    conn
    |> visit("/")
    |> assert_has("button", text: "Structural")
    |> assert_has("button", text: "Text")
  end

  test "file paths are links to hex.pm", %{conn: conn} do
    conn
    |> wait_for_monaco()
    |> click_button("GenServer callbacks")
    |> evaluate("() => new Promise(r => setTimeout(r, 300))", is_function: true)
    |> click_button("Run")
    |> assert_has("a[href*='hex.pm']")
  end

  test "arrow keys work in editor after running a query", %{conn: conn} do
    conn
    |> wait_for_monaco()
    |> set_editor(~s|from(f in Fragment, where: matches(f, "def _ do ... end"), limit: 5)|)
    |> click_button("Run")
    |> assert_has("span", text: "results")
    |> evaluate(
      """
      () => {
        const ed = document.querySelector('#editor')._monacoEditor;
        const ta = document.querySelector('#editor textarea.inputarea');
        ta.focus();
        ed.setPosition({ lineNumber: 1, column: 5 });

        return new Promise(resolve => {
          setTimeout(() => {
            const before = ed.getPosition().column;

            // Dispatch trusted-equivalent keydown events the way Monaco expects
            ta.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39, bubbles: true, cancelable: true }));
            ta.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39, bubbles: true, cancelable: true }));
            ta.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39, bubbles: true, cancelable: true }));

            // Monaco also needs to process via its trigger API as synthetic events aren't trusted
            ed.trigger('keyboard', 'cursorRight', null);
            ed.trigger('keyboard', 'cursorRight', null);
            ed.trigger('keyboard', 'cursorRight', null);

            setTimeout(() => {
              resolve({ before, after: ed.getPosition().column });
            }, 100);
          }, 100);
        });
      }
      """,
      [is_function: true],
      fn result ->
        assert result["after"] == 8,
               "Arrow keys broken after Run: cursor at #{result["after"]}, expected 8 (was #{result["before"]})"
      end
    )
  end

  test "typing in editor works after running a query", %{conn: conn} do
    conn
    |> wait_for_monaco()
    |> set_editor("hello")
    |> click_button("Run")
    |> click("#editor")
    |> evaluate(
      """
      () => {
        const ed = document.querySelector('#editor')._monacoEditor;
        ed.focus();
        ed.setPosition({ lineNumber: 1, column: 6 });
        return true;
      }
      """,
      is_function: true
    )
    |> type("#editor textarea.inputarea", " world")
    |> evaluate("() => new Promise(r => setTimeout(r, 100))", is_function: true)
    |> get_editor(fn value -> assert value =~ "world" end)
  end
end
