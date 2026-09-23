# =====================================================================
# register-appids.ps1 - one-time setup
#
# A Windows toast borrows its header name from an AppUserModelId (AUMID).
# Without a registered AUMID the toast says "Windows PowerShell" instead of
# the agent name. This registers one AUMID per entry in config.json's
# "tools" map, so the header reads "Claude Code" / "Codex" / ... correctly.
#
# Idempotent - safe to re-run after editing the tools map.
# Writes only to HKCU, so it affects just the current user.
#
# ASCII ONLY (see notify.ps1 for why).
# =====================================================================
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath   = Join-Path $scriptDir 'config.json'

if (-not (Test-Path $cfgPath)) {
  Write-Output "config.json not found: $cfgPath"
  exit 1
}

$cfg = ([System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json

if (-not $cfg.tools) {
  Write-Output "no 'tools' map in config.json - nothing to register"
  exit 0
}

foreach ($prop in $cfg.tools.PSObject.Properties) {
  $def = $prop.Value
  if (-not $def.appId) { continue }

  $key = "HKCU:\Software\Classes\AppUserModelId\$($def.appId)"
  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
  New-ItemProperty -Path $key -Name 'DisplayName' -Value ([string]$def.displayName) `
                   -PropertyType String -Force | Out-Null

  Write-Output ("registered  {0}  ->  {1}" -f $def.appId, $def.displayName)
}

Write-Output ""
Write-Output "done. to undo, delete:"
Write-Output "  HKCU:\Software\Classes\AppUserModelId\AgentTaskDone.*"
