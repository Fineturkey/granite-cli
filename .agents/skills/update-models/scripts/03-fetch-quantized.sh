#!/usr/bin/env bash
set -euo pipefail

# Cross-references models with quantized variants
# Input: models.json
# Output: Enriched models.json with variants array

MODELS_FILE="${1:-data/models.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HF_ORG="ibm-granite"
HF_API="https://huggingface.co/api"
MLX_ORG="mlx-community"

if [ ! -f "$MODELS_FILE" ]; then
    echo "Error: Models file not found: $MODELS_FILE" >&2
    exit 1
fi

# Check for JSON tool (jq or python)
if ! command -v jq &> /dev/null; then
    if ! command -v python3 &> /dev/null && ! command -v python &> /dev/null; then
        echo "Error: Neither jq nor Python is available. Please install one of them." >&2
        exit 1
    fi
fi

# Total size in GB of all .safetensors files in a repo (HF uses GB, not GiB).
# Prints 0 if the tree can't be read.
safetensors_tree_size_gb() {
    local repo="$1"
    $SCRIPT_DIR/utils/hf-curl.sh "${HF_API}/models/${repo}/tree/main" 2>/dev/null | \
        jq -r '([.[]? | select(.type == "file" and (.path | endswith(".safetensors"))) | .size // 0] | add // 0) / 1000000000 * 1000 | round / 1000' \
        2>/dev/null || echo "0"
}

find_mlx_variants() {
    local base_repo="$1"
    local bytes_to_gb="$((1000**3))"
    local base_name
    base_name=$(basename "$base_repo" | tr '[:upper:]' '[:lower:]')

    # mlx-community tags every conversion with a `base_model:<owner>/<repo>`
    # tag pointing back at the model it was converted from, so we can look
    # these up directly instead of guessing at their naming convention.
    local search_results
    search_results=$($SCRIPT_DIR/utils/hf-curl.sh "${HF_API}/models?filter=base_model:${base_repo}&author=${MLX_ORG}&limit=100" 2>/dev/null || echo "[]")

    echo "$search_results" | jq -c 'if type == "array" then [.[] | select(.private != true and .library_name == "mlx")] else [] end' 2>/dev/null | \
        jq -c '.[]' 2>/dev/null | while read -r repo_entry; do
        repo_id=$(echo "$repo_entry" | jq -r '.id')

        # The base_model tag is occasionally mis-set upstream (e.g. a repo
        # named after one Granite variant tagged as derived from another).
        # Guard against that by requiring the repo's own name to actually
        # start with the base model's name.
        candidate_name=$(basename "$repo_id" | tr '[:upper:]' '[:lower:]')
        candidate_name="${candidate_name#ibm-}"
        if [[ "$candidate_name" != "$base_name"* ]]; then
            echo "Skipping ${repo_id}: name doesn't match base model ${base_repo} (mistagged upstream?)" >&2
            continue
        fi

        # Quantized conversions carry a "<bits>-bit" tag (e.g. "4-bit");
        # full-precision conversions don't, since they aren't quantized.
        bit_tag=$(echo "$repo_entry" | jq -r '[.tags[]? | select(test("^[0-9]+-bit$"))][0] // empty')

        # Micro-scaled float formats (mxfp4/mxfp8/...) and NVIDIA's fp4/fp8
        # formats are also tagged with a plain "<bits>-bit" tag, since they
        # do use that many bits per element, but that loses the distinction
        # from plain integer quantization - so prefer the more specific
        # format name from the repo's own suffix when present.
        fp_format=$(echo "$repo_id" | grep -oiE '(mx|nv)fp[0-9]+$' 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)

        detail=$($SCRIPT_DIR/utils/hf-curl.sh "${HF_API}/models/${repo_id}" 2>/dev/null || echo "{}")
        sleep "${HF_REQUEST_DELAY:-0}"

        precision=""
        if [ -n "$fp_format" ]; then
            precision="$fp_format"
        elif [ -n "$bit_tag" ]; then
            precision="${bit_tag%-bit}bit"
        else
            # Fall back to the quantization config, then the dtype of the
            # (single, unquantized) safetensors weights.
            bits=$(echo "$detail" | jq -r '.config.quantization_config.bits // empty' 2>/dev/null || echo "")
            if [ -n "$bits" ]; then
                precision="${bits}bit"
            else
                dtype_key=$(echo "$detail" | jq -r '(.safetensors.parameters // {}) | keys[0] // empty' 2>/dev/null || echo "")
                case "$dtype_key" in
                    BF16) precision="bfloat16" ;;
                    F16 | FP16) precision="float16" ;;
                    F32) precision="float32" ;;
                    *) precision="" ;;
                esac
            fi
        fi

        if [ -z "$precision" ]; then
            echo "Skipping ${repo_id}: could not determine precision" >&2
            continue
        fi

        # Sum the actual .safetensors file sizes from the repo tree. We can't
        # derive this from `.safetensors.parameters`: for packed low-bit
        # quantizations HF reports the *unpacked* parameter count under the
        # packed container dtype (e.g. U32), so multiplying by dtype width
        # overstates the size several-fold. `.safetensors.total` is likewise a
        # parameter count, not bytes.
        size_gb=$(safetensors_tree_size_gb "$repo_id")

        jq -n \
            --arg precision "$precision" \
            --argjson size_gb "$size_gb" \
            --arg url "https://huggingface.co/${repo_id}" \
            '{format: "MLX", precision: $precision, size_gb: $size_gb, url: $url}'
    done | jq -s '.'
}

find_variants() {
    local model_info="$1"
    local base_repo=$(echo "$model_info" | jq -r .repo)
    local base_name=$(basename "$base_repo")
    local bytes_to_gb="$((1000**3))" # HF uses GB, not GiB
    local safetensors_dtype=$(echo "$model_info" | jq -r '.config.torch_dtype // .config.dtype // "bfloat16"') # Assume BF16 by default
    multiplier=1
    if [[ "$safetensors_dtype" == *"16"* ]]; then
        multiplier="2"
    elif [[ "$safetensors_dtype" == *"32"* ]]; then
        multiplier="4"
    elif [[ "$safetensors_dtype" == *"64"* ]]; then
        multiplier="8"
    elif [[ "$safetensors_dtype" == *"4"* ]]; then
        multiplier="0.5"
    fi
    # Prefer the real on-disk size; fall back to an estimate from the
    # parameter count if the tree can't be read. (Models like Granite Switch
    # carry extra non-BF16 tensors that the estimate misses.)
    local safetensors_size_gb
    safetensors_size_gb=$(safetensors_tree_size_gb "$base_repo")
    if [ "$safetensors_size_gb" = "0" ]; then
        safetensors_size_gb=$(echo "$model_info" | jq -r "((.size // 0) / $bytes_to_gb * $multiplier * 1000 | round/1000)")
    fi

    # Look for GGUF repo
    local gguf_repo="${base_repo}-GGUF"

    variants="[]"

    # Check if GGUF repo exists
    http_code=$($SCRIPT_DIR/utils/hf-curl.sh -o /dev/null -w "%{http_code}" "https://huggingface.co/${gguf_repo}")

    if [ "$http_code" = "200" ]; then
        # Fetch GGUF files
        gguf_files=$($SCRIPT_DIR/utils/hf-curl.sh "${HF_API}/models/${gguf_repo}/tree/main" 2>/dev/null | \
            jq -c '[.[] | select(.type == "file" and (.path | endswith(".gguf")))]' 2>/dev/null || echo "[]")

        # Process each GGUF file
        if [ "$gguf_files" != "[]" ]; then
            variants=$(echo "$gguf_files" | jq -c --argjson bytes_to_gb "$bytes_to_gb" --arg gguf_repo "$gguf_repo" '
                # Group by base filename to handle multi-file splits (e.g. bf16-00001-of-00005.gguf)
                group_by([.path | rtrimstr(".gguf") | sub("-[0-9]{5}-of-[0-9]{5}$"; "")]) |
                [.[] | {
                    format: "GGUF",
                    precision: (.[0].path | rtrimstr(".gguf") | sub("-[0-9]{5}-of-[0-9]{5}$"; "") | split("-") | last | ascii_upcase),
                    size_gb: ((([.[] | .size // 0] | add) / $bytes_to_gb) * 1000 | round / 1000),
                    url: ("https://huggingface.co/" + $gguf_repo + "/blob/main/" + .[0].path)
                }]
            ')
        fi
    fi

    # Add base model as safetensors variant
    base_variant=$(jq -n \
        --arg repo "https://huggingface.co/${base_repo}" \
        --arg safetensors_dtype "$safetensors_dtype" \
        --argjson safetensors_size_gb "$safetensors_size_gb" \
        '[{
            format: "safetensors",
            precision: $safetensors_dtype,
            size_gb: $safetensors_size_gb,
            url: $repo
        }]')

    # Look for MLX conversions published by the mlx-community org
    mlx_variants=$(find_mlx_variants "$base_repo")

    # Merge variants
    echo "$variants" | jq --argjson base "$base_variant" --argjson mlx "$mlx_variants" '. + $base + $mlx'
}

# Process each model
jq -c '.[]' "$MODELS_FILE" | while read -r model; do
    repo=$(echo "$model" | jq -r '.repo')

    echo "Finding variants for: $repo" >&2

    variants=$(find_variants "$model")

    # Add variants to model
    echo "$model" | jq --argjson variants "$variants" '. + {variants: $variants}'
done | jq -s '.'