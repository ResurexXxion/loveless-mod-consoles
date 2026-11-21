<#
.SYNOPSIS
    Mass Effect Console - live external log console, crash post-mortem and setup checker for
    Mass Effect 1 (Legendary Edition, Steam, Windows, ME3Tweaks Mod Manager install).

.DESCRIPTION
    ME1 LE has no log of its own that shows engine crashes. What it does have:
      Logs\bink2w64_proxy.log   LEBinkProxy: ASI loading, hook installs, and "OnDetach ... goodbye" on a clean teardown
      Logs\AutoloadEnabler.log  DLC_MOD scan, TFC/ISB registration, DLC mount order, startup files
      Logs\TextureOverride.log  every texture replaced by ALOT / Improved Static Lighting / AVC (names the level being loaded)
    This tool follows all of them, times the load phases, and adds what the logs cannot say by themselves:
      * Setup check before launch: proxy DLL pair, ASI list, DLC_MOD folders, Steam build id, Coalesced_INT.bin,
        and a diff against your last CLEAN run ("what changed since it last worked").
      * Process watch for MassEffect1.exe: exit code, memory, GPU memory/temperature (nvidia-smi), not-responding.
      * Crash evidence the logs lack: Windows Application Error (faulting module/offset), WER dumps, hardware events.
      * Save protection: copies Save\ME1 at start and after every save the game writes.
      * Keeps a copy of every session (the game overwrites its logs on each launch).
    Read-only toward the game folders. Writes only to its own data folder and a copy of your saves.

    Keys: ? help  q quit  p pause  c clear  l level  v noise  r raw  s summary  m mods  g gpu/setup  e errors
          h system events  b bless current setup as known-good  a snapshot  o open folder  f filter  x exclude  i info
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$OutDir,
    [ValidateSet('Debug','Info','Warn','Error')][string]$MinLevel = 'Info',
    [string]$Include,
    [string]$Exclude,
    [string]$ProcessName = 'MassEffect1',
    [string[]]$ExtraLog = @(),
    [int]$Backlog = 25,
    [int]$ShowRepeats = 3,
    [int]$PollMs = 250,
    [int]$SnapshotSec = 30,
    [switch]$FromStart,
    [switch]$Raw,
    [switch]$NoColor,
    [switch]$NoFooter,
    [switch]$NoArchive,
    [switch]$NoSystemEvents,
    [switch]$NoSaveBackup,
    [switch]$NoGpu,
    [switch]$Ascii,
    [switch]$Analyze,
    [string]$AnalyzeFolder,
    [string]$DumpFile,
    [int]$KeepSessions = 30,
    [int]$KeepSaveBackups = 20,
    [int]$MaxSeconds = 0,
    [switch]$Quit,
    [switch]$Bless,
    [string]$SaveDir,
    [switch]$AllowMultiple
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:Ver     = '1.0'
$script:IsWin   = ($env:OS -eq 'Windows_NT')
$script:Utf8    = New-Object System.Text.UTF8Encoding($false)
$script:RunStart = [datetime]::Now
$script:Ci = [System.Globalization.CultureInfo]::InvariantCulture

#region output layer
$script:Esc = [string][char]27
$script:UseColor  = (-not $NoColor)
$script:Footer    = (-not $NoFooter)
$script:Interactive = $true
$script:Quiet = $false; $script:Paused = $false
$script:PauseQ = New-Object System.Collections.Generic.Queue[string]
$script:Ring = New-Object System.Collections.Generic.List[string]
$script:Transcript = $null; $script:CaptureTo = $null; $script:Tee = $null
$script:WinH = 0
$script:SGR = @{ reset='0'; bold='1'; dim='2'; rev='7'; red='31'; green='32'; yellow='33'; blue='34'; mag='35'; cyan='36'; white='97'
    gray='90'; bred='1;31'; bgreen='1;32'; byellow='1;33'; bcyan='1;36'; bmag='1;35'; bwhite='1;97' }
function Col([string]$name) { if ($script:UseColor -and $script:SGR.ContainsKey($name)) { return ($script:Esc + '[' + $script:SGR[$name] + 'm') } return '' }
$script:R = ''
if ($Ascii) { $script:G = @{ dot='*'; bar='='; arrow='>'; star='*'; up='^'; sep='|'; ell='...'; rep='x' } }
else { $script:G = @{ dot=[string][char]0x25CF; bar=[string][char]0x2550; arrow=[string][char]0x25B6; star=[string][char]0x2605; up=[string][char]0x2191; sep=[string][char]0x2502; ell=[string][char]0x2026; rep=[string][char]0x00D7 } }

function Enable-VT {
    if (-not $script:IsWin) { return $true }
    try {
        if (-not ('MeNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class MeNative {
  [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
  [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
  [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
'@
        }
        $h = [MeNative]::GetStdHandle(-11); [uint32]$m = 0
        if (-not [MeNative]::GetConsoleMode($h, [ref]$m)) { return $false }
        return [MeNative]::SetConsoleMode($h, ($m -bor 4))
    } catch { return $false }
}
function Dbg([string]$m) { if ($env:ME_DEBUG) { [Console]::Error.WriteLine('[dbg] ' + $m) } }
function Strip-Ansi([string]$s) { return [regex]::Replace($s, "\x1B\[[0-9;?]*[A-Za-z]", '') }
function Out-Raw([string]$text) { try { [Console]::Out.Write($text) } catch { } }

function Write-Line([string]$rendered, [bool]$ring = $false) {
    $plain = Strip-Ansi $rendered
    if ($null -ne $script:CaptureTo) { $script:CaptureTo.Add($plain); return }
    if ($null -ne $script:Tee) { $script:Tee.Add($plain) }
    if ($null -ne $script:Transcript) { try { $script:Transcript.WriteLine($plain) } catch { } }
    if ($ring) { $script:Ring.Add($rendered); if ($script:Ring.Count -gt 600) { $script:Ring.RemoveRange(0, 100) } }
    if ($script:Quiet) { return }
    if ($script:Paused) { if ($script:PauseQ.Count -lt 5000) { $script:PauseQ.Enqueue($rendered) }; return }
    Out-Raw ($rendered + $script:R + "`n")
}
function Write-Plain([string]$text, [string]$color = '') { if ($color -ne '') { Write-Line ((Col $color) + $text + $script:R) } else { Write-Line $text } }
function Write-Banner([string]$text, [string]$color = 'bcyan') {
    $w = 78
    try { if ($script:Interactive) { $w = [Math]::Max(40, [Math]::Min(120, [Console]::WindowWidth - 2)) } } catch { }
    Write-Line ''; Write-Line ((Col $color) + ($script:G.bar * $w) + $script:R)
    Write-Line ((Col $color) + ' ' + $text + $script:R); Write-Line ((Col $color) + ($script:G.bar * $w) + $script:R)
}
function Write-Head([string]$text) {
    Write-Line ''; Write-Line ((Col 'bwhite') + $text + $script:R)
    Write-Line ((Col 'gray') + ($script:G.bar * [Math]::Min(78, [Math]::Max(10, $text.Length))) + $script:R)
}
function Trunc([string]$s, [int]$n) { if ($null -eq $s) { return '' } if ($s.Length -le $n) { return $s } return $s.Substring(0, [Math]::Max(0, $n - 1)) + $script:G.ell }
function Fmt-Span([timespan]$t) {
    if ($t.TotalHours -ge 1) { return ('{0:0}h{1:00}m{2:00}s' -f [Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds) }
    if ($t.TotalMinutes -ge 1) { return ('{0:0}m{1:00}s' -f $t.Minutes, $t.Seconds) }
    return ('{0:0.0}s' -f $t.TotalSeconds)
}
function Fmt-Bytes([double]$b) {
    if ($b -ge 1GB) { return ('{0:0.0} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:0.0} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:0} KB' -f ($b / 1KB)) }
    return ('{0:0} B' -f $b)
}
function Fmt-N([double]$n) { return ('{0:N0}' -f $n) }

function Setup-Footer {
    if (-not $script:Footer -or -not $script:Interactive) { return }
    try {
        $h = [Console]::WindowHeight
        if ($h -lt 6) { $script:Footer = $false; return }
        $script:WinH = $h
        Out-Raw ($script:Esc + '[1;' + ($h - 1) + 'r'); Out-Raw ($script:Esc + '[' + ($h - 1) + ';1H')
    } catch { $script:Footer = $false }
}
function Reset-Footer {
    if (-not $script:Interactive) { return }
    try { if ($script:WinH -gt 0) { Out-Raw ($script:Esc + '[r'); Out-Raw ($script:Esc + '[' + $script:WinH + ';1H' + $script:Esc + '[2K') } } catch { }
}
function Draw-Footer([string]$text) {
    if (-not $script:Footer -or -not $script:Interactive) { return }
    try {
        $h = [Console]::WindowHeight; $w = [Console]::WindowWidth
        if ($h -ne $script:WinH) { Setup-Footer }
        $t = (Trunc $text ($w - 1)).PadRight($w - 1)
        Out-Raw ($script:Esc + '7' + $script:Esc + '[' + $h + ';1H' + (Col 'rev') + $t + $script:R + $script:Esc + '8')
    } catch { }
}
function Set-Title([string]$t) { if ($script:Interactive) { try { $Host.UI.RawUI.WindowTitle = $t } catch { } } }
#endregion

#region state, rules, classifier
$script:LvlName = @('DBG','INF','WRN','ERR')
$script:LvlCol  = @('gray','white','byellow','bred')
$script:MinLvl  = @{ Debug=0; Info=1; Warn=2; Error=3 }[$MinLevel]
$script:RxInclude = $null; $script:RxExclude = $null
if ($Include) { $script:RxInclude = New-Object System.Text.RegularExpressions.Regex($Include, 'IgnoreCase') }
if ($Exclude) { $script:RxExclude = New-Object System.Text.RegularExpressions.Regex($Exclude, 'IgnoreCase') }
$script:ShowNoise = $false
$script:ShowRaw = [bool]$Raw

# level-code -> name. Only what is certain is built in; add more in data\levels.txt as CODE=Name (e.g. ICE20=Noveria).
$script:LevelNames = @{ 'PRO10'='Eden Prime'; 'NOR10'='SSV Normandy' }

function New-Session {
    return @{
        Start=$null; Phase='Idle'; PhaseSince=[datetime]::Now; PhaseT=$null; PhaseLog=(New-Object System.Collections.Generic.List[string])
        Lines=0; Noise=0; Err=0; Warn=0; Cats=@{}; ErrSig=@{}
        RecentMap=@{}; RecentOrder=(New-Object System.Collections.Generic.List[string])
        ProxyVer=''; ExePath=''; AttachT=$null; AllDoneT=$null; CleanExit=$false; Detaching=$false
        AsiFound=(New-Object System.Collections.Generic.List[string]); Asi=@{}; Attached=(New-Object 'System.Collections.Generic.HashSet[string]')
        HooksCreated=(New-Object 'System.Collections.Generic.HashSet[string]'); HooksEnabled=(New-Object 'System.Collections.Generic.HashSet[string]')
        Offsets=0; BindHook=$false
        Mounts=@{}; MountOrder=(New-Object System.Collections.Generic.List[string]); MountedN=0; StartupFiles=(New-Object System.Collections.Generic.List[string])
        Tex=@{}; TexTotal=0; TexFirstT=$null; LastTexObj=''; LastTexSrc=''; Manifests=(New-Object System.Collections.Generic.List[string])
        Levels=@{}; LevelOrder=(New-Object System.Collections.Generic.List[string]); LvlCur=''; LvlCand=''; LvlCandN=0
        LastLineAt=[datetime]::Now; LoadOrderOk=$null
    }
}
$script:S = New-Session

function Get-Cat([string]$id, [string]$title, [int]$lvl) {
    if ($script:S.Cats.ContainsKey($id)) { return $script:S.Cats[$id] }
    $c = @{ Id=$id; Title=$title; Lvl=$lvl; Count=0; Printed=0; Told=$false; First=''; Last=''; Owners=@{}; Samples=(New-Object System.Collections.Generic.List[string]) }
    $script:S.Cats[$id] = $c
    return $c
}
function New-Rule([string]$id,[string]$kind,[string]$rx,[string]$mode,[int]$lvl,[string]$title) {
    return [pscustomobject]@{ Id=$id; Kind=$kind; Rx=(New-Object System.Text.RegularExpressions.Regex($rx, 'Compiled')); Mode=$mode; Lvl=$lvl; Title=$title }
}
$script:Rules = @{}
function Add-Rule($r) { if (-not $script:Rules.ContainsKey($r.Kind)) { $script:Rules[$r.Kind] = New-Object System.Collections.Generic.List[object] } $script:Rules[$r.Kind].Add($r) }

# ---- LEBinkProxy log (bink2w64_proxy.log)
Add-Rule (New-Rule 'p_attach'  'proxy' '^Attached\.\.\.' 'special' 1 'Proxy attached')
Add-Rule (New-Rule 'p_ver'     'proxy' '^Version="(?<key>[^"]+)"' 'special' 1 'Proxy version')
Add-Rule (New-Rule 'p_exe'     'proxy' '^\.\.Initialize: exe path = (?<key>.+)$' 'special' 1 'Game exe')
Add-Rule (New-Rule 'p_found'   'proxy' '^Found ASI: (?<key>.+)$' 'special' 1 'ASI found')
Add-Rule (New-Rule 'p_info'    'proxy' "registerLoadInfo_: provided info: '(?<key>[^']+)' \(ver (?<ver>[\d.]+)\) by '(?<by>[^']*)'" 'special' 1 'ASI info')
Add-Rule (New-Rule 'p_spi'     'proxy' 'SpiSupportDecl' 'hide' 0 'Raw ASI without SPI support (normal for AutoTOCLE)')
Add-Rule (New-Rule 'p_attached' 'proxy' 'PostLoad: OnAttach dispatch succeeded \[(?<key>[^\]]+)\]' 'special' 1 'ASI attached')
Add-Rule (New-Rule 'p_offs'    'proxy' 'findOffsets_: found (?<key>.+?) at ' 'special' 1 'Engine offset found')
Add-Rule (New-Rule 'p_hook'    'proxy' 'HookManager\.Install: installed hook \[(?<key>[^\]]+)\]' 'special' 1 'Core hook installed')
Add-Rule (New-Rule 'p_shc'     'proxy' 'SharedHookMngr\.Install: created \[(?<key>[^\]]+)\]' 'special' 0 'Hook created')
Add-Rule (New-Rule 'p_she'     'proxy' 'SharedHookMngr\.Install: enabled \[(?<key>[^\]]+)\]' 'special' 0 'Hook enabled')
Add-Rule (New-Rule 'p_detach'  'proxy' '^OnDetach: entered' 'special' 1 'Shutdown begun')
Add-Rule (New-Rule 'p_bye'     'proxy' '^OnDetach: goodbye' 'special' 1 'Clean teardown')
Add-Rule (New-Rule 'p_noise'   'proxy' '^(\.\.|registerLoadInfo_|directoryExists_|AsiLoaderModule|dispatchAttach_|detourOffsets_|WaitForDRM|OnAttach|HookManager|SharedHookMngr|LEBinkProxy|Only trust|UFunctionBind|OnDetach)' 'hide' 0 'Proxy routine messages')
# ---- ME3Tweaks ASI logs (AutoloadEnabler, TextureOverride, ...)
Add-Rule (New-Rule 'a_scan'    'asi' '^Performing DLC content scan' 'special' 1 'DLC scan')
Add-Rule (New-Rule 'a_scandone' 'asi' '^DLC content scan completed' 'special' 1 'DLC scan done')
Add-Rule (New-Rule 'a_found'   'asi' '^Found DLC Autoload\.ini: (?<key>.+?)[\\/]AutoLoad\.ini, mount (?<mount>\d+)' 'special' 1 'DLC autoload')
Add-Rule (New-Rule 'a_tfc'     'asi' '^Registering DLC mod TFCs' 'special' 1 'TFC registration')
Add-Rule (New-Rule 'a_tfcdone' 'asi' '^TFC Registration complete' 'special' 1 'TFC done')
Add-Rule (New-Rule 'a_isb'     'asi' '^Registering DLC mod ISBs' 'special' 1 'ISB registration')
Add-Rule (New-Rule 'a_isbdone' 'asi' '^ISB Registration complete' 'special' 1 'ISB done')
Add-Rule (New-Rule 'a_mounting' 'asi' '^Mounting DLC mods$' 'special' 1 'DLC mounting')
Add-Rule (New-Rule 'a_mountone' 'asi' '^Mounting DLC mod Autoload\.ini (?<key>.+?)[\\/]AutoLoad\.ini' 'special' 0 'DLC mounted')
Add-Rule (New-Rule 'a_mountdone' 'asi' '^DLC mount complete' 'special' 1 'DLC mount done')
Add-Rule (New-Rule 'a_startup' 'asi' '^Mounting startup file: (?<key>.+)$' 'special' 0 'Startup file')
Add-Rule (New-Rule 'a_alldone' 'asi' '^All AutoLoaderEnabler tasks completed' 'special' 1 'Autoload finished')
Add-Rule (New-Rule 'a_noise'   'asi' '^(Scanning |Found (TFC|ISB)|Registering (TFC|ISB)|Rooted |Hooks initialized|globals initialized|hooks initialized|looking for dlc roots|TFC registration taking place)' 'hide' 0 'Autoload/texture routine messages')
Add-Rule (New-Rule 't_manifest' 'asi' '^loading manifest .*?DLC[\\/](?<key>[^\\/]+)[\\/]' 'special' 1 'Texture manifest')
Add-Rule (New-Rule 't_mdone'   'asi' '^manifests loaded' 'hide' 0 'Manifests loaded')
Add-Rule (New-Rule 't_replace' 'asi' '^UTexture2D::Serialize: replacing (?<obj>\S+) via (?<key>\S+)' 'special' 0 'Texture replaced')

$script:RxErr  = New-Object System.Text.RegularExpressions.Regex('(?i)(^error\b|\[(error|err|fatal|crit\w*)\]|\b(fatal|exception|crash(ed)?|access violation|assertion|unhandled|stack overflow)\b|(?<![\w=])error[:!]|\bfail(ed|ure)?\b(?!\s*[=s_])|\babort(ed)?\b)', 'Compiled')
$script:RxWarn = New-Object System.Text.RegularExpressions.Regex('(?i)(^warn|\[warn\w*\]|\bwarning\b|\bdeprecated\b|\bnot found\b|\bmissing\b|\bcannot\b|\bcould not\b|\binvalid\b|\bunsupported\b)', 'Compiled')
$script:RxProxyLine = New-Object System.Text.RegularExpressions.Regex('^(\d\d:\d\d:\d\d\.\d+)\s+(.*)$', 'Compiled')
$script:RxAsiLine   = New-Object System.Text.RegularExpressions.Regex('^\[(\d\d:\d\d:\d\d\.\d+)\s+(\w+)\]\s*(?:\((?<c>[^)]*)\)\s?)?(.*)$', 'Compiled')
$script:RxNorm = New-Object System.Text.RegularExpressions.Regex('0x[0-9A-Fa-f]+|[0-9A-Fa-f]{12,16}|\d+(\.\d+)?', 'Compiled')
$script:RxLevel = New-Object System.Text.RegularExpressions.Regex('^BIOA_(?<lvl>[A-Z]{3}\d{2})(?:_|\.)', 'Compiled')
function Guess-Level([string]$m) { if ($script:RxErr.IsMatch($m)) { return 3 }; if ($script:RxWarn.IsMatch($m)) { return 2 }; return 1 }
function Norm-Sig([string]$m) { return $script:RxNorm.Replace($m, 'N') }

$script:pT = ''; $script:pL = 1; $script:pM = ''
function Parse-Line([string]$kind, [string]$line) {
    if ($kind -eq 'proxy') {
        $m = $script:RxProxyLine.Match($line)
        if ($m.Success) { $script:pT = $m.Groups[1].Value; $script:pM = $m.Groups[2].Value } else { $script:pT = ''; $script:pM = $line }
        $script:pL = Guess-Level $script:pM
        return
    }
    $m = $script:RxAsiLine.Match($line)
    if ($m.Success) {
        $script:pT = $m.Groups[1].Value; $script:pM = $m.Groups[3].Value.TrimStart()
        switch ($m.Groups[2].Value.ToLowerInvariant()) { 'error' { $script:pL = 3 } 'err' { $script:pL = 3 } 'fatal' { $script:pL = 3 } 'critical' { $script:pL = 3 } 'warn' { $script:pL = 2 } 'warning' { $script:pL = 2 } 'debug' { $script:pL = 0 } 'trace' { $script:pL = 0 } default { $script:pL = 1 } }
        if ($script:pL -eq 1 -and $script:RxErr.IsMatch($script:pM)) { $script:pL = 3 }
        return
    }
    $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line
}

# time of day as a TimeSpan; null if unparseable
function To-Tod([string]$t) {
    if (-not $t) { return $null }
    $r = [timespan]::Zero
    if ([timespan]::TryParseExact($t, 'hh\:mm\:ss\.fff', $script:Ci, [ref]$r)) { return $r }
    if ([timespan]::TryParseExact($t, 'hh\:mm\:ss', $script:Ci, [ref]$r)) { return $r }
    return $null
}
function Tod-Diff($a, $b) {   # b - a, midnight-safe
    if ($null -eq $a -or $null -eq $b) { return $null }
    $d = $b - $a
    if ($d.TotalSeconds -lt 0) { if ($d.TotalHours -lt -12) { $d = $d + [timespan]::FromHours(24) } else { $d = [timespan]::Zero } }
    return $d
}
#endregion

#region emit, aggregate, lifecycle
$script:ModNames = @{}      # DLC_MOD_x (lower) -> friendly name
function Mod-Label([string]$dlc) {
    if ($null -eq $dlc -or $dlc -eq '') { return '' }
    $k = $dlc.ToLowerInvariant()
    if ($script:ModNames.ContainsKey($k)) { return ($dlc + ' (' + $script:ModNames[$k] + ')') }
    return $dlc
}
function Level-Label([string]$code) {
    if ($script:LevelNames.ContainsKey($code)) { return ($code + ' = ' + $script:LevelNames[$code]) }
    return $code
}

function Emit([object]$src, [string]$t, [int]$lvl, [string]$msg) {
    if ($msg.Length -gt 700) { $msg = $msg.Substring(0, 700) + $script:G.ell }
    $ts = $t; if ($ts.Length -gt 12) { $ts = $ts.Substring(0, 12) }
    $line = (Col 'gray') + $ts.PadRight(12) + ' ' + $script:R + (Col $src.Color) + $src.Tag.PadRight(5) + $script:R + ' ' + (Col $script:LvlCol[$lvl]) + $script:LvlName[$lvl] + ' ' + $msg
    Write-Line $line $true
}
function Notice([string]$text, [string]$color = 'gray') { Write-Line ((Col $color) + '             ' + $text) $true }

function Set-Phase([string]$name, $tod) {
    $S = $script:S; $now = [datetime]::Now
    $prev = $S.Phase; $took = ''
    $d = Tod-Diff $S.PhaseT $tod
    if ($null -ne $d) { $took = Fmt-Span $d } elseif ($prev -ne 'Idle') { $took = Fmt-Span ($now - $S.PhaseSince) }
    if ($prev -ne 'Idle' -and $took) { $S.PhaseLog.Add(('{0} = {1}' -f $prev, $took)) }
    $S.Phase = $name; $S.PhaseSince = $now; $S.PhaseT = $tod
    $extra = ''; if ($took -and $prev -ne 'Idle') { $extra = '   (' + $prev + ' took ' + $took + ')' }
    Write-Line ((Col 'bcyan') + ('             ' + $script:G.arrow + ' ' + $name + $extra)) $true
}

function Cat-Hit([string]$id, [string]$title, [int]$lvl, $m, [string]$msg) {
    $c = Get-Cat $id $title $lvl
    $c.Count++
    if ($m -ne $null) {
        $o = $m.Groups['key']
        if ($o.Success) { $ov = $o.Value; if ($c.Owners.ContainsKey($ov)) { $c.Owners[$ov] = $c.Owners[$ov] + 1 } else { $c.Owners[$ov] = 1 } }
    }
    if ($c.Samples.Count -lt 5) { $c.Samples.Add($msg) }
    return $c
}
function Visible([int]$lvl, [string]$msg) {
    if ($lvl -lt $script:MinLvl) { return $false }
    if ($script:RxInclude -and -not $script:RxInclude.IsMatch($msg)) { return $false }
    if ($script:RxExclude -and $script:RxExclude.IsMatch($msg)) { return $false }
    return $true
}
function Push-Recent([object]$src, [string]$t, [string]$msg) {
    $S = $script:S; $sig = $src.Tag + '|' + (Norm-Sig $msg)
    if ($S.RecentMap.ContainsKey($sig)) {
        $e = $S.RecentMap[$sig]; $e.Count++; $e.Line = ($t + ' ' + $src.Tag + ' ' + (Trunc $msg 230))
        [void]$S.RecentOrder.Remove($sig); $S.RecentOrder.Add($sig)
    } else {
        $S.RecentMap[$sig] = @{ Count=1; Line=($t + ' ' + $src.Tag + ' ' + (Trunc $msg 230)) }
        $S.RecentOrder.Add($sig)
        while ($S.RecentOrder.Count -gt 40) { $S.RecentMap.Remove($S.RecentOrder[0]); $S.RecentOrder.RemoveAt(0) }
    }
}
function Get-RecentLines([int]$n) {
    $S = $script:S; $out = New-Object System.Collections.Generic.List[string]
    $start = [Math]::Max(0, $S.RecentOrder.Count - $n)
    for ($i = $start; $i -lt $S.RecentOrder.Count; $i++) {
        $e = $S.RecentMap[$S.RecentOrder[$i]]
        $c = ''; if ($e.Count -gt 1) { $c = '   (' + $script:G.rep + (Fmt-N $e.Count) + ')' }
        $out.Add($e.Line + $c)
    }
    return $out
}

# Things the logs imply but do not say out loud. Returned as @{Lvl; Text}.
function Get-BootFindings {
    $S = $script:S; $f = New-Object System.Collections.Generic.List[object]
    if ($S.AttachT -eq $null -and $S.AsiFound.Count -eq 0 -and $S.Mounts.Count -eq 0) { return $f }
    if (-not $S.BindHook -and $S.Phase -notlike 'Proxy*') { $f.Add(@{ Lvl=3; Text='Core hook [UFunctionBind] was never installed. The ASI mods are INACTIVE (no autoload, no texture override). Usual cause: Steam updated MassEffect1.exe. Update M3 / the ASIs, or restore and reinstall.' }) }
    elseif ($S.Offsets -gt 0 -and $S.Offsets -lt 2) { $f.Add(@{ Lvl=2; Text=('Only ' + $S.Offsets + ' of 2 engine offsets were found by the proxy.') }) }
    foreach ($a in $S.AsiFound) {
        $base = $a -replace '\.asi$',''
        $hasInfo = $false; foreach ($k in $S.Asi.Keys) { if ($base -like ($k + '*')) { $hasInfo = $true } }
        $att = $false; foreach ($x in $S.Attached) { if ($x -eq $a) { $att = $true } }
        if ($hasInfo -and -not $att -and $S.BindHook) { $f.Add(@{ Lvl=3; Text=('ASI ' + $a + ' was found and registered, but never attached.') }) }
    }
    $nc = @(); foreach ($h in $S.HooksCreated) { if (-not $S.HooksEnabled.Contains($h)) { $nc += $h } }
    if ($nc.Count -gt 0) { $f.Add(@{ Lvl=3; Text=('Hook(s) created but never enabled: ' + ($nc -join ', ') + '. That ASI feature is not active.') }) }
    $dups = @{}
    foreach ($kv in $S.Mounts.GetEnumerator()) { $n = [string]$kv.Value; if (-not $dups.ContainsKey($n)) { $dups[$n] = New-Object System.Collections.Generic.List[string] }; $dups[$n].Add($kv.Key) }
    foreach ($d in $dups.GetEnumerator()) { if ($d.Value.Count -gt 1) { $f.Add(@{ Lvl=2; Text=('Mount priority ' + $d.Key + ' is shared by ' + ($d.Value -join ', ') + ' - their overlapping files conflict by chance of ordering.') }) } }
    if ($S.Mounts.Count -gt 0 -and $S.MountedN -gt 0 -and $S.MountedN -ne $S.Mounts.Count) { $f.Add(@{ Lvl=2; Text=('Found ' + $S.Mounts.Count + ' DLC_MOD autoloads but mounted ' + $S.MountedN + '.') }) }
    return $f
}

function Handle-Special([object]$src, [object]$rule, $m, [string]$t, [string]$msg) {
    $S = $script:S; $tod = To-Tod $t
    $S.LastLineAt = [datetime]::Now
    switch ($rule.Id) {
        'p_attach' {
            if ($S.Phase -ne 'Idle') { Finish-Session 'new launch detected in log' }
            $S = $script:S
            $S.Start = [datetime]::Now; $S.AttachT = $tod; $S.Lines = 1
            Write-Banner ('MASS EFFECT 1 LAUNCH   ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss') + '   (proxy attached)') 'bgreen'
            Set-Phase 'Proxy attached, loading ASI plugins' $tod
        }
        'p_ver'   { $S.ProxyVer = $m.Groups['key'].Value; Emit $src $t 1 ('LEBinkProxy ' + $S.ProxyVer) }
        'p_exe'   { $S.ExePath = $m.Groups['key'].Value; Emit $src $t 1 ('game exe: ' + $S.ExePath) }
        'p_found' { $S.AsiFound.Add($m.Groups['key'].Value); if ($script:ShowRaw) { Emit $src $t 1 $msg } }
        'p_info'  { $S.Asi[$m.Groups['key'].Value] = @{ Ver=$m.Groups['ver'].Value; By=$m.Groups['by'].Value }; Emit $src $t 1 ('ASI ' + $m.Groups['key'].Value + ' ' + $m.Groups['ver'].Value + ' (' + $m.Groups['by'].Value + ')') }
        'p_attached' { [void]$S.Attached.Add($m.Groups['key'].Value); if ($script:ShowRaw) { Emit $src $t 1 $msg } }
        'p_offs'  { $S.Offsets++; if ($script:ShowRaw) { Emit $src $t 1 $msg } }
        'p_hook'  { if ($m.Groups['key'].Value -eq 'UFunctionBind') { $S.BindHook = $true; Emit $src $t 1 'core hook [UFunctionBind] installed - ASI mods are live'; Set-Phase 'Engine hooked, ASI mods starting' $tod } elseif ($script:ShowRaw) { Emit $src $t 1 $msg } }
        'p_shc'   { [void]$S.HooksCreated.Add($m.Groups['key'].Value); if ($script:ShowRaw -or $script:MinLvl -eq 0) { Emit $src $t 0 $msg } }
        'p_she'   { [void]$S.HooksEnabled.Add($m.Groups['key'].Value); if ($script:ShowRaw -or $script:MinLvl -eq 0) { Emit $src $t 0 $msg } }
        'p_detach' { $S.Detaching = $true; Set-Phase 'Shutting down' $tod }
        'p_bye'   { $S.CleanExit = $true; Write-Line ((Col 'green') + ('             ' + $script:G.dot + ' proxy: OnDetach reached "goodbye" - the game process tore down normally')) $true }
        'a_scan'  { Set-Phase 'Autoload: scanning DLC_MOD folders' $tod }
        'a_scandone' { if ($script:ShowRaw) { Emit $src $t 1 $msg } }
        'a_found' {
            $name = $m.Groups['key'].Value -replace '^.*[\\/]',''
            $S.Mounts[$name] = [int]$m.Groups['mount'].Value
            if ($script:ShowRaw) { Emit $src $t 1 $msg }
        }
        'a_tfc'   { Set-Phase 'Autoload: registering texture files (TFC)' $tod }
        'a_tfcdone' { if ($script:ShowRaw) { Emit $src $t 1 $msg } }
        'a_isb'   { Set-Phase 'Autoload: registering sound banks (ISB)' $tod }
        'a_isbdone' { if ($script:ShowRaw) { Emit $src $t 1 $msg } }
        'a_mounting' { Set-Phase 'Autoload: mounting DLC mods' $tod }
        'a_mountone' { $S.MountedN++; $S.MountOrder.Add(($m.Groups['key'].Value -replace '^.*[\\/]','')); if ($script:ShowRaw) { Emit $src $t 1 $msg } }
        'a_mountdone' { Emit $src $t 1 ('DLC mount complete: ' + $S.MountedN + ' mods mounted (' + $S.Mounts.Count + ' autoloads found)') }
        'a_startup' { $S.StartupFiles.Add($m.Groups['key'].Value); if ($script:ShowRaw) { Emit $src $t 1 $msg } }
        'a_alldone' {
            $S.AllDoneT = $tod
            $took = ''; $d = Tod-Diff $S.AttachT $tod; if ($null -ne $d) { $took = '  Launch -> mods ready: ' + (Fmt-Span $d) + '.' }
            Set-Phase 'Mods ready (title screen / loading)' $tod
            Write-Line ((Col 'bgreen') + ('             ' + $script:G.star + ' Autoload finished. ' + $S.MountedN + ' DLC_MOD mounted, ' + $S.StartupFiles.Count + ' startup files, ' + $S.Asi.Count + ' ASIs.' + $took)) $true
            foreach ($f in (Get-BootFindings)) { Write-Line ((Col $(if ($f.Lvl -ge 3) { 'bred' } else { 'byellow' })) + ('             ! ' + $f.Text)) $true }
        }
        't_manifest' { $S.Manifests.Add($m.Groups['key'].Value); if ($script:ShowRaw) { Emit $src $t 1 $msg } }
        't_replace' {
            $s2 = $m.Groups['key'].Value; $obj = $m.Groups['obj'].Value
            $S.TexTotal++; $S.LastTexObj = $obj; $S.LastTexSrc = $s2
            if ($S.Tex.ContainsKey($s2)) { $S.Tex[$s2] = $S.Tex[$s2] + 1 } else { $S.Tex[$s2] = 1 }
            if ($S.TexTotal -eq 1) {
                $S.TexFirstT = $tod
                Emit $src $t 1 ('texture overrides are live (first: ' + $obj + ' via ' + (Mod-Label $s2) + ')')
            }
            $lm = $script:RxLevel.Match($obj)
            if ($lm.Success) {
                $code = $lm.Groups['lvl'].Value
                if ($code -ne $S.LvlCur) {
                    if ($code -eq $S.LvlCand) { $S.LvlCandN++ } else { $S.LvlCand = $code; $S.LvlCandN = 1 }
                    if ($S.LvlCandN -ge 3) {
                        $S.LvlCur = $code; $S.LvlCandN = 0
                        if ($S.Levels.ContainsKey($code)) { $S.Levels[$code] = $S.Levels[$code] + 1 } else { $S.Levels[$code] = 1; $S.LevelOrder.Add($code) }
                        Write-Line ((Col 'cyan') + ('             ' + $script:G.arrow + ' loading level ' + (Level-Label $code) + '   (from texture names)')) $true
                    }
                } else { $S.LvlCandN = 0 }
            }
            if ($script:ShowRaw -or $script:MinLvl -eq 0 -and $script:ShowNoise) { Emit $src $t 0 $msg }
        }
    }
}

function Handle-Line([object]$src, [string]$line) {
    $S = $script:S
    if ($line.Length -eq 0) { return }
    if ($line[$line.Length - 1] -eq "`r") { $line = $line.Substring(0, $line.Length - 1); if ($line.Length -eq 0) { return } }
    $S.Lines++; $S.LastLineAt = [datetime]::Now
    Parse-Line $src.Kind $line
    $t = $script:pT; $lvl = $script:pL; $msg = $script:pM
    $rule = $null; $m = $null
    $kinds = @($src.Kind); if ($src.Kind -eq 'plain') { $kinds = @('plain') }
    foreach ($kd in $kinds) {
        if ($script:Rules.ContainsKey($kd)) { foreach ($r in $script:Rules[$kd]) { $mm = $r.Rx.Match($msg); if ($mm.Success) { $rule = $r; $m = $mm; break } } }
        if ($rule) { break }
    }
    if ($rule -ne $null -and $rule.Mode -eq 'special') { Handle-Special $src $rule $m $t $msg; return }
    if ($rule -ne $null) {
        $eff = $rule.Lvl
        $c = Cat-Hit $rule.Id $rule.Title $eff $m $msg
        if ($c.First -eq '') { $c.First = $t }; $c.Last = $t
        if ($script:ShowRaw) { if (Visible 0 $msg) { Emit $src $t $eff $msg }; return }
        $S.Noise++
        if ($script:ShowNoise -and (Visible 0 $msg)) { Emit $src $t 0 $msg }
        return
    }
    if ($lvl -ge 3) { $S.Err++; $src.Err++ } elseif ($lvl -eq 2) { $S.Warn++; $src.Warn++ }
    if ($lvl -ge 2) {
        $cat = Cat-Hit ('other' + $lvl + ':' + $src.Name) ($(if ($lvl -ge 3) { 'Errors' } else { 'Warnings' }) + ' (' + $src.Name + ')') $lvl $null $msg
        if ($cat.First -eq '') { $cat.First = $t }; $cat.Last = $t
        if ($lvl -ge 3) { Push-Recent $src $t $msg }
        if ($script:ShowRaw) { if (Visible $lvl $msg) { Emit $src $t $lvl $msg }; return }
        $sig = $src.Name + '|' + (Norm-Sig $msg)
        $n = 1; if ($S.ErrSig.ContainsKey($sig)) { $n = $S.ErrSig[$sig] + 1 }; $S.ErrSig[$sig] = $n
        if (-not (Visible $lvl $msg)) { return }
        if ($n -le $ShowRepeats) { Emit $src $t $lvl $msg }
        elseif ($n -eq $ShowRepeats + 1) { Notice ($script:G.up + ' identical lines now counted silently') 'gray' }
        return
    }
    if (Visible $lvl $msg) { Emit $src $t $lvl $msg }
}
#endregion

#region discovery, tailing
$script:Sources = New-Object System.Collections.Generic.List[object]
$script:SrcByPath = @{}
$script:LeRoot = ''; $script:Me1 = ''; $script:Win64 = ''; $script:LogDir = ''; $script:DlcDir = ''
$script:LogDirOverride = ''
$script:LastScan = [datetime]::MinValue
$script:SteamApp = '1328670'
$script:Collect = $null; $script:Seq = 0
$script:RxTs = New-Object System.Text.RegularExpressions.Regex('^\[?(\d\d):(\d\d):(\d\d)(?:\.(\d+))?', 'Compiled')

function Test-LeDir([string]$d) {
    if (-not $d) { return '' }
    try {
        if (Test-Path -LiteralPath (Join-Path $d 'Game\ME1\BioGame')) { return $d }
        if (Test-Path -LiteralPath (Join-Path $d 'ME1\BioGame')) { return (Split-Path -Parent $d) }
    } catch { }
    return ''
}
function Resolve-LeRoot([string]$d) {
    $cur = $d
    for ($i = 0; $i -lt 7 -and $cur; $i++) {
        $r = Test-LeDir $cur; if ($r) { return $r }
        $p = ''; try { $p = Split-Path -Parent $cur } catch { $p = '' }
        if (-not $p -or $p -eq $cur) { break }
        $cur = $p
    }
    return ''
}
function Find-Game {
    if ($GamePath) { return (Resolve-LeRoot $GamePath) }
    $c = New-Object System.Collections.Generic.List[string]
    try { foreach ($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) { $pp = $null; try { $pp = $p.Path } catch { }; if ($pp) { $c.Add((Split-Path -Parent $pp)) } } } catch { }
    if ($script:IsWin) {
        $steam = @()
        foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
            try { $v = Get-ItemProperty -Path $k -ErrorAction Stop; foreach ($n in @('SteamPath', 'InstallPath')) { if ($v.PSObject.Properties[$n]) { $steam += [string]$v.$n } } } catch { }
        }
        $libs = New-Object System.Collections.Generic.List[string]
        foreach ($s in $steam) {
            if (-not $s) { continue }
            $libs.Add($s)
            $vdf = Join-Path $s 'steamapps\libraryfolders.vdf'
            if (Test-Path -LiteralPath $vdf) { foreach ($l in (Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue)) { if ($l -match '"path"\s+"([^"]+)"') { $libs.Add(($Matches[1] -replace '\\\\', '\')) } } }
        }
        foreach ($l in $libs) { $c.Add((Join-Path $l 'steamapps\common\Mass Effect Legendary Edition')) }
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -ne 'Fixed') { continue }
            $r = $d.RootDirectory.FullName
            foreach ($rel in @('Steam', 'SteamLibrary', 'Program Files (x86)\Steam', 'Games\Steam', 'Games\SteamLibrary')) { $c.Add((Join-Path $r ($rel + '\steamapps\common\Mass Effect Legendary Edition'))) }
        }
    }
    if ($PSScriptRoot) { $c.Add($PSScriptRoot) }
    foreach ($x in $c) { $r = Resolve-LeRoot $x; if ($r) { return $r } }
    return ''
}
function Set-GamePaths([string]$root) {
    $script:LeRoot = $root
    $script:Me1 = Join-Path $root 'Game\ME1'
    $script:Win64 = Join-Path $script:Me1 'Binaries\Win64'
    $script:LogDir = Join-Path $script:Win64 'Logs'
    $script:DlcDir = Join-Path $script:Me1 'BioGame\DLC'
}

function Get-Tag([string]$file) {
    $n = [System.IO.Path]::GetFileName($file); $l = $n.ToLowerInvariant()
    if ($l -eq 'bink2w64_proxy.log') { return @{ Kind='proxy'; Tag='PROXY'; Color='cyan' } }
    if ($l -like 'autoloadenabler*') { return @{ Kind='asi'; Tag='AUTO';  Color='white' } }
    if ($l -like 'textureoverride*') { return @{ Kind='asi'; Tag='TEX';   Color='mag' } }
    if ($l -like '*pngscreenshots*') { return @{ Kind='asi'; Tag='PNG';   Color='green' } }
    if ($l -like '*ssrunlocker*')    { return @{ Kind='asi'; Tag='SSR';   Color='yellow' } }
    $t = ($n -replace '\.(log|txt)$', '' -replace '[^A-Za-z0-9]', ''); if ($t.Length -gt 5) { $t = $t.Substring(0, 5) }
    $kind = 'plain'; if ($file -like '*Win64*Logs*') { $kind = 'asi' }
    return @{ Kind=$kind; Tag=$t.ToUpperInvariant(); Color='blue' }
}
function Add-Source([string]$path) {
    if ($script:SrcByPath.ContainsKey($path)) { return }
    $i = Get-Tag $path
    $s = [pscustomobject]@{ Name=[System.IO.Path]::GetFileName($path); Path=$path; Kind=$i.Kind; Tag=$i.Tag; Color=$i.Color; Order=$script:Sources.Count; Pos=[long]0; Head=''; Rest=$null; Bytes=[long]0; Lines=0; Resets=0; Seen=$false; Err=0; Warn=0; PrevSec=[double]0; Day=0 }
    $script:Sources.Add($s); $script:SrcByPath[$path] = $s
}
function Scan-Sources {
    $dirs = New-Object System.Collections.Generic.List[string]
    if ($script:LogDirOverride) { $dirs.Add($script:LogDirOverride) }
    else {
        $dirs.Add($script:LogDir)
        $dirs.Add((Join-Path $script:Me1 'BioGame\Logs'))
        $docs = ''; try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch { }
        if ($docs) { $dirs.Add((Join-Path $docs 'BioWare\Mass Effect Legendary Edition\Logs')) }
    }
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        try { foreach ($f in [System.IO.Directory]::EnumerateFiles($d)) { if ($f.EndsWith('.log', 'OrdinalIgnoreCase')) { $files.Add($f) } } } catch { }
    }
    # the proxy log must be read first: its "Attached..." line starts a session, the ASI logs belong to it
    foreach ($f in @($files | Sort-Object @{ Expression = { if ([System.IO.Path]::GetFileName($_) -ieq 'bink2w64_proxy.log') { 0 } else { 1 } } }, @{ Expression = { $_ } })) { Add-Source $f }
    foreach ($x in $ExtraLog) { if ($x -and (Test-Path -LiteralPath $x)) { Add-Source (Resolve-Path -LiteralPath $x).Path } }
}

function Read-Source([object]$src, [bool]$catchUp) {
    $fi = $null
    try { $fi = New-Object System.IO.FileInfo($src.Path); if (-not $fi.Exists) { return 0 } } catch { return 0 }
    if ($fi.Length -eq $src.Pos -and $src.Seen) { return 0 }
    $fs = $null; $handled = 0
    try {
        $fs = New-Object System.IO.FileStream($src.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete), 65536)
        $len = $fs.Length
        $hb = New-Object byte[] 48
        $fs.Seek(0, 'Begin') | Out-Null
        $hn = $fs.Read($hb, 0, 48)
        $head = [System.BitConverter]::ToString($hb, 0, $hn)
        $reset = $false
        if ($src.Seen -and ($len -lt $src.Pos -or ($src.Pos -ge 48 -and $hn -ge 48 -and $head -ne $src.Head))) { $reset = $true }
        if ($reset) {
            $src.Pos = 0; $src.Rest = $null; $src.Resets++; $src.PrevSec = 0; $src.Day = 0
            if (-not $catchUp) { Write-Line ((Col 'byellow') + ('             ' + $script:G.arrow + ' ' + $src.Name + ' was restarted by the game (new run) - reading from the top')) }
        }
        if ($hn -ge 48) { $src.Head = $head }
        $src.Seen = $true
        while ($src.Pos -lt $len) {
            $want = [Math]::Min([long]8MB, $len - $src.Pos)
            $buf = New-Object byte[] ([int]$want)
            $fs.Seek($src.Pos, 'Begin') | Out-Null
            $got = $fs.Read($buf, 0, [int]$want)
            if ($got -le 0) { break }
            $src.Pos += $got; $src.Bytes += $got
            $data = $buf; $dlen = $got
            if ($src.Rest -ne $null) {
                $data = New-Object byte[] ($src.Rest.Length + $got)
                [System.Buffer]::BlockCopy($src.Rest, 0, $data, 0, $src.Rest.Length)
                [System.Buffer]::BlockCopy($buf, 0, $data, $src.Rest.Length, $got)
                $dlen = $data.Length
            }
            $last = [System.Array]::LastIndexOf($data, [byte]10, $dlen - 1)
            if ($last -lt 0) { $src.Rest = New-Object byte[] $dlen; [System.Buffer]::BlockCopy($data, 0, $src.Rest, 0, $dlen); if ($dlen -gt 1MB) { $src.Rest = $null }; continue }
            $text = $script:Utf8.GetString($data, 0, $last + 1)
            $remain = $dlen - ($last + 1)
            if ($remain -gt 0) { $src.Rest = New-Object byte[] $remain; [System.Buffer]::BlockCopy($data, $last + 1, $src.Rest, 0, $remain) } else { $src.Rest = $null }
            if ($src.Lines -eq 0 -and $text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
            foreach ($ln in $text.Split("`n")) {
                if ($ln.Length -eq 0) { continue }
                if ($null -ne $script:Collect) {
                    $tm = $script:RxTs.Match($ln); $sec = $src.PrevSec
                    if ($tm.Success) {
                        $sec = [double]$tm.Groups[1].Value * 3600 + [double]$tm.Groups[2].Value * 60 + [double]$tm.Groups[3].Value
                        if ($tm.Groups[4].Success -and $tm.Groups[4].Value.Length -gt 0) { $sec += [double]('0.' + $tm.Groups[4].Value) }
                        if ($sec -lt $src.PrevSec - 43200) { $src.Day++ }
                        $src.PrevSec = $sec
                    }
                    $script:Seq++
                    $script:Collect.Add([pscustomobject]@{ K=($src.Day * 86400 + $sec); Si=$src.Order; Q=$script:Seq; Src=$src; Line=$ln })
                } else { Handle-Line $src $ln }
                $handled++; $src.Lines++
            }
        }
    } catch { if ($env:ME_DEBUG) { [Console]::Error.WriteLine('Read-Source ' + $src.Name + ': ' + $_.Exception.Message) } }
    finally { if ($fs) { $fs.Dispose() } }
    return $handled
}
#endregion

# Read every source, then feed the lines to the parser in log-time order. The proxy log, the autoload log and the texture log are
# separate files; reading them one after the other would replay the proxy's shutdown before the autoloader's start.
function Pump([bool]$catchUp) {
    $col = New-Object System.Collections.Generic.List[object]
    $script:Collect = $col
    try { foreach ($s in $script:Sources.ToArray()) { [void](Read-Source $s $catchUp) } } finally { $script:Collect = $null }
    if ($col.Count -eq 0) { return 0 }
    $items = $col.ToArray()
    $multi = $false; for ($i = 1; $i -lt $items.Length; $i++) { if ($items[$i].Si -ne $items[0].Si) { $multi = $true; break } }
    if ($multi) { $items = @($items | Sort-Object K, Si, Q) }
    foreach ($it in $items) { Handle-Line $it.Src $it.Line }
    return $items.Length
}

#region setup check, fingerprint, known-good diff, saves
$script:Data = ''
$script:Fp = $null
$script:SaveRoot = ''
$script:SaveSig = @{}
$script:SaveLastBackupSig = ''
$script:Gpu = @{ Exe=$null; Name=''; Total=0.0; Used=0.0; Peak=0.0; TempPeak=0.0; Temp=0.0; Util=0.0; Told=$false; TempTold=$false; Last=[datetime]::MinValue; Ok=$false }

function Get-Steam-Build {
    try {
        $steamapps = Split-Path -Parent (Split-Path -Parent $script:LeRoot)
        $acf = Join-Path $steamapps ('appmanifest_' + $script:SteamApp + '.acf')
        if (-not (Test-Path -LiteralPath $acf)) { return @{ Build=''; Updated='' } }
        $txt = [System.IO.File]::ReadAllText($acf)
        $b = ''; $u = ''
        if ($txt -match '"buildid"\s+"(\d+)"') { $b = $Matches[1] }
        if ($txt -match '"LastUpdated"\s+"(\d+)"') { $u = ([datetime]'1970-01-01').AddSeconds([double]$Matches[1]).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
        return @{ Build=$b; Updated=$u }
    } catch { return @{ Build=''; Updated='' } }
}
function Get-DirPrint([string]$d) {
    $n = 0; $bytes = [long]0
    try {
        $di = New-Object System.IO.DirectoryInfo($d)
        foreach ($f in $di.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories)) { $n++; $bytes += $f.Length }
    } catch { }
    return ('{0}|{1}' -f $n, $bytes)
}
function Read-MetaCmm([string]$dir) {
    $p = Join-Path $dir '_metacmm.txt'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $l = [System.IO.File]::ReadAllLines($p, $script:Utf8); if ($l.Count -ge 2) { return @{ Name=$l[0].Trim(); Ver=$l[1].Trim() } } } catch { }
    return $null
}
function Load-LoadOrderNames {
    if (-not $script:DlcDir) { return 0 }
    $p = Join-Path $script:DlcDir 'LoadOrder.Txt'
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    $n = 0
    try {
        foreach ($l in [System.IO.File]::ReadAllLines($p, $script:Utf8)) {
            if ($l -match '^\s*(\d+):\s*(\S+)\s*\((.*)\)\s*$') { $script:ModNames[$Matches[2].ToLowerInvariant()] = $Matches[3]; $n++ }
        }
    } catch { }
    return $n
}
function Load-LevelNames {
    $p = Join-Path $script:Data 'levels.txt'
    if (-not (Test-Path -LiteralPath $p)) { return }
    try { foreach ($l in [System.IO.File]::ReadAllLines($p)) { if ($l -match '^\s*([A-Za-z]{3}\d{2})\s*=\s*(.+?)\s*$') { $script:LevelNames[$Matches[1].ToUpperInvariant()] = $Matches[2] } } } catch { }
}

# a compact picture of everything that decides whether the modded game boots
function Get-Fingerprint {
    $fp = @{ When=[datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Build=''; Updated=''; Exe=''; Proxy=''; ProxyOrig=''; Asi=@{}; Dlc=@{}; Coal=@{}; Toc='' }
    $sb = Get-Steam-Build; $fp.Build = $sb.Build; $fp.Updated = $sb.Updated
    try { $e = Get-Item -LiteralPath (Join-Path $script:Win64 'MassEffect1.exe') -ErrorAction Stop; $fp.Exe = ('{0}|{1}' -f $e.Length, $e.LastWriteTimeUtc.ToString('yyyyMMddHHmmss')) } catch { }
    foreach ($pair in @(@('Proxy', 'bink2w64.dll'), @('ProxyOrig', 'bink2w64_original.dll'))) {
        try { $f = Get-Item -LiteralPath (Join-Path $script:Win64 $pair[1]) -ErrorAction Stop; $fp[$pair[0]] = ('{0}' -f $f.Length) } catch { }
    }
    try { foreach ($f in [System.IO.Directory]::EnumerateFiles((Join-Path $script:Win64 'ASI'), '*.asi')) { $i = New-Object System.IO.FileInfo($f); $fp.Asi[$i.Name] = [string]$i.Length } } catch { }
    try { foreach ($d in [System.IO.Directory]::EnumerateDirectories($script:DlcDir)) { $n = [System.IO.Path]::GetFileName($d); if ($n -like 'DLC_MOD_*') { $fp.Dlc[$n] = Get-DirPrint $d } } } catch { }
    try {
        $cc = Join-Path $script:Me1 'BioGame\CookedPCConsole'
        foreach ($f in [System.IO.Directory]::EnumerateFiles($cc, 'Coalesced*.bin')) { $i = New-Object System.IO.FileInfo($f); $fp.Coal[$i.Name] = ('{0}|{1}' -f $i.Length, $i.LastWriteTimeUtc.ToString('yyyyMMddHHmmss')) }
        $t = Get-Item -LiteralPath (Join-Path $cc 'PCConsoleTOC.bin') -ErrorAction SilentlyContinue; if ($t) { $fp.Toc = [string]$t.Length }
    } catch { }
    return $fp
}
function Fp-Diff($old, $new) {
    $d = New-Object System.Collections.Generic.List[string]
    if ($null -eq $old) { return $d }
    if ($old.Build -ne $new.Build) { $d.Add(('Steam build id changed: ' + $old.Build + ' -> ' + $new.Build + '  (the game was patched; ASIs may need updating)')) }
    if ($old.Exe -ne $new.Exe) { $d.Add('MassEffect1.exe changed (size/date) - game was patched or replaced') }
    if ($old.Proxy -ne $new.Proxy) { $d.Add('bink2w64.dll (the proxy that loads ASIs) changed size') }
    if ($old.ProxyOrig -ne $new.ProxyOrig) { $d.Add('bink2w64_original.dll changed size') }
    foreach ($k in $new.Asi.Keys) { if (-not $old.Asi.ContainsKey($k)) { $d.Add('ASI added: ' + $k) } elseif ($old.Asi[$k] -ne $new.Asi[$k]) { $d.Add('ASI changed: ' + $k) } }
    foreach ($k in $old.Asi.Keys) { if (-not $new.Asi.ContainsKey($k)) { $d.Add('ASI removed: ' + $k) } }
    foreach ($k in $new.Dlc.Keys) { if (-not $old.Dlc.ContainsKey($k)) { $d.Add('mod added: ' + (Mod-Label $k)) } elseif ($old.Dlc[$k] -ne $new.Dlc[$k]) { $d.Add('mod files changed: ' + (Mod-Label $k) + '   (' + $old.Dlc[$k] + ' -> ' + $new.Dlc[$k] + ' files|bytes)') } }
    foreach ($k in $old.Dlc.Keys) { if (-not $new.Dlc.ContainsKey($k)) { $d.Add('mod removed: ' + $k) } }
    foreach ($k in $new.Coal.Keys) { if (-not $old.Coal.ContainsKey($k)) { $d.Add($k + ' appeared') } elseif ($old.Coal[$k] -ne $new.Coal[$k]) { $d.Add($k + ' changed (a trainer/config mod overwrote it? M3 installs rebuild it too)') } }
    if ($old.Toc -ne $new.Toc) { $d.Add('PCConsoleTOC.bin changed size (normal after an M3 / MEM install)') }
    return $d
}
function Save-Fp($fp, [string]$path) { try { [System.IO.File]::WriteAllText($path, ($fp | ConvertTo-Json -Depth 5), $script:Utf8) } catch { Dbg ('Save-Fp: ' + $_.Exception.Message) } }
function Load-Fp([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $o = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
        $h = @{ When=[string]$o.When; Build=[string]$o.Build; Updated=[string]$o.Updated; Exe=[string]$o.Exe; Proxy=[string]$o.Proxy; ProxyOrig=[string]$o.ProxyOrig; Toc=[string]$o.Toc; Asi=@{}; Dlc=@{}; Coal=@{} }
        foreach ($sec in @('Asi','Dlc','Coal')) { if ($o.$sec) { foreach ($p in $o.$sec.PSObject.Properties) { $h[$sec][$p.Name] = [string]$p.Value } } }
        return $h
    } catch { return $null }
}

function Find-NvSmi {
    if ($NoGpu -or -not $script:IsWin) { return $null }
    try { $c = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue; if ($c) { return $c.Source } } catch { }
    foreach ($p in @((Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'), 'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe')) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}
function Gpu-Poll([bool]$force) {
    $g = $script:Gpu
    if ($null -eq $g.Exe) { return }
    $now = [datetime]::Now
    if (-not $force -and ($now - $g.Last).TotalSeconds -lt 5) { return }
    $g.Last = $now
    try {
        $o = & $g.Exe '--query-gpu=name,memory.used,memory.total,temperature.gpu,utilization.gpu' '--format=csv,noheader,nounits' 2>$null
        $line = @($o)[0]
        if (-not $line) { return }
        $p = $line -split ',\s*'
        if ($p.Count -lt 5) { return }
        $g.Name = $p[0]; $g.Used = [double]$p[1]; $g.Total = [double]$p[2]; $g.Temp = [double]$p[3]; $g.Util = [double]$p[4]; $g.Ok = $true
        if ($g.Used -gt $g.Peak) { $g.Peak = $g.Used }
        if ($g.Temp -gt $g.TempPeak) { $g.TempPeak = $g.Temp }
        if (-not $g.Told -and $g.Total -gt 0 -and ($g.Used / $g.Total) -ge 0.93) {
            $g.Told = $true
            Write-Line ((Col 'byellow') + ('             ! GPU memory ' + ('{0:0.0}' -f ($g.Used / 1024)) + ' of ' + ('{0:0.0}' -f ($g.Total / 1024)) + ' GB used - high-res textures (ALOT) at high resolution are close to the limit; stutter or a driver crash follows when it runs out')) $true
        }
        if (-not $g.TempTold -and $g.Temp -ge 85) {
            $g.TempTold = $true
            Write-Line ((Col 'byellow') + ('             ! GPU temperature ' + $g.Temp + ' C')) $true
        }
    } catch { }
}

function Get-FreeGb([string]$path) {
    try { $root = [System.IO.Path]::GetPathRoot($path); $d = New-Object System.IO.DriveInfo($root); return ($d.AvailableFreeSpace / 1GB) } catch { return -1 }
}

function Resolve-SaveRoot {
    if ($SaveDir) { return $SaveDir }
    $docs = ''; try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch { }
    if (-not $docs) { return '' }
    return (Join-Path $docs 'BioWare\Mass Effect Legendary Edition\Save\ME1')
}
function Get-SaveMap {
    $m = @{}
    if (-not $script:SaveRoot -or -not (Test-Path -LiteralPath $script:SaveRoot -PathType Container)) { return $m }
    try {
        $di = New-Object System.IO.DirectoryInfo($script:SaveRoot)
        foreach ($f in $di.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories)) { $rel = $f.FullName.Substring($script:SaveRoot.Length).TrimStart('\','/'); $m[$rel] = ('{0}|{1}' -f $f.Length, $f.LastWriteTimeUtc.Ticks) }
    } catch { }
    return $m
}
function Map-Sig($m) { return (($m.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Value }) -join ';') }
function Backup-Saves([string]$why) {
    if ($NoSaveBackup -or -not $script:SaveRoot -or -not (Test-Path -LiteralPath $script:SaveRoot -PathType Container)) { return $null }
    try {
        $map = Get-SaveMap
        if ($map.Count -eq 0) { return $null }
        $sig = Map-Sig $map
        if ($sig -eq $script:SaveLastBackupSig) { return $null }
        $root = Join-Path $script:Data 'save-backups'
        $dest = Join-Path $root ([datetime]::Now.ToString('yyyy-MM-dd_HH-mm-ss') + '_' + $why)
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -LiteralPath $script:SaveRoot -Destination (Join-Path $dest 'ME1') -Recurse -Force
        $script:SaveLastBackupSig = $sig
        $all = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        if ($all.Count -gt $KeepSaveBackups) { $all | Select-Object -Skip $KeepSaveBackups | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } }
        return $dest
    } catch { Dbg ('Backup-Saves: ' + $_.Exception.Message); return $null }
}
function Save-Poll {
    if ($NoSaveBackup -or -not $script:SaveRoot) { return }
    $new = Get-SaveMap
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($k in $new.Keys) { if (-not $script:SaveSig.ContainsKey($k) -or $script:SaveSig[$k] -ne $new[$k]) { $changed.Add($k) } }
    if ($changed.Count -eq 0) { $script:SaveSig = $new; return }
    # let the game finish writing, then re-read once
    Start-Sleep -Milliseconds 800
    $new = Get-SaveMap
    foreach ($k in $changed) {
        if (-not $new.ContainsKey($k)) { continue }
        $len = [long]($new[$k] -split '\|')[0]
        $warn = ''; if ($len -lt 1024 -and $k -match '(?i)\.(pcsav|sav)$') { $warn = '  <-- under 1 KB: this save looks truncated' }
        Write-Line ((Col $(if ($warn) { 'bred' } else { 'green' })) + ('             ' + $script:G.dot + ' save written: ' + $k + ' (' + (Fmt-Bytes $len) + ')' + $warn)) $true
    }
    $script:SaveSig = $new
    $b = Backup-Saves 'save'
    if ($b) { Notice ('saves copied to ' + $b) 'gray' }
}
#endregion

#region setup check display
function Show-SetupCheck {
    Write-Head 'Setup check'
    $ok = 'green'; $bad = 'byellow'
    $exe = Join-Path $script:Win64 'MassEffect1.exe'
    if (Test-Path -LiteralPath $exe) {
        $e = Get-Item -LiteralPath $exe
        $sb = Get-Steam-Build
        Write-Plain ('  ' + $script:G.dot + ' MassEffect1.exe  ' + (Fmt-Bytes $e.Length) + ', ' + $e.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + $(if ($sb.Build) { '   Steam build ' + $sb.Build + ' (updated ' + $sb.Updated + ')' } else { '   (Steam build id not readable)' })) $ok
    } else { Write-Plain '  ! MassEffect1.exe not found under Binaries\Win64' 'bred' }
    $p = Join-Path $script:Win64 'bink2w64.dll'; $o = Join-Path $script:Win64 'bink2w64_original.dll'
    if ((Test-Path -LiteralPath $p) -and (Test-Path -LiteralPath $o)) {
        Write-Plain ('  ' + $script:G.dot + ' ASI loader pair: bink2w64.dll ' + (Fmt-Bytes (Get-Item -LiteralPath $p).Length) + ' + bink2w64_original.dll ' + (Fmt-Bytes (Get-Item -LiteralPath $o).Length)) $ok
    } else { Write-Plain '  ! bink2w64.dll / bink2w64_original.dll pair incomplete - ASI mods will not load (use M3: restore, then reinstall)' 'bred' }
    $asiDir = Join-Path $script:Win64 'ASI'; $asi = @()
    try { $asi = @([System.IO.Directory]::EnumerateFiles($asiDir, '*.asi') | ForEach-Object { [System.IO.Path]::GetFileName($_) }) } catch { }
    Write-Plain ('  ' + $script:G.dot + ' ASI plugins (' + $asi.Count + '): ' + ($asi -join ', ')) $(if ($asi.Count -gt 0) { $ok } else { $bad })
    $mods = @(); try { $mods = @([System.IO.Directory]::EnumerateDirectories($script:DlcDir) | Where-Object { [System.IO.Path]::GetFileName($_) -like 'DLC_MOD_*' }) } catch { }
    $noAuto = @(); $noMeta = 0
    foreach ($m in $mods) {
        if (-not (Test-Path -LiteralPath (Join-Path $m 'AutoLoad.ini'))) { $noAuto += [System.IO.Path]::GetFileName($m) }
        if (-not (Test-Path -LiteralPath (Join-Path $m '_metacmm.txt'))) { $noMeta++ }
    }
    Write-Plain ('  ' + $script:G.dot + ' DLC_MOD folders: ' + $mods.Count + '   (' + $(if ($noMeta -eq 0) { 'all have M3 install records' } else { $noMeta.ToString() + ' lack an M3 record (_metacmm.txt) = not installed by M3' }) + ')') $(if ($noMeta -eq 0) { $ok } else { $bad })
    if ($noAuto.Count -gt 0) { Write-Plain ('  ! no AutoLoad.ini in: ' + ($noAuto -join ', ') + '  (not mounted by the autoloader)') $bad }
    $lo = Join-Path $script:DlcDir 'LoadOrder.Txt'
    if (Test-Path -LiteralPath $lo) { Write-Plain ('  ' + $script:G.dot + ' LoadOrder.Txt written ' + (Get-Item -LiteralPath $lo).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + ' (regenerated each launch; a stale time after a launch means autoload did not run)') $ok }
    else { Write-Plain '  ! LoadOrder.Txt missing (appears after the first modded launch)' $bad }
    try {
        $cc = Join-Path $script:Me1 'BioGame\CookedPCConsole'
        foreach ($f in [System.IO.Directory]::EnumerateFiles($cc, 'Coalesced*.bin')) { $i = New-Object System.IO.FileInfo($f); Write-Plain ('  ' + $script:G.dot + ' ' + $i.Name + '  ' + (Fmt-Bytes $i.Length) + ', ' + $i.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + '   (trainer/config mods that replace this file clash with M3 installs)') 'gray' }
    } catch { }
    $gs = Join-Path $script:Me1 'BioGame\Config\GamerSettings.ini'
    if (Test-Path -LiteralPath $gs) {
        $k = @(); try { $k = @([System.IO.File]::ReadAllLines($gs) | Where-Object { $_ -match '(?i)^\s*(resx|resy|fullscreen|usevsync|vsync|maxfps|framerate|windowed)' }) } catch { }
        if ($k.Count -gt 0) { Write-Plain ('  ' + $script:G.dot + ' GamerSettings.ini display keys: ' + ($k -join '  ')) $ok }
        else { Write-Plain '  ! GamerSettings.ini has no resolution / fullscreen / vsync keys yet - ME1 graphics options have not been saved (open Options in-game once)' $bad }
    }
    Write-Plain ('  ' + $script:G.dot + ' saves: ' + $script:SaveRoot + $(if ($script:SaveRoot -and (Test-Path -LiteralPath $script:SaveRoot)) { '   (' + (Get-SaveMap).Count + ' files)' } else { '   (folder not found)' })) $(if ($script:SaveRoot -and (Test-Path -LiteralPath $script:SaveRoot)) { $ok } else { $bad })
    foreach ($pair in @(@('game drive', $script:LeRoot), @('console data drive', $script:Data))) {
        $gb = Get-FreeGb $pair[1]
        if ($gb -ge 0) { Write-Plain ('  ' + $script:G.dot + ' free space on ' + $pair[0] + ': ' + ('{0:0.0}' -f $gb) + ' GB' + $(if ($gb -lt 10) { '  <-- low' } else { '' })) $(if ($gb -lt 10) { $bad } else { 'gray' }) }
    }
    if ($script:Gpu.Exe) { Gpu-Poll $true; if ($script:Gpu.Ok) { Write-Plain ('  ' + $script:G.dot + ' GPU ' + $script:Gpu.Name + ': ' + ('{0:0.0}' -f ($script:Gpu.Used / 1024)) + ' / ' + ('{0:0.0}' -f ($script:Gpu.Total / 1024)) + ' GB in use now, ' + $script:Gpu.Temp + ' C') 'gray' } }
    else { Write-Plain '  - GPU watch off (nvidia-smi not found or -NoGpu)' 'gray' }
    $old = Load-Fp (Join-Path $script:Data 'lastgood.json')
    if ($null -eq $old) { Write-Plain '  - no known-good snapshot yet. After the first clean run this tool saves one and from then on tells you what changed (b = save one now).' 'gray' }
    else {
        $d = @(Fp-Diff $old (Get-Fingerprint))
        Write-Plain ('  Changes since the last CLEAN run (' + $old.When + '):') 'bwhite'
        if ($d.Count -eq 0) { Write-Plain '    none - game, ASIs, mods and Coalesced are as they were when it last ran clean' 'green' }
        foreach ($l in $d) { Write-Plain ('    ~ ' + $l) 'byellow' }
    }
    Write-Line ''
}
#endregion

#region archive, process, events, post-mortem
$script:ArcDir = $null; $script:ArcSnap = @{}; $script:LastSnap = [datetime]::MinValue
$script:Proc = $null
$script:ProcInfo = @{ Pid=0; Start=$null; Mem=0.0; Peak=0.0; Responding=$true; NotRespSince=$null; Exit=$null; ExitCode=$null; PMDue=$null; NativeCode=$null; NRTold=$false; Uptime=$null; StallTold=$false }
$script:NativeOk = $null; $script:ProcHandle = [IntPtr]::Zero

function Ensure-Native {
    if ($null -ne $script:NativeOk) { return $script:NativeOk }
    $script:NativeOk = $false
    if (-not $script:IsWin) { return $false }
    try {
        if (-not ('MeProc' -as [type])) {
            Add-Type -Language CSharp -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public static class MeProc {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);
    delegate bool HandlerRoutine(uint ctrlType);
    static HandlerRoutine keep;
    public static volatile bool CloseRequested = false;
    public static ManualResetEvent Done = new ManualResetEvent(false);
    public static IntPtr Open(int pid) { return OpenProcess(0x1000 | 0x100000, false, (uint)pid); }
    public static int Poll(IntPtr h, out int code) {
        code = 0; uint c;
        if (h == IntPtr.Zero) return -1;
        if (!GetExitCodeProcess(h, out c)) return -1;
        if (c == 259) return 0;
        code = unchecked((int)c); return 1;
    }
    public static void Close(IntPtr h) { if (h != IntPtr.Zero) CloseHandle(h); }
    public static void HookClose() { keep = new HandlerRoutine(OnCtrl); SetConsoleCtrlHandler(keep, true); }
    static bool OnCtrl(uint t) { if (t == 2 || t == 5 || t == 6) { CloseRequested = true; Done.WaitOne(4500); return true; } return false; }
}
'@
        }
        $script:NativeOk = $true
    } catch { Dbg ('Ensure-Native: ' + $_.Exception.Message) }
    return $script:NativeOk
}
function Close-ProcHandle { if ($script:ProcHandle -ne [IntPtr]::Zero) { try { [MeProc]::Close($script:ProcHandle) } catch { }; $script:ProcHandle = [IntPtr]::Zero } }

function Arc-Open([datetime]$when) {
    if ($NoArchive) { return }
    try {
        $root = Join-Path $script:Data 'sessions'
        $dir = Join-Path $root ($when.ToString('yyyy-MM-dd_HH-mm-ss'))
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'logs') | Out-Null
        $script:ArcDir = $dir; $script:ArcSnap = @{}
        if ($script:Transcript) { try { $script:Transcript.Dispose() } catch { } }
        $fs = New-Object System.IO.FileStream((Join-Path $dir 'console.txt'), [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $script:Transcript = New-Object System.IO.StreamWriter($fs, $script:Utf8); $script:Transcript.AutoFlush = $true
        foreach ($f in @((Join-Path $script:DlcDir 'LoadOrder.Txt'), (Join-Path $script:Me1 'BioGame\Config\GamerSettings.ini'))) { if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination $dir -Force -ErrorAction SilentlyContinue } }
        # mod list as M3 recorded it (name + version per DLC_MOD folder)
        try {
            $rows = New-Object System.Collections.Generic.List[string]
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($script:DlcDir)) {
                $n = [System.IO.Path]::GetFileName($d); if ($n -notlike 'DLC_MOD_*') { continue }
                $mc = Read-MetaCmm $d; $mt = ''; if ($mc) { $mt = $mc.Name + ' ' + $mc.Ver }
                $rows.Add(($n + "`t" + $mt))
            }
            [System.IO.File]::WriteAllLines((Join-Path $dir 'mods.txt'), [string[]]($rows | Sort-Object), $script:Utf8)
        } catch { }
        if ($script:Fp) { Save-Fp $script:Fp (Join-Path $dir 'setup.json') }
        $all = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        if ($all.Count -gt $KeepSessions) { $all | Select-Object -Skip $KeepSessions | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } }
    } catch { $script:ArcDir = $null; Dbg ('Arc-Open: ' + $_.Exception.Message) }
}
function Arc-Snapshot([bool]$force) {
    if (-not $script:ArcDir) { return 0 }
    $n = 0
    foreach ($s in $script:Sources) {
        try {
            $fi = New-Object System.IO.FileInfo($s.Path); if (-not $fi.Exists) { continue }
            $sig = '' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
            if (-not $force -and $script:ArcSnap.ContainsKey($s.Path) -and $script:ArcSnap[$s.Path] -eq $sig) { continue }
            $dest = Join-Path (Join-Path $script:ArcDir 'logs') $s.Name
            $in = New-Object System.IO.FileStream($s.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try { $out = New-Object System.IO.FileStream($dest, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read); try { $in.CopyTo($out) } finally { $out.Dispose() } } finally { $in.Dispose() }
            $script:ArcSnap[$s.Path] = $sig; $n++
        } catch { Dbg ('Arc-Snapshot ' + $s.Name + ': ' + $_.Exception.Message) }
    }
    $script:LastSnap = [datetime]::Now
    return $n
}

function Proc-Poll {
    $pi = $script:ProcInfo; $cur = $null
    try { $cur = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1 } catch { }
    if ($script:Proc -ne $null) {
        $gone = $false
        if ($script:NativeOk -and $script:ProcHandle -ne [IntPtr]::Zero) {
            $c = 0; $r = [MeProc]::Poll($script:ProcHandle, [ref]$c)
            if ($r -eq 1) { $gone = $true; $pi.NativeCode = $c }
            elseif ($r -ne 0) { try { $script:Proc.Refresh(); if ($script:Proc.HasExited) { $gone = $true } } catch { $gone = $true } }
        } else { try { $script:Proc.Refresh(); if ($script:Proc.HasExited) { $gone = $true } } catch { $gone = $true } }
        if ($gone) { Proc-Exited }
    }
    if ($cur -ne $null -and $script:Proc -eq $null) { Proc-Started $cur }
    if ($script:Proc -ne $null) {
        try {
            $script:Proc.Refresh()
            $pi.Mem = [double]$script:Proc.WorkingSet64
            if ($pi.Mem -gt $pi.Peak) { $pi.Peak = $pi.Mem }
            $resp = $true; try { $resp = $script:Proc.Responding } catch { }
            if (-not $resp) {
                if ($null -eq $pi.NotRespSince) { $pi.NotRespSince = [datetime]::Now }
                elseif (-not $pi.NRTold -and ([datetime]::Now - $pi.NotRespSince).TotalSeconds -ge 15) {
                    $pi.NRTold = $true
                    $why = 'game window is frozen'
                    if ($script:S.Phase -notlike 'Mods ready*' -and $script:S.Phase -notlike 'Shutting*') { $why = 'can be normal while the autoloader scans/mounts mods - worry only if the log stops moving for minutes' }
                    Write-Line ((Col 'byellow') + ('             ! MassEffect1 not responding for ' + (Fmt-Span ([datetime]::Now - $pi.NotRespSince)) + ' (' + $why + ')')) $true
                }
            } else {
                if ($pi.NRTold) { Write-Line ((Col 'green') + ('             ' + $script:G.dot + ' MassEffect1 responding again after ' + (Fmt-Span ([datetime]::Now - $pi.NotRespSince)))) $true }
                $pi.NotRespSince = $null; $pi.NRTold = $false
            }
            $pi.Responding = $resp
            # silent log during boot: the autoloader normally finishes within ~30 s
            $S = $script:S
            if (-not $pi.StallTold -and $S.AttachT -ne $null -and $S.AllDoneT -eq $null -and -not $S.Detaching -and ([datetime]::Now - $S.LastLineAt).TotalSeconds -ge 60) {
                $pi.StallTold = $true
                Write-Line ((Col 'byellow') + ('             ! boot is stuck: no log line for ' + (Fmt-Span ([datetime]::Now - $S.LastLineAt)) + ' and autoload has not finished (phase: ' + $S.Phase + ')')) $true
            }
        } catch { }
    }
    if ($script:Proc) { Gpu-Poll $false }
}

function Switch-Game([string]$root) { Set-GamePaths $root; Scan-Sources; Notice ('game folder is ' + $root + '  (' + $script:Sources.Count + ' log files)') 'gray' }

function Proc-Started($p) {
    $pi = $script:ProcInfo; $script:Proc = $p
    try { [void]$p.Handle } catch { }
    if (Ensure-Native) { try { Close-ProcHandle; $script:ProcHandle = [MeProc]::Open($p.Id) } catch { $script:ProcHandle = [IntPtr]::Zero } }
    $pi.NativeCode = $null
    try { $pp = $null; try { $pp = $p.Path } catch { }; if ($pp -and -not $GamePath) { $root = Resolve-LeRoot (Split-Path -Parent $pp); if ($root -and $root -ne $script:LeRoot) { Switch-Game $root } } } catch { }
    $pi.Pid = $p.Id; $pi.Exit = $null; $pi.ExitCode = $null; $pi.Peak = 0.0; $pi.NRTold = $false; $pi.NotRespSince = $null; $pi.PMDue = $null; $pi.StallTold = $false
    try { $pi.Start = $p.StartTime } catch { $pi.Start = [datetime]::Now }
    if ($script:S.Phase -ne 'Idle') { Finish-Session 'new game process' }
    $script:S = New-Session; $script:S.Start = $pi.Start
    $script:Gpu.Peak = 0.0; $script:Gpu.TempPeak = 0.0; $script:Gpu.Told = $false; $script:Gpu.TempTold = $false
    $script:Fp = Get-Fingerprint
    Arc-Open $pi.Start
    Write-Banner ('PROCESS STARTED   ' + $ProcessName + '.exe   PID ' + $p.Id + '   ' + $pi.Start.ToString('HH:mm:ss')) 'bgreen'
    if ($script:ArcDir) { Notice ('session archive: ' + $script:ArcDir) 'gray' }
    $old = Load-Fp (Join-Path $script:Data 'lastgood.json')
    if ($old) {
        $d = @(Fp-Diff $old $script:Fp)
        if ($d.Count -gt 0) { Write-Line ((Col 'byellow') + ('             ! ' + $d.Count + ' change(s) since the last clean run (g = details). First: ' + (Trunc $d[0] 120))) $true }
        else { Write-Line ((Col 'green') + ('             ' + $script:G.dot + ' setup identical to the last clean run')) $true }
    }
    $script:SaveSig = Get-SaveMap; $script:SaveLastBackupSig = ''
    $b = Backup-Saves 'launch'; if ($b) { Notice ('saves copied before this run: ' + $b) 'gray' }
    Set-Title ('Mass Effect Console - running (PID ' + $p.Id + ')')
}

$script:ExitMeaning = @{
    '0'='clean exit'; '1'='exit code 1 (the game called exit(1))'; '-1'='exit(-1) / forced termination'
    '-1073741819'='0xC0000005 ACCESS VIOLATION (bad pointer: the typical UE3 engine crash - bad package/mod data, an ASI, or a driver)'
    '-1073740791'='0xC0000409 STACK BUFFER OVERRUN / fail-fast (the program aborted itself)'
    '-1073741795'='0xC000001D ILLEGAL INSTRUCTION'; '-1073741571'='0xC00000FD STACK OVERFLOW'; '-1073740940'='0xC0000374 HEAP CORRUPTION'
    '-1073741515'='0xC0000135 a DLL was not found'; '-1073741701'='0xC000007B bad image / 32-64 bit DLL mismatch'
    '-1073741510'='0xC000013A closed by Ctrl-C / console close'; '-529697949'='0xE06D7363 unhandled C++ exception'
    '-2147483645'='0x80000003 breakpoint / assertion'; '-1073741676'='0xC0000094 integer divide by zero'
    '-1073741818'='0xC0000006 in-page I/O error (disk/driver problem reading a memory-mapped file)'
    '-805306369'='0xCFFFFFFF forced termination (task kill / Steam stop)'
}
function Describe-Exit($code) {
    if ($null -eq $code) { return 'exit code not readable (access denied or already gone)' }
    $k = [string][int]$code
    if ($script:ExitMeaning.ContainsKey($k)) { return $script:ExitMeaning[$k] }
    $u = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int]$code), 0)
    return ('exit code {0} (0x{1:X8})' -f $code, $u)
}
function Proc-Exited {
    $pi = $script:ProcInfo; $code = $null
    if ($null -ne $pi.NativeCode) { $code = $pi.NativeCode }
    elseif ($script:NativeOk -and $script:ProcHandle -ne [IntPtr]::Zero) { $c = 0; if ([MeProc]::Poll($script:ProcHandle, [ref]$c) -eq 1) { $code = $c } }
    if ($null -eq $code) { try { $code = $script:Proc.ExitCode } catch { } }
    Close-ProcHandle
    try { $pi.Exit = $script:Proc.ExitTime } catch { $pi.Exit = [datetime]::Now }
    $pi.ExitCode = $code
    if ($pi.Exit -lt $pi.Start) { $pi.Exit = [datetime]::Now }
    $pi.Uptime = $pi.Exit - $pi.Start; $script:Proc = $null
    $pi.PMDue = [datetime]::Now.AddSeconds(4)
    Write-Banner ('PROCESS EXITED   PID ' + $pi.Pid + '   ran ' + (Fmt-Span $pi.Uptime) + '   exit: ' + (Describe-Exit $code)) $(if ($code -eq 0) { 'bgreen' } else { 'bred' })
    Set-Title 'Mass Effect Console - game exited'
}

function Get-SysEvents([datetime]$from, [datetime]$to, [bool]$wide) {
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $script:IsWin -or $NoSystemEvents) { return $out }
    try {
        $sys = Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$from; EndTime=$to; Level=@(1,2,3) } -ErrorAction SilentlyContinue
        foreach ($e in $sys) {
            $p = [string]$e.ProviderName; $keep = $false
            if ($p -eq 'Microsoft-Windows-Kernel-Power' -and $e.Id -eq 41) { $keep = $true }
            elseif ($p -like 'Microsoft-Windows-WHEA*') { $keep = $true }
            elseif ($p -in @('nvlddmkm','amdkmdag','amdkmdap','atikmdag')) { $keep = $true }
            elseif ($p -eq 'Display' -and $e.Id -in @(4101)) { $keep = $true }
            elseif ($p -in @('disk','stornvme','storahci','iaStorA','Ntfs','Microsoft-Windows-Ntfs','volmgr','partmgr')) { $keep = $true }
            elseif ($p -eq 'EventLog' -and $e.Id -eq 6008) { $keep = $true }
            elseif ($p -like '*SystemErrorReporting*' -or ($p -eq 'BugCheck')) { $keep = $true }
            elseif ($p -eq 'Microsoft-Windows-Resource-Exhaustion-Detector') { $keep = $true }
            if ($keep) { $out.Add(@{ T=$e.TimeCreated; Log='System'; Prov=$p; Id=$e.Id; Msg=(([string]$e.Message) -split "`n")[0].Trim() }) }
        }
    } catch { }
    try {
        $app = Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$from; EndTime=$to; Level=@(1,2,3) } -ErrorAction SilentlyContinue
        foreach ($e in $app) {
            $msg = [string]$e.Message
            if ($msg -match '(?i)MassEffect|bink2w64|\.asi\b') {
                $p = [string]$e.ProviderName
                if ($p -in @('Application Error','Windows Error Reporting','Application Hang','.NET Runtime','SideBySide')) {
                    $fm = ''; $ex = ''; $off = ''
                    if ($msg -match '(?i)Faulting module name:\s*([^,\r\n]+)') { $fm = $Matches[1].Trim() }
                    if ($msg -match '(?i)Exception code:\s*(\S+)') { $ex = $Matches[1].Trim() }
                    if ($msg -match '(?i)Fault offset:\s*(\S+)') { $off = $Matches[1].Trim() }
                    $short = (($msg -split "`n" | Select-Object -First 4) -join ' | ')
                    if ($fm) { $short = 'faulting module ' + $fm + ', exception ' + $ex + ', offset ' + $off }
                    $out.Add(@{ T=$e.TimeCreated; Log='Application'; Prov=$p; Id=$e.Id; Msg=$short; Module=$fm; Exc=$ex })
                }
            }
        }
    } catch { }
    return ($out | Sort-Object { $_.T })
}

function Get-DumpFiles([datetime]$since) {
    $found = New-Object System.Collections.Generic.List[object]
    $dirs = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) { $dirs.Add((Join-Path $env:LOCALAPPDATA 'CrashDumps')) }
    $dirs.Add((Join-Path $script:Data 'dumps'))
    if ($script:Win64) { $dirs.Add($script:Win64) }
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        try { foreach ($f in Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue) { if ($f.LastWriteTime -ge $since -and ($f.Extension -in @('.dmp','.mdmp')) -and ($f.Name -like '*MassEffect*' -or $d -like '*dumps')) { $found.Add($f) } } } catch { }
    }
    if ($env:ProgramData) {
        foreach ($sub in @('ReportArchive','ReportQueue')) {
            $w = Join-Path $env:ProgramData ('Microsoft\Windows\WER\' + $sub)
            if (-not (Test-Path -LiteralPath $w)) { continue }
            try { foreach ($d in Get-ChildItem -LiteralPath $w -Directory -Filter '*MassEffect*' -ErrorAction SilentlyContinue) { if ($d.LastWriteTime -ge $since) { $found.Add($d) } } } catch { }
        }
    }
    return $found
}

# --- minidump reader (streams only: works on mini and on multi-GB full dumps without loading them)
function Read-MiniDumpFile([string]$path) {
    $r = @{ Ok=$false; Why='' }; $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $br = New-Object System.IO.BinaryReader($fs)
        if ($fs.Length -lt 32 -or $br.ReadUInt32() -ne 0x504D444D) { $r.Why = 'not a minidump'; return $r }
        [void]$br.ReadUInt32(); $n = $br.ReadInt32(); $dirRva = $br.ReadInt32()
        $exc = -1; $mods = -1
        $fs.Seek($dirRva, 'Begin') | Out-Null
        for ($i = 0; $i -lt $n; $i++) { $type = $br.ReadInt32(); [void]$br.ReadInt32(); $rva = $br.ReadInt32(); if ($type -eq 6) { $exc = $rva } elseif ($type -eq 4) { $mods = $rva } }
        if ($exc -lt 0) { $r.Why = 'dump has no exception record'; return $r }
        $fs.Seek($exc, 'Begin') | Out-Null
        $r.ThreadId = $br.ReadUInt32(); [void]$br.ReadUInt32(); $r.Code = $br.ReadUInt32(); [void]$br.ReadUInt32(); [void]$br.ReadUInt64(); $r.Addr = $br.ReadUInt64()
        $np = $br.ReadInt32(); [void]$br.ReadInt32(); $r.Info0 = [uint64]0; $r.Info1 = [uint64]0
        if ($np -ge 2) { $r.Info0 = $br.ReadUInt64(); $r.Info1 = $br.ReadUInt64() }
        $r.Module = ''; $r.Offset = [uint64]0; $r.Loaded = New-Object System.Collections.Generic.List[string]
        if ($mods -ge 0) {
            $fs.Seek($mods, 'Begin') | Out-Null
            $cnt = $br.ReadInt32(); $raw = $br.ReadBytes(108 * $cnt)
            for ($i = 0; $i -lt $cnt; $i++) {
                $o = 108 * $i
                $base = [BitConverter]::ToUInt64($raw, $o); $size = [BitConverter]::ToUInt32($raw, $o + 8); $nrva = [BitConverter]::ToInt32($raw, $o + 20)
                $fs.Seek($nrva, 'Begin') | Out-Null; $len = $br.ReadInt32()
                $nm = ([System.Text.Encoding]::Unicode.GetString($br.ReadBytes($len)) -split '[\\/]')[-1]
                if ($nm -match '(?i)\.asi$|^bink2w64') { $r.Loaded.Add($nm) }
                if ($r.Addr -ge $base -and $r.Addr -lt ($base + $size)) { $r.Module = $nm; $r.Offset = $r.Addr - $base }
            }
        }
        $r.Ok = $true
    } catch { $r.Why = $_.Exception.Message } finally { if ($fs) { $fs.Dispose() } }
    return $r
}
function Describe-NtCode([uint32]$c) {
    switch ($c) {
        3221225477 { return 'ACCESS VIOLATION' } 3221225620 { return 'DIVIDE BY ZERO' } 3221225725 { return 'STACK OVERFLOW' }
        3221226356 { return 'HEAP CORRUPTION' } 3221226505 { return 'FAIL-FAST / stack buffer overrun' } 3221225501 { return 'ILLEGAL INSTRUCTION' }
        3765269347 { return 'C++ exception (0xE06D7363)' } 3762504530 { return 'unhandled .NET exception (0xE0434352)' } 2147483651 { return 'BREAKPOINT' } default { return 'exception' }
    }
}
function Describe-Module([string]$mod) {
    if (-not $mod) { return '' }
    $l = $mod.ToLowerInvariant()
    if ($l -like 'massEffect1*') { return 'the engine itself (MassEffect1.exe): it was fed bad data - a mod package/texture, a bad save, or a mod script. The faulting module alone cannot name which mod.' }
    if ($l -like '*.asi') { return 'an ASI plugin (' + $mod + ') - that is the first suspect; update or remove it in M3' }
    if ($l -like 'bink2w64*') { return 'the ASI loader proxy; M3 can reinstall it (restore game from backup, then reinstall)' }
    if ($l -match '^(nvwgf2umx|nvlddmkm|nvd3dum|atidxx64|amdxx64|igd10iumd64|nvoglv64|nvapi64)') { return 'the GPU driver (' + $mod + '): driver crash. VRAM exhaustion, an unstable overclock, or a driver bug; check the GPU lines below' }
    if ($l -in @('d3d11.dll','dxgi.dll','d3d9.dll')) { return 'DirectX runtime - usually a symptom of the GPU driver or a device-removed event' }
    if ($l -in @('kernelbase.dll','ntdll.dll','kernel32.dll')) { return 'Windows core DLL - a generic exit path; the real cause is in the lines around it' }
    return $mod + ' (not one of the known suspects)'
}
function Describe-CrashDump([string]$dumpPath) {
    $out = New-Object System.Collections.Generic.List[string]
    $d = Read-MiniDumpFile $dumpPath
    if (-not $d.Ok) { $out.Add('could not read the dump: ' + $d.Why); return $out }
    $how = ''
    if ($d.Code -eq 3221225477) {
        $kind = @{ 0='READ from'; 1='WRITE to'; 8='EXECUTE at' }
        $how = ' - ' + $(if ($kind.ContainsKey([int]$d.Info0)) { $kind[[int]$d.Info0] } else { 'touched' }) + ' address 0x' + ('{0:X}' -f $d.Info1)
        if ($d.Info1 -lt 65536) { $how += ' (NULL pointer + 0x' + ('{0:X}' -f $d.Info1) + ': code used an object that does not exist)' }
    }
    $out.Add(('exception 0x{0:X8} {1}{2}' -f $d.Code, (Describe-NtCode ([uint32]$d.Code)), $how))
    $where = '0x' + ('{0:X}' -f $d.Addr); if ($d.Module) { $where += '  =  ' + $d.Module + ' + 0x' + ('{0:X}' -f $d.Offset) }
    $out.Add('at ' + $where + '   (thread ' + $d.ThreadId + ')')
    if ($d.Module) { $out.Add('faulting code is in ' + (Describe-Module $d.Module)) }
    if ($d.Loaded.Count -gt 0) { $out.Add('ASI/proxy modules loaded in the process: ' + (($d.Loaded | Sort-Object -Unique) -join ', ')) }
    return $out
}

function Post-Mortem {
    $pi = $script:ProcInfo; $S = $script:S
    $pi.PMDue = $null
    $script:Tee = New-Object System.Collections.Generic.List[string]
    $start = $pi.Start; $end = $pi.Exit; if (-not $end) { $end = [datetime]::Now }
    $code = $pi.ExitCode
    Write-Head 'POST-MORTEM'
    Write-Plain ('  Ran ............ ' + (Fmt-Span $pi.Uptime) + '   (' + $start.ToString('HH:mm:ss') + ' -> ' + $end.ToString('HH:mm:ss') + ')')
    Write-Plain ('  Exit ........... ' + (Describe-Exit $code))
    Write-Plain ('  Peak RAM ....... ' + (Fmt-Bytes $pi.Peak))
    $g = $script:Gpu
    if ($g.Ok) { Write-Plain ('  GPU ............ ' + $g.Name + '  VRAM peak ' + ('{0:0.0}' -f ($g.Peak / 1024)) + ' of ' + ('{0:0.0}' -f ($g.Total / 1024)) + ' GB, temp peak ' + $g.TempPeak + ' C, last sample ' + ('{0:0.0}' -f ($g.Used / 1024)) + ' GB / ' + $g.Temp + ' C / ' + $g.Util + '% load') }
    Write-Plain ('  Phase at exit .. ' + $S.Phase)
    if ($S.LvlCur) { Write-Plain ('  Last level ..... ' + (Level-Label $S.LvlCur) + '   (levels seen this run: ' + (($S.LevelOrder | ForEach-Object { $_ }) -join ', ') + ')') }
    if ($S.LastTexObj) { Write-Plain ('  Last texture ... ' + $S.LastTexObj + '   via ' + (Mod-Label $S.LastTexSrc)) }
    if ($script:Sources.Count -eq 0) { Write-Plain ('  !! No log files were followed (game folder: ' + $script:LeRoot + '). The counters below are empty because of that.') 'bred' }
    if ($S.CleanExit) { Write-Plain '  Proxy log ...... OnDetach reached "goodbye": normal teardown' 'green' }
    elseif ($S.AttachT -ne $null) { Write-Plain '  Proxy log ...... no "goodbye" line: the process did NOT shut down normally' 'byellow' }
    else { Write-Plain '  Proxy log ...... no "Attached..." line this run: ASIs never loaded (or the logs are from an older run)' 'byellow' }
    Write-Plain ('  Log counters ... errors ' + $S.Err + ', warnings ' + $S.Warn + ', hidden noise ' + (Fmt-N $S.Noise) + ', textures replaced ' + (Fmt-N $S.TexTotal))

    $bf = @(Get-BootFindings)
    if ($bf.Count -gt 0) { Write-Head 'Boot findings'; foreach ($f in $bf) { Write-Plain ('  ' + $f.Text) $(if ($f.Lvl -ge 3) { 'bred' } else { 'byellow' }) } }
    if ($S.RecentOrder.Count -gt 0) { Write-Head 'Last distinct errors in the logs'; foreach ($l in (Get-RecentLines 8)) { Write-Plain ('  ' + $l) 'red' } }
    Write-Head 'Last log lines before the end'
    foreach ($l in ($script:Ring.ToArray() | Select-Object -Last 14)) { Write-Line ('  ' + $l) }

    $dumps = @(Get-DumpFiles ($start.AddSeconds(-5)))
    $dumpInfo = New-Object System.Collections.Generic.List[string]
    if ($dumps.Count -gt 0) {
        Write-Head 'Crash dumps / WER reports from this run'
        foreach ($d in $dumps) {
            if ($d.PSIsContainer) { Write-Plain ('  WER report folder: ' + $d.FullName) 'byellow'; continue }
            Write-Plain ('  ' + $d.FullName + '   (' + (Fmt-Bytes $d.Length) + ', ' + $d.LastWriteTime.ToString('HH:mm:ss') + ')') 'byellow'
            if ($d.Length -le 600MB -and $script:ArcDir) { try { Copy-Item -LiteralPath $d.FullName -Destination (Join-Path $script:ArcDir $d.Name) -Force; Write-Plain '    copy kept in the session folder' 'green' } catch { } }
            foreach ($l in (Describe-CrashDump $d.FullName)) { Write-Plain ('    ' + $l) 'bred'; $dumpInfo.Add($l) }
        }
    }
    $ev = @(); $hw = 0; $appErr = @()
    if ($script:IsWin -and -not $NoSystemEvents) {
        $ev = @(Get-SysEvents ($start.AddMinutes(-1)) ($end.AddMinutes(2)) $false)
        Write-Head ('Windows events during the run (' + $ev.Count + ')')
        if ($ev.Count -eq 0) { Write-Plain '  none of: app crash/hang, Kernel-Power 41, WHEA, GPU driver, disk/NVMe, bugcheck' 'gray' }
        foreach ($e in $ev) {
            $isHw = ($e.Prov -like 'Microsoft-Windows-Kernel-Power' -or $e.Prov -like 'Microsoft-Windows-WHEA*' -or $e.Prov -in @('nvlddmkm','amdkmdag','disk','stornvme','EventLog') -or $e.Prov -like '*SystemErrorReporting*')
            if ($isHw) { $hw++ }
            if ($e.Log -eq 'Application' -and $e.Prov -eq 'Application Error') { $appErr += $e }
            Write-Plain ('  ' + $e.T.ToString('HH:mm:ss') + '  ' + $e.Log.PadRight(11) + $e.Prov + ' #' + $e.Id + '  ' + (Trunc $e.Msg 200)) $(if ($isHw) { 'bred' } else { 'byellow' })
        }
    }

    Write-Head 'Reading of the evidence (inferred - not proof)'
    $v = New-Object System.Collections.Generic.List[string]
    $clean = ($code -eq 0) -and $S.CleanExit -and ($dumpInfo.Count -eq 0) -and ($appErr.Count -eq 0)
    if ($clean) { $v.Add('Clean shutdown: exit code 0 and the proxy reached "goodbye". Nothing to chase.') }
    else {
        if ($hw -gt 0) { $v.Add('Hardware/system events were logged around the end (red lines above). A reboot, driver reset or storage error is not caused by a mod; check hardware first (temperatures, drivers, RAM stability, RGB/fan controllers, PCIe and storage devices).') }
        if ($null -ne $code -and $code -ne 0) { $v.Add('The process ended with ' + (Describe-Exit $code) + '.') }
        elseif ($null -eq $code) { $v.Add('Exit code could not be read.') }
        foreach ($a in $appErr) { if ($a.ContainsKey('Module') -and $a.Module) { $v.Add('Windows Application Error names the faulting module ' + $a.Module + ' (exception ' + $a.Exc + '): ' + (Describe-Module $a.Module)) } }
        if ($S.AttachT -ne $null -and $S.AllDoneT -eq $null) { $v.Add('It ended DURING the ASI/autoload boot (phase: ' + $S.Phase + ', ' + $S.MountedN + ' of ' + $S.Mounts.Count + ' DLC mods mounted). Boot crashes come from a broken DLC_MOD folder, a bad ASI, or a patched exe; compare the setup diff (g).') }
        elseif ($S.LvlCur -and -not $S.CleanExit) { $v.Add('It ended while the game was streaming level ' + (Level-Label $S.LvlCur) + ', last texture ' + $S.LastTexObj + '. Loading screens are when texture overrides are applied - ALOT / Improved Static Lighting / AVC content for that level is a candidate, not a proven cause.') }
        if ($S.Phase -like 'Mods ready*' -and $S.TexTotal -eq 0 -and -not $S.CleanExit) { $v.Add('It ended at the title screen / before any level loaded.') }
        if ($pi.NotRespSince) { $v.Add('The window had been "not responding" for ' + (Fmt-Span ([datetime]::Now - $pi.NotRespSince)) + ' before the end: a hang, then killed.') }
        if ($g.Ok -and $g.Total -gt 0 -and ($g.Peak / $g.Total) -ge 0.93) { $v.Add('VRAM peaked at ' + ('{0:0.0}' -f ($g.Peak / 1024)) + ' GB of ' + ('{0:0.0}' -f ($g.Total / 1024)) + ' GB. Running out of video memory can crash the driver; lower texture/shadow settings or resolution to test.') }
        if ($S.Err -eq 0 -and $hw -eq 0 -and $dumps.Count -eq 0 -and $appErr.Count -eq 0 -and $null -ne $code -and $code -ne 0) { $v.Add('No log error, no Windows crash event and no dump: nothing here can name the cause. Run Enable-CrashDumps.bat once (as administrator) so the next crash leaves a dump.') }
        if ($dumpInfo.Count -gt 0) { $v.Add('The crash dump above is the best evidence available: trust its exception and module over the exit code.') }
        if ($v.Count -eq 0) { $v.Add('Closed without a clean teardown line but with no crash evidence. Likely killed from Task Manager or Steam.') }
        if ($S.Phase -like 'IN GAME*' -or $S.TexTotal -gt 0) { $v.Add('If a save was being written, check the backups: ' + (Join-Path $script:Data 'save-backups')) }
    }
    foreach ($l in $v) { Write-Plain ('  - ' + $l) }
    [void](Arc-Snapshot $true)
    $b = Backup-Saves 'exit'; if ($b) { Notice ('saves copied after this run: ' + $b) 'gray' }
    if ($clean -and $script:Fp) {
        Save-Fp $script:Fp (Join-Path $script:Data 'lastgood.json')
        Write-Plain '  Clean run: this setup is now saved as the known-good snapshot (lastgood.json).' 'green'
    }
    Write-SessionSummary
    if ($script:ArcDir) {
        try { $lines = @($script:Tee.ToArray()); if ($lines.Count -eq 0) { $lines = @('(post-mortem produced no output)') }; [System.IO.File]::WriteAllLines((Join-Path $script:ArcDir 'postmortem.txt'), [string[]]$lines, $script:Utf8) } catch { }
        Notice ('logs of this run saved: ' + $script:ArcDir) 'green'
    }
    $script:Tee = $null
    Write-Line ''
    Write-Plain ('  Waiting for the next launch of ' + $ProcessName + '.exe ... (q = quit, ? = help)') 'gray'
}

function Write-SessionSummary {
    if (-not $script:ArcDir) { return }
    try {
        $save = $script:Quiet; $script:Quiet = $true
        $sb = $script:Transcript; $script:Transcript = $null
        $text = New-Object System.Collections.Generic.List[string]
        $script:CaptureTo = $text
        Show-Summary
        $script:CaptureTo = $null; $script:Transcript = $sb; $script:Quiet = $save
        [System.IO.File]::WriteAllLines((Join-Path $script:ArcDir 'summary.txt'), [string[]]$text, $script:Utf8)
    } catch { $script:CaptureTo = $null; Dbg ('Write-SessionSummary: ' + $_.Exception.Message) }
}
$script:LastPersist = [datetime]::MinValue
function Persist-Live([bool]$force) {
    if (-not $script:ArcDir) { return }
    $now = [datetime]::Now
    $n = Arc-Snapshot $force
    if ($force -or $n -gt 0 -or ($now - $script:LastPersist).TotalSeconds -ge 120) {
        $script:LastPersist = $now
        Write-SessionSummary
        try {
            $tail = @($script:Ring.ToArray() | Select-Object -Last 300 | ForEach-Object { Strip-Ansi $_ })
            $head = @('Live tail written ' + $now.ToString('yyyy-MM-dd HH:mm:ss') + ' (last 300 visible console lines). postmortem.txt holds the verdict once the game has ended.')
            [System.IO.File]::WriteAllLines((Join-Path $script:ArcDir 'tail.txt'), [string[]]($head + $tail), $script:Utf8)
        } catch { }
    }
}
function Finish-Session([string]$why) {
    if ($script:S.Phase -eq 'Idle') { return }
    if ($script:ArcDir) { [void](Arc-Snapshot $true) }
    Write-SessionSummary
    $script:S = New-Session
}
#endregion

#region reports
function Show-Summary {
    $S = $script:S; $pi = $script:ProcInfo
    Write-Head 'SESSION SUMMARY'
    Write-Plain ('  Phase ............ ' + $S.Phase)
    if ($S.ProxyVer) { Write-Plain ('  Proxy ............ LEBinkProxy ' + $S.ProxyVer) }
    if ($S.ExePath) { Write-Plain ('  Game exe ......... ' + $S.ExePath) }
    if ($S.PhaseLog.Count -gt 0) { Write-Plain ('  Phase timings .... ' + ($S.PhaseLog -join '; ')) }
    Write-Plain ('  Log lines ........ ' + (Fmt-N $S.Lines) + '   hidden noise ' + (Fmt-N $S.Noise) + '   errors ' + (Fmt-N $S.Err) + '   warnings ' + (Fmt-N $S.Warn))
    if ($S.Asi.Count -gt 0) {
        Write-Plain ('  ASI plugins ...... ' + $S.AsiFound.Count + ' found, ' + $S.Attached.Count + ' attached (AutoTOCLE and other raw ASIs report no attach line)')
        foreach ($k in ($S.Asi.Keys | Sort-Object)) { Write-Plain ('      ' + $k.PadRight(22) + $S.Asi[$k].Ver.PadRight(14) + $S.Asi[$k].By) 'gray' }
    }
    Write-Plain ('  Core hook ........ ' + $(if ($S.BindHook) { 'UFunctionBind installed' } elseif ($S.AttachT -ne $null) { 'NOT installed' } else { '(no launch in the logs)' }) + '   engine offsets found: ' + $S.Offsets + '   hooks enabled: ' + $S.HooksEnabled.Count + '/' + $S.HooksCreated.Count)
    Write-Plain ('  DLC_MOD .......... ' + $S.Mounts.Count + ' autoloads found, ' + $S.MountedN + ' mounted, ' + $S.StartupFiles.Count + ' startup files')
    if ($S.TexTotal -gt 0) {
        Write-Plain ('  Textures replaced  ' + (Fmt-N $S.TexTotal) + ' (so far this run):')
        foreach ($kv in ($S.Tex.GetEnumerator() | Sort-Object Value -Descending)) { Write-Plain ('      {0,7}  {1}' -f (Fmt-N $kv.Value), (Mod-Label $kv.Key)) 'gray' }
    }
    if ($S.LevelOrder.Count -gt 0) { Write-Plain ('  Levels loaded .... ' + (($S.LevelOrder | ForEach-Object { Level-Label $_ }) -join ', ')) }
    if ($pi.Start) { Write-Plain ('  Process .......... PID ' + $pi.Pid + ', started ' + $pi.Start.ToString('HH:mm:ss') + $(if ($script:Proc) { ', running, RAM ' + (Fmt-Bytes $pi.Mem) + ' (peak ' + (Fmt-Bytes $pi.Peak) + ')' } else { ', exited ' + $(if ($null -ne $pi.ExitCode) { Describe-Exit $pi.ExitCode } else { '' }) })) }
    $g = $script:Gpu
    if ($g.Ok) { Write-Plain ('  GPU .............. ' + $g.Name + ', VRAM ' + ('{0:0.0}' -f ($g.Used / 1024)) + '/' + ('{0:0.0}' -f ($g.Total / 1024)) + ' GB (peak ' + ('{0:0.0}' -f ($g.Peak / 1024)) + '), ' + $g.Temp + ' C (peak ' + $g.TempPeak + ')') }
    Write-Plain ('  Shutdown ......... ' + $(if ($S.CleanExit) { 'clean (proxy "goodbye")' } elseif ($S.Detaching) { 'started, no "goodbye"' } else { 'not reached' }))
    $bf = @(Get-BootFindings)
    if ($bf.Count -gt 0) { Write-Plain '  Findings:' 'bwhite'; foreach ($f in $bf) { Write-Plain ('    ! ' + $f.Text) $(if ($f.Lvl -ge 3) { 'bred' } else { 'byellow' }) } }
    if ($S.Cats.Count -gt 0) {
        $shown = $false
        foreach ($c in ($S.Cats.Values | Sort-Object { -$_.Lvl }, { -$_.Count })) {
            if ($c.Lvl -lt 2) { continue }
            if (-not $shown) { Write-Plain '  Problems:' 'bwhite'; $shown = $true }
            Write-Plain ('    {0,6}  {1}' -f (Fmt-N $c.Count), $c.Title) $(if ($c.Lvl -ge 3) { 'red' } else { 'yellow' })
            foreach ($smp in ($c.Samples | Select-Object -First 2)) { Write-Plain ('            ' + (Trunc $smp 150)) 'gray' }
        }
    }
    Write-Line ''
}
function Show-Mods {
    $S = $script:S
    Write-Head 'DLC_MOD mount order (lowest priority number loads first; this is what the autoloader logged)'
    if ($S.Mounts.Count -eq 0) { Write-Plain '  nothing mounted yet in this run' 'gray'; return }
    $rows = $S.Mounts.GetEnumerator() | Sort-Object Value
    $dir = $script:DlcDir
    foreach ($kv in $rows) {
        $mc = $null; if ($dir) { $mc = Read-MetaCmm (Join-Path $dir $kv.Key) }; $ver = ''; if ($mc) { $ver = ' v' + $mc.Ver }
        Write-Plain ('  {0,6}  {1}{2}' -f $kv.Value, (Mod-Label $kv.Key), $ver)
    }
    if ($S.StartupFiles.Count -gt 0) { Write-Plain ('  startup files: ' + ($S.StartupFiles -join ', ')) 'gray' }
    Write-Line ''
}
function Show-Recent {
    Write-Head 'Recent distinct errors'
    $l = @(Get-RecentLines 25)
    if ($l.Count -eq 0) { Write-Plain '  none' 'green' } else { foreach ($x in $l) { Write-Plain ('  ' + $x) 'red' } }
    Write-Line ''
}
function Show-Help {
    Write-Head 'Mass Effect Console - keys'
    foreach ($h in @(
        '  ?  this help                       q  quit (Ctrl+C also works)',
        '  s  session summary                 m  DLC_MOD mount order (with M3 versions)',
        '  g  setup check + changes since the last clean run',
        '  b  save the CURRENT setup as the known-good snapshot',
        '  e  recent errors                   h  Windows system events (last 2 h)',
        '  l  cycle level filter DBG>INF>WRN>ERR     v  show/hide noise lines',
        '  r  raw mode (every line, no grouping)     p  pause/resume screen',
        '  c  clear screen                    f  include filter (regex)    x  exclude filter',
        '  a  snapshot logs + saves now       o  open the data folder      i  info: paths, sources')) { Write-Plain $h }
    Write-Plain '  Colours: red = error, yellow = warning, white = info, gray = debug/noise.' 'gray'
    Write-Line ''
}
function Show-Info {
    Write-Head 'Info'
    Write-Plain ('  Game folder ...... ' + $script:LeRoot)
    Write-Plain ('  Data folder ...... ' + $script:Data)
    Write-Plain ('  Save folder ...... ' + $script:SaveRoot)
    Write-Plain ('  This session ..... ' + $(if ($script:ArcDir) { $script:ArcDir } else { '(starts with the game process)' }))
    Write-Plain ('  Level ............ ' + $script:LvlName[$script:MinLvl] + '   noise: ' + $script:ShowNoise + '   raw: ' + $script:ShowRaw)
    Write-Plain ('  Console .......... PowerShell ' + $PSVersionTable.PSVersion + '   colours: ' + $script:UseColor + '   footer: ' + $script:Footer)
    Write-Plain ('  Sources (' + $script:Sources.Count + '):')
    foreach ($s in $script:Sources) { Write-Plain ('    ' + $s.Tag.PadRight(6) + $s.Path + '   (' + (Fmt-Bytes $s.Bytes) + ' read)') 'gray' }
    Write-Line ''
}
function Show-SysEvents {
    Write-Head 'Windows events, last 2 hours'
    if (-not $script:IsWin) { Write-Plain '  not available on this OS' 'gray'; return }
    if ($NoSystemEvents) { Write-Plain '  disabled (-NoSystemEvents)' 'gray'; return }
    $ev = @(Get-SysEvents ([datetime]::Now.AddHours(-2)) ([datetime]::Now) $true)
    if ($ev.Count -eq 0) { Write-Plain '  none (no app crash/hang, Kernel-Power 41, WHEA, GPU driver, disk/NVMe, or bugcheck events)' 'green' }
    foreach ($e in $ev) { Write-Plain ('  ' + $e.T.ToString('HH:mm:ss') + '  ' + $e.Log.PadRight(11) + $e.Prov + ' #' + $e.Id + '  ' + (Trunc $e.Msg 200)) 'byellow' }
    Write-Line ''
}
function Startup-HardwareCheck {
    if (-not $script:IsWin -or $NoSystemEvents) { return }
    try {
        $ev = @(Get-SysEvents ([datetime]::Now.AddDays(-3)) ([datetime]::Now) $false | Where-Object { $_.Prov -like 'Microsoft-Windows-Kernel-Power' -or $_.Prov -like 'Microsoft-Windows-WHEA*' -or $_.Prov -like '*SystemErrorReporting*' -or $_.Prov -eq 'EventLog' })
        if ($ev.Count -eq 0) { Write-Plain ('  ' + $script:G.dot + ' hardware check: no hard resets, WHEA errors or bugchecks in the last 3 days') 'green' }
        else {
            Write-Plain ('  ! hardware check: ' + $ev.Count + ' hard-reset / WHEA / bugcheck event(s) in the last 3 days. Latest:') 'byellow'
            foreach ($e in ($ev | Select-Object -Last 3)) { Write-Plain ('      ' + $e.T.ToString('MM-dd HH:mm:ss') + '  ' + $e.Prov + ' #' + $e.Id + '  ' + (Trunc $e.Msg 120)) 'byellow' }
            Write-Plain '      (a crash with no game error is hardware until proven otherwise; press h for details)' 'gray'
        }
    } catch { }
}
#endregion

#region footer, keys, analyze, main
function Footer-Text {
    $S = $script:S; $pi = $script:ProcInfo; $parts = New-Object System.Collections.Generic.List[string]
    if ($script:Proc) { $parts.Add(' ' + $script:G.dot + ' RUNNING pid ' + $pi.Pid + ' ' + (Fmt-Span ([datetime]::Now - $pi.Start))) } else { $parts.Add(' o waiting for ' + $ProcessName + '.exe') }
    $ph = $S.Phase
    if ($ph -like 'Autoload: mounting*' -and $S.Mounts.Count -gt 0) { $ph = 'Mounting ' + $S.MountedN + '/' + $S.Mounts.Count }
    $parts.Add($ph)
    if ($S.LvlCur) { $parts.Add('level ' + $S.LvlCur) }
    if ($S.TexTotal -gt 0) { $parts.Add('tex ' + (Fmt-N $S.TexTotal)) }
    if ($script:Proc) { $parts.Add('RAM ' + (Fmt-Bytes $pi.Mem)) }
    if ($script:Gpu.Ok -and $script:Proc) { $parts.Add(('VRAM {0:0.0}/{1:0.0}G {2:0}C' -f ($script:Gpu.Used / 1024), ($script:Gpu.Total / 1024), $script:Gpu.Temp)) }
    $parts.Add('E ' + (Fmt-N $S.Err) + ' W ' + (Fmt-N $S.Warn))
    $flags = $script:LvlName[$script:MinLvl]
    if ($script:ShowRaw) { $flags += ' RAW' }; if ($script:ShowNoise) { $flags += ' +noise' }; if ($script:Paused) { $flags += ' PAUSED(' + $script:PauseQ.Count + ')' }
    if ($script:RxInclude) { $flags += ' inc' }; if ($script:RxExclude) { $flags += ' exc' }
    $parts.Add($flags); $parts.Add('? help')
    return ($parts -join (' ' + $script:G.sep + ' '))
}
function Flush-Pause { while ($script:PauseQ.Count -gt 0) { Out-Raw (($script:PauseQ.Dequeue()) + $script:R + "`n") } }
function Prompt-Line([string]$label) { Out-Raw ((Col 'bwhite') + $label + $script:R + ' '); $v = ''; try { $v = [Console]::ReadLine() } catch { }; return $v }

function Handle-Key([System.ConsoleKeyInfo]$k) {
    $c = [string]$k.KeyChar
    switch -CaseSensitive ($c) {
        '?' { Show-Help }
        'q' { return $true }
        's' { Show-Summary }
        'm' { Show-Mods }
        'g' { Show-SetupCheck }
        'b' { $fp = Get-Fingerprint; Save-Fp $fp (Join-Path $script:Data 'lastgood.json'); Write-Plain '  current setup saved as the known-good snapshot' 'cyan' }
        'e' { Show-Recent }
        'h' { Show-SysEvents }
        'i' { Show-Info }
        'l' { $script:MinLvl = ($script:MinLvl + 1) % 4; Write-Plain ('  level filter: ' + $script:LvlName[$script:MinLvl] + ' and above') 'cyan' }
        'v' { $script:ShowNoise = -not $script:ShowNoise; Write-Plain ('  noise lines: ' + $(if ($script:ShowNoise) { 'SHOWN' } else { 'hidden' })) 'cyan' }
        'r' { $script:ShowRaw = -not $script:ShowRaw; Write-Plain ('  raw mode: ' + $(if ($script:ShowRaw) { 'ON' } else { 'off' })) 'cyan' }
        'p' { $script:Paused = -not $script:Paused; if (-not $script:Paused) { Flush-Pause; Write-Plain '  resumed' 'cyan' } else { Out-Raw ((Col 'cyan') + '  paused - logging continues (p to resume)' + $script:R + "`n") } }
        'c' { try { Clear-Host } catch { }; Setup-Footer }
        'f' { $v = Prompt-Line 'include regex (empty = off):'; if ($v) { $script:RxInclude = New-Object System.Text.RegularExpressions.Regex($v, 'IgnoreCase') } else { $script:RxInclude = $null } }
        'x' { $v = Prompt-Line 'exclude regex (empty = off):'; if ($v) { $script:RxExclude = New-Object System.Text.RegularExpressions.Regex($v, 'IgnoreCase') } else { $script:RxExclude = $null } }
        'a' { $n = Arc-Snapshot $true; $b = Backup-Saves 'manual'; Write-Plain ('  snapshot: ' + $n + ' log file(s) copied; saves ' + $(if ($b) { 'copied to ' + $b } else { 'unchanged since the last copy' })) 'cyan' }
        'o' { try { if ($script:IsWin) { Start-Process explorer.exe -ArgumentList ('"' + $script:Data + '"') } } catch { } }
    }
    return $false
}
function Write-HeaderBanner {
    Write-Banner ('MASS EFFECT CONSOLE ' + $script:Ver + '   ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) 'bcyan'
    Write-Plain ('  Game ........... ' + $script:LeRoot)
    Write-Plain ('  Following ...... ' + (($script:Sources | ForEach-Object { $_.Tag }) -join ' '))
    Write-Plain ('  Data folder .... ' + $script:Data)
    Write-Plain '  Read-only toward the game. Copies your ME1 saves into the data folder at launch, exit and after every save.' 'gray'
    Write-Plain '  Keys: ? help   s summary   m mods   g setup/diff   b bless   e errors   l level   v noise   r raw   p pause   q quit' 'gray'
}
function Catch-Up {
    $script:Quiet = (-not $FromStart)
    $total = $script:Sources.Count; $i = 0
    if ($script:Interactive -and -not $Analyze) { Draw-Footer (' reading existing logs (' + $total + ' files)') }
    [void](Pump $true)
    $script:Quiet = $false
}
function Run-Analyze {
    $script:Footer = $false; $script:Interactive = $false
    if ($AnalyzeFolder) {
        $f = (Resolve-Path -LiteralPath $AnalyzeFolder -ErrorAction Stop).Path
        if (Test-Path -LiteralPath (Join-Path $f 'logs') -PathType Container) { $script:LogDirOverride = Join-Path $f 'logs' } else { $script:LogDirOverride = $f }
        $lo = Join-Path $f 'LoadOrder.Txt'
        if (Test-Path -LiteralPath $lo) { foreach ($l in [System.IO.File]::ReadAllLines($lo, $script:Utf8)) { if ($l -match '^\s*(\d+):\s*(\S+)\s*\((.*)\)\s*$') { $script:ModNames[$Matches[2].ToLowerInvariant()] = $Matches[3] } } }
    }
    Scan-Sources
    if ($script:Sources.Count -eq 0) { Write-Plain 'No log files found to analyse.' 'red'; return }
    $rdir = Join-Path $script:Data 'reports'; New-Item -ItemType Directory -Force -Path $rdir | Out-Null
    $rpath = Join-Path $rdir ('analysis_' + [datetime]::Now.ToString('yyyyMMdd_HHmmss') + '.txt')
    Write-Plain ('Analysing ' + $script:Sources.Count + ' log file(s) ...') 'cyan'
    $script:Quiet = $true
    [void](Pump $true)
    $script:Quiet = $false
    try { $fsr = New-Object System.IO.FileStream($rpath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read); $script:Transcript = New-Object System.IO.StreamWriter($fsr, $script:Utf8); $script:Transcript.AutoFlush = $true; $script:Transcript.WriteLine('Mass Effect Console analysis ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss') + '   source: ' + $(if ($AnalyzeFolder) { $AnalyzeFolder } else { $script:LogDir })) } catch { }
    Show-Summary
    Show-Mods
    Write-Head 'Per-log notes'
    foreach ($s in $script:Sources) { Write-Plain ('  ' + $s.Tag.PadRight(6) + $s.Name + ': ' + $s.Lines + ' lines, ' + $s.Err + ' error(s), ' + $s.Warn + ' warning(s)') $(if ($s.Err -gt 0) { 'byellow' } else { 'white' }) }
    Write-Line ''
    Write-Plain ('Report saved: ' + $rpath) 'green'
    if ($script:Transcript) { try { $script:Transcript.Dispose() } catch { }; $script:Transcript = $null }
}

function Main {
    try { $script:Interactive = (-not [Console]::IsOutputRedirected) } catch { $script:Interactive = $true }
    if (-not $script:Interactive) { $script:UseColor = $false; $script:Footer = $false }
    if ($script:Interactive) { try { [Console]::OutputEncoding = $script:Utf8 } catch { }; if (-not (Enable-VT)) { $script:UseColor = $false; $script:Footer = $false } }
    if ($script:UseColor) { $script:R = $script:Esc + '[0m' }

    $base = $PSScriptRoot; if (-not $base) { $base = (Get-Location).Path }
    if ($OutDir) { $script:Data = $OutDir } else { $script:Data = Join-Path $base 'data' }
    try { New-Item -ItemType Directory -Force -Path $script:Data | Out-Null } catch { }

    if ($DumpFile) {
        if (-not (Test-Path -LiteralPath $DumpFile)) { Write-Host ('File not found: ' + $DumpFile) -ForegroundColor Red; return }
        Write-Host ('Crash dump: ' + $DumpFile) -ForegroundColor Cyan
        foreach ($l in (Describe-CrashDump (Resolve-Path -LiteralPath $DumpFile).Path)) { Write-Host ('  ' + $l) }
        return
    }
    $root = Find-Game
    if (-not $root -and -not $AnalyzeFolder) { Write-Host 'Could not find Mass Effect Legendary Edition. Run again with -GamePath "C:\...\steamapps\common\Mass Effect Legendary Edition".' -ForegroundColor Red; return }
    if ($root) { Set-GamePaths $root }
    $script:SaveRoot = Resolve-SaveRoot
    [void](Load-LoadOrderNames); Load-LevelNames
    $script:Gpu.Exe = Find-NvSmi

    if ($Bless) { $fp = Get-Fingerprint; Save-Fp $fp (Join-Path $script:Data 'lastgood.json'); Write-Host ('Known-good snapshot saved: ' + (Join-Path $script:Data 'lastgood.json')); return }
    if ($Analyze -or $AnalyzeFolder) { Run-Analyze; return }

    $script:Mutex = $null
    if (-not $AllowMultiple) {
        $created = $false
        try { $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\MassEffectConsoleSingleton', [ref]$created) } catch { $created = $true }
        if (-not $created) { Write-Host 'Another Mass Effect Console is already running. Close it first, or run with -AllowMultiple.' -ForegroundColor Yellow; $script:Mutex = $null; return }
    }
    [void](Ensure-Native)
    if ($script:NativeOk) { try { [MeProc]::HookClose() } catch { } }

    Scan-Sources
    Write-HeaderBanner
    if ($script:Sources.Count -eq 0) {
        Write-Plain ('  !! No log files under ' + $script:LogDir + ' yet (the game creates them on the first modded launch).') 'bred'
    }
    $script:Fp = Get-Fingerprint
    Show-SetupCheck
    Startup-HardwareCheck
    Setup-Footer
    Set-Title 'Mass Effect Console'
    $script:SaveSig = Get-SaveMap

    Proc-Poll
    if ($script:Proc -eq $null) { Write-Plain ('  ' + $script:G.dot + ' ' + $ProcessName + '.exe is not running. Showing the end of the last run; launch the game and this window follows it.') 'gray' }
    Write-Plain '  Reading existing logs ...' 'gray'
    Catch-Up
    if (-not $FromStart -and $Backlog -gt 0) {
        $tail = $script:Ring.ToArray() | Select-Object -Last $Backlog
        if ($tail) { Write-Line ((Col 'gray') + ('  ----- last ' + @($tail).Count + ' lines of the existing logs -----')); foreach ($l in $tail) { Out-Raw ($l + $script:R + "`n") } }
    }
    if ($script:S.Phase -ne 'Idle') {
        $s = $script:S
        Write-Line ((Col 'gray') + ('  ----- state: ' + $s.Phase + ' | mods mounted ' + $s.MountedN + ' | textures ' + (Fmt-N $s.TexTotal) + ' | errors ' + (Fmt-N $s.Err) + ' | s = full summary -----'))
        foreach ($f in (Get-BootFindings)) { Write-Line ((Col $(if ($f.Lvl -ge 3) { 'bred' } else { 'byellow' })) + ('             ! ' + $f.Text)) }
    }
    if ($Quit) { Show-Summary; return }
    if (-not $script:Proc -and -not $NoArchive -and $script:S.Phase -ne 'Idle' -and -not $script:ArcDir) {
        try {
            $pl = $script:Sources | Where-Object { $_.Kind -eq 'proxy' } | Select-Object -First 1
            if ($pl) { Arc-Open (Get-Item -LiteralPath $pl.Path).LastWriteTime; if ($script:ArcDir) { [void](Arc-Snapshot $true); Write-SessionSummary; Write-Plain ('  ' + $script:G.dot + ' last run saved before it can be overwritten: ' + $script:ArcDir) 'green' } }
        } catch { }
    }
    [void](Backup-Saves 'start')
    Write-Line ''
    Write-Plain (' ' + $script:G.arrow + ' live. Waiting for new log lines ...') 'bcyan'

    $lastFoot = [datetime]::MinValue; $lastProc = [datetime]::MinValue; $lastSave = [datetime]::MinValue
    $quit = $false
    try {
        while (-not $quit) {
            $now = [datetime]::Now
            if ($MaxSeconds -gt 0 -and ($now - $script:RunStart).TotalSeconds -ge $MaxSeconds) { break }
            if (($now - $script:LastScan).TotalSeconds -ge 3) { $script:LastScan = $now; Scan-Sources }
            $got = 0
            $got += Pump $false
            if (($now - $lastProc).TotalSeconds -ge 1) { $lastProc = $now; Proc-Poll }
            if ($script:Proc -and ($now - $lastSave).TotalSeconds -ge 3) { $lastSave = $now; Save-Poll }
            if ($script:ProcInfo.PMDue -and $now -ge $script:ProcInfo.PMDue) {
                [void](Pump $false)
                Post-Mortem
            }
            if ($SnapshotSec -gt 0 -and $script:Proc -and ($now - $script:LastSnap).TotalSeconds -ge $SnapshotSec) { Persist-Live $false }
            if ($script:NativeOk -and [MeProc]::CloseRequested) { $quit = $true; Notice 'console window is closing - saving the session first' 'byellow' }
            if (($now - $lastFoot).TotalMilliseconds -ge 400) { $lastFoot = $now; Draw-Footer (Footer-Text) }
            if ($script:Interactive) { try { while ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if (Handle-Key $k) { $quit = $true; break } } } catch { } }
            if (-not $quit -and $got -eq 0) { Start-Sleep -Milliseconds $PollMs }
        }
    } finally {
        try {
            if ($script:ArcDir) {
                if ($script:Proc -ne $null) { Notice ('console closed while ' + $ProcessName + '.exe was still running (PID ' + $script:ProcInfo.Pid + ')') 'byellow' }
                Persist-Live $true
            }
            if ($script:ProcInfo.PMDue) { try { Post-Mortem } catch { } }
        } catch { }
        Close-ProcHandle; Reset-Footer
        if ($script:Transcript) { try { $script:Transcript.Dispose() } catch { } }
        Out-Raw ($script:R + "`n")
        if ($script:NativeOk) { try { [MeProc]::Done.Set() } catch { } }
        if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { }; try { $script:Mutex.Dispose() } catch { } }
    }
}
Main
#endregion
