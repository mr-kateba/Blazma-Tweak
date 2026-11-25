# Blazma Tweak - Arabic Windows tweaking tool by kateba (https://github.com/mr-kateba/Blazma-Tweak). MIT licence.
param(
    [switch]$NoElevate,
    [switch]$DryRun,
    [string]$Shot,
    [string]$Lang,
    # without the window: -Preset basic|gaming|max|recommended, -Apply id,id, -Undo id,id|all, -Config file.json, -List
    [string]$Preset,
    [string[]]$Apply,
    [string[]]$Undo,
    [string]$Config,
    [switch]$List
)

$BTVersion = '0.2.0'
$BTReleaseUrl = 'https://github.com/mr-kateba/Blazma-Tweak/releases/latest/download/BlazmaTweak.ps1'

# ------------------------------------------------------------------ start-up: STA + administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta = [Threading.Thread]::CurrentThread.ApartmentState -eq 'STA'
$headless = [bool]($Preset -or $Apply -or $Undo -or $Config -or $List)
if ((-not $isAdmin -and -not $NoElevate -and -not $DryRun -and -not $List) -or (-not $isSta -and -not $headless)) {
    $self = $PSCommandPath
    $extra = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) { if ($kv.Value) { $extra += "-$($kv.Key)" } }
        else { $extra += "-$($kv.Key) '$((@($kv.Value) -join ',') -replace "'", "''")'" }
    }
    $keep = if ($headless) { '-NoExit ' } else { '' }
    if ($self) { $argLine = "$keep-NoProfile -ExecutionPolicy Bypass -STA -File `"$self`" $($extra -join ' ')" }
    else { $argLine = "$keep-NoProfile -ExecutionPolicy Bypass -STA -Command `"& ([ScriptBlock]::Create((Invoke-RestMethod '$BTReleaseUrl'))) $($extra -join ' ')`"" }
    $verb = if ($isAdmin -or $NoElevate -or $DryRun) { 'Open' } else { 'RunAs' }
    try { Start-Process powershell.exe -Verb $verb -ArgumentList $argLine } catch { Write-Host 'Blazma Tweak needs administrator rights.' -ForegroundColor Yellow }
    return
}

# ------------------------------------------------------------------ parts (embedded by build.ps1, read from disk when running the sources)
if (-not $BTCoreText) {
    $root = Split-Path -Parent $PSScriptRoot
    $BTCoreText = [IO.File]::ReadAllText((Join-Path $root 'src\core.ps1'))
    $BTXaml = [IO.File]::ReadAllText((Join-Path $root 'src\ui.xaml'))
    $BTTweaksJson = [IO.File]::ReadAllText((Join-Path $root 'config\tweaks.json'))
    $BTStringsJson = [IO.File]::ReadAllText((Join-Path $root 'config\strings.json'))
    $BTAppsJson = [IO.File]::ReadAllText((Join-Path $root 'config\apps.json'))
}

$BTDir = Join-Path $env:LOCALAPPDATA 'BlazmaTweak'
$BTDryRun = [bool]$DryRun
. ([scriptblock]::Create($BTCoreText))
$Tweaks = @(($BTTweaksJson | ConvertFrom-Json).tweaks)
$AppCatalog = @(($BTAppsJson | ConvertFrom-Json).apps)

# ------------------------------------------------------------------ command line (no window)
if ($headless) {
    function Find-Tweaks([string[]]$Ids) {
        $ids2 = @($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($i in $ids2) { if (-not ($Tweaks | Where-Object id -eq $i)) { Write-Host "  unknown tweak: $i" -ForegroundColor Yellow } }
        @($Tweaks | Where-Object { $ids2 -contains $_.id })
    }
    Write-Host "Blazma Tweak $BTVersion$(if ($BTDryRun) { '  (dry run: nothing is changed)' })" -ForegroundColor DarkYellow
    if ($List) {
        foreach ($t in $Tweaks) { '{0,-22} {1,-4} {2,-9} {3}' -f $t.id, (Get-BTTweakState $t), $t.risk, $t.en.name }
        return
    }
    $todo = @(); $mode = 'apply'
    if ($Preset) {
        $pc = Get-BTProfile
        $todo = if ($Preset -eq 'recommended') { @($Tweaks | Where-Object { Test-BTRecommended $_ $pc }) } else { @($Tweaks | Where-Object { @($_.presets) -contains $Preset }) }
        if (-not $todo.Count) { Write-Host "Unknown preset '$Preset'. Use basic, gaming, max or recommended." -ForegroundColor Red; return }
    }
    if ($Config) { $todo += Find-Tweaks (Import-BTConfig $Config) }
    if ($Apply) { $todo += Find-Tweaks $Apply }
    if ($Undo) {
        $mode = 'undo'
        $todo = if (@($Undo) -contains 'all') { $b = Read-BTBackup; @($Tweaks | Where-Object { $b.ContainsKey($_.id) }) } else { Find-Tweaks $Undo }
    }
    $todo = @($todo | Sort-Object id -Unique)
    if ($mode -eq 'apply' -and -not $BTDryRun) { Write-Host 'Creating a restore point...'; [void](New-BTRestorePoint 'Blazma Tweak') }
    $n = 0
    foreach ($t in $todo) {
        $n++
        try {
            if ($mode -eq 'apply') { if ((Get-BTTweakState $t) -ne 'on') { Invoke-BTTweak $t } } else { Undo-BTTweak $t }
            Write-Host ('[{0}/{1}] {2,-6} {3}  -> {4}' -f $n, $todo.Count, $mode, $t.id, (Get-BTTweakState $t))
        } catch { Write-Host "[$n/$($todo.Count)] $($t.id): $($_.Exception.Message)" -ForegroundColor Red }
    }
    if ($todo | Where-Object restart -eq 'reboot') { Write-Host 'Restart the PC to finish.' -ForegroundColor Yellow }
    Write-Host 'Done.' -ForegroundColor Green
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
[xml]$xamlDoc = $BTXaml
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlDoc))
$ui = @{}
$xamlDoc.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($n) { $ui[$n] = $win.FindName($n) }
}

$Categories = @(($BTTweaksJson | ConvertFrom-Json).categories)
$Strings = $BTStringsJson | ConvertFrom-Json
$State = @{}           # tweak id -> on | off | partial
$Switches = @{}        # tweak id -> list of switches showing it (a tweak can appear on two pages)
$script:Busy = $false
$script:RestoreDone = $false
$script:NeedReboot = $false

# ------------------------------------------------------------------ settings
$SettingsFile = Join-Path $BTDir 'settings.json'
$Settings = [ordered]@{ lang = 'ar'; restore = $true; autoClean = $false; threshold = 15 }
if (Test-Path $SettingsFile) {
    try { (Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $Settings[$_.Name] = $_.Value } } catch { }
}
if ($Lang) { $Settings.lang = $Lang }
function Save-Settings {
    if ($BTDryRun) { return }
    if (-not (Test-Path $BTDir)) { New-Item -ItemType Directory -Path $BTDir -Force | Out-Null }
    [IO.File]::WriteAllText($SettingsFile, ($Settings | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------ text helpers
function S([string]$Key) {
    $v = $Strings.($Settings.lang).$Key
    if ($null -eq $v) { $v = $Strings.en.$Key }
    if ($null -eq $v) { $v = $Key }
    $v
}
function F([string]$Key) { $f = S $Key; if ($args.Count) { [string]::Format($f, [object[]]$args) } else { $f } }
function TN($Tweak) { $Tweak.($Settings.lang).name }
function TD($Tweak) { $Tweak.($Settings.lang).desc }
function Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { F 'unit.gb' ('{0:0.0}' -f ($Bytes / 1GB)) } else { F 'unit.mb' ('{0:0}' -f ($Bytes / 1MB)) }
}
function Brush([string]$Hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex) }

function Set-Status([string]$Text) { $ui.TxtStatus.Text = $Text }

# Every element tagged "t:key" gets its text from the string table.
function Update-Texts($Node) {
    if ($Node -is [Windows.FrameworkElement] -and $Node.Tag -is [string] -and $Node.Tag.StartsWith('t:')) {
        $t = S $Node.Tag.Substring(2)
        if ($Node -is [Windows.Controls.TextBlock]) { $Node.Text = $t }
        elseif ($Node -is [Windows.Controls.ContentControl]) { $Node.Content = $t }
    }
    foreach ($c in [Windows.LogicalTreeHelper]::GetChildren($Node)) { if ($c -is [Windows.DependencyObject]) { Update-Texts $c } }
}

# ------------------------------------------------------------------ background work
# Each job runs in its own runspace with the engine loaded, so the window never freezes.
$Sync = [hashtable]::Synchronized(@{ Progress = '' })
$Jobs = New-Object System.Collections.ArrayList
$Pool = [runspacefactory]::CreateRunspacePool(1, 3)
$Pool.ApartmentState = 'STA'
$Pool.Open()

function Start-Job2([scriptblock]$Work, $Argument, [scriptblock]$Done) {
    # One script per job: settings, the engine, then the work. (Several statements on a pooled
    # PowerShell instance never complete on Windows PowerShell 5.1.)
    $text = "param(`$__arg, `$__sync)`r`n`$BTDir = '$($BTDir -replace "'", "''")'; `$BTDryRun = `$$BTDryRun`r`n" + $BTCoreText + "`r`n& {`r`n" + $Work.ToString() + "`r`n} `$__arg `$__sync"
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($text).AddArgument($Argument).AddArgument($Sync)
    [void]$Jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Done = $Done })
}

$JobTimer = New-Object Windows.Threading.DispatcherTimer
$JobTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$JobTimer.Add_Tick({
    foreach ($j in @($Jobs)) {
        if (-not $j.Handle.IsCompleted) { continue }
        [void]$Jobs.Remove($j)
        $result = $null; $err = $null
        try { $result = $j.PS.EndInvoke($j.Handle) } catch { $err = $_.Exception.InnerException; if (-not $err) { $err = $_.Exception } }
        # non-terminating errors (a missing task, a locked file) are only logged
        foreach ($e in @($j.PS.Streams.Error | Select-Object -First 3)) { Write-BTLog "job warning: $e" }
        if ($err) { Write-BTLog "job error: $($err.Message)" }
        $j.PS.Dispose()
        try { & $j.Done $result $err } catch { Write-BTLog "ui error: $_ $($_.InvocationInfo.PositionMessage)"; Set-Status (F 'status.error' $_.Exception.Message) }
    }
    if ($script:Busy -and $Sync.Progress) { $ui.TxtBusy.Text = $Sync.Progress }
    if ($ui.Busy.Visibility -eq 'Visible') {
        $w = [math]::Max(120, $ui.BusyBar.Parent.ActualWidth)
        $ui.BusyShift.X = (($ui.BusyShift.X + 14) % ($w + 90)) - 0
    }
})
$JobTimer.Start()

function Show-Busy([string]$Text) { $script:Busy = $true; $Sync.Progress = ''; $ui.TxtBusy.Text = $Text; $ui.Busy.Visibility = 'Visible' }
function Hide-Busy { $script:Busy = $false; $ui.Busy.Visibility = 'Collapsed' }

function Ask([string]$Text) {
    $opt = if ($Settings.lang -eq 'ar') { [Windows.MessageBoxOptions]::RtlReading -bor [Windows.MessageBoxOptions]::RightAlign } else { [Windows.MessageBoxOptions]::None }
    [Windows.MessageBox]::Show($win, $Text, 'Blazma Tweak', 'YesNo', 'Question', 'No', $opt) -eq 'Yes'
}

# ------------------------------------------------------------------ tweak cards
$RiskColor = @{ safe = '#34D399'; advanced = '#FFB300'; expert = '#FF5252' }

function New-Badge([string]$Text, [string]$Color) {
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = 6; $b.Padding = '8,2'; $b.Margin = '0,0,6,0'
    $c = [Windows.Media.ColorConverter]::ConvertFromString($Color)
    $b.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(36, $c.R, $c.G, $c.B))
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = 11.5; $t.Foreground = New-Object Windows.Media.SolidColorBrush $c
    $b.Child = $t
    $b
}

function New-TweakCard($Tweak) {
    $card = New-Object Windows.Controls.Border
    $card.Style = $win.FindResource('Card'); $card.Padding = '18,14'; $card.Margin = '0,0,0,10'
    $card.Tag = $Tweak.id
    $grid = New-Object Windows.Controls.Grid
    foreach ($w in [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star), [Windows.GridLength]::Auto) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $grid.ColumnDefinitions.Add($cd) }

    $text = New-Object Windows.Controls.StackPanel
    $title = New-Object Windows.Controls.TextBlock
    $title.Text = TN $Tweak; $title.FontSize = 14.5; $title.FontWeight = 'SemiBold'
    $desc = New-Object Windows.Controls.TextBlock
    $desc.Text = TD $Tweak; $desc.Foreground = $win.FindResource('Muted'); $desc.Margin = '0,4,0,8'
    $tags = New-Object Windows.Controls.WrapPanel
    [void]$tags.Children.Add((New-Badge (S "risk.$($Tweak.risk)") $RiskColor[$Tweak.risk]))
    [void]$tags.Children.Add((New-Badge (S "cat.$($Tweak.cat)") '#A0A0AB'))
    if ($script:Pc -and (Test-BTRecommended $Tweak $script:Pc)) { [void]$tags.Children.Add((New-Badge (S 'scan.badge') '#FF6D00')) }
    if ($Tweak.restart -eq 'reboot') { [void]$tags.Children.Add((New-Badge (S 'need.reboot') '#5B6CFF')) }
    if ($Tweak.restart -eq 'explorer') { [void]$tags.Children.Add((New-Badge (S 'need.explorer') '#5B6CFF')) }
    $partial = New-Badge (S 'partial') '#FFB300'; $partial.Visibility = 'Collapsed'
    [void]$tags.Children.Add($partial)
    [void]$text.Children.Add($title); [void]$text.Children.Add($desc); [void]$text.Children.Add($tags)
    [Windows.Controls.Grid]::SetColumn($text, 0)

    $sw = New-Object Windows.Controls.CheckBox
    $sw.Style = $win.FindResource('Switch'); $sw.Margin = '18,0,0,0'; $sw.Tag = $Tweak.id
    $sw.IsEnabled = $State.ContainsKey($Tweak.id) -and -not $script:Busy
    $sw.IsChecked = $State[$Tweak.id] -eq 'on'
    if ($State[$Tweak.id] -eq 'partial') { $partial.Visibility = 'Visible' }
    $sw.Add_Click({ param($s, $e) Switch-Tweak $s })
    [Windows.Controls.Grid]::SetColumn($sw, 1)
    [void]$grid.Children.Add($text); [void]$grid.Children.Add($sw)
    $card.Child = $grid

    if (-not $Switches.ContainsKey($Tweak.id)) { $Switches[$Tweak.id] = New-Object System.Collections.ArrayList }
    [void]$Switches[$Tweak.id].Add(@{ Switch = $sw; Partial = $partial })
    $card
}

function Update-TweakSwitches([string]$Id) {
    foreach ($x in @($Switches[$Id])) {
        $x.Switch.IsChecked = $State[$Id] -eq 'on'
        $x.Switch.IsEnabled = $State.ContainsKey($Id) -and -not $script:Busy
        $x.Partial.Visibility = if ($State[$Id] -eq 'partial') { 'Visible' } else { 'Collapsed' }
    }
}

function Update-AllSwitches { foreach ($id in @($Switches.Keys)) { Update-TweakSwitches $id }; Update-Summary; Update-Scan }

# Applies or undoes one tweak when its switch is clicked.
function Switch-Tweak($Sw) {
    $tw = $Tweaks | Where-Object id -eq $Sw.Tag | Select-Object -First 1
    $want = [bool]$Sw.IsChecked
    $Sw.IsChecked = -not $want                     # the switch flips only once the change really happened
    if ($want -and $tw.risk -eq 'expert' -and -not (Ask (F 'confirm.expert' (TN $tw) (TD $tw)))) { return }
    Invoke-TweakChange @($tw) $want
}

function Invoke-TweakChange($List, [bool]$Apply, [string]$DoneText) {
    $List = @($List)
    if (-not $List.Count) { return }
    $makePoint = $Apply -and $ui.ChkRestore.IsChecked -and -not $script:RestoreDone
    Show-Busy $(if ($List.Count -eq 1) { if ($Apply) { F 'status.applying' (TN $List[0]) } else { F 'status.undoing' (TN $List[0]) } } else { S 'busy' })
    foreach ($t in $List) { foreach ($x in @($Switches[$t.id])) { $x.Switch.IsEnabled = $false } }
    $labels = @{}; foreach ($t in $List) { $labels[$t.id] = TN $t }
    $arg = @{ List = $List; Apply = $Apply; Point = $makePoint; Labels = $labels; PointText = (S 'status.rp'); StepText = (S 'status.preset'); DoneText = $DoneText }
    Start-Job2 {
        param($a, $sync)
        $out = @{ States = @{}; Point = $null; Errors = @(); Apply = $a.Apply; DoneText = $a.DoneText; Ids = @($a.List | ForEach-Object { $_.id }) }
        if ($a.Point) { $sync.Progress = $a.PointText; $out.Point = New-BTRestorePoint 'Blazma Tweak' }
        $i = 0
        foreach ($t in $a.List) {
            $i++
            if ($a.List.Count -gt 1) { $sync.Progress = [string]::Format($a.StepText, $i, $a.List.Count) }
            try { if ($a.Apply) { Invoke-BTTweak $t } else { Undo-BTTweak $t } }
            catch { $out.Errors += "$($a.Labels[$t.id]): $($_.Exception.Message)"; Write-BTLog "error $($t.id): $_" }
            try { $out.States[$t.id] = Get-BTTweakState $t } catch { $out.States[$t.id] = 'off' }
        }
        $out
    } $arg { param($r, $err) Complete-TweakChange $r $err }
}

function Complete-TweakChange($r, $err) {
    Hide-Busy
    $res = @($r)[0]
    if ($err -or -not $res) { Set-Status (F 'status.error' $(if ($err) { $err.Message } else { '?' })); Update-AllSwitches; return }
    if ($null -ne $res.Point) { $script:RestoreDone = $true }
    foreach ($k in $res.States.Keys) { $State[$k] = $res.States[$k] }
    $list = @($Tweaks | Where-Object { $res.Ids -contains $_.id })
    $needExplorer = $false
    foreach ($t in $list) {
        if ($t.restart -eq 'reboot') { $script:NeedReboot = $true }
        if ($t.restart -eq 'explorer') { $needExplorer = $true }
    }
    if ($script:NeedReboot) { $ui.PillReboot.Visibility = 'Visible' }
    if ($needExplorer -and -not $BTDryRun) { $ui.BtnExplorer.Visibility = 'Visible' }
    Update-AllSwitches
    Update-Applied
    if ($res.Errors.Count) { Set-Status (F 'status.error' ($res.Errors -join ' | ')) }
    elseif ($res.Point -eq $false) { Set-Status (S 'status.rpFail') }
    elseif ($res.DoneText) { Set-Status $res.DoneText }
    elseif ($list.Count -eq 1) { Set-Status $(if ($res.Apply) { F 'status.applied' (TN $list[0]) } else { F 'status.undone' (TN $list[0]) }) }
}

# ------------------------------------------------------------------ tweaks page
$script:Cat = 'all'
function Build-Tweaks {
    $ui.TweakList.Children.Clear(); $ui.MemTweakList.Children.Clear(); $ui.PowerTweakList.Children.Clear(); $ui.NetTweakList.Children.Clear()
    $Switches.Clear()
    foreach ($t in $Tweaks) { [void]$ui.TweakList.Children.Add((New-TweakCard $t)) }
    foreach ($t in $Tweaks | Where-Object cat -eq 'memory') { [void]$ui.MemTweakList.Children.Add((New-TweakCard $t)) }
    foreach ($t in $Tweaks | Where-Object cat -eq 'power') { [void]$ui.PowerTweakList.Children.Add((New-TweakCard $t)) }
    foreach ($t in $Tweaks | Where-Object cat -eq 'network') { [void]$ui.NetTweakList.Children.Add((New-TweakCard $t)) }
    $empty = New-Object Windows.Controls.TextBlock
    $empty.Text = S 'tweaks.empty'; $empty.Foreground = $win.FindResource('Faint'); $empty.Margin = '4,20,0,0'; $empty.Visibility = 'Collapsed'; $empty.Tag = '__empty'
    [void]$ui.TweakList.Children.Add($empty)

    $ui.CatPanel.Children.Clear()
    foreach ($c in @('all') + $Categories) {
        $rb = New-Object Windows.Controls.RadioButton
        $rb.Style = $win.FindResource('Chip'); $rb.GroupName = 'cat'; $rb.Tag = $c
        $n = if ($c -eq 'all') { $Tweaks.Count } else { @($Tweaks | Where-Object cat -eq $c).Count }
        $rb.Content = '{0}  {1}' -f (S "cat.$c"), $n
        $rb.IsChecked = $c -eq $script:Cat
        $rb.Add_Checked({ param($s, $e) $script:Cat = $s.Tag; Filter-Tweaks })
        [void]$ui.CatPanel.Children.Add($rb)
    }
    Filter-Tweaks
}

function Filter-Tweaks {
    $q = $ui.TxtSearch.Text.Trim()
    $ui.SearchHint.Visibility = if ($q) { 'Collapsed' } else { 'Visible' }
    $shown = 0
    foreach ($card in $ui.TweakList.Children) {
        if ($card.Tag -eq '__empty') { $emptyBox = $card; continue }
        $t = $Tweaks | Where-Object id -eq $card.Tag | Select-Object -First 1
        $ok = ($script:Cat -eq 'all' -or $t.cat -eq $script:Cat)
        if ($ok -and $q) { $ok = ((TN $t) + ' ' + (TD $t) + ' ' + $t.en.name + ' ' + $t.id) -like "*$q*" }
        $card.Visibility = if ($ok) { 'Visible' } else { 'Collapsed' }
        if ($ok) { $shown++ }
    }
    if ($emptyBox) { $emptyBox.Visibility = if ($shown) { 'Collapsed' } else { 'Visible' } }
}

function Update-Summary {
    $on = @($Tweaks | Where-Object { $State[$_.id] -eq 'on' }).Count
    $ui.TxtTweakCount.Text = F 'tweaks.count' $Tweaks.Count $on
    $rec = if ($script:Pc) { @($Tweaks | Where-Object { Test-BTRecommended $_ $script:Pc }) } else { @($Tweaks | Where-Object { $_.presets -contains 'gaming' }) }
    $recOn = @($rec | Where-Object { $State[$_.id] -eq 'on' }).Count
    if ($State.Count) {
        $pct = [math]::Round(100 * $recOn / [math]::Max(1, $rec.Count))
        $ui.TxtScore.Text = "$pct%"
        $ui.ScoreBar.Width = [math]::Max(0, ($ui.ScoreBar.Parent.ActualWidth) * $pct / 100)
        $ui.TxtScoreHint.Text = F 'home.scoreHint' $recOn $rec.Count
    }
    foreach ($p in $PresetCards.Keys) {
        $todo = @($Tweaks | Where-Object { $_.presets -contains $p -and $State[$_.id] -ne 'on' })
        $c = $PresetCards[$p]
        $c.Count.Text = F 'preset.count' @($Tweaks | Where-Object { $_.presets -contains $p }).Count
        $c.Button.Content = if ($State.Count -and -not $todo.Count) { S 'preset.done' } else { S 'preset.apply' }
        $c.Button.IsEnabled = $State.Count -and $todo.Count -and -not $script:Busy
    }
}

# ------------------------------------------------------------------ home
$PresetCards = [ordered]@{}
function Build-Presets {
    $ui.PresetGrid.Children.Clear(); $PresetCards.Clear()
    $accent = @{ basic = '#34D399'; gaming = '#FF6D00'; max = '#FF5252' }
    $i = 0
    foreach ($p in 'basic', 'gaming', 'max') {
        $card = New-Object Windows.Controls.Border
        $card.Style = $win.FindResource('Card'); $card.Margin = $(if ($i -eq 0) { '0,0,8,0' } elseif ($i -eq 2) { '8,0,0,0' } else { '8,0,8,0' })
        $sp = New-Object Windows.Controls.DockPanel
        $bar = New-Object Windows.Controls.Border; $bar.Height = 3; $bar.Width = 34; $bar.CornerRadius = 2; $bar.Background = Brush $accent[$p]; $bar.HorizontalAlignment = 'Left'; $bar.Margin = '0,0,0,12'
        [Windows.Controls.DockPanel]::SetDock($bar, 'Top')
        $title = New-Object Windows.Controls.TextBlock; $title.Text = S "preset.$p"; $title.FontSize = 16; $title.FontWeight = 'SemiBold'
        [Windows.Controls.DockPanel]::SetDock($title, 'Top')
        $desc = New-Object Windows.Controls.TextBlock; $desc.Text = S "preset.$p.d"; $desc.Foreground = $win.FindResource('Muted'); $desc.Margin = '0,6,0,14'; $desc.MinHeight = 58
        [Windows.Controls.DockPanel]::SetDock($desc, 'Top')
        $row = New-Object Windows.Controls.DockPanel
        [Windows.Controls.DockPanel]::SetDock($row, 'Bottom')
        $btn = New-Object Windows.Controls.Button; $btn.Style = $win.FindResource($(if ($p -eq 'gaming') { 'Primary' } else { 'Btn' })); $btn.Tag = $p; $btn.Content = S 'preset.apply'
        [Windows.Controls.DockPanel]::SetDock($btn, 'Right'); $btn.HorizontalAlignment = 'Right'
        $cnt = New-Object Windows.Controls.TextBlock; $cnt.Foreground = $win.FindResource('Faint'); $cnt.VerticalAlignment = 'Center'
        [void]$row.Children.Add($btn); [void]$row.Children.Add($cnt)
        [void]$sp.Children.Add($bar); [void]$sp.Children.Add($title); [void]$sp.Children.Add($desc); [void]$sp.Children.Add($row)
        $card.Child = $sp
        $btn.Add_Click({ param($s, $e) Apply-Preset $s.Tag })
        [void]$ui.PresetGrid.Children.Add($card)
        $PresetCards[$p] = @{ Button = $btn; Count = $cnt }
        $i++
    }
}

function Apply-Preset([string]$Name) {
    $todo = @($Tweaks | Where-Object { $_.presets -contains $Name -and $State[$_.id] -ne 'on' })
    if (-not $todo.Count) { return }
    if (-not (Ask (F 'confirm.preset' $todo.Count (S "preset.$Name")))) { return }
    Invoke-TweakChange $todo $true (F 'status.presetDone' $todo.Count)
}

function Load-SystemInfo {
    Start-Job2 { param($a, $sync) Get-BTSystemInfo } $null {
        param($r, $err)
        $i = @($r)[0]; if (-not $i) { return }
        $ui.TxtCpu.Text = $i.Cpu; $ui.TxtCpu.ToolTip = $i.Cpu
        $c = $i.Cores -split '/'; $ui.TxtCpuSub.Text = F 'home.cores' $c[0] $c[1]
        $ui.TxtGpu.Text = $i.Gpu; $ui.TxtGpu.ToolTip = $i.Gpu
        $ui.TxtGpuSub.Text = ''
        $ui.TxtRam.Text = F 'unit.gb' $i.RamGB
        $ui.TxtRamSub.Text = if ($i.RamSpeed) { F 'home.ramSub' $i.RamSpeed } else { '' }
        $ui.TxtOs.Text = $i.Os
        $ui.TxtOsSub.Text = F 'home.osSub' $i.Version $i.Build
    }
}

function Load-States {
    Set-Status (S 'status.loading')
    Start-Job2 {
        param($list, $sync)
        $h = @{}
        foreach ($t in $list) { try { $h[$t.id] = Get-BTTweakState $t } catch { $h[$t.id] = 'off' } }
        $h
    } $Tweaks {
        param($r, $err)
        $h = @($r)[0]
        if ($h) { foreach ($k in $h.Keys) { $State[$k] = $h[$k] } }
        Update-AllSwitches; Update-Applied
        Set-Status (S 'status.ready')
        $script:StatesLoaded = $true
    }
}

# ------------------------------------------------------------------ memory page
$script:LastAuto = $null
function Update-Memory {
    try { $m = Get-BTMemory } catch { return }
    $pct = [math]::Round(100 * ($m.Total - $m.Available) / $m.Total)
    $ui.TxtMemPct.Text = "$pct%"
    $ui.TxtMemPct.Foreground = Brush $(if ($pct -ge 85) { '#FF5252' } elseif ($pct -ge 70) { '#FFB300' } else { '#F2F2F5' })
    $ui.TxtMemUsed.Text = '{0} {1}' -f (Size ($m.Total - $m.Available)), (F 'mem.of' (Size $m.Total))
    $ui.TxtMemComp.Text = F 'mem.compressed' (Size $m.Compressed)
    $cols = $ui.MemBar.ColumnDefinitions
    $vals = @($m.Used, $m.Modified, $m.Standby, $m.Free)
    for ($i = 0; $i -lt 4; $i++) { $cols[$i].Width = [Windows.GridLength]::new([math]::Max(0.0001, [double]$vals[$i]), [Windows.GridUnitType]::Star) }
    $ui.LblUsed.Text = Size $m.Used; $ui.LblModified.Text = Size $m.Modified; $ui.LblStandby.Text = Size $m.Standby; $ui.LblFree.Text = Size $m.Free
    if ($ui.ChkAutoClean.IsChecked -and -not $script:Busy) {
        $limit = [double]($ui.CmbAuto.SelectedItem.Content -replace '%', '') / 100
        $since = if ($script:LastAuto) { ((Get-Date) - $script:LastAuto).TotalSeconds } else { 1e9 }
        if (($m.Free / $m.Total) -lt $limit -and $since -gt 90) {
            $script:LastAuto = Get-Date
            $freed = Invoke-BTMemoryClean
            $ui.TxtAutoLast.Text = F 'mem.autoLast' ('{0:HH:mm}  ({1})' -f $script:LastAuto, (Size $freed))
        }
    }
}

function Clean-Memory([bool]$WorkingSets) {
    $win.Cursor = 'Wait'
    try {
        $freed = if ($WorkingSets) { Invoke-BTMemoryClean -WorkingSets } else { Invoke-BTMemoryClean }
        $ui.TxtMemResult.Text = if ($freed -gt 20MB) { F 'mem.freed' (Size $freed) } else { S 'mem.freedNone' }
    } catch { $ui.TxtMemResult.Text = F 'status.error' $_.Exception.Message }
    $win.Cursor = $null
    Update-Memory
}

# ------------------------------------------------------------------ power page
function Load-Plans {
    $ui.PlanList.Children.Clear()
    foreach ($p in Get-BTPowerPlans) {
        $row = New-Object Windows.Controls.Border
        $row.BorderBrush = $win.FindResource('Line'); $row.BorderThickness = '0,1,0,0'; $row.Padding = '2,10'
        $dp = New-Object Windows.Controls.DockPanel
        if ($p.Active) {
            $b = New-Badge (S 'power.active') '#34D399'; [Windows.Controls.DockPanel]::SetDock($b, 'Right'); $b.HorizontalAlignment = 'Right'; [void]$dp.Children.Add($b)
        } else {
            $btn = New-Object Windows.Controls.Button; $btn.Style = $win.FindResource('Btn'); $btn.Padding = '12,4'; $btn.Content = S 'power.use'; $btn.Tag = $p.Guid
            [Windows.Controls.DockPanel]::SetDock($btn, 'Right'); $btn.HorizontalAlignment = 'Right'
            $btn.Add_Click({ param($s, $e) Set-BTPowerPlan $s.Tag; Load-Plans; Set-Status (S 'status.plan') })
            [void]$dp.Children.Add($btn)
        }
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $p.Name; $t.VerticalAlignment = 'Center'; $t.FontWeight = $(if ($p.Active) { 'SemiBold' } else { 'Normal' })
        [void]$dp.Children.Add($t)
        $row.Child = $dp
        [void]$ui.PlanList.Children.Add($row)
    }
}

# ------------------------------------------------------------------ cleanup page
$CleanBoxes = [ordered]@{}
$script:CleanSizes = @{}
function Build-Clean {
    $ui.CleanList.Children.Clear(); $CleanBoxes.Clear()
    $defaults = @('usertemp', 'wintemp', 'update', 'dumps', 'reports', 'delivery', 'thumbs')
    foreach ($t in Get-BTCleanTargets) {
        $card = New-Object Windows.Controls.Border
        $card.Style = $win.FindResource('Card'); $card.Padding = '16,12'; $card.Margin = '0,0,0,8'
        $dp = New-Object Windows.Controls.DockPanel
        $size = New-Object Windows.Controls.TextBlock; $size.FontWeight = 'SemiBold'; $size.VerticalAlignment = 'Center'; $size.FlowDirection = 'LeftToRight'; $size.MinWidth = 80; $size.TextAlignment = 'Right'
        [Windows.Controls.DockPanel]::SetDock($size, 'Right'); $size.HorizontalAlignment = 'Right'
        $size.Text = if ($script:CleanSizes.ContainsKey($t.id)) { Size $script:CleanSizes[$t.id] } else { '-' }
        $cb = New-Object Windows.Controls.CheckBox; $cb.Style = $win.FindResource('Check'); $cb.IsChecked = $defaults -contains $t.id; $cb.Tag = $t.id
        $sp = New-Object Windows.Controls.StackPanel
        $n = New-Object Windows.Controls.TextBlock; $n.Text = S "clean.$($t.id)"; $n.FontWeight = 'SemiBold'
        $d = New-Object Windows.Controls.TextBlock; $d.Text = S "clean.$($t.id).d"; $d.Foreground = $win.FindResource('Faint'); $d.FontSize = 12
        [void]$sp.Children.Add($n); [void]$sp.Children.Add($d)
        $cb.Content = $sp
        $cb.Add_Click({ Update-CleanTotal })
        [void]$dp.Children.Add($size); [void]$dp.Children.Add($cb)
        $card.Child = $dp
        [void]$ui.CleanList.Children.Add($card)
        $CleanBoxes[$t.id] = @{ Box = $cb; Size = $size }
    }
    Update-CleanTotal
}

function Update-CleanTotal {
    $sum = 0
    foreach ($k in $CleanBoxes.Keys) { if ($CleanBoxes[$k].Box.IsChecked -and $script:CleanSizes.ContainsKey($k)) { $sum += $script:CleanSizes[$k] } }
    $ui.TxtCleanTotal.Text = if ($script:CleanSizes.Count) { F 'clean.total' (Size $sum) } else { '' }
}

function Scan-Clean {
    $ui.TxtCleanTotal.Text = S 'clean.scanning'; $ui.BtnScan.IsEnabled = $false; $ui.BtnClean.IsEnabled = $false
    Start-Job2 { param($a, $sync) Measure-BTCleanTargets } $null {
        param($r, $err)
        $ui.BtnScan.IsEnabled = $true; $ui.BtnClean.IsEnabled = $true
        $h = @($r)[0]; if (-not $h) { return }
        $script:CleanSizes = $h
        foreach ($k in $CleanBoxes.Keys) { $CleanBoxes[$k].Size.Text = Size $h[$k] }
        Update-CleanTotal
    }
}

function Run-Clean {
    $ids = @($CleanBoxes.Keys | Where-Object { $CleanBoxes[$_].Box.IsChecked })
    if (-not $ids.Count) { return }
    Show-Busy (S 'busy')
    Start-Job2 { param($a, $sync) Invoke-BTClean $a } $ids {
        param($r, $err)
        Hide-Busy
        $res = @($r)[0]
        if ($err -or -not $res) { Set-Status (F 'status.error' $(if ($err) { $err.Message } else { '?' })); return }
        $script:CleanSizes = $res.Sizes
        foreach ($k in $CleanBoxes.Keys) { $CleanBoxes[$k].Size.Text = Size $res.Sizes[$k] }
        $ui.TxtCleanResult.Text = F 'clean.freed' (Size $res.Freed)
        Set-Status (F 'clean.freed' (Size $res.Freed))
        Update-CleanTotal
    }
}

# ------------------------------------------------------------------ network page
$DnsButtons = [ordered]@{ auto = 'DnsAuto'; cloudflare = 'DnsCloudflare'; google = 'DnsGoogle'; quad9 = 'DnsQuad9'; adguard = 'DnsAdguard' }
function Load-Network {
    Start-Job2 { param($a, $sync) Get-BTAdapters } $null {
        param($r, $err)
        $a = @($r) | Where-Object { $_ } | Select-Object -First 1
        if (-not $a) { $ui.TxtAdapter.Text = S 'net.none'; $ui.TxtAdapterSub.Text = ''; $ui.TxtDnsNow.Text = ''; return }
        $ui.TxtAdapter.Text = $a.Name
        $ui.TxtAdapterSub.Text = '{0} - {1}' -f $a.Description, $a.Speed
        $dns = @($a.Dns)
        $ui.TxtDnsNow.Text = F 'net.dnsNow' $(if ($dns.Count) { $dns -join ', ' } else { '-' })
        foreach ($k in $BTDnsSets.Keys) { if ($dns.Count -and $dns[0] -eq $BTDnsSets[$k][0]) { $ui[$DnsButtons[$k]].IsChecked = $true } }
    }
}

# ------------------------------------------------------------------ backup page
function Update-Applied {
    $ui.AppliedList.Children.Clear()
    $backup = Read-BTBackup
    $applied = @($Tweaks | Where-Object { $backup.ContainsKey($_.id) -or $State[$_.id] -eq 'on' })
    if (-not $applied.Count) {
        $t = New-Object Windows.Controls.TextBlock; $t.Text = S 'backup.none'; $t.Foreground = $win.FindResource('Faint')
        [void]$ui.AppliedList.Children.Add($t); return
    }
    foreach ($tw in $applied) {
        $row = New-Object Windows.Controls.Border
        $row.BorderBrush = $win.FindResource('Line'); $row.BorderThickness = '0,0,0,1'; $row.Padding = '2,10'
        $dp = New-Object Windows.Controls.DockPanel
        $btn = New-Object Windows.Controls.Button; $btn.Style = $win.FindResource('Btn'); $btn.Padding = '12,4'; $btn.Content = S 'backup.undo'; $btn.Tag = $tw.id
        [Windows.Controls.DockPanel]::SetDock($btn, 'Right'); $btn.HorizontalAlignment = 'Right'
        $btn.Add_Click({ param($s, $e) $t = $Tweaks | Where-Object id -eq $s.Tag | Select-Object -First 1; Invoke-TweakChange @($t) $false })
        $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
        $n = New-Object Windows.Controls.TextBlock; $n.Text = TN $tw; $n.VerticalAlignment = 'Center'
        $when = New-Object Windows.Controls.TextBlock; $when.Foreground = $win.FindResource('Faint'); $when.FontSize = 12; $when.Margin = '12,0,0,0'; $when.VerticalAlignment = 'Center'; $when.FlowDirection = 'LeftToRight'
        if ($backup.ContainsKey($tw.id)) { try { $when.Text = ([datetime]$backup[$tw.id].time).ToString('yyyy-MM-dd HH:mm') } catch { } }
        [void]$sp.Children.Add($n); [void]$sp.Children.Add($when)
        [void]$dp.Children.Add($btn); [void]$dp.Children.Add($sp)
        $row.Child = $dp
        [void]$ui.AppliedList.Children.Add($row)
    }
}


# ------------------------------------------------------------------ smart scan
$script:Pc = $null
function Run-Scan {
    $ui.TxtScanPc.Text = S 'scan.wait'; $ui.BtnScanPc.IsEnabled = $false
    Start-Job2 { param($a, $sync) Get-BTProfile } $null {
        param($r, $err)
        $ui.BtnScanPc.IsEnabled = $true
        $pc = @($r)[0]
        if (-not $pc) { $ui.TxtScanPc.Text = F 'status.error' $(if ($err) { $err.Message } else { '?' }); return }
        $script:Pc = $pc
        Build-Tweaks; Update-AllSwitches
    }
}

function Update-Scan {
    if (-not $script:Pc) { return }
    $pc = $script:Pc
    $rec = @($Tweaks | Where-Object { Test-BTRecommended $_ $pc })
    $on = @($rec | Where-Object { $State[$_.id] -eq 'on' }).Count
    $ui.TxtScanPc.Text = F 'scan.result' $pc.RamGB $(if ($pc.Ssd) { S 'scan.ssd' } else { S 'scan.hdd' }) $(if ($pc.Laptop) { S 'scan.laptop' } else { S 'scan.desktop' }) $(if ($pc.Printers -eq 0) { S 'scan.noprinter' } else { '' }) $rec.Count $on
    $ui.BtnApplyRec.IsEnabled = $State.Count -and ($on -lt $rec.Count) -and -not $script:Busy
}

function Apply-Recommended {
    if (-not $script:Pc) { return }
    $todo = @($Tweaks | Where-Object { (Test-BTRecommended $_ $script:Pc) -and $State[$_.id] -ne 'on' })
    if (-not $todo.Count -or -not (Ask (F 'confirm.rec' $todo.Count))) { return }
    Invoke-TweakChange $todo $true (F 'status.presetDone' $todo.Count)
}

# ------------------------------------------------------------------ apps page
$script:AppsLoaded = $false
$AppBoxes = [ordered]@{}
function Load-Apps {
    $ui.TxtApps.Text = S 'apps.loading'; $ui.BtnAppsRemove.IsEnabled = $false
    Start-Job2 { param($a, $sync) @(Get-BTApps $a) } $AppCatalog {
        param($r, $err)
        $script:AppsLoaded = $true
        Build-Apps @($r)
    }
}

function Build-Apps($Info) {
    $ui.AppList.Children.Clear(); $AppBoxes.Clear()
    $removed = Get-BTRemovedApps
    $lang = $Settings.lang
    foreach ($g in 'ms', 'ads', 'xbox') {
        $head = New-Object Windows.Controls.TextBlock
        $head.Text = S "apps.g.$g"; $head.Style = $win.FindResource('H2'); $head.Margin = '0,10,0,8'
        [void]$ui.AppList.Children.Add($head)
        $wrap = New-Object Windows.Controls.WrapPanel
        foreach ($a in $AppCatalog | Where-Object group -eq $g) {
            $st = $Info | Where-Object { $_.Match -eq $a.match } | Select-Object -First 1
            $gone = $removed | Where-Object { $_.match -eq $a.match } | Select-Object -First 1
            if (-not ($st -and $st.Installed) -and -not $gone) { continue }
            $card = New-Object Windows.Controls.Border
            $card.Style = $win.FindResource('Card'); $card.Padding = '14,10'; $card.Margin = '0,0,10,10'; $card.Width = 270
            if ($st -and $st.Installed) {
                $cb = New-Object Windows.Controls.CheckBox; $cb.Style = $win.FindResource('Check'); $cb.IsChecked = [bool]$a.default; $cb.Tag = $a.match
                $t = New-Object Windows.Controls.TextBlock; $t.Text = $a.$lang; $t.TextTrimming = 'CharacterEllipsis'; $t.TextWrapping = 'NoWrap'; $t.MaxWidth = 210
                $cb.Content = $t
                $cb.Add_Click({ Update-AppCount })
                $card.Child = $cb
                $AppBoxes[$a.match] = $cb
            } else {
                $sp = New-Object Windows.Controls.StackPanel
                $t = New-Object Windows.Controls.TextBlock; $t.Text = '{0}  -  {1}' -f $a.$lang, (S 'apps.removed'); $t.Foreground = $win.FindResource('Faint')
                $lnk = New-Object Windows.Controls.TextBlock; $lnk.Text = S 'apps.restore'; $lnk.Foreground = $win.FindResource('Accent'); $lnk.Cursor = 'Hand'; $lnk.Margin = '0,4,0,0'; $lnk.Tag = $gone.family
                $lnk.Add_MouseLeftButtonUp({ param($s, $e) Start-Process ("ms-windows-store://pdp/?PFN=" + $s.Tag) })
                [void]$sp.Children.Add($t); [void]$sp.Children.Add($lnk)
                $card.Child = $sp
            }
            [void]$wrap.Children.Add($card)
        }
        if ($wrap.Children.Count) { [void]$ui.AppList.Children.Add($wrap) } else { [void]$ui.AppList.Children.Remove($head) }
    }
    if (-not $ui.AppList.Children.Count) {
        $t = New-Object Windows.Controls.TextBlock; $t.Text = S 'apps.none'; $t.Foreground = $win.FindResource('Faint'); [void]$ui.AppList.Children.Add($t)
    }
    Update-AppCount
}

function Update-AppCount {
    $sel = @($AppBoxes.Values | Where-Object { $_.IsChecked }).Count
    $ui.TxtApps.Text = F 'apps.count' $AppBoxes.Count $sel
    $ui.BtnAppsRemove.IsEnabled = $sel -gt 0 -and -not $script:Busy
}

function Remove-SelectedApps {
    $sel = @($AppBoxes.Keys | Where-Object { $AppBoxes[$_].IsChecked })
    if (-not $sel.Count -or -not (Ask (F 'apps.confirm' $sel.Count))) { return }
    Show-Busy (S 'busy')
    Start-Job2 { param($a, $sync) @(Remove-BTApps $a) } $sel {
        param($r, $err)
        Hide-Busy
        if ($err) { Set-Status (F 'status.error' $err.Message) } else { Set-Status (F 'apps.done' @($r).Count) }
        Load-Apps
    }
}

# ------------------------------------------------------------------ startup page
function Load-Startup {
    Start-Job2 { param($a, $sync) @(Get-BTStartupItems) } $null { param($r, $err) Build-Startup @($r | Where-Object { $_ }) }
}

function Build-Startup($Items) {
    $ui.StartupList.Children.Clear()
    $ui.TxtStartupCount.Text = F 'startup.count' $Items.Count @($Items | Where-Object Enabled).Count
    if (-not $Items.Count) {
        $t = New-Object Windows.Controls.TextBlock; $t.Text = S 'startup.none'; $t.Foreground = $win.FindResource('Faint'); [void]$ui.StartupList.Children.Add($t); return
    }
    foreach ($it in $Items) {
        $card = New-Object Windows.Controls.Border
        $card.Style = $win.FindResource('Card'); $card.Padding = '16,12'; $card.Margin = '0,0,0,8'
        $dp = New-Object Windows.Controls.DockPanel
        $sw = New-Object Windows.Controls.CheckBox; $sw.Style = $win.FindResource('Switch'); $sw.IsChecked = [bool]$it.Enabled; $sw.Margin = '16,0,0,0'
        $sw.Tag = $it
        [Windows.Controls.DockPanel]::SetDock($sw, 'Right')
        $sw.Add_Click({
            param($s, $e)
            try {
                Set-BTStartupItem $s.Tag ([bool]$s.IsChecked)
                $s.Tag.Enabled = [bool]$s.IsChecked
                Set-Status $(if ($s.IsChecked) { F 'startup.on' $s.Tag.Name } else { F 'startup.off' $s.Tag.Name })
            } catch { $s.IsChecked = -not $s.IsChecked; Set-Status (F 'status.error' $_.Exception.Message) }
        })
        $sp = New-Object Windows.Controls.StackPanel
        $n = New-Object Windows.Controls.TextBlock; $n.Text = $it.Name -replace '(?i)\.(lnk|url)$', ''; $n.FontWeight = 'SemiBold'; $n.FontSize = 14
        $where = if ($it.Kind -eq 'store') { S 'startup.store' } elseif ($it.Scope -eq 'user') { S 'startup.user' } else { S 'startup.machine' }
        $meta = New-Object Windows.Controls.TextBlock; $meta.Foreground = $win.FindResource('Muted'); $meta.FontSize = 12; $meta.Margin = '0,2,0,0'
        $meta.Text = (@($it.Publisher, $where) | Where-Object { $_ }) -join '  -  '
        $cmd = New-Object Windows.Controls.TextBlock; $cmd.Text = $it.Command; $cmd.Foreground = $win.FindResource('Faint'); $cmd.FontSize = 11.5; $cmd.TextTrimming = 'CharacterEllipsis'; $cmd.TextWrapping = 'NoWrap'; $cmd.FlowDirection = 'LeftToRight'; $cmd.HorizontalAlignment = 'Right'; $cmd.Margin = '0,3,0,0'
        if ($Settings.lang -ne 'ar') { $cmd.HorizontalAlignment = 'Left' }
        [void]$sp.Children.Add($n); [void]$sp.Children.Add($meta); [void]$sp.Children.Add($cmd)
        [void]$dp.Children.Add($sw); [void]$dp.Children.Add($sp)
        $card.Child = $dp
        [void]$ui.StartupList.Children.Add($card)
    }
}

# ------------------------------------------------------------------ export / import
function Get-AppliedIds { @($Tweaks | Where-Object { $State[$_.id] -eq 'on' } | ForEach-Object id) }
function Update-Cli {
    $ids = Get-AppliedIds
    $ui.TxtCli.Text = if ($ids.Count) { "& ([ScriptBlock]::Create((irm mr-kateba.github.io/tweak))) -Apply $($ids -join ',')" } else { "& ([ScriptBlock]::Create((irm mr-kateba.github.io/tweak))) -Preset recommended" }
}
function Export-Settings {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = 'BlazmaTweak-{0:yyyy-MM-dd}.json' -f (Get-Date); $dlg.Filter = "$(S 'file.filter') (*.json)|*.json"
    if (-not $dlg.ShowDialog($win)) { return }
    $ids = Get-AppliedIds
    Export-BTConfig $dlg.FileName $ids
    Set-Status (F 'status.exported' $ids.Count)
}
function Import-Settings {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = "$(S 'file.filter') (*.json)|*.json"
    if (-not $dlg.ShowDialog($win)) { return }
    try { $ids = Import-BTConfig $dlg.FileName } catch { Set-Status (S 'status.badfile'); return }
    $list = @($Tweaks | Where-Object { $ids -contains $_.id })
    $todo = @($list | Where-Object { $State[$_.id] -ne 'on' })
    if (-not $todo.Count) { Set-Status (S 'preset.done'); return }
    if (-not (Ask (F 'confirm.import' $list.Count $todo.Count))) { return }
    Invoke-TweakChange $todo $true (F 'status.presetDone' $todo.Count)
}

# ------------------------------------------------------------------ navigation + language
$Pages = [ordered]@{ NavHome = 'PageHome'; NavTweaks = 'PageTweaks'; NavApps = 'PageApps'; NavStartup = 'PageStartup'; NavMemory = 'PageMemory'; NavPower = 'PagePower'; NavClean = 'PageClean'; NavNet = 'PageNet'; NavBackup = 'PageBackup' }
$NavKeys = @{ NavHome = 'nav.home'; NavTweaks = 'nav.tweaks'; NavApps = 'nav.apps'; NavStartup = 'nav.startup'; NavMemory = 'nav.memory'; NavPower = 'nav.power'; NavClean = 'nav.clean'; NavNet = 'nav.net'; NavBackup = 'nav.backup' }
function Show-Page([string]$Nav) {
    foreach ($k in $Pages.Keys) { $ui[$Pages[$k]].Visibility = if ($k -eq $Nav) { 'Visible' } else { 'Collapsed' } }
    $ui[$Nav].IsChecked = $true
    switch ($Nav) {
        'NavMemory' { Update-Memory }
        'NavPower'  { Load-Plans }
        'NavNet'    { Load-Network }
        'NavBackup' { Update-Applied; Update-Cli }
        'NavClean'  { if (-not $script:CleanSizes.Count) { Scan-Clean } }
        'NavApps'   { if (-not $script:AppsLoaded) { Load-Apps } }
        'NavStartup' { Load-Startup }
    }
}

function Apply-Language {
    $win.FlowDirection = if ($Settings.lang -eq 'ar') { 'RightToLeft' } else { 'LeftToRight' }
    Update-Texts $win
    foreach ($k in $NavKeys.Keys) { $ui[$k].Content = S $NavKeys[$k] }
    Build-Presets; Build-Tweaks; Build-Clean; Update-AllSwitches; Update-Applied
    $ui.TxtVersion.Text = "v$BTVersion - kateba"
}

# ------------------------------------------------------------------ events
foreach ($k in $Pages.Keys) {
    $ui[$k].Tag = [Windows.Media.Geometry]::Parse([string]$ui[$k].Tag)   # icon path for the nav template
    $ui[$k].Add_Checked({ param($s, $e) Show-Page $s.Name })
}
$ui.BtnClose.Add_Click({ $win.Close() })
$ui.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ $win.WindowState = if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
$ui.BtnLang.Add_Click({ $Settings.lang = if ($Settings.lang -eq 'ar') { 'en' } else { 'ar' }; Save-Settings; Apply-Language })
$ui.TxtSearch.Add_TextChanged({ Filter-Tweaks })
$ui.ChkRestore.Add_Click({ $Settings.restore = [bool]$ui.ChkRestore.IsChecked; Save-Settings })
$ui.BtnMemClean.Add_Click({ Clean-Memory $true })
$ui.BtnMemStandby.Add_Click({ Clean-Memory $false })
$ui.ChkAutoClean.Add_Click({ $Settings.autoClean = [bool]$ui.ChkAutoClean.IsChecked; Save-Settings })
$ui.CmbAuto.Add_SelectionChanged({ $Settings.threshold = [int]($ui.CmbAuto.SelectedItem.Content -replace '%', ''); Save-Settings })
$ui.BtnUltimate.Add_Click({ Add-BTUltimatePlan | Out-Null; Load-Plans; Set-Status (S 'status.plan') })
$ui.BtnScan.Add_Click({ Scan-Clean })
$ui.BtnClean.Add_Click({ Run-Clean })
$ui.BtnPing.Add_Click({
    $ui.TxtPing.Text = '...'
    Start-Job2 { param($a, $sync) Test-BTPing } $null { param($r, $err) $p = @($r)[0]; $ui.TxtPing.Text = if ($p -ne $null) { F 'net.pingResult' $p } else { S 'net.pingFail' } }
})
$ui.BtnDns.Add_Click({
    $set = ($DnsButtons.Keys | Where-Object { $ui[$DnsButtons[$_]].IsChecked } | Select-Object -First 1)
    Show-Busy (S 'busy')
    Start-Job2 { param($a, $sync) Set-BTDns $a } $set { param($r, $err) Hide-Busy; if ($err) { Set-Status (F 'status.error' $err.Message) } else { Set-Status (S 'status.dns') }; Load-Network }
})
$ui.BtnFlush.Add_Click({ if (-not $BTDryRun) { Clear-DnsClientCache }; Set-Status (S 'status.flushed') })
$ui.BtnNetReset.Add_Click({
    if (-not (Ask (S 'confirm.reset'))) { return }
    Reset-BTNetwork; $script:NeedReboot = $true; $ui.PillReboot.Visibility = 'Visible'; Set-Status (S 'status.netReset')
})
$ui.BtnRestorePoint.Add_Click({
    Show-Busy (S 'status.rp')
    Start-Job2 { param($a, $sync) New-BTRestorePoint 'Blazma Tweak' } $null {
        param($r, $err) Hide-Busy
        if (@($r)[0] -eq $true) { $script:RestoreDone = $true; Set-Status (S 'status.rpOk') } else { Set-Status (S 'status.rpFail') }
    }
})
$ui.BtnSysRestore.Add_Click({ Start-Process rstrui.exe })
$ui.BtnFolder.Add_Click({ if (-not (Test-Path $BTDir)) { New-Item -ItemType Directory -Path $BTDir -Force | Out-Null }; Start-Process explorer.exe $BTDir })
$ui.BtnUndoAll.Add_Click({
    $backup = Read-BTBackup
    $list = @($Tweaks | Where-Object { $backup.ContainsKey($_.id) })
    if (-not $list.Count -or -not (Ask (F 'confirm.undoAll' $list.Count))) { return }
    Invoke-TweakChange $list $false (S 'status.undoAllDone')
})
$ui.BtnScanPc.Add_Click({ Run-Scan })
$ui.BtnApplyRec.Add_Click({ Apply-Recommended })
$ui.BtnAppsRefresh.Add_Click({ Load-Apps })
$ui.BtnAppsRemove.Add_Click({ Remove-SelectedApps })
$ui.BtnExport.Add_Click({ Export-Settings })
$ui.BtnImport.Add_Click({ Import-Settings })
$ui.BtnExplorer.Add_Click({ Restart-BTExplorer; $ui.BtnExplorer.Visibility = 'Collapsed' })

$MemTimer = New-Object Windows.Threading.DispatcherTimer
$MemTimer.Interval = [TimeSpan]::FromSeconds(2)
$MemTimer.Add_Tick({ if ($ui.PageMemory.Visibility -eq 'Visible' -or $ui.ChkAutoClean.IsChecked) { Update-Memory } })

$win.Add_Closed({ $JobTimer.Stop(); $MemTimer.Stop(); try { $Pool.Close() } catch { } })

# ------------------------------------------------------------------ screenshots for the docs (-Shot <folder>)
function Save-Shot([string]$Path) {
    $win.UpdateLayout()
    $root = $win.Content
    $w = [int]$root.ActualWidth; $h = [int]$root.ActualHeight
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap $w, $h, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($root)
    $img = $bmp
    # an element laid out right-to-left renders mirrored on its own; flip it back
    if ($win.FlowDirection -eq 'RightToLeft') { $img = New-Object Windows.Media.Imaging.TransformedBitmap $bmp, (New-Object Windows.Media.ScaleTransform -1, 1) }
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($img))
    $fs = [IO.File]::Create($Path); $enc.Save($fs); $fs.Close()
}

if ($Shot) {
    if (-not (Test-Path $Shot)) { New-Item -ItemType Directory -Path $Shot -Force | Out-Null }
    # Each page gets a few ticks to load its data, then is saved as <nn>_<page>_<lang>.png.
    $script:ShotQueue = New-Object System.Collections.Queue
    $script:ShotWait = 0
    foreach ($k in $Pages.Keys) { $script:ShotQueue.Enqueue($k) }
    $ShotTimer = New-Object Windows.Threading.DispatcherTimer
    $ShotTimer.Interval = [TimeSpan]::FromMilliseconds(700)
    $ShotTimer.Add_Tick({
        if (-not $script:StatesLoaded -and $script:ShotWait++ -lt 60) { return }
        if ($BTDryRun -and -not $script:ShotFlow) {
            # in test mode also run the real apply path once (nothing is written)
            $script:ShotFlow = $true
            $todo = @($Tweaks | Where-Object { $_.presets -contains 'gaming' -and $State[$_.id] -ne 'on' })
            Invoke-TweakChange $todo $true (F 'status.presetDone' $todo.Count)
            return
        }
        if ($script:Busy) { return }
        if ($script:ShotCurrent) {
            if ($script:ShotTicks-- -gt 0 -or $script:Busy) { return }
            $n = $Pages.Count - $script:ShotQueue.Count - 1
            Save-Shot (Join-Path $Shot ('{0:00}_{1}_{2}.png' -f $n, $script:ShotCurrent.Substring(3).ToLower(), $Settings.lang))
            $script:ShotCurrent = $null
        }
        if (-not $script:ShotQueue.Count) { $ShotTimer.Stop(); $win.Close(); return }
        $script:ShotCurrent = $script:ShotQueue.Dequeue()
        $script:ShotTicks = if ($script:ShotCurrent -in 'NavClean', 'NavApps', 'NavStartup') { 8 } else { 2 }
        Show-Page $script:ShotCurrent
    })
}

# ------------------------------------------------------------------ go
if ($BTDryRun) { $ui.DryPill.Visibility = 'Visible' }
if (-not $isAdmin) { $ui.AdminPill.Visibility = 'Collapsed' }
$ui.ChkRestore.IsChecked = [bool]$Settings.restore
$ui.ChkAutoClean.IsChecked = [bool]$Settings.autoClean
foreach ($item in $ui.CmbAuto.Items) { if ($item.Content -eq "$($Settings.threshold)%") { $item.IsSelected = $true } }
Apply-Language
$win.Add_ContentRendered({
    try {
        Load-SystemInfo
        Load-States
        Run-Scan
        $MemTimer.Start()
        if ($Shot) { $ShotTimer.Start() }
    } catch { Write-BTLog "start error: $_ $($_.InvocationInfo.PositionMessage)" }
})
Write-BTLog "start v$BTVersion admin=$isAdmin dry=$BTDryRun"
[void]$win.ShowDialog()
