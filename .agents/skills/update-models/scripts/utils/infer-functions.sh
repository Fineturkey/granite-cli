#!/usr/bin/env bash
set -euo pipefail

# Infers supported model functions from model metadata
# Input: model JSON (via stdin)
# Output: JSON array of function names

model=$(cat)

# Check model type
model_type=$(echo "$model" | jq -r '.model_type')
family=$(echo "$model" | jq -r '.family // ""')

# Build functions array
functions=()

# Granite Guardian models reuse their upstream model's chat template purely
# to format the transcript being judged, so template-derived signals (tool /
# thinking gates) are inherited artifacts, not real capabilities -- and
# Guardian models can't hold a standard back-and-forth chat either. Guardian
# is their only function, regardless of model_type or chat-template signals.
if [ "$family" = "Granite Guardian" ]; then
    functions+=("Guardian")
else
    # Chat is the base function for most models
    if [ "$model_type" != "Embedding" ]; then
        functions+=("Chat")
    fi

    # Embedding models provide Embeddings function
    if [ "$model_type" = "Embedding" ]; then
        functions+=("Embeddings")
    fi

    # Speech models provide Chat and Transcription
    if [ "$model_type" = "Speech" ]; then
        functions+=("Transcription")
    fi

    # Vision models provide Chat and ImageUnderstanding
    if [ "$model_type" = "Vision" ]; then
        functions+=("ImageUnderstanding")
    fi

    # ToolCalling/Thinking are detected from the model's chat template
    # (see detect_chat_template_signals in 02-fetch-all-models.sh)
    supports_tool_calling=$(echo "$model" | jq -r '.supports_tool_calling // false')
    supports_thinking=$(echo "$model" | jq -r '.supports_thinking // false')

    if [ "$supports_tool_calling" = "true" ]; then
        functions+=("ToolCalling")
    fi

    if [ "$supports_thinking" = "true" ]; then
        functions+=("Thinking")
    fi

    # Granite Switch models bundle named adapters (config.json
    # `adapter_names`). The names are free-form strings, not an enum, so
    # match them heuristically (case-insensitive substring). Not every
    # Switch model ships these adapters, so each function is opt-in.
    #   *decision*  -> Decision  (e.g. "decision")
    #   *guardian*  -> Guardian  (e.g. "guardian-core")
    adapter_names=$(echo "$model" | jq -r '(.config.adapter_names // []) | map(ascii_downcase) | .[]')
    if echo "$adapter_names" | grep -q 'decision'; then
        functions+=("Decision")
    fi
    if echo "$adapter_names" | grep -q 'guardian'; then
        functions+=("Guardian")
    fi
fi

# Output as JSON array
printf '%s\n' "${functions[@]}" | jq -R . | jq -s .
