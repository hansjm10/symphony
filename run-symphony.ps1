Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RootDir = $PSScriptRoot
$EnvFile = if ($env:ENV_FILE) { $env:ENV_FILE } else { Join-Path $RootDir ".env" }

function Import-DotEnv {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Path
  )

  foreach ($line in (Get-Content -Path $Path)) {
    $trimmed = $line.Trim()

    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
      continue
    }

    if ($trimmed.StartsWith("export ")) {
      $trimmed = $trimmed.Substring(7).Trim()
    }

    $separator = $trimmed.IndexOf("=")

    if ($separator -lt 1) {
      continue
    }

    $key = $trimmed.Substring(0, $separator).Trim()
    $value = $trimmed.Substring($separator + 1).Trim()

    if ($value.Length -ge 2) {
      $first = $value[0]
      $last = $value[$value.Length - 1]

      if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
        $value = $value.Substring(1, $value.Length - 2)
      }
    }

    [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
  }
}

function Resolve-CommandPath {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Name
  )

  $command = Get-Command -Name $Name -ErrorAction SilentlyContinue

  if ($null -eq $command) {
    return $null
  }

  return $command.Source
}

function Resolve-ToolPath {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Value
  )

  if (Test-Path -LiteralPath $Value -PathType Leaf) {
    return (Resolve-Path -LiteralPath $Value).Path
  }

  return Resolve-CommandPath -Name $Value
}

function Test-AnyFileNewerThan {
  param(
    [Parameter(Mandatory = $true)]
    [string[]] $Paths,
    [Parameter(Mandatory = $true)]
    [datetime] $ReferenceTime
  )

  foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path)) {
      continue
    }

    $newerFile = Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt $ReferenceTime } |
      Select-Object -First 1

    if ($null -ne $newerFile) {
      return $true
    }
  }

  return $false
}

if (Test-Path -LiteralPath $EnvFile) {
  Import-DotEnv -Path $EnvFile
}

$SymphonyDir = if ($env:SYMPHONY_DIR) { $env:SYMPHONY_DIR } else { Join-Path $RootDir "elixir" }
$MiseBin = if ($env:MISE_BIN) { Resolve-ToolPath -Value $env:MISE_BIN } else { Resolve-CommandPath -Name "mise" }
$Port = if ($env:SYMPHONY_PORT) { $env:SYMPHONY_PORT } else { "8080" }
$Host = if ($env:SYMPHONY_HOST) { $env:SYMPHONY_HOST } else { "0.0.0.0" }
$WorkflowFile = if ($env:WORKFLOW_FILE) { $env:WORKFLOW_FILE } else { Join-Path $SymphonyDir "WORKFLOW.md" }
$SymphonyBin = if ($env:SYMPHONY_BIN) { $env:SYMPHONY_BIN } else { Join-Path $SymphonyDir "bin/symphony" }

if (-not (Test-Path -LiteralPath $SymphonyDir -PathType Container)) {
  Write-Error "Symphony directory not found: $SymphonyDir"
}

if ([string]::IsNullOrWhiteSpace($MiseBin) -or -not (Test-Path -LiteralPath $MiseBin -PathType Leaf)) {
  $resolvedMiseBin = if ([string]::IsNullOrWhiteSpace($MiseBin)) { "<unset>" } else { $MiseBin }
  Write-Error "mise binary not found: $resolvedMiseBin"
}

if (-not (Test-Path -LiteralPath $WorkflowFile -PathType Leaf)) {
  Write-Error "Workflow file not found: $WorkflowFile"
}

$env:LANG = if ($env:LANG) { $env:LANG } else { "C.UTF-8" }
$env:LC_ALL = if ($env:LC_ALL) { $env:LC_ALL } else { "C.UTF-8" }
$env:ELIXIR_ERL_OPTIONS = if ($env:ELIXIR_ERL_OPTIONS) { $env:ELIXIR_ERL_OPTIONS } else { "+fnu" }

$needsBuild = $false

if (-not (Test-Path -LiteralPath $SymphonyBin -PathType Leaf)) {
  $needsBuild = $true
} else {
  $binWriteTime = (Get-Item -LiteralPath $SymphonyBin).LastWriteTime
  $mixExs = Join-Path $SymphonyDir "mix.exs"
  $mixLock = Join-Path $SymphonyDir "mix.lock"

  if ((Test-Path -LiteralPath $mixExs -PathType Leaf) -and (Get-Item -LiteralPath $mixExs).LastWriteTime -gt $binWriteTime) {
    $needsBuild = $true
  }

  if (-not $needsBuild -and (Test-Path -LiteralPath $mixLock -PathType Leaf) -and (Get-Item -LiteralPath $mixLock).LastWriteTime -gt $binWriteTime) {
    $needsBuild = $true
  }

  if (-not $needsBuild) {
    $needsBuild = Test-AnyFileNewerThan -Paths @(
      (Join-Path $SymphonyDir "lib"),
      (Join-Path $SymphonyDir "config")
    ) -ReferenceTime $binWriteTime
  }
}

Push-Location $SymphonyDir

try {
  if ($needsBuild) {
    & $MiseBin exec -- mix build

    if ($LASTEXITCODE -ne 0) {
      exit $LASTEXITCODE
    }
  }

  # Launch via escript so the generated entrypoint also works on Windows.
  & $MiseBin exec -- escript $SymphonyBin `
    --i-understand-that-this-will-be-running-without-the-usual-guardrails `
    --port $Port `
    --host $Host `
    $WorkflowFile

  exit $LASTEXITCODE
} finally {
  Pop-Location
}
