param(
    [Parameter(Mandatory = $true)]
    [string]$HookName
)

$ErrorActionPreference = 'SilentlyContinue'

$NODE_EXE = (Get-Command node -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($NODE_EXE)) {
    $fallbackNode = 'C:\Program Files\nodejs\node.exe'
    if (Test-Path -LiteralPath $fallbackNode) {
        $NODE_EXE = $fallbackNode
    }
}
$NOTIFIER = Join-Path $PSScriptRoot 'notifier.js'
$PET_SCRIPT = Join-Path $PSScriptRoot 'pet.ps1'
$REGISTRY_FILE = [System.IO.Path]::Combine($env:TEMP, 'claude-wt-pets-registry.json')
$TRANSITION_LOG = [System.IO.Path]::Combine($env:TEMP, 'claude-wt-pets-transition.log')
$MAX_SLOTS = 4

if ($env:CLAUDE_WT_PETS_DISABLED -eq '1') {
    [void][Console]::In.ReadToEnd()
    exit 0
}

if ([string]::IsNullOrWhiteSpace($NODE_EXE)) {
    [void][Console]::In.ReadToEnd()
    exit 0
}

function Ensure-OwnerWindowProbeType {
    $typeName = 'ClaudeWtPets.OwnerWindowProbe'
    if (([System.Management.Automation.PSTypeName]$typeName).Type) { return }

    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeWtPets {
    public class TerminalWindowInfo {
        public long Hwnd { get; set; }
        public int ProcessId { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Right { get; set; }
        public int Bottom { get; set; }
        public int Width { get { return Right - Left; } }
        public int Height { get { return Bottom - Top; } }
    }

    public static class OwnerWindowProbe {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

        public static IntPtr GetRootWindow(IntPtr hwnd) {
            return GetAncestor(hwnd, 2);
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll")]
        public static extern int GetWindowTextLength(IntPtr hWnd);

        public static string GetWindowTitle(long hwndValue) {
            var hwnd = new IntPtr(hwndValue);
            int length = GetWindowTextLength(hwnd);
            if (length <= 0) return "";
            var sb = new StringBuilder(length + 1);
            GetWindowText(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static int GetProcessId(long hwndValue) {
            uint processId;
            GetWindowThreadProcessId(new IntPtr(hwndValue), out processId);
            return (int)processId;
        }

        public static bool IsVisibleTerminalWindow(long hwndValue) {
            var hwnd = new IntPtr(hwndValue);
            if (!IsWindow(hwnd) || !IsWindowVisible(hwnd)) return false;

            var className = new StringBuilder(256);
            GetClassName(hwnd, className, className.Capacity);
            return className.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS";
        }

        public static TerminalWindowInfo[] FindVisibleTerminalWindows() {
            var windows = new List<TerminalWindowInfo>();
            EnumWindows((hWnd, lParam) => {
                if (!IsWindow(hWnd) || !IsWindowVisible(hWnd)) return true;

                var className = new StringBuilder(256);
                GetClassName(hWnd, className, className.Capacity);
                if (className.ToString() != "CASCADIA_HOSTING_WINDOW_CLASS") return true;

                uint processId;
                GetWindowThreadProcessId(hWnd, out processId);

                RECT rect;
                if (!GetWindowRect(hWnd, out rect)) return true;

                windows.Add(new TerminalWindowInfo {
                    Hwnd = hWnd.ToInt64(),
                    ProcessId = (int)processId,
                    Left = rect.Left,
                    Top = rect.Top,
                    Right = rect.Right,
                    Bottom = rect.Bottom
                });
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool FreeConsole();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AttachConsole(uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool SetConsoleTitle(string lpConsoleTitle);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern uint GetConsoleTitle(StringBuilder lpConsoleTitle, uint nSize);

        public static string ReadConsoleTitle() {
            var sb = new StringBuilder(1024);
            uint len = GetConsoleTitle(sb, (uint)sb.Capacity);
            return len > 0 ? sb.ToString() : "";
        }
    }
}
"@
}

function Test-WtPetsSupportedEnvironment {
    if ([string]::IsNullOrWhiteSpace($env:CLAUDE_WT_PETS_SESSION_PID)) { return $false }

    try {
        $sessionProc = Get-Process -Id ([int]$env:CLAUDE_WT_PETS_SESSION_PID) -ErrorAction SilentlyContinue
        if (-not $sessionProc -or $sessionProc.ProcessName -ne 'claude') { return $false }
    } catch { return $false }

    try {
        $parentPid = [ClaudeWtPets.ProcessParent]::GetParentProcessId([int]$env:CLAUDE_WT_PETS_SESSION_PID)
        if ($parentPid -le 0) { return $false }
        $parentProc = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
        if (-not $parentProc) { return $false }
        if (@('powershell', 'pwsh') -notcontains $parentProc.ProcessName.ToLowerInvariant()) { return $false }
    } catch { return $false }

    try {
        Ensure-OwnerWindowProbeType
        $windows = [ClaudeWtPets.OwnerWindowProbe]::FindVisibleTerminalWindows()
        if ($null -eq $windows -or $windows.Count -eq 0) { return $false }
    } catch { return $false }

    return $true
}

function Get-ForegroundInfo {
    try {
        Ensure-OwnerWindowProbeType
        $hwnd = [ClaudeWtPets.OwnerWindowProbe]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $null }

        $root = [ClaudeWtPets.OwnerWindowProbe]::GetRootWindow($hwnd)
        if ($root -ne [IntPtr]::Zero) { $hwnd = $root }

        [uint32]$foregroundPid = 0
        [void][ClaudeWtPets.OwnerWindowProbe]::GetWindowThreadProcessId($hwnd, [ref]$foregroundPid)
        if ($foregroundPid -le 0) { return $null }

        $proc = Get-Process -Id ([int]$foregroundPid) -ErrorAction SilentlyContinue
        if (-not $proc) { return $null }

        return [pscustomobject]@{
            Hwnd = [Int64]$hwnd.ToInt64()
            Pid = [int]$proc.Id
            Name = $proc.ProcessName
        }
    } catch {}

    return $null
}

function Get-OwnerProbeJson {
    $probe = [ordered]@{
        foreground_hwnd = 0
        foreground_pid = 0
        foreground_name = ''
        matched_hwnd = 0
        tab_title = ''
        visible_windows = @()
    }

    try {
        $fg = Get-ForegroundInfo
        if ($fg) {
            $probe.foreground_hwnd = $fg.Hwnd
            $probe.foreground_pid = $fg.Pid
            $probe.foreground_name = $fg.Name
        }
    } catch {}

    try {
        Ensure-OwnerWindowProbeType
        $windows = [ClaudeWtPets.OwnerWindowProbe]::FindVisibleTerminalWindows()
        $windowList = @()
        $preMarkerTitles = @{}
        foreach ($w in $windows) {
            $wt = [ClaudeWtPets.OwnerWindowProbe]::GetWindowTitle([Int64]$w.Hwnd)
            if ($wt) { $preMarkerTitles[[string]$w.Hwnd] = $wt }
            $windowList += [ordered]@{
                hwnd = [Int64]$w.Hwnd
                pid = [int]$w.ProcessId
                left = $w.Left
                top = $w.Top
                title = $wt
            }
        }
        $probe.visible_windows = $windowList

        if ($probe.foreground_hwnd -gt 0 -and $probe.foreground_name -eq 'WindowsTerminal') {
            $fgInList = $false
            foreach ($w in $windows) {
                if ([Int64]$w.Hwnd -eq $probe.foreground_hwnd) { $fgInList = $true; break }
            }
            if (-not $fgInList) {
                foreach ($w in $windows) {
                    if ([int]$w.ProcessId -eq $probe.foreground_pid) {
                        $probe.foreground_hwnd = [Int64]$w.Hwnd
                        break
                    }
                }
            }
        }

        if ($windows.Count -eq 1) {
            $probe.matched_hwnd = [Int64]$windows[0].Hwnd
            $savedTitle = $preMarkerTitles[[string]$windows[0].Hwnd]
            if ($savedTitle) { $probe.tab_title = $savedTitle }
        } else {
            $parentPid = 0
            if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_WT_PETS_SESSION_PARENT_PID)) {
                try { $parentPid = [int]$env:CLAUDE_WT_PETS_SESSION_PARENT_PID } catch {}
            }
            if ($parentPid -gt 0) {
                $marker = "__claude_wt_pets_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
                $restoreTitle = ''
                try {
                    [void][ClaudeWtPets.OwnerWindowProbe]::FreeConsole()
                    if ([ClaudeWtPets.OwnerWindowProbe]::AttachConsole([uint32]$parentPid)) {
                        $restoreTitle = [ClaudeWtPets.OwnerWindowProbe]::ReadConsoleTitle()
                        [void][ClaudeWtPets.OwnerWindowProbe]::SetConsoleTitle($marker)
                        for ($attempt = 0; $attempt -lt 5 -and $probe.matched_hwnd -le 0; $attempt++) {
                            if ($attempt -eq 0) { [System.Threading.Thread]::Sleep(15) }
                            else { [System.Threading.Thread]::Sleep(30) }
                            foreach ($w in $windows) {
                                $title = [ClaudeWtPets.OwnerWindowProbe]::GetWindowTitle([Int64]$w.Hwnd)
                                if ($title -and $title.Contains($marker)) {
                                    $probe.matched_hwnd = [Int64]$w.Hwnd
                                    $savedTitle = $preMarkerTitles[[string]$w.Hwnd]
                                    if ($savedTitle) { $probe.tab_title = $savedTitle }
                                    break
                                }
                            }
                        }
                    } else {
                        Write-TransitionLog 'probe-attach-failed' 0 "parent_pid=$parentPid"
                    }
                } finally {
                    try {
                        if (-not [string]::IsNullOrWhiteSpace($restoreTitle)) {
                            [void][ClaudeWtPets.OwnerWindowProbe]::SetConsoleTitle($restoreTitle)
                        }
                    } catch {}
                    try { [void][ClaudeWtPets.OwnerWindowProbe]::FreeConsole() } catch {}
                }
            }
            if ($probe.matched_hwnd -le 0) {
                if ($probe.foreground_hwnd -gt 0) {
                    $fgTitle = $preMarkerTitles[[string]$probe.foreground_hwnd]
                    if ($fgTitle) { $probe.tab_title = $fgTitle }
                }
                Write-TransitionLog 'probe-marker-miss' 0 "windows=$($windows.Count);fg=$($probe.foreground_hwnd);fg_name=$($probe.foreground_name);parent_pid=$parentPid"
            }
        }
    } catch {}

    return ($probe | ConvertTo-Json -Compress -Depth 5)
}

function Set-SessionProcessEnv {
    try {
        $typeName = 'ClaudeWtPets.ProcessParent'
        if (-not ([System.Management.Automation.PSTypeName]$typeName).Type) {
            Add-Type @"
using System;
using System.Runtime.InteropServices;

namespace ClaudeWtPets {
    public static class ProcessParent {
        private const uint TH32CS_SNAPPROCESS = 0x00000002;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private struct PROCESSENTRY32 {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool Process32First(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool Process32Next(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        public static int GetParentProcessId(int processId) {
            IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) return 0;

            try {
                PROCESSENTRY32 entry = new PROCESSENTRY32();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                if (!Process32First(snapshot, ref entry)) return 0;

                do {
                    if (entry.th32ProcessID == (uint)processId) {
                        return (int)entry.th32ParentProcessID;
                    }
                } while (Process32Next(snapshot, ref entry));
            } finally {
                CloseHandle(snapshot);
            }

            return 0;
        }
    }
}
"@
        }

        $seen = @{}
        $currentProcessId = $PID

        for ($i = 0; $i -lt 12; $i++) {
            $parentProcessId = [ClaudeWtPets.ProcessParent]::GetParentProcessId($currentProcessId)
            if ($parentProcessId -le 0) { return }
            if ($seen.ContainsKey([string]$parentProcessId)) { return }
            $seen[[string]$parentProcessId] = $true

            $parent = Get-Process -Id $parentProcessId -ErrorAction SilentlyContinue
            if (-not $parent) { return }

            if ($parent.ProcessName -eq 'claude') {
                $env:CLAUDE_WT_PETS_SESSION_PID = [string]$parent.Id
                $env:CLAUDE_WT_PETS_SESSION_NAME = $parent.ProcessName
                $claudeParentPid = [ClaudeWtPets.ProcessParent]::GetParentProcessId($parent.Id)
                if ($claudeParentPid -gt 0) {
                    $env:CLAUDE_WT_PETS_SESSION_PARENT_PID = [string]$claudeParentPid
                }
                return
            }

            $currentProcessId = $parentProcessId
        }
    } catch {}
}

function Write-TransitionLog($action, [int]$slot = 0, [string]$detail = '') {
    try {
        $payload = [ordered]@{
            ts = [DateTimeOffset]::Now.ToString('o')
            source = 'hook-entry'
            action = $action
            hook = $HookName
        }
        if ($slot -gt 0) { $payload['slot'] = $slot }
        if (-not [string]::IsNullOrWhiteSpace($detail)) { $payload['detail'] = $detail }
        Add-Content -LiteralPath $TRANSITION_LOG -Encoding UTF8 -Value ($payload | ConvertTo-Json -Compress -Depth 5)
    } catch {}
}

function Get-HookSessionId([string]$inputText) {
    try {
        if ([string]::IsNullOrWhiteSpace($inputText)) { return '' }
        $event = $inputText | ConvertFrom-Json
        foreach ($name in @('session_id', 'sessionId')) {
            if ($event.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$event.$name)) {
                return [string]$event.$name
            }
        }
        if ($event.session -and $event.session.PSObject.Properties['id']) {
            return [string]$event.session.id
        }
    } catch {}
    return ''
}

function Get-WtPetsSlotForCurrentHook([string]$inputText) {
    try {
        if (-not (Test-Path -LiteralPath $REGISTRY_FILE)) { return 0 }
        $registry = Get-Content -LiteralPath $REGISTRY_FILE -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $sessionId = Get-HookSessionId $inputText

        if (-not [string]::IsNullOrWhiteSpace($sessionId) -and $registry.PSObject.Properties[$sessionId]) {
            return [int]$registry.PSObject.Properties[$sessionId].Value.slot
        }

        $sessionPid = 0
        if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_WT_PETS_SESSION_PID)) {
            $sessionPid = [int]$env:CLAUDE_WT_PETS_SESSION_PID
        }

        foreach ($property in $registry.PSObject.Properties) {
            $value = $property.Value
            if ($sessionPid -gt 0 -and [int]$value.session_pid -eq $sessionPid) {
                return [int]$value.slot
            }
        }
    } catch {}
    return 0
}

function Start-WtPetsPetFallback([int]$slot) {
    if ($slot -lt 1 -or $slot -gt 4) { return }
    if (-not (Test-Path -LiteralPath $PET_SCRIPT)) { return }

    $pidFile = [System.IO.Path]::Combine($env:TEMP, "claude-wt-pets-pet-$slot.pid")
    try {
        if (Test-Path -LiteralPath $pidFile) {
            $existingPid = [int]((Get-Content -LiteralPath $pidFile -Raw -Encoding ASCII).Trim())
            if ($existingPid -gt 0 -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
                return
            }
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            Write-TransitionLog 'hook-remove-stale-pet-pid' $slot ([string]$existingPid)
        }
    } catch {}

    try {
        $envVars = [Environment]::GetEnvironmentVariables('Process')
        if ($envVars.Contains('Path') -and $envVars.Contains('PATH')) {
            [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
        }
    } catch {}

    try {
        $powerShellExe = Join-Path $PSHOME 'powershell.exe'
        $launchArgs = @(
            '-NoProfile',
            '-WindowStyle', 'Hidden',
            '-STA',
            '-ExecutionPolicy', 'RemoteSigned',
            '-File', "`"$PET_SCRIPT`"",
            '-Slot', [string]$slot
        )
        Write-TransitionLog 'hook-launch-pet' $slot
        $shell = New-Object -ComObject Shell.Application
        $shell.ShellExecute($powerShellExe, ($launchArgs -join ' '), '', 'open', 0)
        Write-TransitionLog 'hook-launch-pet-shellexecute-hidden' $slot
    } catch {
        Write-TransitionLog 'hook-launch-pet-error' $slot ([string]$_.Exception.Message)
    }
}

# --- main flow ---

$inputText = [Console]::In.ReadToEnd()
Set-SessionProcessEnv

if (-not (Test-WtPetsSupportedEnvironment)) {
    $fgName = ''
    try {
        $fgInfo = Get-ForegroundInfo
        if ($fgInfo) { $fgName = $fgInfo.Name }
    } catch {}
    Write-TransitionLog 'skip-unsupported-environment' 0 "foreground_name=$fgName;session_pid=$($env:CLAUDE_WT_PETS_SESSION_PID)"
    exit 0
}

if (@('SessionStart', 'UserPromptSubmit', 'PreToolUse') -contains $HookName) {
    $env:CLAUDE_WT_PETS_OWNER_PROBE = Get-OwnerProbeJson
    if ($HookName -eq 'SessionStart') {
        $probeData = $null
        try { $probeData = $env:CLAUDE_WT_PETS_OWNER_PROBE | ConvertFrom-Json } catch {}
        if ($probeData -and [Int64]$probeData.matched_hwnd -le 0) {
            [System.Threading.Thread]::Sleep(250)
            $env:CLAUDE_WT_PETS_OWNER_PROBE = Get-OwnerProbeJson
            Write-TransitionLog 'probe-sessionstart-retry' 0 ''
        }
    }
}

try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $NODE_EXE
    $psi.Arguments = '"' + $NOTIFIER + '" ' + $HookName
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Write($inputText)
    $proc.StandardInput.Close()

    if (-not $proc.WaitForExit(10000)) {
        try { $proc.Kill() } catch {}
        try { [void]$proc.WaitForExit(1000) } catch {}
    }

    try { [void]$stdoutTask.Wait(1000) } catch {}
    try { [void]$stderrTask.Wait(1000) } catch {}
} catch {}

try {
    $slot = Get-WtPetsSlotForCurrentHook $inputText
    Start-WtPetsPetFallback $slot
} catch {}

if ($slot -ge 1 -and $slot -le 4 -and @('SessionStart', 'UserPromptSubmit', 'PreToolUse') -contains $HookName) {
    $parentPid = 0
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_WT_PETS_SESSION_PARENT_PID)) {
        try { $parentPid = [int]$env:CLAUDE_WT_PETS_SESSION_PARENT_PID } catch {}
    }
    if ($parentPid -gt 0) {
        try {
            Ensure-OwnerWindowProbeType
            [void][ClaudeWtPets.OwnerWindowProbe]::FreeConsole()
            if ([ClaudeWtPets.OwnerWindowProbe]::AttachConsole([uint32]$parentPid)) {
                [void][ClaudeWtPets.OwnerWindowProbe]::SetConsoleTitle("Claude #$slot")
            }
        } finally {
            try { [void][ClaudeWtPets.OwnerWindowProbe]::FreeConsole() } catch {}
        }
    }
}

exit 0
