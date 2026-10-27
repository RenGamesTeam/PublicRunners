# Shared helpers for the Windows runners scripts.
#
# Dot-source this file:
#   . (Join-Path $PSScriptRoot 'lib.ps1')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
  param([Parameter(Mandatory)][string]$Message)
  $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  Write-Host "[$timestamp] $Message"
}

function Get-GitHubApiBase {
  if ($env:GITHUB_API_URL) {
    return $env:GITHUB_API_URL.TrimEnd('/')
  }
  return 'https://api.github.com'
}

function Invoke-GitHubApi {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Token,
    [string]$Body,
    [int]$MaxAttempts = 4
  )

  $uri = (Get-GitHubApiBase) + $Path
  $headers = @{
    Accept                 = 'application/vnd.github+json'
    Authorization          = "Bearer $Token"
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'PublicRunners'
  }

  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      $request = @{
        Method     = $Method
        Uri        = $uri
        Headers    = $headers
        TimeoutSec = 60
      }
      if ($Body) {
        $request['Body'] = $Body
        $request['ContentType'] = 'application/json'
      }
      return Invoke-RestMethod @request
    }
    catch {
      $status = 0
      if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        $status = [int]$_.Exception.Response.StatusCode
      }
      # 4xx (except rate limiting) will not succeed on retry.
      if ($status -ge 400 -and $status -lt 500 -and $status -ne 403 -and $status -ne 429) {
        throw
      }
      if ($attempt -eq $MaxAttempts) {
        throw
      }
      Start-Sleep -Seconds (2 * $attempt)
    }
  }
}

function Get-RegistrationToken {
  param(
    [Parameter(Mandatory)][string]$Org,
    [Parameter(Mandatory)][string]$Token
  )

  $payload = Invoke-GitHubApi -Method POST -Path "/orgs/$Org/actions/runners/registration-token" -Token $Token
  if (-not $payload.token) {
    throw 'registration token missing from API response'
  }
  return $payload.token
}
