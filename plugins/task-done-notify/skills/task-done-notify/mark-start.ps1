# =====================================================================
# mark-start.ps1 - Claude Code "UserPromptSubmit" hook
#
# Stamps the moment the user hit Enter, so notify.ps1 can tell a 3-second
# answer from a 4-minute task and stay quiet for the short ones.
#
# ASCII ONLY (see notify.ps1 for why). Writes nothing to stdout, exits 0.
# =====================================================================
$ErrorActionPreference = 'Stop'

$stateDir = Join-Path $env:TEMP 'claude-task-notify'

try {
  if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

  $sid = 'default'
  if ([Console]::IsInputRedirected) {
    $raw = [Console]::In.ReadToEnd()
    if ($raw -and $raw.Trim().Length -gt 0) {
      try {
        $o = $raw | ConvertFrom-Json
        if ($o.session_id) { $sid = [string]$o.session_id }
      } catch { }
    }
  }

  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $stateDir "$sid.start"), [string]$now, $enc)

  # housekeeping: drop markers older than a day
  Get-ChildItem -Path $stateDir -Filter '*.start' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

} catch { }

exit 0
