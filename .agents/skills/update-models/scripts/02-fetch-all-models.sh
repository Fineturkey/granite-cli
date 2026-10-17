#!/usr/bin/env bash
set -euo pipefail

# Fetches model metadata for all models in collections
# Input: collections.json
# Output: JSON array of model metadata objects

COLLECTIONS_FILE="${1:-data/collections.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HF_API="https://huggingface.co/api"

if [ ! -f "$COLLECTIONS_FILE" ]; then
    echo "Error: Collections file not found: $COLLECTIONS_FILE" >&2
    exit 1
fi

# Check for JSON tool (jq or python)
if ! command -v jq &> /dev/null; then
    if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
        echo "Error: Neither jq nor Python is available. Please install one of them." >&2
        echo "  macOS: brew install jq" >&2
        echo "  Linux: apt-get install jq" >&2
        exit 1
    fi
fi

# Request delay to avoid rate limiting
REQUEST_DELAY="${HF_REQUEST_DELAY:-1}"

# Derives the generic `architecture` block (layer shape + per-layer-kind
# counts) from a model's raw config.json. Encodes the config-schema-specific
# knowledge (layer_types vocabularies, mamba field names, dtype field-name
# drift) here so the Rust side only ever sees the generic LayerKind shape.
extract_architecture() {
    local repo="$1"
    local config="$2"

    # Vision-language models nest the actual language-backbone shape under
    # text_config instead of the top level. Fall back to it whenever it's
    # present so VLMs get a real (non-degenerate) architecture too.
    local config
    config=$(echo "$config" | jq -c 'if .text_config then .text_config else . end')

    local num_hidden_layers hidden_size num_attention_heads num_key_value_heads head_dim
    num_hidden_layers=$(echo "$config" | jq -r '.num_hidden_layers // 0')
    hidden_size=$(echo "$config" | jq -r '.hidden_size // 0')
    num_attention_heads=$(echo "$config" | jq -r '.num_attention_heads // 0')
    num_key_value_heads=$(echo "$config" | jq -r '.num_key_value_heads // .num_attention_heads // 0')
    head_dim=$(echo "$config" | jq -r '
        if .head_dim then .head_dim
        elif (.num_attention_heads // 0) > 0 then ((.hidden_size / .num_attention_heads) | floor)
        else 0
        end')

    # Mamba d_inner: prefer n_heads*d_head, fall back to expand*hidden_size,
    # and warn (not fail) if both are present but disagree.
    local mamba_n_heads mamba_d_head mamba_expand
    mamba_n_heads=$(echo "$config" | jq -r '.mamba_n_heads // empty')
    mamba_d_head=$(echo "$config" | jq -r '.mamba_d_head // empty')
    mamba_expand=$(echo "$config" | jq -r '.mamba_expand // empty')

    local d_inner_from_heads="" d_inner_from_expand="" d_inner=""
    if [ -n "$mamba_n_heads" ] && [ -n "$mamba_d_head" ]; then
        d_inner_from_heads=$((mamba_n_heads * mamba_d_head))
    fi
    if [ -n "$mamba_expand" ] && [ "$hidden_size" != "0" ]; then
        d_inner_from_expand=$((mamba_expand * hidden_size))
    fi
    if [ -n "$d_inner_from_heads" ]; then
        d_inner="$d_inner_from_heads"
    else
        d_inner="$d_inner_from_expand"
    fi
    if [ -n "$d_inner_from_heads" ] && [ -n "$d_inner_from_expand" ] && [ "$d_inner_from_heads" != "$d_inner_from_expand" ]; then
        echo "  WARNING: $repo: mamba d_inner mismatch (n_heads*d_head=$d_inner_from_heads vs expand*hidden_size=$d_inner_from_expand)" >&2
    fi

    local mamba_d_conv mamba_d_state mamba_n_groups sliding_window
    mamba_d_conv=$(echo "$config" | jq -r '.mamba_d_conv // empty')
    mamba_d_state=$(echo "$config" | jq -r '.mamba_d_state // empty')
    mamba_n_groups=$(echo "$config" | jq -r '.mamba_n_groups // empty')
    sliding_window=$(echo "$config" | jq -r '.sliding_window // empty')

    # Group the raw layer_types list (if present) into per-kind counts. Two
    # vocabularies are known in the wild: "mamba"/"attention" (hybrid models)
    # and "full_attention"/"sliding_attention" (SWA models). Absent
    # layer_types means a plain dense model -- one full_attention entry
    # covering every layer.
    local layer_types_raw
    layer_types_raw=$(echo "$config" | jq -c '.layer_types // null')

    local layer_types_json
    if [ "$layer_types_raw" == "null" ]; then
        layer_types_json=$(jq -n --argjson count "$num_hidden_layers" '[{kind: "full_attention", count: $count}]')
    else
        layer_types_json=$(echo "$layer_types_raw" | jq -c '
            map(
                if . == "mamba" then "recurrent"
                elif . == "sliding_attention" then "sliding_attention"
                else "full_attention"
                end
            )
            | group_by(.)
            | map({kind: .[0], count: length})
        ')
        layer_types_json=$(echo "$layer_types_json" | jq -c \
            --argjson window "${sliding_window:-null}" \
            --argjson d_conv "${mamba_d_conv:-null}" \
            --argjson d_state "${mamba_d_state:-null}" \
            --argjson d_inner "${d_inner:-null}" \
            --argjson n_groups "${mamba_n_groups:-null}" \
            'map(
                if .kind == "sliding_attention" then . + {window: $window}
                elif .kind == "recurrent" then . + {mamba: {d_conv: $d_conv, d_state: $d_state, d_inner: $d_inner, n_groups: $n_groups}}
                else .
                end
            )')
    fi

    jq -n \
        --argjson num_hidden_layers "$num_hidden_layers" \
        --argjson hidden_size "$hidden_size" \
        --argjson num_attention_heads "$num_attention_heads" \
        --argjson num_key_value_heads "$num_key_value_heads" \
        --argjson head_dim "$head_dim" \
        --argjson layer_types "$layer_types_json" \
        '{
            num_hidden_layers: $num_hidden_layers,
            hidden_size: $hidden_size,
            num_attention_heads: $num_attention_heads,
            num_key_value_heads: $num_key_value_heads,
            head_dim: $head_dim,
            layer_types: $layer_types
        }'
}

# Detects tool-calling/thinking support by looking for the specific Jinja
# if/elif gate each capability uses, not a bare substring (which also
# matches unrelated usages, e.g. Guardian's tools-role check).
detect_chat_template_signals() {
    local template="$1"

    local supports_tool_calling=false
    if echo "$template" | grep -qE '\{%-?\s*(if|elif)\s+tools\b'; then
        supports_tool_calling=true
    fi

    local supports_thinking=false
    if echo "$template" | grep -qE '\{%-?\s*(if|elif)\s+thinking\b' \
        || echo "$template" | grep -q 'enable_thinking' \
        || echo "$template" | grep -q 'reasoning_content' \
        || echo "$template" | grep -qF '<think>'; then
        supports_thinking=true
    fi

    jq -n --argjson tools "$supports_tool_calling" --argjson thinking "$supports_thinking" \
        '{supports_tool_calling: $tools, supports_thinking: $thinking}'
}

# Returns success if `repo` is a quantized/converted derivative of another
# model (GGUF, fp8, nvfp4, mxfp4, <quant>-mlx, ...) rather than a catalog
# model in its own right. These repos are also members of the core model
# collections, but are attached to their parent as variants by
# 03-fetch-quantized.sh. HF marks them with a `base_model:quantized:<parent>`
# tag; the name-suffix check is a fallback for repos missing that tag.
is_derived_model() {
    local repo="$1"
    local tags
    tags=$("$SCRIPT_DIR/utils/hf-curl.sh" "${HF_API}/models/${repo}" 2>/dev/null \
        | jq -c '.tags // []' 2>/dev/null || echo "[]")
    if echo "$tags" | jq -e 'any(.[]; startswith("base_model:quantized:"))' >/dev/null 2>&1; then
        return 0
    fi
    local lower
    lower=$(basename "$repo" | tr '[:upper:]' '[:lower:]')
    [[ "$lower" =~ (-gguf|-fp8|-nvfp4|-mxfp4|-mlx)$ ]]
}

map_family() {
    local family="$1"
    if [[ "$family" =~ [0-9] ]]; then
        echo "Granite Language"
    else
        echo "$family"
    fi
}

fetch_model_metadata() {
    local repo="$1"
    local family
    family=$(map_family "$2")
    local version="$3"

    # If version is not set from the collection, parse from the model name
    if [ "$version" == "" ]; then
        if [[ "$repo" =~ [a-z\-]+-([0-9\.]+)-.* ]]; then
            version="${BASH_REMATCH[1]}"
        # Handle embedding model versioning
        elif [[ "$repo" =~ .*-(r[0-9\.]+).* ]]; then
            version="${BASH_REMATCH[1]}"
        fi
    fi

    # Fetch config.json if available
    config_url="https://huggingface.co/${repo}/raw/main/config.json"
    config=$($SCRIPT_DIR/utils/hf-curl.sh "$config_url")
    if [ "$config" == "Entry not found" ]; then
        echo "No config.json found" >&2
        config="{}"
    fi

    # Extract fields
    local size=0
    local context_length=8192
    local model_type="Text"
    local description=""
    local native_dtype="unknown"
    local architecture="null"

    if [ "$config" != "{}" ]; then
        context_length=$(echo "$config" | jq -r '.max_position_embeddings // .n_positions // 8192')
        native_dtype=$(echo "$config" | jq -r '.torch_dtype // .dtype // "unknown"')
        architecture=$(extract_architecture "$repo" "$config")
    fi

    # Get the model metadata to fetch the size
    md_url="https://huggingface.co/api/models/${repo}"
    md_size=$($SCRIPT_DIR/utils/hf-curl.sh "$md_url" | jq .safetensors.total)
    if [ "$md_size" != "null" ]; then
        size=$md_size
    fi

    # Get the model description from the README if available
    readme_url="https://huggingface.co/$repo/raw/main/README.md"
    readme=$($SCRIPT_DIR/utils/hf-curl.sh $readme_url)
    description=$(echo -e "$readme" | awk '/\*\*Model Summary:\*\*/ {found=1; sub(/.*\*\*Model Summary:\*\*[[:space:]]*/, ""); if ($0 != "") {seen=1; print}; next} /## Model Summary/ {found=1; next} found && seen && /^$/ {exit} found && /^$/ {next} found && NF > 0 {seen=1; print}')

    # Detect ToolCalling/Thinking support from the model's chat template
    chat_template=$("${SCRIPT_DIR}/utils/fetch-chat-template.sh" "$repo")
    capabilities=$(detect_chat_template_signals "$chat_template")
    supports_tool_calling=$(echo "$capabilities" | jq -r '.supports_tool_calling')
    supports_thinking=$(echo "$capabilities" | jq -r '.supports_thinking')

    # Infer model type from family
    if [[ "$family" == *"Vision"* ]] || [[ "$family" == *"Docling"* ]]; then
        model_type="Vision"
    elif [[ "$family" == *"Speech"* ]]; then
        model_type="Speech"
    elif [[ "$family" == *"Embedding"* ]]; then
        model_type="Embedding"
    fi

    # Output JSON
    jq -n \
        --arg repo "$repo" \
        --arg family "$family" \
        --arg version "$version" \
        --argjson size "$size" \
        --argjson context_length "$context_length" \
        --arg model_type "$model_type" \
        --arg description "$description" \
        --arg native_dtype "$native_dtype" \
        --argjson architecture "$architecture" \
        --argjson config "$config" \
        --argjson supports_tool_calling "$supports_tool_calling" \
        --argjson supports_thinking "$supports_thinking" \
        '{
            repo: $repo,
            family: $family,
            version: $version,
            size: $size,
            context_length: $context_length,
            model_type: $model_type,
            description: $description,
            native_dtype: $native_dtype,
            architecture: $architecture,
            config: $config,
            supports_tool_calling: $supports_tool_calling,
            supports_thinking: $supports_thinking
        }'

    sleep "$REQUEST_DELAY"
}

echo "["
first=true

# Repos already emitted. A repo can belong to multiple collections (e.g.
# granite-switch-4.1-30b is in both "Granite Switch" and "Granite Speech"),
# but must only appear once, under a single family. (Newline-delimited string
# rather than an associative array to stay compatible with macOS bash 3.2.)
seen_repos=$'\n'

# Process each collection. "Granite Switch" is sorted first (sort_by is
# stable) so that Switch models, which can also be listed in more specific
# collections like Speech, are always attributed to the Switch family.
jq -c 'sort_by(.name != "Granite Switch") | .[]' "$COLLECTIONS_FILE" | while read -r collection; do
    name=$(echo "$collection" | jq -r '.name')
    slug=$(echo "$collection" | jq -r '.slug')
    category=$(echo "$collection" | jq -r '.category')
    version=$(echo "$collection" | jq -r '.version')

    # Skip quantized collection (processed separately)
    if [ "$category" = "quantized" ]; then
        continue
    fi

    echo "Processing collection: $name" >&2

    # Fetch models in collection. Keep each item's `private` flag alongside
    # its id so private repos (visible here only because HF_TOKEN has org
    # access) can be skipped below by default.
    collection_api="${HF_API}/collections/${slug}"
    models=$($SCRIPT_DIR/utils/hf-curl.sh "$collection_api" 2>/dev/null | jq -c '.items[] | select(.type == "model") | {id, private: (.private // false)}' || echo "")

    # Process each model
    while IFS= read -r item; do
        if [ -z "$item" ]; then
            continue
        fi
        repo=$(echo "$item" | jq -r '.id')
        private=$(echo "$item" | jq -r '.private')

        if [ -z "$repo" ]; then
            continue
        fi
        if [[ "$repo" =~ .*-base ]]; then
            echo "  Skipping base model: $repo" >&2
            continue
        fi
        if [[ "$repo" =~ .*-lora-.* ]]; then
            echo "  Skipping lora adapter: $repo" >&2
            continue
        fi
        if [[ "$seen_repos" == *$'\n'"$repo"$'\n'* ]]; then
            echo "  Skipping duplicate (already in an earlier collection): $repo" >&2
            continue
        fi
        if is_derived_model "$repo"; then
            echo "  Skipping derived (quantized) model: $repo" >&2
            continue
        fi
        if [ "$private" = "true" ] && [ "${HF_INCLUDE_PRIVATE:-false}" != "true" ]; then
            echo "  Skipping private model: $repo (set HF_INCLUDE_PRIVATE=true to include)" >&2
            continue
        fi

        seen_repos+="${repo}"$'\n'
        echo "  Fetching: $repo" >&2

        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi

        fetch_model_metadata "$repo" "$name" "$version"
    done <<< "$models"
done

echo "]"