# Runs a loop of ephemeral GitHub Actions runners until the time budget ends.
#
# Each iteration configures a uniquely named ephemeral runner, lets it accept a
# single job, then removes the workspace. An ephemeral runner deregisters
# itself after one job, so a compromised job cannot persist on the machine.
#
# Environment:
#   ORG_NAME            Organisation that owns the runner (required)
#   RUNNER_ADMIN_TOKEN  Token allowed to create registration tokens (required)
#   DURATION_SECONDS    Wall clock budget (default: 18000)
#   RUNNER_PREFIX       Runner name prefix (default: pr-windows)
#   LABELS              Runner labels (default: self-hosted,Windows,X64)
#   RUNNER_DIR          Runner install directory (default: <script dir>\actions-runner)
#   GITHUB_SERVER_URL   GitHub server URL (default: https://github.com)
#   RUNNER_LOG_TO_STDOUT
#                       "true" keeps the inner runner's console output in this
#                       (public) step log. The default "false" writes it to
#                       <runner dir>\_diag\console-<name>.log instead, so job
#                       names from other repositories never show up in a public
#                       run log.

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib.ps1')

function Get-EnvOrDefault {
  param([string]$Name, [string]$Default)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
  return $value
}

$org = Get-EnvOrDefault 'ORG_NAME' ''
$adminToken = Get-EnvOrDefault 'RUNNER_ADMIN_TOKEN' ''
$durationRaw = Get-EnvOrDefault 'DURATION_SECONDS' '18000'
$prefix = Get-EnvOrDefault 'RUNNER_PREFIX' 'pr-windows'
$labels = Get-EnvOrDefault 'LABELS' 'self-hosted,Windows,X64'
$runnerDir = Get-EnvOrDefault 'RUNNER_DIR' (Join-Path $PSScriptRoot 'actions-runner')
$serverUrl = (Get-EnvOrDefault 'GITHUB_SERVER_URL' 'https://github.com').TrimEnd('/')
$runId = Get-EnvOrDefault 'GITHUB_RUN_ID' 'local'
$logToStdout = (Get-EnvOrDefault 'RUNNER_LOG_TO_STDOUT' 'false') -eq 'true'

if (-not $org) { throw 'ORG_NAME is required.' }
if (-not $adminToken) { throw 'RUNNER_ADMIN_TOKEN is required.' }
if (-not $prefix) { throw 'RUNNER_PREFIX must not be empty.' }

$duration = 0
if (-not [int]::TryParse($durationRaw, [ref]$duration) -or $duration -lt 1 -or $duration -gt 18000) {
  throw "DURATION_SECONDS must be an integer between 1 and 18000 (got '$durationRaw')."
}

if (-not (Test-Path (Join-Path $runnerDir 'config.cmd'))) {
  throw "Runner not installed at $runnerDir; run setup.ps1 first."
}

$deadline = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $duration
$iteration = 0
$failureStreak = 0
$maxFailureStreak = 5

Write-Log "Starting ephemeral runner loop for ${duration}s (prefix=$prefix, labels=$labels)"

while ($true) {
  $remaining = $deadline - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($remaining -le 10) { break }

  $iteration++
  $runnerName = "$prefix-$runId-$iteration"

  $token = $null
  try {
    $token = Get-RegistrationToken -Org $org -Token $adminToken
  }
  catch {
    $failureStreak++
    Write-Log "WARN: could not obtain a registration token ($($_.Exception.Message)); attempt $failureStreak/$maxFailureStreak"
    if ($failureStreak -ge $maxFailureStreak) {
      throw 'Giving up: no registration token available. Check RUNNER_ADMIN_TOKEN and its admin:org scope.'
    }
    Start-Sleep -Seconds 30
    continue
  }

  # A previous iteration killed by the timeout may have left local
  # configuration behind; iterations are sequential, so dropping it is safe.
  foreach ($file in '.runner', '.credentials', '.credentials_rsaparams') {
    Remove-Item -Path (Join-Path $runnerDir $file) -Force -ErrorAction SilentlyContinue
  }

  Write-Log "Configuring ephemeral runner '$runnerName'"
  Push-Location $runnerDir
  try {
    & .\config.cmd --unattended --url "$serverUrl/$org" --token $token --name $runnerName --labels $labels --ephemeral --work "_work"
    $configured = ($LASTEXITCODE -eq 0)
  }
  finally {
    Pop-Location
  }

  if (-not $configured) {
    $failureStreak++
    Write-Log "WARN: runner configuration failed for '$runnerName'; attempt $failureStreak/$maxFailureStreak"
    if ($failureStreak -ge $maxFailureStreak) {
      throw 'Giving up: runner could not be configured.'
    }
    Start-Sleep -Seconds 30
    continue
  }
  $failureStreak = 0

  Write-Log "Runner '$runnerName' is waiting for a job (up to ${remaining}s)"
  $timeoutMs = [int]($remaining * 1000)
  $consoleOut = Join-Path $runnerDir "_diag\console-$runnerName.out.log"
  $consoleErr = Join-Path $runnerDir "_diag\console-$runnerName.err.log"
  New-Item -ItemType Directory -Path (Join-Path $runnerDir '_diag') -Force | Out-Null

  $startArgs = @{
    FilePath         = (Join-Path $runnerDir 'run.cmd')
    WorkingDirectory = $runnerDir
    PassThru         = $true
    NoNewWindow      = $true
  }
  if (-not $logToStdout) {
    # The runner prints the name and result of every job it processes. This run
    # is public, so keep that output on the ephemeral machine instead of the
    # step log (the file disappears with the machine).
    $startArgs.RedirectStandardOutput = $consoleOut
    $startArgs.RedirectStandardError = $consoleErr
  }
  $process = Start-Process @startArgs
  $finished = $process.WaitForExit($timeoutMs)

  if ($finished) {
    Write-Log "Runner '$runnerName' finished (exit code $($process.ExitCode))"
  }
  else {
    if ($logToStdout) {
      Write-Log "Runner '$runnerName' reached the time budget and was stopped"
    }
    else {
      Write-Log "Runner '$runnerName' reached the time budget and was stopped (console log: $consoleOut)"
    }
    & taskkill.exe /T /F /PID $process.Id 2>&1 | Out-Null
    $process.WaitForExit(30000) | Out-Null

    Push-Location $runnerDir
    try {
      & .\config.cmd remove --token $token
      if ($LASTEXITCODE -ne 0) {
        Write-Log "WARN: could not remove runner '$runnerName' (it will be cleaned up by prefix)."
      }
    }
    finally {
      Pop-Location
    }
  }

  # Never let file system state leak from one job/repository into the next.
  Remove-Item -Path (Join-Path $runnerDir '_work') -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Log "Runner loop finished after $iteration iteration(s)"
