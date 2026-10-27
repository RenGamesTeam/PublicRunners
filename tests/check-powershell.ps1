# Checks PowerShell script syntax without running it.
$ErrorActionPreference = 'Stop'

$failed = $false
foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot '..\src\windows') -Filter '*.ps1') {
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors) | Out-Null
  if ($errors -and $errors.Count -gt 0) {
    $failed = $true
    foreach ($error in $errors) {
      Write-Host "ERROR $($file.Name): $($error.Message)"
    }
  }
}

if ($failed) { exit 1 }
Write-Host 'PowerShell syntax OK'
