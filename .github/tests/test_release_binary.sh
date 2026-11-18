#!/usr/bin/env bash
set -euo pipefail

binary="${1:?missing release binary path}"
"$binary" --version

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/source"
source_file="$fixture/source/input.rs"
printf 'fn main() { println!("release regression needle"); }\n' > "$source_file"

"$binary" --regex needle "$source_file" --json | tee "$fixture/regex.jsonl"
"$binary" --index "$fixture/source"
"$binary" --sem 'release regression' "$source_file" --threshold 0 --json \
  | tee "$fixture/semantic.jsonl"

# JSON avoids terminal highlighting and lets us reject dummy zero-score
# embeddings as well as missing or incorrectly scoped results.
# Windows runners provide `python` rather than `python3`, so callers can override it.
"${PYTHON:-python3}" - "$source_file" "$fixture/regex.jsonl" "$fixture/semantic.jsonl" <<'PY'
import json
import math
import sys
from pathlib import Path

# ck reports Windows paths in verbatim form (\\?\C:\...), which pathlib
# doesn't treat as equal to the plain path.
def normalise(path):
    return Path(path.removeprefix("\\\\?\\")).resolve()

expected_file = normalise(sys.argv[1])
for mode, output in zip(("regex", "semantic"), sys.argv[2:]):
    results = [json.loads(line) for line in Path(output).read_text().splitlines()]
    assert results, f"{mode}: no results"
    for result in results:
        assert normalise(result["file"]) == expected_file, result
        assert "release regression needle" in result["preview"], result
        if mode == "semantic":
            score = result["score"]
            assert math.isfinite(score) and 0 < score <= 1, result
print("Release binary passed regex, indexing, and semantic regressions")
PY
