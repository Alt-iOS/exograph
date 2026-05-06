defmodule Exograph.AST.Terms do
  @moduledoc false

  @spec from_source(Macro.t()) :: MapSet.t(String.t())
  defdelegate from_source(ast), to: ExAST.Index.Terms, as: :from_ast

  @spec from_pattern(ExAST.Pattern.pattern() | [ExAST.Pattern.pattern()]) :: MapSet.t(String.t())
  defdelegate from_pattern(pattern), to: ExAST.Index.Terms

  @spec high_signal?(String.t()) :: boolean()
  defdelegate high_signal?(term), to: ExAST.Index.Terms
end
