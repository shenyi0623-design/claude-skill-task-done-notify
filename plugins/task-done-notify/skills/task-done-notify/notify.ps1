# =====================================================================
# notify.ps1 - task-finished notifier for agent CLIs
#
# Fires a Windows toast saying the task finished - but ONLY when the
# terminal window running the agent is NOT in the foreground and the turn
# ran longer than config.thresholdSeconds.
#
# Which agent owns the task (Claude Code / Codex / Gemini CLI / ...) is
# detected at notify time, so the toast header and {tool} token are right
# no matter which CLI is running.
#
# PERFORMANCE (this runs at the end of every turn):
#   short turn / focused window ... PS startup only, no P/Invoke
#   actually notifying ........... ~1.5s
# Never call Get-CimInstance per ancestor - WMI costs ~450ms per filtered
# query and occasionally stalls for minutes, which silently kills the
# hook. One CreateToolhelp32Snapshot covers every process in ~160ms.
#
# ASCII ONLY. Windows PowerShell 5.1 decodes BOM-less files as ANSI
# (GBK on a zh-CN box). Any non-ASCII byte in this file corrupts the
# source and breaks parsing. All display text lives in config.json,
# which is read back explicitly as UTF-8.
#
# Always exits 0 and writes nothing to stdout, so it can never block
# or interfere with the agent stopping.
# =====================================================================
[CmdletBinding()]
param(
  [switch]$DryRun,              # print the decision as JSON, notify nothing
  [switch]$TestToast,           # skip every check, fire the toast now
  [string]$ConfigPath,          # override config.json location
  [string]$SimulateForeground,  # fake the foreground process name (tests)
  [string]$SimulateTool         # fake the detected tool id (tests)
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $env:TEMP 'claude-task-notify'
$logPath  = Join-Path $stateDir 'notify.log'

# Config resolution, first hit wins.
#
# As a plugin, this script lives in a VERSIONED cache directory that is
# replaced wholesale on every plugin update, so users must not be expected to
# edit config.json in place. A user override outside the plugin shadows it.
if (-not $ConfigPath) {
  $candidates = @()
  if ($env:CLAUDE_TASK_NOTIFY_CONFIG) { $candidates += $env:CLAUDE_TASK_NOTIFY_CONFIG }
  $candidates += (Join-Path $env:USERPROFILE '.claude\task-done-notify.json')
  $candidates += (Join-Path $scriptDir 'config.json')
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { $ConfigPath = $c; break }
  }
  if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir 'config.json' }
}

# ---------- defaults (ASCII fallbacks; config.json overrides) ---------
$cfg = [pscustomobject]@{
  enabled               = $true
  thresholdSeconds      = 30
  appId                 = 'AgentTaskDone.Generic'
  appDisplayName        = 'AI Agent'
  sound                 = $true
  fallbackSound         = $true
  autoRegisterAppId     = $true
  debug                 = $false
  title                 = 'Task completed'
  body                  = 'took {elapsed} - terminal not in foreground'
  elapsedMinutesSeconds = '{m}m {s}s'
  elapsedSeconds        = '{s}s'
  terminalWindowClasses = @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS')
  terminalProcesses     = @('WindowsTerminal', 'conhost', 'cmd', 'powershell', 'pwsh',
                            'OpenConsole', 'wezterm-gui', 'alacritty', 'mintty',
                            'ConEmu', 'ConEmu64', 'Tabby', 'hyper')
  checkAncestorNames    = $true
  tools                 = $null
  defaultTool           = 'generic'
  toolEnvMarkers        = @()
  toolProcessNames      = $null
  toolCommandLinePatterns = @()
}

try {
  if (Test-Path $ConfigPath) {
    $user = ([System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
    if ($user) {
      foreach ($p in $user.PSObject.Properties) {
        $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
      }
    }
  }
} catch { }

function Write-Log([string]$msg) {
  if (-not $cfg.debug) { return }
  try {
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    Add-Content -Path $logPath -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
  } catch { }
}

# user32 for the foreground window, kernel32 toolhelp for the process tree.
# Compiling both in one Add-Type costs ~600ms once; two separate Add-Type
# calls would cost it twice.
function Initialize-Native {
  if ('AgentNotify.Native' -as [type]) { return }
  Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace AgentNotify {
  public class Native {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PROCESSENTRY32 {
      public uint dwSize; public uint cntUsage; public uint th32ProcessID;
      public IntPtr th32DefaultHeapID; public uint th32ModuleID; public uint cntThreads;
      public uint th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool Process32First(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool Process32Next(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr h);

    private static readonly Dictionary<int, int> parents = new Dictionary<int, int>();
    private static readonly Dictionary<int, string> names = new Dictionary<int, string>();
    private static bool loaded = false;

    private static void Load() {
      if (loaded) return;
      loaded = true;
      IntPtr snap = CreateToolhelp32Snapshot(0x00000002, 0);
      if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return;
      try {
        var pe = new PROCESSENTRY32();
        pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
        if (Process32First(snap, ref pe)) {
          do {
            int p = (int)pe.th32ProcessID;
            parents[p] = (int)pe.th32ParentProcessID;
            string n = pe.szExeFile;
            if (n != null && n.ToLower().EndsWith(".exe")) n = n.Substring(0, n.Length - 4);
            names[p] = n;
          } while (Process32Next(snap, ref pe));
        }
      } finally { CloseHandle(snap); }
    }

    // "<pid>|<name>" for this process and each ancestor, nearest first
    public static string[] Ancestors(int startPid, int maxDepth) {
      Load();
      var list = new List<string>();
      int cur = startPid;
      for (int i = 0; i < maxDepth; i++) {
        int parent;
        if (!parents.TryGetValue(cur, out parent)) break;
        string n;
        if (!names.TryGetValue(cur, out n)) n = "";
        list.Add(cur.ToString() + "|" + n);
        if (parent <= 0 || parent == cur) break;
        cur = parent;
      }
      return list.ToArray();
    }
  }
}
'@
}

function Get-ForegroundInfo {
  $h = [AgentNotify.Native]::GetForegroundWindow()
  $fgPid = 0
  [void][AgentNotify.Native]::GetWindowThreadProcessId($h, [ref]$fgPid)
  $sb = New-Object System.Text.StringBuilder 256
  [void][AgentNotify.Native]::GetClassName($h, $sb, 256)
  $name = ''
  $p = Get-Process -Id $fgPid -ErrorAction SilentlyContinue
  if ($p) { $name = $p.ProcessName }
  return [pscustomobject]@{ Pid = $fgPid; Name = $name; Class = $sb.ToString() }
}

$script:ancCache = $null
function Get-Ancestors {
  if ($script:ancCache) { return $script:ancCache }
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($row in [AgentNotify.Native]::Ancestors($PID, 12)) {
    $parts = $row.Split('|')
    $list.Add([pscustomobject]@{ Pid = [int]$parts[0]; Name = $parts[1] })
  }
  $script:ancCache = $list
  return $list
}

# Which CLI owns this task?
#
# Ancestors win over environment variables: the chain literally says which
# agent process spawned us, while env vars are inherited and can leak
# (running codex inside a Claude Code session still exports CLAUDECODE).
# Env markers are only a fallback for an unlisted tool.
#
# Process names alone are not enough - codex and gemini run as node.exe, so
# their identity lives in the command line (".../@openai/codex/bin/codex.js").
# Reading command lines means WMI, so it is the last resort, one query only.
function Resolve-ToolId {
  if ($SimulateTool) { return $SimulateTool }

  $anc = Get-Ancestors

  if ($cfg.toolProcessNames) {
    foreach ($a in $anc) {
      foreach ($prop in $cfg.toolProcessNames.PSObject.Properties) {
        if ($prop.Name -eq $a.Name) { return [string]$prop.Value }
      }
    }
  }

  foreach ($m in @($cfg.toolEnvMarkers)) {
    if ($m -and $m.var) {
      $v = [Environment]::GetEnvironmentVariable([string]$m.var)
      if ($v -and ([string]$v).Length -gt 0) { return [string]$m.tool }
    }
  }

  try {
    $cmdByPid = @{}
    foreach ($proc in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
      if ($proc.CommandLine) { $cmdByPid[[int]$proc.ProcessId] = ([string]$proc.CommandLine) -replace '\\', '/' }
    }
    foreach ($a in $anc) {
      if (-not $cmdByPid.ContainsKey($a.Pid)) { continue }
      $cl = $cmdByPid[$a.Pid]
      foreach ($m in @($cfg.toolCommandLinePatterns)) {
        if ($m -and $m.pattern -and ($cl -match [string]$m.pattern)) { return [string]$m.tool }
      }
    }
  } catch { }

  return [string]$cfg.defaultTool
}

function Find-ToolDef([string]$toolId) {
  if (-not $cfg.tools -or -not $toolId) { return $null }
  foreach ($prop in $cfg.tools.PSObject.Properties) {
    if ($prop.Name -eq $toolId) { return $prop.Value }
  }
  return $null
}

function Get-ToolDisplay([string]$toolId) {
  $fallback = [pscustomobject]@{ displayName = [string]$cfg.appDisplayName; appId = [string]$cfg.appId }
  foreach ($id in @($toolId, [string]$cfg.defaultTool)) {
    $def = Find-ToolDef $id
    if ($def) {
      $dn = $fallback.displayName
      $ai = $fallback.appId
      if ($def.displayName) { $dn = [string]$def.displayName }
      if ($def.appId) { $ai = [string]$def.appId }
      return [pscustomobject]@{ displayName = $dn; appId = $ai }
    }
  }
  return $fallback
}

# A toast borrows its header name from an AppUserModelId. Registering one in
# HKCU is what makes the toast read "Claude Code" instead of "Windows
# PowerShell". Idempotent, user-scoped, and only ever writes under
# HKCU:\Software\Classes\AppUserModelId - disable with autoRegisterAppId.
function Register-AppId([string]$appId, [string]$displayName) {
  if (-not $cfg.autoRegisterAppId -or -not $appId) { return }
  try {
    $key = "HKCU:\Software\Classes\AppUserModelId\$appId"
    if (Test-Path $key) { return }
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DisplayName' -Value $displayName -PropertyType String -Force | Out-Null
    Write-Log "registered appId $appId as '$displayName'"
  } catch {
    Write-Log "appId registration failed: $($_.Exception.Message)"
  }
}

function Show-Toast([string]$appId, [string]$title, [string]$bodyText) {
  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
  [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

  $audio = '<audio src="ms-winsoundevent:Notification.Default"/>'
  if (-not $cfg.sound) { $audio = '<audio silent="true"/>' }

  $xml = '<toast duration="short"><visual><binding template="ToastGeneric"><text>' +
         [System.Security.SecurityElement]::Escape($title) + '</text><text>' +
         [System.Security.SecurityElement]::Escape($bodyText) + '</text></binding></visual>' +
         $audio + '</toast>'

  $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
  $doc.LoadXml($xml)
  $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
}

function Get-ElapsedText([int]$seconds) {
  $m = [math]::Floor($seconds / 60)
  $s = $seconds % 60
  if ($m -gt 0) {
    return ([string]$cfg.elapsedMinutesSeconds).Replace('{m}', [string]$m).Replace('{s}', [string]$s)
  }
  return ([string]$cfg.elapsedSeconds).Replace('{s}', [string]$s)
}

# ============================ main ============================
$decision = 'silent'
$reason   = 'unknown'
$elapsed  = -1
$fg       = $null
$toolId   = ''
$toolDisp = $null

try {
  # --- stdin payload from the agent (skip when run by hand) ---
  $hookIn = $null
  if ([Console]::IsInputRedirected) {
    $raw = [Console]::In.ReadToEnd()
    if ($raw -and $raw.Trim().Length -gt 0) {
      try { $hookIn = $raw | ConvertFrom-Json } catch { }
    }
  }

  $sid = 'default'
  if ($hookIn -and $hookIn.session_id) { $sid = [string]$hookIn.session_id }

  # --- how long did this turn take? ---
  $startedMs = [int64]0
  $stateFile = Join-Path $stateDir "$sid.start"
  if (Test-Path $stateFile) {
    $t = ''
    try { $t = [System.IO.File]::ReadAllText($stateFile).Trim() } catch { }
    [void][int64]::TryParse($t, [ref]$startedMs)
  }
  if ($startedMs -gt 0) {
    $elapsed = [int](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $startedMs) / 1000)
  }

  # --- gate on duration BEFORE touching any native API ---
  # A short answer never pays for the foreground check.
  if (-not $TestToast) {
    if (-not $cfg.enabled)     { $reason = 'disabled' }
    elseif ($elapsed -lt 0)    { $reason = 'no-start-marker' }
    elseif ($elapsed -lt [int]$cfg.thresholdSeconds) { $reason = "below-threshold:${elapsed}s" }
  }

  if ($reason -eq 'unknown') {
    Initialize-Native

    $fg = Get-ForegroundInfo
    if ($SimulateForeground) { $fg.Name = $SimulateForeground; $fg.Class = '' }

    $isForeground = $false
    $matchBy = 'none'

    if ($fg.Pid -eq $PID) {
      $isForeground = $true; $matchBy = 'own-pid'
    } elseif ($cfg.terminalWindowClasses -contains $fg.Class) {
      $isForeground = $true; $matchBy = "window-class:$($fg.Class)"
    } elseif ($cfg.terminalProcesses -contains $fg.Name) {
      $isForeground = $true; $matchBy = "process-name:$($fg.Name)"
    } elseif ($cfg.checkAncestorNames -and $fg.Name) {
      foreach ($a in (Get-Ancestors)) {
        if ($a.Name -eq $fg.Name) { $isForeground = $true; $matchBy = "ancestor-name:$($fg.Name)"; break }
      }
    }

    Write-Log ("fg pid=$($fg.Pid) name='$($fg.Name)' class='$($fg.Class)' match=$matchBy elapsed=${elapsed}s")

    if ($TestToast) {
      $decision = 'notify'; $reason = 'test-toast'
    } elseif ($isForeground) {
      $reason = "foreground:$matchBy"
    } else {
      $decision = 'notify'; $reason = "background(fg=$($fg.Name))"
    }
  }

  if ($decision -eq 'notify') {
    $toolId   = Resolve-ToolId
    $toolDisp = Get-ToolDisplay $toolId
    $elapsedText = Get-ElapsedText -seconds ([math]::Max($elapsed, 0))

    $titleText = ([string]$cfg.title).Replace('{tool}', $toolDisp.displayName)
    $bodyText  = ([string]$cfg.body).Replace('{elapsed}', $elapsedText).Replace('{tool}', $toolDisp.displayName)

    Write-Log "notify: tool=$toolId appId=$($toolDisp.appId) reason=$reason"
    if (-not $DryRun) {
      try {
        Register-AppId -appId $toolDisp.appId -displayName $toolDisp.displayName
        Show-Toast -appId $toolDisp.appId -title $titleText -bodyText $bodyText
      } catch {
        Write-Log "toast failed: $($_.Exception.Message)"
        if ($cfg.fallbackSound) {
          try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
        }
      }
    }
  }

} catch {
  Write-Log "unhandled: $($_.Exception.Message)"
}

if ($DryRun) {
  [pscustomobject]@{
    decision        = $decision
    reason          = $reason
    elapsedSeconds  = $elapsed
    tool            = $toolId
    toolDisplayName = if ($toolDisp) { $toolDisp.displayName } else { '' }
    appId           = if ($toolDisp) { $toolDisp.appId } else { '' }
    foregroundPid   = if ($fg) { $fg.Pid } else { 0 }
    foregroundName  = if ($fg) { $fg.Name } else { '' }
    foregroundClass = if ($fg) { $fg.Class } else { '' }
    threshold       = [int]$cfg.thresholdSeconds
  } | ConvertTo-Json -Compress
}

exit 0
