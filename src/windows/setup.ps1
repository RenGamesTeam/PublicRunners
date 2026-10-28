# Downloads and verifies the GitHub Actions runner for Windows.
#
# The version is pinned and the archive checksum is verified before extraction.
# Already extracted runners are left untouched, so the script is idempotent.
#
# Note: the environment variables are deliberately NOT named RUNNER_VERSION /
# RUNNER_ARCH. GitHub Actions already exports RUNNER_ARCH (for example "X64")
# into every step; reusing such names makes the download depend on the runner
# image instead of the values this repository pins.
#
# Environment (parameters win when supplied):
#   RUNNER_PACKAGE_VERSION  Runner version (default: 2.338.2)
#   RUNNER_PACKAGE_SHA256   Override the expected checksum
#   RUNNER_DIR              Install directory (default: <script dir>\actions-runner)

[CmdletBinding()]
param(
  [string]$Version = $(if ($env:RUNNER_PACKAGE_VERSION) { $env:RUNNER_PACKAGE_VERSION } else { '2.338.2' }),
  [string]$RunnerDir = $(if ($env:RUNNER_DIR) { $env:RUNNER_DIR } else { Join-Path $PSScriptRoot 'actions-runner' }),
  [string]$Sha256 = $env:RUNNER_PACKAGE_SHA256
)

. (Join-Path $PSScriptRoot 'lib.ps1')

$Version = $Version.Trim().TrimStart('v')

# Windows runners are x64; the win-arm64 archive is not used here.
$checksums = @{
  '2.338.2' = 'a1f17aa987fc8158bc7521d284912267a0d01b7c2c4684b33c86783b5e8221cc'
}

if (-not $Sha256) {
  $Sha256 = $checksums[$Version]
}
if (-not $Sha256) {
  throw "No pinned checksum for runner $Version; set RUNNER_PACKAGE_SHA256."
}
if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
  throw 'RUNNER_PACKAGE_SHA256 must be a 64 character hex digest.'
}

if ((Test-Path (Join-Path $RunnerDir 'config.cmd')) -and (Test-Path (Join-Path $RunnerDir 'run.cmd'))) {
  Write-Log "Runner already present at $RunnerDir; skipping download"
  exit 0
}

$archive = "actions-runner-win-x64-$Version.zip"
$url = "https://github.com/actions/runner/releases/download/v$Version/$archive"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
  $zip = Join-Path $tempDir $archive
  Write-Log "Downloading $url"
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

  Write-Log 'Verifying SHA256 checksum'
  $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $Sha256.ToLowerInvariant()) {
    throw "Checksum verification failed for $archive (expected $Sha256, got $actual)."
  }

  New-Item -ItemType Directory -Path $RunnerDir -Force | Out-Null
  Write-Log "Extracting runner $Version into $RunnerDir"
  Expand-Archive -Path $zip -DestinationPath $RunnerDir -Force

  if (-not (Test-Path (Join-Path $RunnerDir 'run.cmd'))) {
    throw 'Runner archive did not contain run.cmd.'
  }
  Write-Log "Runner $Version is ready"
}
finally {
  Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
