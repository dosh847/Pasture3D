#!/usr/bin/env bash
# Headless test launcher (Linux / macOS / Git-Bash).
#
#   ./run_tests.sh                          # run every test
#   ./run_tests.sh --filter=detach          # only methods whose name contains "detach"
#   ./run_tests.sh --dir=res://tests/unit   # limit discovery to a subtree
#
# Godot binary resolution (first hit wins):
#   1. $GODOT_BIN   2. a `godot` on PATH
# e.g.  GODOT_BIN=/opt/godot/Godot_v4.7-stable_linux.x86_64 ./run_tests.sh
#
# Exits with the runner's code (0 = all passed, 1 = any failure).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$HERE")"          # tests/.. = the project root (holds project.godot)
GODOT="${GODOT_BIN:-godot}"

ARGS=(--headless --path "$PROJECT_ROOT" --script res://tests/framework/test_runner.gd)
if [ "$#" -gt 0 ]; then
	ARGS+=(--)
	ARGS+=("$@")
fi

exec "$GODOT" "${ARGS[@]}"
