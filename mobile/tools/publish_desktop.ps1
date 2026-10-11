# Publish the desktop app to a prominent path.
#
# A Flutter Windows release is a bundle, not a single exe: the launcher
# next to flutter_windows.dll and data/app.so. This script copies the
# whole bundle to E:\TravelPlanner\ and renames the launcher to
# TravelPlanner.exe, so the app lives at
#
#     E:\TravelPlanner\TravelPlanner.exe
#
# The target folder holds no secrets beyond the app's own decision: the
# bundled config comes from mobile/assets/turso_config.json, which is
# git-ignored (the keys ship in the app by design, 2026-10-11).
#
# AVG flags every freshly built copy as IDP.Generic (false positive; see
# HANDOFF.md). The publish leaves a NEW file at E:\TravelPlanner\ on
# disk, which is what AVG's dialog needs to offer the exclusion for that
# path.

$ErrorActionPreference = "Stop"

$source = Join-Path $PSScriptRoot "..\build\windows\x64\runner\Release"
$target = "E:\TravelPlanner"

if (-not (Test-Path $source)) {
    throw "No release build found at $source -- run 'flutter build windows' first."
}

New-Item -ItemType Directory -Path $target -Force | Out-Null

# Everything except the launcher keeps its name; the launcher is the
# user-facing entry point and gets the short name.
$sourceRoot = (Resolve-Path $source).Path
Get-ChildItem -Recurse -File $source | ForEach-Object {
    $relative = $_.FullName.Substring($sourceRoot.Length + 1)
    if ($relative -eq "travel_planner.exe") {
        $relative = "TravelPlanner.exe"
    }
    $destination = Join-Path $target $relative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item $_.FullName $destination -Force
}

$exe = Join-Path $target "TravelPlanner.exe"
if (-not (Test-Path $exe)) {
    throw "Publish failed: $exe is missing."
}
Write-Output "Published $exe"
$info = Get-ChildItem -Recurse -File $target |
    Measure-Object -Property Length -Sum
"Bundle: {0:N1} MB in {1} files" -f ($info.Sum / 1MB), $info.Count
