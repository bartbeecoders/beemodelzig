# Zui demo runner for Windows. The same commands as run.sh. See .\run.ps1 help
#
# Windows has no system SDL3 to link, so this script builds SDL3 from source
# through the Zig package manager (-Dsdl=source). The first build fetches and
# compiles it, which takes a minute.
#
# Not yet tried on a real Windows machine; please report what breaks.

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
    Write-Error "zig not found. Install Zig 0.17.1 from https://ziglang.org/download/ and put it on PATH."
    exit 1
}

$Sdl = "-Dsdl=source"

function Get-Examples {
    Get-ChildItem -Path examples -Directory |
        Where-Object { $_.Name -ne "common" } |
        Sort-Object Name |
        ForEach-Object { $_.Name }
}

function Show-Usage {
    @"
Usage: .\run.ps1 <command> [args]

  <demo> [args]   Build (ReleaseFast) and run a demo
  list            List the demos
  test            Run the unit tests
  docs            Check that every public declaration has a doc comment
  bench [N W H]   Time N frames of a busy UI at W x H (default 1000 1280 800)
  gl-check        Compare the OpenGL renderer with the software one, pixel by pixel
  native [args]   Run the demo on the native Win32 backend (no C runtime)
  cross           Compile-check the core for Windows and macOS
  scenarios       Play the scripts in tests/scenarios against their demos
  check           test + docs + cross + scenarios: everything before a release
  build           Build every demo into zig-out\bin
  help            Show this help

Demos:
"@
    Get-Examples | ForEach-Object { "  $_" }
    ""
    "Start with:  .\run.ps1 demo"
}

function Invoke-Zig {
    & zig @args
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$Command = if ($args.Count -gt 0) { $args[0] } else { "help" }
$Rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

switch ($Command) {
    { $_ -in "help", "-h", "--help" } { Show-Usage }
    "list" { Get-Examples }
    "test" { Invoke-Zig build test --summary all @Rest }
    "docs" { Invoke-Zig build check-docs @Rest }
    "bench" { Invoke-Zig build bench -- @Rest }
    "gl-check" { Invoke-Zig build gl-check $Sdl @Rest }
    "native" { Invoke-Zig build native -Doptimize=ReleaseSafe -- @Rest }
    "cross" { Invoke-Zig build cross --summary all @Rest }
    "scenarios" { Invoke-Zig build scenarios --summary all @Rest }
    "check" {
        Invoke-Zig build test --summary all
        Invoke-Zig build check-docs
        Invoke-Zig build cross --summary all
        Invoke-Zig build scenarios --summary all
    }
    "build" { Invoke-Zig build -Doptimize=ReleaseFast $Sdl @Rest }
    default {
        if ((Get-Examples) -notcontains $Command) {
            Write-Host "error: unknown command or demo '$Command'"
            Show-Usage
            exit 1
        }
        Invoke-Zig build "run-$Command" -Doptimize=ReleaseFast $Sdl -- @Rest
    }
}
