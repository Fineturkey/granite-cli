#!/usr/bin/env python3
"""Interactive model-by-model reviewer for models.yaml.

Display: field: value [edit Y/N?]
  Y = edit, N/Enter = accept, q = quit
"""
import sys
import os
import re

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def load_yaml(path):
    with open(path, 'r') as f:
        return yaml.safe_load(f)


def dump_yaml(data, path):
    with open(path, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)


def display_value(val):
    if val is None:
        return "(empty)"
    return str(val)


def parse_int(s):
    try:
        return int(s)
    except (ValueError, TypeError):
        return None


def parse_float(s):
    try:
        return float(s)
    except (ValueError, TypeError):
        return None


def prompt_edit(label, current_value, field_type="string"):
    """Ask user for a new value. Type-coerced based on field_type."""
    print(f"  New {label}: ", end="", flush=True)
    try:
        raw = input().strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return None, "quit"

    if raw == 'q':
        return None, "quit"

    # Empty = keep current
    if raw == '':
        return current_value, "accept"

    # Type coercion
    if field_type == "int":
        val = parse_int(raw)
        if val is None:
            print(f"  Warning: could not parse as int, keeping current: {current_value}")
            return current_value, "accept"
        return val, "edit"

    if field_type == "float":
        val = parse_float(raw)
        if val is None:
            print(f"  Warning: could not parse as float, keeping current: {current_value}")
            return current_value, "accept"
        return val, "edit"

    # String
    return raw, "edit"


def parse_list(s):
    """Parse comma-separated string into list."""
    return [x.strip() for x in s.split(',') if x.strip()]


def parse_variant(s):
    """Parse a variant line like: format=GGUF precision=Q4_K_M size_gb=1.5 url=https://..."""
    variant = {}
    for match in re.finditer(r'(\w+)=(.+)', s):
        key, val = match.group(1), match.group(2).strip()
        if key == 'size_gb':
            try:
                val = float(val)
            except ValueError:
                pass
        variant[key] = val
    return variant


# Valid model functions for validation
VALID_FUNCTIONS = {
    "Chat", "ToolCalling", "Thinking", "ImageUnderstanding", "Guardian", "Decision",
    "Embeddings", "Transcription", "Translation", "SpeakerAttribution", "KeywordBiasing"
}


def review_model(model, model_index, total):
    """Review a single model entry field by field."""
    print(f"\n{'─' * 60}")
    print(f"  Model {model_index}/{total}: {model.get('id', 'UNKNOWN')}")
    print(f"{'─' * 60}")

    # Define fields with their types and display names
    simple_fields = [
        ('family', str, 'family'),
        ('version', str, 'version'),
        ('size', int, 'size'),
        ('context_length', int, 'context_length'),
        ('model_type', str, 'model type'),
        ('huggingface_repo', str, 'huggingface_repo'),
    ]

    for field, ftype, label in simple_fields:
        value = model.get(field)
        display = display_value(value)
        print(f"  {label}: {display} [edit Y/N?] ", end="", flush=True)
        try:
            choice = input().strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            return False

        if choice == 'q':
            return False

        if choice == 'y':
            new_val, action = prompt_edit(label, value, ftype.__name__)
            if action == "quit":
                return False
            if action == "edit":
                model[field] = new_val
            # if "accept" we keep current

    # supported_functions
    functions = model.get('supported_functions', [])
    print(f"\n  supported_functions: {functions} [edit Y/N?] ", end="", flush=True)
    try:
        choice = input().strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False

    if choice == 'q':
        return False

    if choice == 'y':
        print(f"  Enter comma-separated functions (or 'q' to quit): ")
        print(f"  Valid: {', '.join(sorted(VALID_FUNCTIONS))}")
        try:
            raw = input().strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return False

        if raw == 'q':
            return False

        if raw == '':
            pass  # keep current
        else:
            raw_funcs = parse_list(raw)
            # Validate functions
            invalid = [f for f in raw_funcs if f not in VALID_FUNCTIONS]
            if invalid:
                print(f"  Warning: unknown functions: {', '.join(invalid)}. Keeping current.")
            else:
                model['supported_functions'] = raw_funcs

    # variants
    variants = model.get('variants', [])
    vlist = []
    for v in variants:
        parts = []
        if isinstance(v, dict):
            if v.get('format'): parts.append(f"format={v['format']}")
            if v.get('precision'): parts.append(f"precision={v['precision']}")
            if v.get('size_gb') is not None: parts.append(f"size_gb={v['size_gb']}")
            parts.append(f"url={v.get('url', '')}")
        vlist.append(' '.join(parts))

    print(f"\n  variants: [{len(variants)} entries] [edit Y/N?] ", end="", flush=True)
    try:
        choice = input().strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False

    if choice == 'q':
        return False

    if choice == 'y':
        print("  Current variants:")
        for i, v in enumerate(vlist, 1):
            preview = v[:80] + "..." if len(v) > 80 else v
            print(f"    {i}. {preview}")
        print("  Enter comma-separated list of key=value pairs per variant, one per line.")
        print("  Or enter 'q' to quit, empty to keep current.")
        print()

        new_variants = []
        while True:
            print(f"  Variant (or 'done' when finished): ", end="", flush=True)
            try:
                raw = input().strip()
            except (EOFError, KeyboardInterrupt):
                print()
                return False

            if raw == 'q':
                return False
            if raw == 'done' or raw == '':
                break

            if raw:
                new_variants.append(parse_variant(raw))

        if new_variants:
            model['variants'] = new_variants

    # description
    desc = model.get('description', '')
    desc_preview = desc.strip()[:100] + "..." if len(desc.strip()) > 100 else desc.strip()
    print(f"\n  description: {desc_preview} [edit Y/N?] ", end="", flush=True)
    try:
        choice = input().strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False

    if choice == 'q':
        return False

    if choice == 'y':
        print("  Enter description (type 'done' on a new line when finished):")
        lines = []
        while True:
            try:
                line = input()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if line.strip() == 'done':
                break
            lines.append(line)

        if lines:
            model['description'] = '\n'.join(lines)

    # tags
    tags = model.get('tags', [])
    print(f"\n  tags: {tags} [edit Y/N?] ", end="", flush=True)
    try:
        choice = input().strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False

    if choice == 'q':
        return False

    if choice == 'y':
        print("  Enter comma-separated tags (or 'q' to quit): ", end="", flush=True)
        try:
            raw = input().strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return False

        if raw == 'q':
            return False

        if raw == '':
            pass  # keep current
        else:
            model['tags'] = parse_list(raw)

    return True


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <models.yaml>", file=sys.stderr)
        sys.exit(1)

    yaml_path = sys.argv[1]
    models = load_yaml(yaml_path)

    if not models:
        print(f"No models found in {yaml_path}", file=sys.stderr)
        sys.exit(1)

    print(f"\n{'=' * 60}")
    print(f"  Granite Models Reviewer")
    print(f"  File: {yaml_path}")
    print(f"  Models to review: {len(models)}")
    print(f"  Y = edit | N/Enter = accept | q = quit")
    print(f"{'=' * 60}")

    total = len(models)
    modified = False
    reviewed_count = 0

    for i, model in enumerate(models, 1):
        success = review_model(model, i, total)
        if not success:
            break
        modified = True
        reviewed_count = i

    if not modified:
        print("\nNo changes made. Original file preserved.")
        return

    # Save with backup
    backup = yaml_path + '.bak'
    os.rename(yaml_path, backup)
    print(f"\n{'=' * 60}")
    print(f"  Backup saved: {backup}")

    dump_yaml(models, yaml_path)
    print(f"  Changes written: {yaml_path}")
    print(f"  Models reviewed: {reviewed_count}/{total}")
    print(f"{'=' * 60}")


if __name__ == '__main__':
    main()
