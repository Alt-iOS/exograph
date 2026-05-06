defmodule Exograph.InvertedIndex.TantivyEx do
  @moduledoc """
  TantivyEx-backed inverted index.

  This backend indexes code-search fields and returns fragment ids for exact
  verification through the fragment store.
  """

  @behaviour Exograph.InvertedIndex

  alias Exograph.{Fragment, Hit, Query}

  defstruct [:schema, :index, :searcher, :path]

  @type t :: %__MODULE__{
          schema: TantivyEx.Schema.t(),
          index: TantivyEx.Index.t(),
          searcher: TantivyEx.Searcher.t() | nil,
          path: String.t() | nil
        }

  @impl true
  def new(opts \\ []) do
    with :ok <- ensure_tantivy_ex(),
         :ok <- register_tokenizers(),
         schema <- schema(),
         {:ok, index} <- open_index(schema, opts),
         {:ok, searcher} <- TantivyEx.Searcher.new(index) do
      {:ok, %__MODULE__{schema: schema, index: index, searcher: searcher, path: opts[:path]}}
    end
  end

  @impl true
  def add(%__MODULE__{} = backend, fragments) when is_list(fragments) do
    with {:ok, writer} <- TantivyEx.IndexWriter.new(backend.index, 50_000_000),
         :ok <- add_all(writer, fragments),
         :ok <- TantivyEx.IndexWriter.commit(writer),
         {:ok, searcher} <- TantivyEx.Searcher.new(backend.index) do
      {:ok, %{backend | searcher: searcher}}
    end
  end

  @impl true
  def search(%__MODULE__{} = backend, %Query{} = query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    with {:ok, tantivy_query} <- tantivy_query(backend.schema, query),
         {:ok, results} <- TantivyEx.Searcher.search(backend.searcher, tantivy_query, limit, true) do
      {:ok, Enum.map(results, &to_hit/1)}
    end
  end

  defp ensure_tantivy_ex do
    if Code.ensure_loaded?(TantivyEx.Index), do: :ok, else: {:error, :tantivy_ex_not_available}
  end

  defp register_tokenizers do
    TantivyEx.Tokenizer.register_default_tokenizers()
    :ok
  rescue
    error -> {:error, error}
  end

  defp schema do
    TantivyEx.Schema.new()
    |> TantivyEx.Schema.add_text_field_with_tokenizer("fragment_id", :text_stored, "raw")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("file", :text_stored, "raw")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("kind", :text_stored, "raw")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("name", :text_stored, "raw")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("full", :text, "default")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("path_text", :text, "whitespace")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("terms", :text, "whitespace")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("subhashes", :text, "whitespace")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("defs", :text, "whitespace")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("refs", :text, "whitespace")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("modules", :text, "whitespace")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("functions", :text, "whitespace")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("aliases", :text, "whitespace")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("structs", :text, "whitespace")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("atoms", :text, "whitespace")
    |> TantivyEx.Schema.add_text_field_with_tokenizer("trigrams", :text, "whitespace")
    |> TantivyEx.Schema.add_u64_field("arity", :fast_stored)
    |> TantivyEx.Schema.add_u64_field("line", :fast_stored)
    |> TantivyEx.Schema.add_u64_field("mass", :fast_stored)
  end

  defp open_index(schema, opts) do
    case Keyword.get(opts, :path) do
      nil -> TantivyEx.Index.create_in_ram(schema)
      path -> TantivyEx.Index.open_or_create(path, schema)
    end
  end

  defp add_all(writer, fragments) do
    documents = Enum.map(fragments, &document/1)

    case TantivyEx.Document.add_batch(writer, documents, schema(),
           validate: false,
           batch_size: 1000
         ) do
      {:ok, _results} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp document(%Fragment{} = fragment) do
    %{
      "fragment_id" => to_string(fragment.id),
      "file" => fragment.file,
      "kind" => Atom.to_string(fragment.kind),
      "name" => fragment.name || "",
      "full" => fragment.source || "",
      "path_text" => path_terms(fragment.file),
      "terms" => join_encoded_terms(fragment.terms),
      "subhashes" => fragment.sub_hashes |> Enum.map(&"subhash:#{&1}") |> join_encoded_terms(),
      "defs" => join_encoded_terms(fragment.defs),
      "refs" => join_encoded_terms(fragment.refs),
      "modules" => join_encoded_terms(fragment.modules),
      "functions" => join_encoded_terms(fragment.functions),
      "aliases" => join_encoded_terms(fragment.aliases),
      "structs" => join_encoded_terms(fragment.structs),
      "atoms" => join_encoded_terms(fragment.atoms),
      "trigrams" =>
        fragment.source |> Kernel.||("") |> Exograph.Text.trigrams() |> join_encoded_terms(),
      "arity" => fragment.arity || 0,
      "line" => fragment.line || 0,
      "mass" => fragment.mass || 0
    }
  end

  defp path_terms(path) do
    path
    |> String.split(["/", "_", "-", "."], trim: true)
    |> Enum.join(" ")
  end

  defp join_encoded_terms(terms), do: Enum.map_join(terms, " ", &encode_term/1)

  defp encode_term(term) do
    hash = :crypto.hash(:sha256, to_string(term)) |> Base.encode16(case: :lower)
    "h" <> hash
  end

  defp tantivy_query(schema, %Query{required_terms: required}) do
    if MapSet.size(required) == 0 do
      TantivyEx.Query.all()
    else
      with {:ok, queries} <- collect_queries(required, schema) do
        TantivyEx.Query.boolean(queries, [], [])
      end
    end
  end

  defp collect_queries(terms, schema) do
    Enum.reduce_while(terms, {:ok, []}, fn term, {:ok, queries} ->
      case TantivyEx.Query.term(schema, "terms", encode_term(term)) do
        {:ok, query} -> {:cont, {:ok, [query | queries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, queries} -> {:ok, Enum.reverse(queries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_hit(result) do
    normalized_result = normalize_keys(result)
    document = Map.get(normalized_result, :document) || result
    fragment_id = field(document, :fragment_id)

    Hit.new(fragment_id: fragment_id, score: Map.get(normalized_result, :score, 0.0))
  end

  defp field(document, key) when is_map(document) do
    document
    |> normalize_keys()
    |> Map.get(key)
    |> unwrap_field()
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      entry -> entry
    end)
  end

  defp unwrap_field([value | _]), do: value
  defp unwrap_field(value), do: value
end
