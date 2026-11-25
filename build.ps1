# Builds dist/BlazmaTweak.ps1: one ASCII-only script with the engine, window and data embedded,
# so it runs the same from `irm ... | iex` (Windows PowerShell reads scripts with the legacy code page).
param([switch]$Run)

$root = $PSScriptRoot
$utf8 = New-Object Text.UTF8Encoding($false)
function Read-Utf8([string]$Rel) { [IO.File]::ReadAllText((Join-Path $root $Rel), $utf8) }

# Arabic in JSON becomes \uXXXX, in XAML &#xXXXX;
function Protect-Json([string]$Text) { [regex]::Replace($Text, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value }) }
function Protect-Xml([string]$Text) { [regex]::Replace($Text, '[\uD800-\uDBFF][\uDC00-\uDFFF]|[^\x00-\x7F]', { param($m) '&#x{0:X};' -f [char]::ConvertToUtf32($m.Value, 0) }) }
function Assert-Ascii([string]$Name, [string]$Text) {
    $m = [regex]::Match($Text, '[^\x00-\x7F]')
    if ($m.Success) { throw "$Name has a non-ASCII character at offset $($m.Index): '$($m.Value)'" }
}
function Assert-HereString([string]$Name, [string]$Text) {
    if ($Text -match "(?m)^'@") { throw "$Name contains a line starting with '@ and can't be embedded" }
}

$main = Read-Utf8 'src\main.ps1'
$core = Read-Utf8 'src\core.ps1'
$xaml = Protect-Xml (Read-Utf8 'src\ui.xaml')
$tweaks = Protect-Json ((Read-Utf8 'config\tweaks.json') | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress)
$strings = Protect-Json ((Read-Utf8 'config\strings.json') | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress)
$apps = Protect-Json ((Read-Utf8 'config\apps.json') | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress)
Assert-Ascii 'src\main.ps1' $main
Assert-Ascii 'src\core.ps1' $core
foreach ($p in @(@('core', $core), @('xaml', $xaml), @('tweaks', $tweaks), @('strings', $strings), @('apps', $apps))) { Assert-HereString $p[0] $p[1] }

# The parts go right after the param() block, which has to stay first in the script.
$cut = $main.IndexOf('$BTVersion =')
if ($cut -lt 0) { throw 'main.ps1: $BTVersion line not found' }
$nl = "`r`n"
$embedded = '$BTCoreText = @''' + $nl + $core + $nl + '''@' + $nl +
            '$BTXaml = @''' + $nl + $xaml + $nl + '''@' + $nl +
            '$BTTweaksJson = @''' + $nl + $tweaks + $nl + '''@' + $nl +
            '$BTStringsJson = @''' + $nl + $strings + $nl + '''@' + $nl +
            '$BTAppsJson = @''' + $nl + $apps + $nl + '''@' + $nl + $nl
$out = $main.Substring(0, $cut) + $embedded + $main.Substring($cut)
$out = $out -replace "`r?`n", "`r`n"

$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($out, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "The built script does not parse: $($errors[0].Message) at line $($errors[0].Extent.StartLineNumber)" }
Assert-Ascii 'dist' $out

$dist = Join-Path $root 'dist'
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
$file = Join-Path $dist 'BlazmaTweak.ps1'
[IO.File]::WriteAllText($file, $out, [Text.Encoding]::ASCII)
'{0}  {1:n0} KB' -f $file, ((Get-Item $file).Length / 1KB)

if ($Run) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $file }
