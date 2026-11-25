# Blazma Tweak - engine: registry, services, scheduled tasks, backups, memory, cleanup, power, network.
# Loaded into the UI thread and into every background runspace. Keep this file free of UI code.
# $BTDir (data folder) and $BTDryRun (log instead of writing) are set by the caller.

function Write-BTLog([string]$Message) {
    try {
        if (-not (Test-Path $BTDir)) { New-Item -ItemType Directory -Path $BTDir -Force | Out-Null }
        $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
        Add-Content -Path (Join-Path $BTDir 'log.txt') -Value $line -Encoding UTF8
    } catch { }
}

# ------------------------------------------------------------------ registry
# Paths look like "HKLM\SOFTWARE\...". The .NET API is used instead of the PowerShell provider so
# value kinds, default values ("" name) and 64-bit views are handled exactly.
function Split-BTRegPath([string]$Path) {
    $i = $Path.IndexOf('\')
    $hiveName = if ($i -lt 0) { $Path } else { $Path.Substring(0, $i) }
    $sub = if ($i -lt 0) { '' } else { $Path.Substring($i + 1) }
    $hive = switch ($hiveName.ToUpperInvariant()) {
        'HKLM' { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKCU' { [Microsoft.Win32.RegistryHive]::CurrentUser }
        'HKU'  { [Microsoft.Win32.RegistryHive]::Users }
        'HKCR' { [Microsoft.Win32.RegistryHive]::ClassesRoot }
        default { throw "Unknown registry hive in $Path" }
    }
    [pscustomobject]@{ Hive = $hive; Sub = $sub }
}

function Open-BTRegBase($Hive) { [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64) }

function ConvertTo-BTRegData([string]$Type, $Value) {
    switch ($Type) {
        'DWord'        { return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32][double]$Value), 0) }
        'QWord'        { return [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64][double]$Value), 0) }
        'Binary'       { return , ([byte[]]@(($Value -split '[\s,]+' | Where-Object { $_ }) | ForEach-Object { [Convert]::ToByte($_, 16) })) }
        'MultiString'  { return , ([string[]]@($Value)) }
        default        { return [string]$Value }
    }
}

# Normalised form used to compare and to store in backups (JSON friendly).
function ConvertFrom-BTRegData($Data, $Kind) {
    switch ([string]$Kind) {
        'DWord'  { return [double][BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$Data), 0) }
        'QWord'  { return [double][BitConverter]::ToUInt64([BitConverter]::GetBytes([int64]$Data), 0) }
        'Binary' { return (($Data | ForEach-Object { '{0:x2}' -f $_ }) -join ' ') }
        'MultiString' { return , @($Data) }
        default  { return [string]$Data }
    }
}

function Get-BTRegValue([string]$Path, [string]$Name) {
    $p = Split-BTRegPath $Path
    $base = Open-BTRegBase $p.Hive
    try {
        $key = $base.OpenSubKey($p.Sub, $false)
        if (-not $key) { return [pscustomobject]@{ KeyExists = $false; Exists = $false; Kind = $null; Value = $null } }
        try {
            if (@($key.GetValueNames()) -notcontains $Name) {
                return [pscustomobject]@{ KeyExists = $true; Exists = $false; Kind = $null; Value = $null }
            }
            $kind = $key.GetValueKind($Name).ToString()
            $raw = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [pscustomobject]@{ KeyExists = $true; Exists = $true; Kind = $kind; Value = (ConvertFrom-BTRegData $raw $kind) }
        } finally { $key.Close() }
    } finally { $base.Close() }
}

# The first key on the path that does not exist yet (so undo can remove exactly what we created).
function Get-BTMissingKey([string]$Path) {
    $p = Split-BTRegPath $Path
    $base = Open-BTRegBase $p.Hive
    try {
        $parts = $p.Sub -split '\\'
        $hiveName = $Path.Substring(0, $Path.IndexOf('\'))
        for ($n = 1; $n -le $parts.Count; $n++) {
            $sub = ($parts[0..($n - 1)] -join '\')
            $k = $base.OpenSubKey($sub, $false)
            if (-not $k) { return "$hiveName\$sub" }
            $k.Close()
        }
        return $null
    } finally { $base.Close() }
}

function Set-BTRegValue([string]$Path, [string]$Name, [string]$Type, $Value) {
    if ($BTDryRun) { Write-BTLog "DRY set $Path [$Name] = $Value ($Type)"; return }
    $p = Split-BTRegPath $Path
    $base = Open-BTRegBase $p.Hive
    try {
        $key = $base.CreateSubKey($p.Sub, $true)
        try {
            $kind = [Microsoft.Win32.RegistryValueKind]$Type
            $key.SetValue($Name, (ConvertTo-BTRegData $Type $Value), $kind)
        } finally { $key.Close() }
    } finally { $base.Close() }
}

function Remove-BTRegValue([string]$Path, [string]$Name) {
    if ($BTDryRun) { Write-BTLog "DRY delete $Path [$Name]"; return }
    $p = Split-BTRegPath $Path
    $base = Open-BTRegBase $p.Hive
    try {
        $key = $base.OpenSubKey($p.Sub, $true)
        if ($key) { try { $key.DeleteValue($Name, $false) } finally { $key.Close() } }
    } finally { $base.Close() }
}

function Remove-BTRegKey([string]$Path) {
    if ($BTDryRun) { Write-BTLog "DRY delete key $Path"; return }
    $p = Split-BTRegPath $Path
    $base = Open-BTRegBase $p.Hive
    try { $base.DeleteSubKeyTree($p.Sub, $false) } finally { $base.Close() }
}

function Test-BTRegMatch($Entry) {
    $cur = Get-BTRegValue $Entry.path $Entry.name
    if (-not $cur.Exists) { return $false }
    $want = ConvertFrom-BTRegData (ConvertTo-BTRegData $Entry.type $Entry.value) $Entry.type
    if ($Entry.type -eq 'MultiString') { return ((@($cur.Value) -join "`n") -eq (@($want) -join "`n")) }
    return ([string]$cur.Value -eq [string]$want)
}

# ------------------------------------------------------------------ services
$script:BTStartNames = @{ 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled'; 0 = 'Boot'; 1 = 'System' }

function Get-BTServiceStart([string]$Name) {
    $v = Get-BTRegValue "HKLM\SYSTEM\CurrentControlSet\Services\$Name" 'Start'
    if (-not $v.Exists) { return $null }
    $start = $script:BTStartNames[[int]$v.Value]
    if ($start -eq 'Automatic') {
        $d = Get-BTRegValue "HKLM\SYSTEM\CurrentControlSet\Services\$Name" 'DelayedAutostart'
        if ($d.Exists -and [int]$d.Value -eq 1) { $start = 'AutomaticDelayed' }
    }
    $start
}

function Set-BTServiceStart([string]$Name, [string]$Start) {
    if ($null -eq (Get-BTServiceStart $Name)) { return }
    if ($BTDryRun) { Write-BTLog "DRY service $Name -> $Start"; return }
    $arg = @{ Automatic = 'auto'; AutomaticDelayed = 'delayed-auto'; Manual = 'demand'; Disabled = 'disabled' }[$Start]
    if (-not $arg) { return }
    & sc.exe config $Name start= $arg | Out-Null
    if ($Start -eq 'Disabled') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ scheduled tasks
function Get-BTTaskEnabled([string]$Path, [string]$Name) {
    $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    return ($t.State -ne 'Disabled')
}

function Set-BTTaskEnabled([string]$Path, [string]$Name, [bool]$Enabled) {
    if ($null -eq (Get-BTTaskEnabled $Path $Name)) { return }
    if ($BTDryRun) { Write-BTLog "DRY task $Path$Name enabled=$Enabled"; return }
    if ($Enabled) { Enable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue | Out-Null }
    else { Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue | Out-Null }
}

# ------------------------------------------------------------------ backups
function Get-BTBackupFile { Join-Path $BTDir 'backup.json' }

function Read-BTBackup {
    $f = Get-BTBackupFile
    $h = @{}
    if (Test-Path $f) {
        try {
            $o = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch { Write-BTLog "backup.json could not be read: $_" }
    }
    $h
}

function Save-BTBackup($Table) {
    if ($BTDryRun) { return }
    if (-not (Test-Path $BTDir)) { New-Item -ItemType Directory -Path $BTDir -Force | Out-Null }
    $o = [ordered]@{}
    foreach ($k in ($Table.Keys | Sort-Object)) { $o[$k] = $Table[$k] }
    [IO.File]::WriteAllText((Get-BTBackupFile), ($o | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}

function New-BTSnapshot($Tweak) {
    $reg = @(foreach ($e in @($Tweak.reg)) { if (-not $e) { continue }
        $cur = Get-BTRegValue $e.path $e.name
        [pscustomobject]@{ path = $e.path; name = $e.name; existed = $cur.Exists; kind = $cur.Kind; value = $cur.Value; createdKey = (Get-BTMissingKey $e.path) } })
    $svc = @(foreach ($s in @($Tweak.svc)) { if (-not $s) { continue }
        [pscustomobject]@{ name = $s.name; start = (Get-BTServiceStart $s.name) } })
    $tsk = @(foreach ($t in @($Tweak.task)) { if (-not $t) { continue }
        [pscustomobject]@{ path = $t.path; name = $t.name; enabled = (Get-BTTaskEnabled $t.path $t.name) } })
    [pscustomobject]@{ time = (Get-Date).ToString('s'); reg = $reg; svc = $svc; task = $tsk }
}

# ------------------------------------------------------------------ tweaks
function Invoke-BTScript([string]$Code) {
    if (-not $Code) { return }
    if ($BTDryRun) { Write-BTLog "DRY script: $Code"; return }
    & ([scriptblock]::Create($Code))
}

# Returns 'on', 'off' or 'partial'.
function Get-BTTweakState($Tweak) {
    $checks = New-Object System.Collections.Generic.List[bool]
    foreach ($e in @($Tweak.reg)) { if ($e) { $checks.Add((Test-BTRegMatch $e)) } }
    foreach ($s in @($Tweak.svc)) { if ($s) { $cur = Get-BTServiceStart $s.name; if ($null -ne $cur) { $checks.Add($cur -eq $s.start) } } }
    foreach ($t in @($Tweak.task)) { if ($t) { $en = Get-BTTaskEnabled $t.path $t.name; if ($null -ne $en) { $checks.Add(-not $en) } } }
    if ($Tweak.detect) {
        try { $checks.Add([bool](& ([scriptblock]::Create($Tweak.detect)))) } catch { $checks.Add($false) }
    }
    if ($checks.Count -eq 0) { return 'off' }
    $on = @($checks | Where-Object { $_ }).Count
    if ($on -eq $checks.Count) { 'on' } elseif ($on -eq 0) { 'off' } else { 'partial' }
}

function Invoke-BTTweak($Tweak) {
    $backup = Read-BTBackup
    if (-not $backup.ContainsKey($Tweak.id)) {
        $backup[$Tweak.id] = New-BTSnapshot $Tweak
        Save-BTBackup $backup
    }
    foreach ($e in @($Tweak.reg)) { if ($e) { Set-BTRegValue $e.path $e.name $e.type $e.value } }
    foreach ($s in @($Tweak.svc)) { if ($s) { Set-BTServiceStart $s.name $s.start } }
    foreach ($t in @($Tweak.task)) { if ($t) { Set-BTTaskEnabled $t.path $t.name $false } }
    Invoke-BTScript $Tweak.apply
    Write-BTLog "applied $($Tweak.id)"
}

function Undo-BTTweak($Tweak) {
    $backup = Read-BTBackup
    $snap = $backup[$Tweak.id]
    foreach ($e in @($Tweak.reg)) {
        if (-not $e) { continue }
        $old = if ($snap) { @($snap.reg) | Where-Object { $_.path -eq $e.path -and $_.name -eq $e.name } | Select-Object -First 1 }
        if ($old) {
            if ($old.existed) { Set-BTRegValue $e.path $e.name $old.kind $(if ($old.kind -eq 'Binary' -or $old.kind -eq 'MultiString') { $old.value } else { $old.value }) }
            else {
                Remove-BTRegValue $e.path $e.name
                if ($old.createdKey) { Remove-BTRegKeyIfEmpty $old.createdKey $e.path }
            }
        } elseif ($null -ne $e.default) { Set-BTRegValue $e.path $e.name $e.type $e.default }
        else { Remove-BTRegValue $e.path $e.name }
    }
    foreach ($s in @($Tweak.svc)) {
        if (-not $s) { continue }
        $old = if ($snap) { @($snap.svc) | Where-Object { $_.name -eq $s.name } | Select-Object -First 1 }
        $start = if ($old -and $old.start) { $old.start } else { $s.default }
        if ($start) { Set-BTServiceStart $s.name $start }
    }
    foreach ($t in @($Tweak.task)) {
        if (-not $t) { continue }
        $old = if ($snap) { @($snap.task) | Where-Object { $_.path -eq $t.path -and $_.name -eq $t.name } | Select-Object -First 1 }
        if (-not $old -or $old.enabled -ne $false) { Set-BTTaskEnabled $t.path $t.name $true }
    }
    Invoke-BTScript $Tweak.undo
    if ($backup.ContainsKey($Tweak.id)) { $backup.Remove($Tweak.id); Save-BTBackup $backup }
    Write-BTLog "undone $($Tweak.id)"
}

# Removes a key we created, but only when nothing else was put inside it since.
function Remove-BTRegKeyIfEmpty([string]$Created, [string]$Leaf) {
    $p = Split-BTRegPath $Created
    $base = Open-BTRegBase $p.Hive
    try {
        $k = $base.OpenSubKey($p.Sub, $false)
        if (-not $k) { return }
        $empty = Test-BTKeyTreeEmpty $k
        $k.Close()
        if ($empty) { Remove-BTRegKey $Created }
    } finally { $base.Close() }
}

function Test-BTKeyTreeEmpty($Key) {
    if ($Key.ValueCount -gt 0) { return $false }
    foreach ($n in $Key.GetSubKeyNames()) {
        $c = $Key.OpenSubKey($n, $false)
        try { if (-not (Test-BTKeyTreeEmpty $c)) { return $false } } finally { $c.Close() }
    }
    return $true
}

function New-BTRestorePoint([string]$Description = 'Blazma Tweak') {
    if ($BTDryRun) { Write-BTLog 'DRY restore point'; return $true }
    try {
        # Windows allows one restore point per 24 hours unless this is 0.
        Set-BTRegValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 'DWord' 0
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-BTLog 'restore point created'
        return $true
    } catch { Write-BTLog "restore point failed: $_"; return $false }
}

function Restart-BTExplorer {
    if ($BTDryRun) { return }
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

# ------------------------------------------------------------------ memory
function Add-BTMemoryType {
    if ('BlazmaTweak.Memory' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace BlazmaTweak {
    public static class Memory {
        [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int infoClass, IntPtr info, int length);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string system, string name, out long luid);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, int length, IntPtr previous, IntPtr returnLength);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [StructLayout(LayoutKind.Sequential, Pack = 4)] struct TokenPrivileges { public int Count; public long Luid; public int Attributes; }

        static bool Enable(string privilege) {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x0028, out token)) return false;
            try {
                long luid;
                if (!LookupPrivilegeValue(null, privilege, out luid)) return false;
                TokenPrivileges tp = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
                return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero) && Marshal.GetLastWin32Error() == 0;
            } finally { CloseHandle(token); }
        }

        // 2 = empty working sets, 3 = flush modified list, 4 = purge standby list, 5 = purge low-priority standby
        public static int Command(int command) {
            Enable("SeProfileSingleProcessPrivilege");
            Enable("SeIncreaseQuotaPrivilege");
            IntPtr buffer = Marshal.AllocHGlobal(4);
            try { Marshal.WriteInt32(buffer, command); return NtSetSystemInformation(80, buffer, 4); }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }
}
"@
}

function Get-BTMemory {
    $os = Get-CimInstance Win32_OperatingSystem
    $pm = Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue
    $total = [double]$os.TotalVisibleMemorySize * 1KB
    $avail = [double]$os.FreePhysicalMemory * 1KB
    $standby = 0; $modified = 0; $free = $avail; $compressed = 0
    if ($pm) {
        $standby = [double]$pm.StandbyCacheCoreBytes + [double]$pm.StandbyCacheNormalPriorityBytes + [double]$pm.StandbyCacheReserveBytes
        $modified = [double]$pm.ModifiedPageListBytes
        $free = [double]$pm.FreeAndZeroPageListBytes
        $avail = [double]$pm.AvailableBytes
    }
    $mc = Get-Process -Name 'Memory Compression' -ErrorAction SilentlyContinue
    if ($mc) { $compressed = [double]$mc.WorkingSet64 }
    $used = [math]::Max([double]0, $total - $avail - $modified)
    [pscustomobject]@{ Total = $total; Available = $avail; Used = $used; Standby = $standby; Modified = $modified; Free = $free; Compressed = $compressed }
}

# Returns the bytes freed (available memory after minus before).
function Invoke-BTMemoryClean([switch]$WorkingSets) {
    if ($BTDryRun) { Write-BTLog 'DRY memory clean'; return 0 }
    Add-BTMemoryType
    $before = (Get-BTMemory).Free
    if ($WorkingSets) { [void][BlazmaTweak.Memory]::Command(2) }
    [void][BlazmaTweak.Memory]::Command(3)
    $r = [BlazmaTweak.Memory]::Command(4)
    Start-Sleep -Milliseconds 300
    $after = (Get-BTMemory).Free
    Write-BTLog ("memory clean status=0x{0:x} freed={1:n0} MB" -f $r, (($after - $before) / 1MB))
    [math]::Max([double]0, $after - $before)
}

# ------------------------------------------------------------------ cleanup
function Get-BTCleanTargets {
    $la = $env:LOCALAPPDATA; $win = $env:windir
    @(
        @{ id = 'usertemp';  paths = @($env:TEMP) }
        @{ id = 'wintemp';   paths = @("$win\Temp") }
        @{ id = 'update';    paths = @("$win\SoftwareDistribution\Download") }
        @{ id = 'shaders';   paths = @("$la\D3DSCache", "$la\NVIDIA\DXCache", "$la\NVIDIA\GLCache", "$la\AMD\DxCache", "$la\AMD\GLCache", "$la\Intel\ShaderCache") }
        @{ id = 'dumps';     paths = @("$win\Minidump", "$la\CrashDumps", "$win\LiveKernelReports") ; files = @("$win\MEMORY.DMP") }
        @{ id = 'reports';   paths = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$la\Microsoft\Windows\WER") }
        @{ id = 'thumbs';    files = @(Get-ChildItem "$la\Microsoft\Windows\Explorer" -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue | ForEach-Object FullName) }
        @{ id = 'delivery';  paths = @("$win\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") }
        @{ id = 'logs';      paths = @("$win\Logs\CBS", "$win\Logs\DISM", "$win\Panther") }
        @{ id = 'recycle';   recycle = $true }
    )
}

function Get-BTFolderSize([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return 0 }
    $s = 0
    try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $s += $_.Length }
    } catch { }
    $s
}

function Get-BTRecycleSize {
    $s = 0
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Join-Path $_.Root '$Recycle.Bin'
        if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { $s += Get-BTFolderSize $p }
    }
    $s
}

function Measure-BTCleanTargets {
    $out = @{}
    foreach ($t in Get-BTCleanTargets) {
        $size = 0
        foreach ($p in @($t.paths)) { if ($p) { $size += Get-BTFolderSize $p } }
        foreach ($f in @($t.files)) { if ($f -and (Test-Path -LiteralPath $f -ErrorAction SilentlyContinue)) { $size += (Get-Item -LiteralPath $f -Force).Length } }
        if ($t.recycle) { $size += Get-BTRecycleSize }
        $out[$t.id] = [double]$size
    }
    $out
}

function Clear-BTFolder([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return }
    if ($BTDryRun) { Write-BTLog "DRY clean $Path"; return }
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-BTClean([string[]]$Ids) {
    $before = Measure-BTCleanTargets
    foreach ($t in Get-BTCleanTargets) {
        if ($Ids -notcontains $t.id) { continue }
        if ($t.id -eq 'update' -and -not $BTDryRun) { Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue }
        if ($t.id -eq 'delivery' -and -not $BTDryRun) { try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { } }
        foreach ($p in @($t.paths)) { Clear-BTFolder $p }
        foreach ($f in @($t.files)) { if ($f -and -not $BTDryRun) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
        if ($t.recycle -and -not $BTDryRun) { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
        if ($t.id -eq 'update' -and -not $BTDryRun) { Start-Service wuauserv -ErrorAction SilentlyContinue }
    }
    $after = Measure-BTCleanTargets
    $freed = 0
    foreach ($id in $Ids) { $freed += [math]::Max([double]0, $before[$id] - $after[$id]) }
    Write-BTLog ("cleaned {0} freed {1:n0} MB" -f ($Ids -join ','), ($freed / 1MB))
    [pscustomobject]@{ Freed = $freed; Sizes = $after }
}

# ------------------------------------------------------------------ power
$script:BTUltimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

function Get-BTPowerPlans {
    $active = $null
    $plans = foreach ($line in (powercfg /list)) {
        if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\((.+?)\)\s*(\*)?\s*$') {
            $p = [pscustomobject]@{ Guid = $Matches[1].ToLowerInvariant(); Name = $Matches[2]; Active = [bool]$Matches[3] }
            $p
        }
    }
    @($plans)
}

function Add-BTUltimatePlan {
    $existing = Get-BTPowerPlans | Where-Object { $_.Name -like 'Blazma*' } | Select-Object -First 1
    if ($existing) { if (-not $BTDryRun) { powercfg /setactive $existing.Guid | Out-Null }; return $existing.Guid }
    if ($BTDryRun) { Write-BTLog 'DRY ultimate plan'; return $null }
    $out = powercfg /duplicatescheme $script:BTUltimateGuid
    if (($out -join ' ') -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $g = $Matches[1]
        powercfg /changename $g 'Blazma Ultimate' 'Maximum performance plan added by Blazma Tweak' | Out-Null
        powercfg /setactive $g | Out-Null
        Write-BTLog "ultimate plan $g"
        return $g
    }
    return $null
}

function Set-BTPowerPlan([string]$Guid) {
    if ($BTDryRun) { Write-BTLog "DRY plan $Guid"; return }
    powercfg /setactive $Guid | Out-Null
}

# ------------------------------------------------------------------ network
function Get-BTAdapters {
    @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object {
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        [pscustomobject]@{ Name = $_.Name; Index = $_.ifIndex; Description = $_.InterfaceDescription; Speed = $_.LinkSpeed; Dns = @($dns) }
    })
}

$script:BTDnsSets = @{
    cloudflare = @('1.1.1.1', '1.0.0.1')
    google     = @('8.8.8.8', '8.8.4.4')
    quad9      = @('9.9.9.9', '149.112.112.112')
    adguard    = @('94.140.14.14', '94.140.15.15')
}

function Set-BTDns([string]$Set) {
    foreach ($a in Get-BTAdapters) {
        if ($BTDryRun) { Write-BTLog "DRY dns $($a.Name) -> $Set"; continue }
        if ($Set -eq 'auto') { Set-DnsClientServerAddress -InterfaceIndex $a.Index -ResetServerAddresses }
        else { Set-DnsClientServerAddress -InterfaceIndex $a.Index -ServerAddresses $script:BTDnsSets[$Set] }
    }
    if (-not $BTDryRun) { Clear-DnsClientCache }
    Write-BTLog "dns -> $Set"
}

function Test-BTPing([string]$Target = '1.1.1.1') {
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $times = foreach ($i in 1..4) { $r = $p.Send($Target, 1500); if ($r.Status -eq 'Success') { $r.RoundtripTime } }
        if (-not $times) { return $null }
        [math]::Round((($times | Measure-Object -Average).Average), 0)
    } catch { $null }
}

function Reset-BTNetwork {
    if ($BTDryRun) { Write-BTLog 'DRY network reset'; return }
    ipconfig /flushdns | Out-Null
    netsh winsock reset | Out-Null
    netsh int ip reset | Out-Null
    Write-BTLog 'network reset'
}

# ------------------------------------------------------------------ system info
function Get-BTSystemInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Virtual|Remote|Parsec' } | Select-Object -First 1
    $ram = Get-CimInstance Win32_PhysicalMemory
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    $build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Os       = ($os.Caption -replace '^Microsoft\s+', '')
        Build    = ('{0}.{1}' -f $build.CurrentBuild, $build.UBR)
        Version  = $build.DisplayVersion
        Cpu      = ($cpu.Name -replace '\s+', ' ').Trim()
        Cores    = ('{0}/{1}' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
        Gpu      = $(if ($gpu) { $gpu.Name } else { '-' })
        RamGB    = [math]::Round(([double]($ram | Measure-Object Capacity -Sum).Sum) / 1GB, 0)
        RamSpeed = ($ram | Measure-Object -Property ConfiguredClockSpeed -Maximum).Maximum
        DiskFree = [double]$disk.FreeSpace
        DiskSize = [double]$disk.Size
        Uptime   = ((Get-Date) - $os.LastBootUpTime)
    }
}
