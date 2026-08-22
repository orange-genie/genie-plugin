# Orange Genie — native Windows install. No WSL, no admin, no pip, no account.
#
#   irm https://raw.githubusercontent.com/orange-genie/genie-plugin/main/cli/install.ps1 | iex
#
# WHY `irm | iex` AND NOT A .ps1 FILE
# ----------------------------------
# ExecutionPolicy governs script FILES on disk. It does not govern a string handed to
# Invoke-Expression. So this one-liner runs on a locked-down machine where saving and running
# install.ps1 would be blocked — and, critically, where writing a `function genie` into the
# user's PowerShell PROFILE is also blocked, because a profile is a script file. That profile
# trick was the old Windows path and it is exactly why a real user hit
# "cannot be loaded because running scripts is disabled on this system".
#
# The fix is a genie.cmd SHIM on PATH. A .cmd is not a PowerShell script, so ExecutionPolicy
# never applies to it, and it works from PowerShell, cmd.exe, VS Code and Task Scheduler alike.
#
# PATH is written to HKCU:\Environment (the real user PATH) and then broadcast with
# WM_SETTINGCHANGE, so already-open windows learn about it. $env:PATH is also updated so the
# CURRENT window works immediately — an installer that needs a restart to prove it worked
# reads as an installer that failed.

$ErrorActionPreference = 'Stop'

$Raw    = 'https://raw.githubusercontent.com/orange-genie/genie-plugin/main'
$Root   = Join-Path $env:USERPROFILE '.orangegenie'
$Dir    = Join-Path $Root 'cli'
$BinDir = Join-Path $Root 'bin'

Write-Host ''
Write-Host '  Orange Genie - Windows install' -ForegroundColor DarkYellow
Write-Host ''

# ── 1. find a real Python ────────────────────────────────────────────────────────────────
# Windows ships a STUB python.exe that only opens the Microsoft Store. It sits on PATH by
# default, so `Get-Command python` succeeds on a machine with no Python at all. The only
# honest test is to RUN the candidate and see whether it executes code. The stub lives under
# WindowsApps, so that path is treated as a miss.
# (chain: cross-platform-python-resolver-in-bash-scripts — same py -3/python3/python ladder.)
#
# Candidates carry their args EXPLICITLY. Slicing with $cand[1..($cand.Length-1)] looks
# equivalent and is not: on a one-element array that range counts DOWN (1..0), so PowerShell
# returns $null plus element 0 — and the exe name comes back as its own argument. The probe
# then runs `python3 python3 -c ...`, fails, and the installer reports "Python not found" on
# a machine that HAS Python. Caught by running the real parser, not by reading the code.
function Find-Python {
  $candidates = @(
    [pscustomobject]@{ Exe = 'py';      Pre = @('-3') },
    [pscustomobject]@{ Exe = 'python3'; Pre = @()     },
    [pscustomobject]@{ Exe = 'python';  Pre = @()     }
  )
  foreach ($c in $candidates) {
    $exe = $c.Exe
    $pre = $c.Pre
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
    try {
      $probe = & $exe @pre -c "import sys;print(sys.executable)" 2>$null
      if ($LASTEXITCODE -eq 0 -and $probe -and $probe -notmatch 'WindowsApps') {
        return [pscustomobject]@{ Exe = $exe; Pre = $pre; Path = ($probe | Select-Object -First 1) }
      }
    } catch { }
  }
  return $null
}

$py = Find-Python
if (-not $py) {
  Write-Host '  x Python 3 is required and was not found.' -ForegroundColor Red
  Write-Host ''
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host '    Install it (no admin needed), then run this same command again:'
    Write-Host '      winget install Python.Python.3.13 --scope user' -ForegroundColor Cyan
  } else {
    Write-Host '    Install it from https://www.python.org/downloads/'
    Write-Host '    Tick "Add python.exe to PATH" in the installer.'
  }
  Write-Host ''
  Write-Host '    If typing `python` opens the Microsoft Store, that is a placeholder,'
  Write-Host '    not Python. Installing properly replaces it.'
  return
}
$ver = & $py.Exe @($py.Pre) -c "import platform;print(platform.python_version())" 2>$null
Write-Host "  + python $ver"

# ── 2. fetch the parts ───────────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $Dir, $BinDir | Out-Null

# chain.py is what makes this work without bash. chain.sh and genie_onboard.sh are still
# fetched so a machine that later gains bash (WSL, Git Bash) has the full set — but nothing
# on the Windows path depends on them.
$files = @(
  @{ r = 'cli/genie';                            l = 'genie'            },
  @{ r = 'plugins/genie/tools/brain.py';         l = 'brain.py'         },
  @{ r = 'plugins/genie/tools/chain.py';         l = 'chain.py'         },
  @{ r = 'plugins/genie/tools/chain.sh';         l = 'chain.sh'         },
  @{ r = 'plugins/genie/tools/genie_llm.py';     l = 'genie_llm.py'     },
  @{ r = 'plugins/genie/tools/genie_onboard.sh'; l = 'genie_onboard.sh' },
  @{ r = 'plugins/genie/skills/wake/canon.md';   l = 'canon.md'         }
)
foreach ($f in $files) {
  try {
    Invoke-WebRequest -Uri "$Raw/$($f.r)" -OutFile (Join-Path $Dir $f.l) -UseBasicParsing
    Write-Host "  + $($f.l)"
  } catch {
    Write-Host "  x could not fetch $($f.l) - $($_.Exception.Message)" -ForegroundColor Red
    return
  }
}

# ── 3. the shim ──────────────────────────────────────────────────────────────────────────
# The python path is baked in because PATH order on Windows is not something an installer
# gets to assume — and because the Store stub may still be sitting ahead of the real Python.
$genieScript = Join-Path $Dir 'genie'
$cmd = @"
@echo off
"$($py.Path)" "$genieScript" %*
"@
Set-Content -Path (Join-Path $BinDir 'genie.cmd') -Value $cmd -Encoding ASCII
Write-Host '  + genie.cmd'

# ── 4. PATH: registry (persistent) + broadcast (open windows) + session (this window) ─────
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $BinDir) {
  $new = if ($userPath.TrimEnd(';')) { $userPath.TrimEnd(';') + ';' + $BinDir } else { $BinDir }
  [Environment]::SetEnvironmentVariable('Path', $new, 'User')
  Write-Host '  + added to your PATH'
}
if (($env:PATH -split ';') -notcontains $BinDir) { $env:PATH = "$env:PATH;$BinDir" }

# Tell already-open windows their environment changed. Without this the user opens a NEW
# terminal and genie works — but every window they already had open still fails, which reads
# as a flaky install.
try {
  if (-not ('Native.W32' -as [type])) {
    Add-Type -Namespace Native -Name W32 -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
  string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
  }
  $res = [UIntPtr]::Zero
  [Native.W32]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero,
                                   'Environment', 2, 5000, [ref]$res) | Out-Null
} catch { }

# ── 5. prove it runs ─────────────────────────────────────────────────────────────────────
Write-Host ''
try {
  & (Join-Path $BinDir 'genie.cmd') providers
} catch {
  Write-Host "  ! installed, but the first run failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Installed. Claim your name on the network:' -ForegroundColor DarkYellow
Write-Host ''
Write-Host '     genie login "the-name-you-want"' -ForegroundColor Cyan
Write-Host ''
Write-Host '   Then ask it anything:'
Write-Host ''
Write-Host '     genie "what is proof-of-availability?"' -ForegroundColor Cyan
Write-Host '     genie recall launchd'
Write-Host ''
Write-Host '   Update any time with: genie update'
Write-Host ''
