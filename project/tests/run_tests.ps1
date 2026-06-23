#!/usr/bin/env pwsh
# Headless test launcher (Windows / PowerShell).
#
#   ./run_tests.ps1                          # run every test
#   ./run_tests.ps1 --filter=detach          # only methods whose name contains "detach"
#   ./run_tests.ps1 --dir=res://tests/unit   # limit discovery to a subtree
#
# Godot binary resolution (first hit wins):
#   1. $env:GODOT_BIN   2. a `godot` on PATH
# Set it once per shell, e.g.:
#   $env:GODOT_BIN = "C:\Users\you\Godot\Godot_v4.7-stable_win64_console.exe"
#
# Exits with the runner's code (0 = all passed, 1 = any failure), so CI / an agent can branch on it.
param([Parameter(ValueFromRemainingArguments = $true)] $Rest)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot   # tests/.. = the project root (holds project.godot)

$godot = if ($env:GODOT_BIN) { $env:GODOT_BIN } else { "godot" }

$gargs = @("--headless", "--path", $projectRoot, "--script", "res://tests/framework/test_runner.gd")
if ($Rest) { $gargs += "--"; $gargs += $Rest }

& $godot @gargs
exit $LASTEXITCODE
