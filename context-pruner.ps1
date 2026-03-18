$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    param(
        [string]$OriginalCwd,
        [string]$ScriptDir
    )

    if ($env:CONTEXT_PRUNER_REPO_ROOT) {
        return $env:CONTEXT_PRUNER_REPO_ROOT
    }

    if (Test-Path (Join-Path $ScriptDir "elixir\\mix.exs")) {
        return $ScriptDir
    }

    $dir = $OriginalCwd

    while ($true) {
        if (Test-Path (Join-Path $dir "elixir\\mix.exs")) {
            return $dir
        }

        $parent = Split-Path $dir -Parent

        if ($parent -eq $dir -or [string]::IsNullOrEmpty($parent)) {
            break
        }

        $dir = $parent
    }

    return $null
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$originalCwd = (Get-Location).Path
$repoRoot = Get-RepoRoot -OriginalCwd $originalCwd -ScriptDir $scriptDir

if (-not $repoRoot) {
    Write-Error "Unable to locate a Symphony checkout from the current directory: $originalCwd"
    exit 1
}

$symphonyDir = Join-Path $repoRoot "elixir"

if (-not (Test-Path (Join-Path $symphonyDir "mix.exs"))) {
    Write-Error "Symphony Elixir project not found under: $symphonyDir"
    exit 1
}

$mise = Get-Command mise -ErrorAction SilentlyContinue
$mix = Get-Command mix -ErrorAction SilentlyContinue

if (-not $mise -and -not $mix) {
    Write-Error "Neither mise nor mix is available; cannot launch context-pruner."
    exit 127
}

$env:CONTEXT_PRUNER_CWD = $originalCwd

if (-not $env:LANG) {
    $env:LANG = "C.UTF-8"
}

if (-not $env:LC_ALL) {
    $env:LC_ALL = "C.UTF-8"
}

if (-not $env:ELIXIR_ERL_OPTIONS) {
    $env:ELIXIR_ERL_OPTIONS = "+fnu"
}

Push-Location $symphonyDir
try {
    if ($mise) {
        & $mise.Source exec -- mix context_pruner @args
    } else {
        & $mix.Source context_pruner @args
    }

    exit $LASTEXITCODE
} finally {
    Pop-Location
}
