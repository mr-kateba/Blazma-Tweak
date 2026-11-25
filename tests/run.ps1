# Checks for Blazma Tweak. Safe to run on a real PC: nothing is changed outside a throw-away
# HKCU test key and a temporary data folder.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Info = '') {
    if ($Ok) { Write-Host "  ok    $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name  $Info" -ForegroundColor Red; $script:fail++ }
}

Write-Host '== build'
& (Join-Path $root 'build.ps1') | Out-Null
$dist = Join-Path $root 'dist\BlazmaTweak.ps1'
Check 'dist exists' (Test-Path $dist)
$bytes = [IO.File]::ReadAllBytes($dist)
Check 'dist is ASCII' (-not ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1))

Write-Host '== data'
$utf8 = New-Object Text.UTF8Encoding($false)
$cfg = [IO.File]::ReadAllText((Join-Path $root 'config\tweaks.json'), $utf8) | ConvertFrom-Json
$str = [IO.File]::ReadAllText((Join-Path $root 'config\strings.json'), $utf8) | ConvertFrom-Json
$ids = @($cfg.tweaks | ForEach-Object id)
Check "$($ids.Count) tweaks, ids unique" ($ids.Count -eq @($ids | Select-Object -Unique).Count)
$arKeys = @($str.ar.PSObject.Properties.Name); $enKeys = @($str.en.PSObject.Properties.Name)
Check 'strings: same keys in ar and en' (-not (Compare-Object $arKeys $enKeys))
$kinds = 'DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString'
foreach ($t in $cfg.tweaks) {
    $p = @()
    if ($cfg.categories -notcontains $t.cat) { $p += "category $($t.cat)" }
    if ('safe', 'advanced', 'expert' -notcontains $t.risk) { $p += "risk $($t.risk)" }
    if (-not $t.ar.name -or -not $t.en.name -or -not $t.ar.desc -or -not $t.en.desc) { $p += 'text' }
    foreach ($e in @($t.reg)) { if ($e) {
        if ($e.path -notmatch '^(HKLM|HKCU|HKU|HKCR)\\') { $p += "hive $($e.path)" }
        if ($kinds -notcontains $e.type) { $p += "type $($e.type)" }
    } }
    foreach ($s in @($t.svc)) { if ($s -and 'Automatic', 'AutomaticDelayed', 'Manual', 'Disabled' -notcontains $s.start) { $p += "start $($s.start)" } }
    foreach ($code in @($t.apply, $t.undo, $t.detect)) { if ($code) {
        $e2 = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$e2)
        if ($e2.Count) { $p += "script: $($e2[0].Message)" }
    } }
    $hasCheck = @($t.reg).Count -or @($t.svc).Count -or @($t.task).Count -or $t.detect
    if (-not $hasCheck) { $p += 'no way to detect state' }
    if (-not (@($t.reg).Count -or @($t.svc).Count -or @($t.task).Count -or $t.undo)) { $p += 'no undo' }
    if ($p.Count) { Check $t.id $false ($p -join '; ') }
}
Check 'every tweak valid' ($fail -eq 0)
foreach ($c in $cfg.categories) { if (-not $str.ar."cat.$c") { Check "string cat.$c" $false } }

Write-Host '== engine (temporary data folder, HKCU test key)'
$BTDir = Join-Path $env:TEMP ('bt-test-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
$BTDryRun = $false
. (Join-Path $root 'src\core.ps1')
$testRoot = 'HKCU\Software\BlazmaTweakTest'
Remove-BTRegKey $testRoot
Set-BTRegValue "$testRoot\Existing" 'Keep' 'DWord' 7
$fake = [pscustomobject]@{
    id = 'test.fake'
    reg = @(
        [pscustomobject]@{ path = "$testRoot\Existing"; name = 'Keep'; type = 'DWord'; value = 1 },
        [pscustomobject]@{ path = "$testRoot\New\Deep"; name = 'Big'; type = 'DWord'; value = 4294967295 },
        [pscustomobject]@{ path = "$testRoot\New\Deep"; name = 'Text'; type = 'String'; value = 'High' },
        [pscustomobject]@{ path = "$testRoot\New\Deep"; name = 'Bin'; type = 'Binary'; value = '90 12 03 80' },
        [pscustomobject]@{ path = "$testRoot\New\Deep"; name = ''; type = 'String'; value = '' })
}
Check 'state off before' ((Get-BTTweakState $fake) -eq 'off')
Invoke-BTTweak $fake
Check 'state on after apply' ((Get-BTTweakState $fake) -eq 'on')
Check 'DWord 0xFFFFFFFF stored' ((Get-BTRegValue "$testRoot\New\Deep" 'Big').Value -eq 4294967295)
Check 'backup written' ((Read-BTBackup).ContainsKey('test.fake'))
Invoke-BTTweak $fake
Check 'second apply keeps the original backup' ((Read-BTBackup)['test.fake'].reg[0].value -eq 7)
Undo-BTTweak $fake
Check 'old value restored' ((Get-BTRegValue "$testRoot\Existing" 'Keep').Value -eq 7)
Check 'created key removed' (-not (Get-BTRegValue "$testRoot\New" 'x').KeyExists)
Check 'backup entry cleared' (-not (Read-BTBackup).ContainsKey('test.fake'))
Check 'state off after undo' ((Get-BTTweakState $fake) -eq 'off')
# undo with no backup falls back to the defaults in the definition
$fake2 = [pscustomobject]@{ id = 'test.default'; reg = @([pscustomobject]@{ path = "$testRoot\Existing"; name = 'Keep'; type = 'DWord'; value = 1; default = 5 }) }
Set-BTRegValue "$testRoot\Existing" 'Keep' 'DWord' 1
Undo-BTTweak $fake2
Check 'default used without backup' ((Get-BTRegValue "$testRoot\Existing" 'Keep').Value -eq 5)
Remove-BTRegKey $testRoot
Check 'test key cleaned up' (-not (Get-BTRegValue $testRoot 'x').KeyExists)
$BTDryRun = $true
Set-BTRegValue "$testRoot" 'Dry' 'DWord' 1
Check 'dry run writes nothing' (-not (Get-BTRegValue $testRoot 'Dry').KeyExists)
$BTDryRun = $false

Write-Host '== read-only checks on this PC'
$sw = [Diagnostics.Stopwatch]::StartNew()
$states = @{}
foreach ($t in $cfg.tweaks) { try { $states[$t.id] = Get-BTTweakState $t } catch { Check "detect $($t.id)" $false $_.Exception.Message } }
Check ("detected {0} tweaks in {1:n1}s" -f $states.Count, $sw.Elapsed.TotalSeconds) ($states.Count -eq $cfg.tweaks.Count)
'   on: ' + (@($states.Keys | Where-Object { $states[$_] -eq 'on' } | Sort-Object) -join ', ')
'   partial: ' + (@($states.Keys | Where-Object { $states[$_] -eq 'partial' } | Sort-Object) -join ', ')
foreach ($t in $cfg.tweaks) { foreach ($s in @($t.svc)) { if ($s -and $null -eq (Get-BTServiceStart $s.name)) { "   (service $($s.name) not on this PC)" } } }
$m = Get-BTMemory
Check ("memory {0:n1}/{1:n1} GB, standby {2:n1} GB" -f (($m.Total - $m.Available) / 1GB), ($m.Total / 1GB), ($m.Standby / 1GB)) ($m.Total -gt 0)
$i = Get-BTSystemInfo
Check "system: $($i.Cpu) | $($i.Gpu) | $($i.RamGB) GB | $($i.Os) $($i.Version)" ([bool]$i.Cpu)
$plans = Get-BTPowerPlans
Check "power plans: $(@($plans).Count)" (@($plans).Count -gt 0)
$sizes = Measure-BTCleanTargets
if (-not (Test-Path $BTDir)) { New-Item -ItemType Directory -Path $BTDir | Out-Null }
Check ('cleanup scan: ' + (($sizes.Keys | Sort-Object | ForEach-Object { '{0}={1:n0}MB' -f $_, ($sizes[$_] / 1MB) }) -join ' ')) ($sizes.Count -eq 10)
$pc = Get-BTProfile
Check ("profile: {0} GB, ssd={1}, laptop={2}, printers={3}" -f $pc.RamGB, $pc.Ssd, $pc.Laptop, $pc.Printers) ($pc.RamGB -gt 0)
$rec = @($cfg.tweaks | Where-Object { Test-BTRecommended $_ $pc })
Check "recommended for this PC: $($rec.Count)" ($rec.Count -gt 10 -and -not ($rec | Where-Object risk -eq 'expert'))
$apps = (([IO.File]::ReadAllText((Join-Path $root 'config\apps.json'), $utf8)) | ConvertFrom-Json).apps
$ai = @(Get-BTApps $apps)
Check ("apps: {0} in catalog, {1} installed here" -f $ai.Count, @($ai | Where-Object Installed).Count) ($ai.Count -eq $apps.Count)
$st = @(Get-BTStartupItems)
Check ("startup items: {0} ({1} on)" -f $st.Count, @($st | Where-Object Enabled).Count) ($true)
# startup switch round trip on a fake HKCU entry
$fakeItem = [pscustomobject]@{ Name = 'BlazmaTweakTestItem'; Hive = 'HKCU'; Approved = 'Run'; Kind = 'reg' }
Set-BTStartupItem $fakeItem $false
Check 'startup off' (-not (Test-BTStartupEnabled 'HKCU' 'Run' 'BlazmaTweakTestItem'))
Set-BTStartupItem $fakeItem $true
Check 'startup on again' (Test-BTStartupEnabled 'HKCU' 'Run' 'BlazmaTweakTestItem')
Remove-BTRegValue "HKCU\$BTApprovedRoot\Run" 'BlazmaTweakTestItem'
$cfgFile = Join-Path $BTDir 'export.json'
Export-BTConfig $cfgFile @('gaming.dvr', 'ui.ext')
Check 'export/import round trip' ((@(Import-BTConfig $cfgFile) -join ',') -eq 'gaming.dvr,ui.ext')
Add-BTMemoryType
Check 'memory API compiled' ([bool]('BlazmaTweak.Memory' -as [type]))

Write-Host '== window'
Add-Type -AssemblyName PresentationFramework
[xml]$x = [IO.File]::ReadAllText((Join-Path $root 'src\ui.xaml'), $utf8)
$w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
Check 'XAML loads' ($null -ne $w)
$main = [IO.File]::ReadAllText((Join-Path $root 'src\main.ps1'))
$used = [regex]::Matches($main, '\$ui\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
$missing = @($used | Where-Object { -not $w.FindName($_) })
Check "all $(@($used).Count) controls used in code exist" (-not $missing.Count) ($missing -join ', ')
$keys = [regex]::Matches($main + [IO.File]::ReadAllText((Join-Path $root 'src\ui.xaml')), "(?:S|F) '([a-z]+\.[\w.]+)'|Tag=`"t:([\w.]+)`"") | ForEach-Object { if ($_.Groups[1].Value) { $_.Groups[1].Value } else { $_.Groups[2].Value } } | Select-Object -Unique
$nokey = @($keys | Where-Object { $arKeys -notcontains $_ })
Check "all $(@($keys).Count) text keys exist" (-not $nokey.Count) ($nokey -join ', ')

Remove-Item $BTDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'all checks passed' -ForegroundColor Green }
