#!/usr/bin/env python3
"""Count reachable Builder and association helper bodies in emitted LLVM IR."""
import argparse
import json
import re
from collections import Counter
from pathlib import Path


SYMBOL_PATTERN = re.compile(r'@(?:"([^"]+)"|([^ (]+))\(')
BUILDER_OWNER = re.compile(r"^\*Grant::Query::Builder\(BenchPerson(\d+)\)(?:@|#|::)")
MODEL_OWNER = re.compile(r"^\*BenchPerson(\d+)(?:@|#|::)")


def read_symbol(definition: str) -> str:
    match = SYMBOL_PATTERN.search(definition)
    if match is None:
        return ""
    return match.group(1) or match.group(2)


def add(counter: Counter, model: int, amount: int = 1) -> None:
    counter[model] += amount


def report(path: Path) -> dict:
    builder_defs = Counter()
    builder_lines = Counter()
    autosave_defs = Counter()
    autosave_lines = Counter()
    validation_defs = Counter()
    validation_lines = Counter()
    shared_relation_defs = 0
    shared_relation_lines = 0
    current = None

    for line in path.open(encoding="utf-8", errors="replace"):
        if line.startswith("define "):
            symbol = read_symbol(line)
            builder_match = BUILDER_OWNER.match(symbol)
            model_match = MODEL_OWNER.match(symbol)
            if builder_match:
                current = ("builder", int(builder_match.group(1)))
                add(builder_defs, current[1])
            elif model_match and "_autosave_" in symbol:
                current = ("autosave", int(model_match.group(1)))
                add(autosave_defs, current[1])
            elif model_match and "_validate_associated_" in symbol:
                current = ("validation", int(model_match.group(1)))
                add(validation_defs, current[1])
            elif "Grant::Query::RelationState" in symbol:
                current = ("shared_relation", -1)
                shared_relation_defs += 1
            else:
                current = None
        elif current is not None and line.strip() == "}":
            current = None

        if current is None:
            continue
        kind, model = current
        if kind == "builder":
            add(builder_lines, model)
        elif kind == "autosave":
            add(autosave_lines, model)
        elif kind == "validation":
            add(validation_lines, model)
        else:
            shared_relation_lines += 1

    model_ids = sorted(set(builder_defs) | set(autosave_defs) | set(validation_defs))

    def per_model(definitions: Counter, body_lines: Counter) -> dict:
        rows = {
            str(model): {
                "function_definitions": definitions[model],
                "function_body_lines": body_lines[model],
            }
            for model in model_ids
        }
        rows["mean"] = {
            "function_definitions": round(sum(definitions.values()) / len(model_ids), 2) if model_ids else 0,
            "function_body_lines": round(sum(body_lines.values()) / len(model_ids), 2) if model_ids else 0,
        }
        rows["total"] = {
            "function_definitions": sum(definitions.values()),
            "function_body_lines": sum(body_lines.values()),
        }
        return rows

    return {
        "ir_path": str(path),
        "llvm_ir_bytes": path.stat().st_size,
        "models": len(model_ids),
        "builder": per_model(builder_defs, builder_lines),
        "autosave": per_model(autosave_defs, autosave_lines),
        "validate_associated": per_model(validation_defs, validation_lines),
        "relation_state": {
            "function_definitions": shared_relation_defs,
            "function_body_lines": shared_relation_lines,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ir_file", type=Path)
    args = parser.parse_args()
    print(json.dumps(report(args.ir_file), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
