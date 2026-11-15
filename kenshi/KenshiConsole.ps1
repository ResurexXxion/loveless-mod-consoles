<#
.SYNOPSIS
    Kenshi Console - live external log console, crash post-mortem and log analyzer for Kenshi (Steam, Windows).

.DESCRIPTION
    Tails every Kenshi-related log at once (kenshi_info.log, kenshi.log, RE_Kenshi_log.txt, MyGUI.log, save.log,
    Dust, SleepFix, BodyMorphCap, SentientSands and any other *.log it finds), parses each format, de-duplicates
    the noise, and shows what matters in a separate window with colours and a live status bar.

    * Understands the game phases (launcher, mod loading, main menu, new game / in game) and times them.
    * Counts mods as they load, checks the real load order against data\mods.cfg, finds slow mods.
    * Groups the repeated problems into categories (missing meshes, missing skeletons, "modified by X does not exist",
      bad research requirements ...) so 7,000 log lines become a short table, with the mod behind each one when it can.
    * Watches kenshi_x64.exe: start, exit code, memory, "not responding".
    * On exit: crash post-mortem (last log lines, last mod loaded, Windows crash events, new dump files, hardware
      events such as WHEA, Kernel-Power 41, nvlddmkm, disk/NVMe resets).
    * Kenshi overwrites its logs on every launch. This tool keeps a copy of every session (and refreshes it while
      the game runs, so even a hard reboot leaves the last logs behind).
    * Read-only toward the game: it never writes into the Kenshi, Workshop or Steam folders.

    Keys while running:  ? help   q quit   p pause   c clear   l level   v noise   r raw   m mods   s summary
                         w missing-records   e recent errors   t trace owners   h system events   a archive
                         o open folder   f filter   x exclude   i info

.PARAMETER KenshiPath     Kenshi install folder. Auto-detected when omitted (Steam libraries, running process, common paths).
.PARAMETER OutDir         Where sessions, transcripts and reports go. Default: KenshiConsole-data next to this script.
.PARAMETER MinLevel       Debug | Info | Warn | Error. Default Info.
.PARAMETER Include        Only show lines whose text matches this regex.
.PARAMETER Exclude        Hide lines whose text matches this regex.
.PARAMETER Raw            No grouping, no suppression, no noise filtering: every line, as written.
.PARAMETER FromStart      Replay the whole of the current logs on screen first (default: only the last -Backlog lines).
.PARAMETER Backlog        Lines of history to show at start. Default 25.
.PARAMETER ShowRepeats    How many times the same problem is printed before it is counted silently. Default 3.
.PARAMETER ShowMissingRecords  Print the "[Mods] Item ... modified by X does not exist" lines too (they are counted either way).
.PARAMETER Analyze        One-shot report on the current logs, then exit. No live tailing.
.PARAMETER AnalyzeFolder  One-shot report on an archived session folder (or any folder holding copies of the logs).
.PARAMETER NoColor / NoFooter / NoArchive / NoSystemEvents / NoModScan / Ascii   Switch features off.
.PARAMETER SnapshotSec    While the game runs, refresh the session copy of the logs every N seconds. 0 = off. Default 30.
.PARAMETER ProcessName    Game process name without .exe. Default kenshi_x64.
.PARAMETER ExtraLog       Extra log files to follow.

.EXAMPLE
    .\KenshiConsole.ps1
.EXAMPLE
    .\KenshiConsole.ps1 -Analyze
.EXAMPLE
    .\KenshiConsole.ps1 -MinLevel Warn -Exclude 'Part map'
#>
[CmdletBinding()]
param(
    [string]$KenshiPath,
    [string]$OutDir,
    [ValidateSet('Debug','Info','Warn','Error')][string]$MinLevel = 'Info',
    [string]$Include,
    [string]$Exclude,
    [string]$ProcessName = 'kenshi_x64',
    [string[]]$ExtraLog = @(),
    [int]$Backlog = 25,
    [int]$ShowRepeats = 3,
    [int]$PollMs = 250,
    [int]$SnapshotSec = 30,
    [switch]$FromStart,
    [switch]$Raw,
    [switch]$ShowMissingRecords,
    [switch]$NoColor,
    [switch]$NoFooter,
    [switch]$NoArchive,
    [switch]$NoSystemEvents,
    [switch]$NoModScan,
    [switch]$Ascii,
    [switch]$Analyze,
    [string]$AnalyzeFolder,
    [int]$KeepSessions = 30,
    [int]$MaxSeconds = 0,    # exit by itself after N seconds (0 = run until q); handy for scheduled/automated runs
    [switch]$Trace,      # with -Analyze: also search the .mod files for who references the missing files
    [switch]$Quit,       # test hook: read everything once, print, exit
    [switch]$AllowMultiple,   # skip the one-copy-at-a-time lock
    [string]$DumpFile     # with -Analyze: read this crashDump zip / .dmp and print what it says
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:Ver     = '1.2'
$script:IsWin   = ($env:OS -eq 'Windows_NT')
$script:Utf8    = New-Object System.Text.UTF8Encoding($false)
$script:RunStart = [datetime]::Now

#region ---------------------------------------------------------------- output layer
$script:Esc = [string][char]27
$script:UseColor  = (-not $NoColor)
$script:Footer    = (-not $NoFooter)
$script:Interactive = $true
$script:Quiet     = $false         # true while catching up: render but do not print
$script:Paused    = $false
$script:PauseQ    = New-Object System.Collections.Generic.Queue[string]
$script:Ring      = New-Object System.Collections.Generic.List[string]   # rendered visible lines (for backlog)
$script:Transcript = $null
$script:CaptureTo = $null
$script:Tee = $null
$script:WinH = 0
$script:LastFooter = [datetime]::MinValue

$script:SGR = @{
    reset='0'; bold='1'; dim='2'; rev='7'; red='31'; green='32'; yellow='33'; blue='34'; mag='35'; cyan='36'; white='97'
    gray='90'; bred='1;31'; bgreen='1;32'; byellow='1;33'; bcyan='1;36'; bmag='1;35'; bwhite='1;97'; errbg='41;97'
}
function Col([string]$name) { if ($script:UseColor -and $script:SGR.ContainsKey($name)) { return ($script:Esc + '[' + $script:SGR[$name] + 'm') } return '' }
$script:R = ''   # reset, set after VT check

if ($Ascii) { $script:G = @{ dot='*'; bar='='; arrow='>'; star='*'; up='^'; sep='|'; ell='...'; rep='x' } }
else        { $script:G = @{ dot=[string][char]0x25CF; bar=[string][char]0x2550; arrow=[string][char]0x25B6; star=[string][char]0x2605; up=[string][char]0x2191; sep=[string][char]0x2502; ell=[string][char]0x2026; rep=[string][char]0x00D7 } }

function Enable-VT {
    if (-not $script:IsWin) { return $true }
    try {
        if (-not ('KcNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class KcNative {
  [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
  [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
  [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
'@
        }
        $h = [KcNative]::GetStdHandle(-11)
        [uint32]$m = 0
        if (-not [KcNative]::GetConsoleMode($h, [ref]$m)) { return $false }
        return [KcNative]::SetConsoleMode($h, ($m -bor 4))
    } catch { return $false }
}

function Dbg([string]$m) { if ($env:KC_DEBUG) { [Console]::Error.WriteLine('[dbg] ' + $m) } }
function Strip-Ansi([string]$s) { return [regex]::Replace($s, "\x1B\[[0-9;?]*[A-Za-z]", '') }

function Out-Raw([string]$text) {
    try { [Console]::Out.Write($text) } catch { }
}

function Write-Line([string]$rendered, [bool]$ring = $false) {
    # one finished, possibly coloured line
    $plain = Strip-Ansi $rendered
    if ($null -ne $script:CaptureTo) { $script:CaptureTo.Add($plain); return }
    if ($null -ne $script:Tee) { $script:Tee.Add($plain) }
    if ($null -ne $script:Transcript) { try { $script:Transcript.WriteLine($plain) } catch { } }
    if ($ring) { $script:Ring.Add($rendered); if ($script:Ring.Count -gt 600) { $script:Ring.RemoveRange(0, 100) } }
    if ($script:Quiet) { return }
    if ($script:Paused) {
        if ($script:PauseQ.Count -lt 5000) { $script:PauseQ.Enqueue($rendered) }
        return
    }
    Out-Raw ($rendered + $script:R + "`n")
}

function Write-Plain([string]$text, [string]$color = '') {
    if ($color -ne '') { Write-Line ((Col $color) + $text + $script:R) } else { Write-Line $text }
}

function Write-Banner([string]$text, [string]$color = 'bcyan') {
    $w = 78
    try { if ($script:Interactive) { $w = [Math]::Max(40, [Math]::Min(120, [Console]::WindowWidth - 2)) } } catch { }
    $bar = ($script:G.bar * $w)
    Write-Line ''
    Write-Line ((Col $color) + $bar + $script:R)
    Write-Line ((Col $color) + ' ' + $text + $script:R)
    Write-Line ((Col $color) + $bar + $script:R)
}

function Write-Head([string]$text) {
    Write-Line ''
    Write-Line ((Col 'bwhite') + $text + $script:R)
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

# footer: reverse-video status line on the last row, scroll region above it
function Setup-Footer {
    if (-not $script:Footer -or -not $script:Interactive) { return }
    try {
        $h = [Console]::WindowHeight
        if ($h -lt 6) { $script:Footer = $false; return }
        $script:WinH = $h
        Out-Raw ($script:Esc + '[1;' + ($h - 1) + 'r')
        Out-Raw ($script:Esc + '[' + ($h - 1) + ';1H')
    } catch { $script:Footer = $false }
}
function Reset-Footer {
    if (-not $script:Interactive) { return }
    try {
        if ($script:WinH -gt 0) {
            Out-Raw ($script:Esc + '[r')
            Out-Raw ($script:Esc + '[' + $script:WinH + ';1H' + $script:Esc + '[2K')
        }
    } catch { }
}
function Draw-Footer([string]$text) {
    if ($script:UseColor) { } 
    if (-not $script:Footer -or -not $script:Interactive) { return }
    try {
        $h = [Console]::WindowHeight; $w = [Console]::WindowWidth
        if ($h -ne $script:WinH) { Setup-Footer }
        $t = Trunc $text ($w - 1)
        $t = $t.PadRight($w - 1)
        Out-Raw ($script:Esc + '7' + $script:Esc + '[' + $h + ';1H' + (Col 'rev') + $t + $script:R + $script:Esc + '8')
    } catch { }
}
function Set-Title([string]$t) { if ($script:Interactive) { try { $Host.UI.RawUI.WindowTitle = $t } catch { } } }
#endregion

#region ---------------------------------------------------------------- state, rules, classifier
$script:LvlName = @('DBG','INF','WRN','ERR')
$script:LvlCol  = @('gray','white','byellow','bred')
$script:MinLvl  = @{ Debug=0; Info=1; Warn=2; Error=3 }[$MinLevel]
$script:RxInclude = $null; $script:RxExclude = $null
if ($Include) { $script:RxInclude = New-Object System.Text.RegularExpressions.Regex($Include, 'IgnoreCase') }
if ($Exclude) { $script:RxExclude = New-Object System.Text.RegularExpressions.Regex($Exclude, 'IgnoreCase') }
$script:ShowNoise = $false     # 'v' toggles: show hidden noise lines
$script:ShowRaw   = [bool]$Raw

function New-Session {
    return @{
        Id = [guid]::NewGuid().ToString('N').Substring(0,6)
        Start = $null; Phase = 'Idle'; PhaseSince = [datetime]::Now; PhaseLog = (New-Object System.Collections.Generic.List[string])
        Lines = 0; Noise = 0; Err = 0; Warn = 0
        ModsLoaded = 0; ModLast = ''; ModFirstT = $null; ModLastT = $null; ModOrder = (New-Object System.Collections.Generic.List[string])
        ModSlow = (New-Object System.Collections.Generic.List[object]); ModPrevT = $null; ModPrevName = ''
        CoreMods = (New-Object System.Collections.Generic.List[string])
        Cats = @{}; ErrSig = @{}
        Launcher = 0; Threads = 0; NewGame = ''; Milestones = (New-Object System.Collections.Generic.List[string])
        Mismatch = (New-Object System.Collections.Generic.List[string])
        PhaseDt = $null; LaunchDt = $null; LogStart = $null; CleanExit = $false; NotLoaded = (New-Object System.Collections.Generic.List[string]); LastIdx = -1
        RecentMap = @{}; RecentOrder = (New-Object System.Collections.Generic.List[string])
    }
}
$script:S = New-Session

function Get-Cat([string]$id, [string]$title, [int]$lvl) {
    $c = $null
    if ($script:S.Cats.ContainsKey($id)) { return $script:S.Cats[$id] }
    $c = @{ Id=$id; Title=$title; Lvl=$lvl; Count=0; Printed=0; Distinct=(New-Object 'System.Collections.Generic.HashSet[string]'); Owners=@{}; First=''; Last=''; Told=$false; Samples=(New-Object System.Collections.Generic.List[string]) }
    $script:S.Cats[$id] = $c
    return $c
}

# rule: Id, Kind, Rx, Mode (flood|show|count|hide|special), Lvl (0-3 or -1 = from line), Title
# named groups: key (distinct item), owner (who is responsible)
function New-Rule([string]$id,[string]$kind,[string]$rx,[string]$mode,[int]$lvl,[string]$title) {
    return [pscustomobject]@{ Id=$id; Kind=$kind; Rx=(New-Object System.Text.RegularExpressions.Regex($rx, 'Compiled')); Mode=$mode; Lvl=$lvl; Title=$title }
}
$script:Rules = @{}
function Add-Rule($r) { if (-not $script:Rules.ContainsKey($r.Kind)) { $script:Rules[$r.Kind] = New-Object System.Collections.Generic.List[object] } $script:Rules[$r.Kind].Add($r) }

# ---- info log (kenshi_info.log)
Add-Rule (New-Rule 'modload'  'info' '^\[Mods\] Loaded mod: (?<key>.+?)\s*$' 'special' 1 'Mod loaded')
Add-Rule (New-Rule 'coreload' 'info' '^\[Mods\] Loaded core(?: mod)?:? ?(?<key>.*)$' 'special' 1 'Core data loaded')
Add-Rule (New-Rule 'missrec'  'info' '^\[Mods\] Item (?<key>.+?) modified by (?<owner>.+?) does not exist' 'count' 2 'Record edited by a mod, but the target record is missing (mod loaded before its master, or master absent)')
Add-Rule (New-Rule 'missrec2' 'info' '^\[Mods\] .*does not exist' 'count' 2 'Other "[Mods] ... does not exist" messages')
Add-Rule (New-Rule 'badmesh'  'info' '^Loaded mesh doesn''t exist: \.?[\\/]?mods[\\/](?<owner>[^\\/]+)[\\/](?<key>.+)$' 'flood' 3 'Mesh file referenced by a mod does not exist on disk')
Add-Rule (New-Rule 'badmesh2' 'info' '^Loaded mesh doesn''t exist: (?<key>.+)$' 'flood' 3 'Mesh file referenced by a mod does not exist on disk')
Add-Rule (New-Rule 'partmap'  'info' '^Part map contains invalid colour' 'count' 2 'Race/part map with an invalid colour value (cosmetic)')
Add-Rule (New-Rule 'research' 'info' '^Invalid research requirement' 'flood' 2 'Research entry with an invalid requirement')
Add-Rule (New-Rule 'validate' 'info' '^\[Launcher\] Validating mod list' 'count' 1 'Launcher mod-list validation passes')
Add-Rule (New-Rule 'nofaction' 'info' '^(?<key>.+): no faction for homeless squad' 'flood' 3 'Squad/character template with no faction (broken entry in some mod)')
Add-Rule (New-Rule 'scythe'   'info' '^\[Scythe\] Created bin file' 'hide' 0 'Scythe: building cached .bin files (first run after a mod change)')
Add-Rule (New-Rule 'thread'   'info' '^\*\* Thread ''(?<key>[^'']+)''' 'special' 1 'Thread started')
# ---- Ogre log (kenshi.log)
Add-Rule (New-Rule 'skel'     'ogre' '^Error: Skeleton file (?<key>.+?) not found' 'flood' 3 'Skeleton (animation) file not found')
Add-Rule (New-Rule 'skelx'    'ogre' '^OGRE EXCEPTION\(5:ItemIdentityException\): Unable to derive resource group for (?<key>\S+?\.skeleton)' 'count' 3 'Skeleton resource group could not be derived (follows a missing skeleton)')
Add-Rule (New-Rule 'tex'      'ogre' '^Error loading texture (?<key>.+?)\.? Texture layer will be blank' 'flood' 3 'Texture file missing')
Add-Rule (New-Rule 'ogrex'    'ogre' '^OGRE EXCEPTION\((?<key>\d+:\w+)\)' 'show' 3 'Ogre exception')
Add-Rule (New-Rule 'pucomp'   'ogre' '^Compiler error: unknown error in (?<key>\S+)' 'count' 2 'ParticleUniverse script compile error (very common with mods; the effect just does not appear)')
Add-Rule (New-Rule 'bonewarn' 'ogre' '^WARNING: the mesh .*(bone|assign)' 'hide' 0 'Mesh bone-assignment warnings')
Add-Rule (New-Rule 'oldfmt'   'ogre' '^WARNING: .* is an older format' 'hide' 0 'Old mesh format notices')
Add-Rule (New-Rule 'ogrenoise' 'ogre' '^(Added resource location|Parsing script|DNDN|Mesh:|Texture:|Loading|All done|ParticleUniverse:|D3D11|Registering|Skeleton:|Material|OGRE initialising|Creating resource group|Initialising resource group|Finished parsing|Loading ND|Texture:|OverlayElement|Overlays|Compiling|Plugin|Installing|Mesh \S+ is|Registering ResourceManager|RenderSystem|Terrain|Created|Starting|Stopping|Loaded|Unloading)' 'hide' 0 'Ogre routine messages')
# ---- MyGUI
Add-Rule (New-Rule 'guiskin'  'mygui' '^Skin ''(?<key>[^'']+)'' not found' 'flood' 2 'MyGUI skin not found (layout uses a missing skin)')
Add-Rule (New-Rule 'guiprop'  'mygui' '^Widget property ''(?<key>[^'']+)'' not found' 'flood' 2 'MyGUI widget property not recognised')
# ---- RE_Kenshi aggregated log
Add-Rule (New-Rule 'rfall'    're' '^FallDamage:' 'hide' 0 'FallDamage periodic stats')
Add-Rule (New-Rule 'rdust'    're' '^Dust: \[Dust\] (GUI effect list|Present #|GameLoop #|ShaderPatch|ShaderMetadata)' 'hide' 0 'Dust periodic chatter (echoed into the RE_Kenshi log)')
Add-Rule (New-Rule 'rperf'    're' 'perf overlay_summary' 'hide' 0 'Vital-Read perf summaries')
Add-Rule (New-Rule 'rhook'    're' 'hooks_installed rows=\d+ ok=\d+ failed=''-''' 'hide' 1 'Hook installs ok')
# ---- save.log
Add-Rule (New-Rule 'savetmp'  'save' 'scanForResidualTempFolders' 'count' 2 'Save system: residual temp folder scan (harmless on a fresh profile)')
Add-Rule (New-Rule 'sess'     'save' '^(Session start\.|Exit\.)' 'special' 1 'Save session')
# ---- Dust
Add-Rule (New-Rule 'dustnoise' 'dust' '^\[Dust\] (GUI effect list|Present #|GameLoop #|ShaderPatch|ShaderMetadata|Config loaded|Loaded effect)' 'hide' 0 'Dust periodic chatter')
# ---- plain logs (SleepFix, BodyMorphCap, SentientSands ...)
Add-Rule (New-Rule 'sfhook'   'plain' 'orig=0{8,16}\s*$' 'show' 3 'SleepFix: hook failed to install (orig=0)')
Add-Rule (New-Rule 'sfcfg'    'plain' '^(\s+\S+=|\s+\S+\s+addr=)|후킹 실패이며' 'hide' 0 'Mod config echo')
Add-Rule (New-Rule 'ssproc'   'plain' 'HOOK_MSG_PROC' 'hide' 0 'SentientSands hook message processing')

$script:RxErr  = New-Object System.Text.RegularExpressions.Regex('(?i)(^error\b|\[(error|err|fatal|crit\w*)\]|\b(fatal|exception|crash(ed)?|access violation|assertion|segfault|unhandled|stack overflow)\b|(?<![\w=])error[:!]|\bfail(ed|ure)?\b(?!\s*[=s_])|\babort(ed)?\b|실패|오류)', 'Compiled')
$script:RxWarn = New-Object System.Text.RegularExpressions.Regex('(?i)(^warn|\[warn\w*\]|\bwarning\b|\bdeprecated\b|\bnot found\b|\bmissing\b|\bcannot\b|\bcould not\b|\binvalid\b|경고)', 'Compiled')
$script:RxInfoLine = New-Object System.Text.RegularExpressions.Regex('^\{0x[0-9A-Fa-f]+\}\s+(\d{4}-\d\d-\d\d)\s+(\d\d:\d\d:\d\d)\s+\[(\w+)\]:\s?(.*)$', 'Compiled')
$script:RxOgreLine = New-Object System.Text.RegularExpressions.Regex('^(\d\d:\d\d:\d\d):\s?(.*)$', 'Compiled')
$script:RxReLine   = New-Object System.Text.RegularExpressions.Regex('^(Error |Warning |Warn )?(\d+\.\d+)\s+(.*)$', 'Compiled')
$script:RxSaveLine = New-Object System.Text.RegularExpressions.Regex('^(\d\d:\d\d:\d\d)\s+\[(\w+)\]\s?(.*)$', 'Compiled')
$script:RxDustKey = New-Object System.Text.RegularExpressions.Regex('(?i)(loading\.\.\.|loaded \d+ effect plugin|found \d+ global presets|all hooks installed|initialized successfully|preset|upscaler|shader cache|crash|localization: language)', 'Compiled')
$script:RxNorm = New-Object System.Text.RegularExpressions.Regex('0x[0-9A-Fa-f]+|\d+(\.\d+)?', 'Compiled')

function Guess-Level([string]$m) {
    if ($script:RxErr.IsMatch($m)) { return 3 }
    if ($script:RxWarn.IsMatch($m)) { return 2 }
    return 1
}
function Norm-Sig([string]$m) { return $script:RxNorm.Replace($m, 'N') }

# parse one raw line into pT (time) pL (level 0-3) pM (message); returns $false if unparseable
$script:pT = ''; $script:pL = 1; $script:pM = ''; $script:pDate = ''
function Parse-Line([string]$kind, [string]$line) {
    $script:pDate = ''
    switch ($kind) {
        'info' {
            $m = $script:RxInfoLine.Match($line)
            if (-not $m.Success) { $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line; return $true }
            $script:pDate = $m.Groups[1].Value; $script:pT = $m.Groups[2].Value; $script:pM = $m.Groups[4].Value
            switch ($m.Groups[3].Value.ToLowerInvariant()) { 'error' { $script:pL = 3 } 'warning' { $script:pL = 2 } 'warn' { $script:pL = 2 } 'debug' { $script:pL = 0 } default { $script:pL = 1 } }
            return $true
        }
        'ogre' {
            $m = $script:RxOgreLine.Match($line)
            if ($m.Success) { $script:pT = $m.Groups[1].Value; $script:pM = $m.Groups[2].Value } else { $script:pT = ''; $script:pM = $line }
            $g = Guess-Level $script:pM
            if ($g -ge 2) { $script:pL = $g } else { $script:pL = 0 }
            return $true
        }
        're' {
            $m = $script:RxReLine.Match($line)
            if (-not $m.Success) { $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line; return $true }
            $script:pT = ('+{0}s' -f $m.Groups[2].Value); $script:pM = $m.Groups[3].Value
            $pre = $m.Groups[1].Value.Trim()
            if ($pre -eq 'Error') { $script:pL = 3 } elseif ($pre -like 'Warn*') { $script:pL = 2 } else { $script:pL = Guess-Level $script:pM; if ($script:pL -eq 1) { $script:pL = 1 } }
            return $true
        }
        'mygui' {
            $p = $line -split '\s+\|\s+'
            if ($p.Count -lt 4) { $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line; return $true }
            $script:pT = $p[0].Trim(); $script:pM = $p[3]
            switch ($p[2].Trim().ToLowerInvariant()) { 'error' { $script:pL = 3 } 'warning' { $script:pL = 2 } 'info' { $script:pL = 0 } default { $script:pL = 1 } }
            if ($p[1].Trim() -ne '' -and $script:pL -ge 2) { $script:pM = $script:pM + '  [' + $p[1].Trim() + ']' }
            return $true
        }
        'save' {
            $m = $script:RxSaveLine.Match($line)
            if (-not $m.Success) { $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line; return $true }
            $script:pT = $m.Groups[1].Value; $script:pM = $m.Groups[3].Value
            switch ($m.Groups[2].Value.ToLowerInvariant()) { 'error' { $script:pL = 3 } 'warning' { $script:pL = 2 } default { $script:pL = 1 } }
            return $true
        }
        'dust' {
            $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line
            if ($script:pL -eq 1 -and -not $script:RxDustKey.IsMatch($line)) { $script:pL = 0 }
            return $true
        }
        default {
            $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line
            return $true
        }
    }
}
#endregion

#region ---------------------------------------------------------------- emit, aggregate, lifecycle
$script:Cfg = New-Object System.Collections.Generic.List[string]
$script:CfgIdx = @{}
$script:CfgPath = ''
$script:ModIndex = $null      # mod base name (lower) -> 'workshop:<id>' | 'local'
$script:Ci = [System.Globalization.CultureInfo]::InvariantCulture

function Load-Cfg {
    $script:Cfg.Clear(); $script:CfgIdx = @{}
    if (-not $script:CfgPath -or -not (Test-Path -LiteralPath $script:CfgPath)) { return }
    try {
        $i = 0
        foreach ($l in [System.IO.File]::ReadAllLines($script:CfgPath, $script:Utf8)) {
            $n = $l.Trim()
            if ($n -eq '') { continue }
            $script:Cfg.Add($n)
            $b = $n; if ($b.EndsWith('.mod', 'OrdinalIgnoreCase')) { $b = $b.Substring(0, $b.Length - 4) }
            $k = $b.ToLowerInvariant()
            if (-not $script:CfgIdx.ContainsKey($k)) { $script:CfgIdx[$k] = $i }
            $i++
        }
    } catch { }
}

function To-Dt([string]$d, [string]$t) {
    if (-not $d -or -not $t) { return $null }
    $r = [datetime]::MinValue
    if ([datetime]::TryParseExact(($d + ' ' + $t), 'yyyy-MM-dd HH:mm:ss', $script:Ci, 'None', [ref]$r)) { return $r }
    return $null
}

function Emit([object]$src, [string]$t, [int]$lvl, [string]$msg) {
    if ($msg.Length -gt 700) { $msg = $msg.Substring(0, 700) + $script:G.ell }
    $ts = $t; if ($ts.Length -gt 9) { $ts = $ts.Substring(0, 9) }
    $line = (Col 'gray') + $ts.PadRight(8) + ' ' + $script:R + (Col $src.Color) + $src.Tag.PadRight(5) + $script:R + ' ' + (Col $script:LvlCol[$lvl]) + $script:LvlName[$lvl] + ' ' + $msg
    Write-Line $line $true
}
function Notice([string]$text, [string]$color = 'gray') { Write-Line ((Col $color) + '          ' + $text) $true }

function Set-Phase([string]$name, [object]$dt) {
    $S = $script:S
    $now = [datetime]::Now
    $prev = $S.Phase
    $took = ''
    if ($S.PhaseDt -and $dt -and $dt -ge $S.PhaseDt) { $took = Fmt-Span ($dt - $S.PhaseDt) } elseif ($S.Phase -ne 'Idle') { $took = Fmt-Span ($now - $S.PhaseSince) }
    if ($prev -ne 'Idle' -and $took) { $S.PhaseLog.Add(('{0} = {1}' -f $prev, $took)) }
    $S.Phase = $name; $S.PhaseSince = $now; $S.PhaseDt = $dt
    $extra = ''; if ($took -and $prev -ne 'Idle') { $extra = '   (' + $prev + ' took ' + $took + ')' }
    Write-Line ((Col 'bcyan') + ('          ' + $script:G.arrow + ' ' + $name + $extra)) $true
}

function Cat-Hit([string]$id, [string]$title, [int]$lvl, [System.Text.RegularExpressions.Match]$m, [string]$msg) {
    $c = Get-Cat $id $title $lvl
    $c.Count++
    if ($m -ne $null) {
        $g = $m.Groups['key']; if ($g.Success) { [void]$c.Distinct.Add($g.Value) }
        $o = $m.Groups['owner']; if ($o.Success) { $ov = $o.Value; if ($c.Owners.ContainsKey($ov)) { $c.Owners[$ov] = $c.Owners[$ov] + 1 } else { $c.Owners[$ov] = 1 } }
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

function Handle-Line([object]$src, [string]$line) {
    $S = $script:S
    if ($line.Length -eq 0) { return }
    if ($line[$line.Length - 1] -eq "`r") { $line = $line.Substring(0, $line.Length - 1); if ($line.Length -eq 0) { return } }
    $S.Lines++
    [void](Parse-Line $src.Kind $line)
    $t = $script:pT; $lvl = $script:pL; $msg = $script:pM
    $rule = $null; $m = $null
    if ($script:Rules.ContainsKey($src.Kind)) {
        foreach ($r in $script:Rules[$src.Kind]) { $mm = $r.Rx.Match($msg); if ($mm.Success) { $rule = $r; $m = $mm; break } }
    }

    if ($rule -ne $null -and $rule.Mode -eq 'special') { Handle-Special $src $rule $m $t $msg; return }

    if ($rule -ne $null) {
        $eff = $rule.Lvl; if ($eff -lt 0) { $eff = $lvl }
        $cid = $rule.Id; if ($cid -eq 'badmesh2') { $cid = 'badmesh' }
        $c = Cat-Hit $cid $rule.Title $eff $m $msg
        if ($c.First -eq '') { $c.First = $t }; $c.Last = $t
        if ($eff -ge 3) { $S.Err++; $src.Err++ } elseif ($eff -eq 2) { $S.Warn++; $src.Warn++ }
        if ($eff -ge 3 -and $rule.Mode -ne 'count' -and $rule.Mode -ne 'hide' -and $rule.Mode -ne 'flood') { Push-Recent $src $t $msg }
        if ($script:ShowRaw) { if (Visible 0 $msg) { Emit $src $t $eff $msg }; return }
        switch ($rule.Mode) {
            'hide'  { $S.Noise++; if ($script:ShowNoise -and (Visible 0 $msg)) { Emit $src $t 0 $msg }; return }
            'count' {
                if ($ShowMissingRecords -and $rule.Id -like 'miss*') { if (Visible $eff $msg) { Emit $src $t $eff $msg } }
                return
            }
            'flood' {
                if ($c.Printed -lt $ShowRepeats) {
                    if (Visible $eff $msg) { $c.Printed++; Emit $src $t $eff $msg }
                } elseif (-not $c.Told) {
                    $c.Told = $true
                    if (Visible $eff $msg) { Notice ($script:G.up + ' "' + $c.Title + '": more of these are counted silently  (w = tallies, t = trace owners)') 'gray' }
                }
                return
            }
            'show' {
                $sig = $rule.Id + '|' + (Norm-Sig $msg)
                $n = 1; if ($S.ErrSig.ContainsKey($sig)) { $n = $S.ErrSig[$sig] + 1 }; $S.ErrSig[$sig] = $n
                if (-not (Visible $eff $msg)) { return }
                if ($n -le $ShowRepeats) { Emit $src $t $eff $msg }
                elseif ($n -eq $ShowRepeats + 1) { Notice ($script:G.up + ' identical lines now counted silently') 'gray' }
                return
            }
        }
        return
    }

    # no rule: lifecycle milestones for the info log, then generic handling
    if ($src.Kind -eq 'info' -and (Check-Milestone $src $t $msg)) { return }
    if ($lvl -ge 3) { $S.Err++; $src.Err++ } elseif ($lvl -eq 2) { $S.Warn++; $src.Warn++ }
    if ($lvl -ge 2) {
        $cat = Cat-Hit ('other' + $lvl + ':' + $src.Kind) ($(if ($lvl -ge 3) { 'Other errors' } else { 'Other warnings' }) + ' (' + $src.Name + ')') $lvl $null $msg
        if ($cat.First -eq '') { $cat.First = $t }; $cat.Last = $t
        if ($lvl -ge 3) { Push-Recent $src $t $msg }
        if ($script:ShowRaw) { if (Visible $lvl $msg) { Emit $src $t $lvl $msg }; return }
        $sig = $src.Kind + '|' + (Norm-Sig $msg)
        $n = 1; if ($S.ErrSig.ContainsKey($sig)) { $n = $S.ErrSig[$sig] + 1 }; $S.ErrSig[$sig] = $n
        if (-not (Visible $lvl $msg)) { return }
        if ($n -le $ShowRepeats) { Emit $src $t $lvl $msg }
        elseif ($n -eq $ShowRepeats + 1) { Notice ($script:G.up + ' identical lines now counted silently') 'gray' }
        return
    }
    if ($lvl -eq 0 -and -not $script:ShowRaw -and -not $script:ShowNoise -and $src.Kind -eq 'ogre') { $S.Noise++; if ($script:MinLvl -gt 0) { return } }
    if (Visible $lvl $msg) { Emit $src $t $lvl $msg }
}

function Push-Recent([object]$src, [string]$t, [string]$msg) {
    $S = $script:S
    $sig = $src.Tag + '|' + (Norm-Sig $msg)
    $e = $null
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

function Check-Milestone([object]$src, [string]$t, [string]$msg) {
    $S = $script:S
    $dt = To-Dt $script:pDate $t
    if ($msg -eq '** Kenshi start **') {
        if ($S.Phase -ne 'Idle') { Finish-Session 'new launch detected in log' }
        $S = $script:S
        $S.Start = [datetime]::Now; $S.LogStart = $dt; $S.Lines = 1
        Load-Cfg
        Write-Banner ('KENSHI START   ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss') + '   (mods.cfg: ' + $script:Cfg.Count + ' entries)') 'bgreen'
        Set-Phase 'Launcher starting' $dt
        return $true
    }
    if ($msg -eq '[Launcher] Initialised') { Set-Phase 'Launcher: mod list screen (waiting for Play)' $dt; return $true }
    if ($msg -like '[Launcher] Launching game*') { Set-Phase 'Launching game' $dt; $S.LaunchDt = $dt; return $true }
    if ($msg -eq 'Root Initialised') { Set-Phase 'Engine up, creating threads' $dt; return $true }
    if ($msg -eq 'Initialising GameData') { Set-Phase 'Loading game data (mods)' $dt; return $true }
    if ($msg -eq 'Compositor Setup') { Set-Phase 'Setting up renderer' $dt; return $true }
    if ($msg -eq 'Starting Title Screen') {
        Set-Phase 'MAIN MENU' $dt
        $took = ''
        if ($S.LaunchDt -and $dt) { $took = '  Play -> main menu: ' + (Fmt-Span ($dt - $S.LaunchDt)) + '.' }
        Write-Line ((Col 'bgreen') + ('          ' + $script:G.star + ' Reached main menu.  Mods loaded: ' + $S.ModsLoaded + ' of ' + $script:Cfg.Count + ' in mods.cfg.' + $took))
        Check-LoadOrder
        return $true
    }
    if ($msg -like 'Reset game*') { Set-Phase 'Starting / loading a game' $dt; return $true }
    if ($msg -like '[[]Game[]] New game start*') { Set-Phase ('IN GAME - ' + $msg) $dt; $S.NewGame = $msg; Emit $src $t 1 $msg; return $true }
    if ($msg -like '[[]Scythe[]]*' -or $msg -like '[[]Game[]]*' -or $msg -like '[[]Launcher[]]*') { Emit $src $t 1 $msg; return $true }
    if ($msg.StartsWith('** Thread ') -or $msg.StartsWith('*** ')) { $S.Threads++; if ($script:MinLvl -eq 0 -or $script:ShowRaw) { Emit $src $t 0 $msg }; return $true }
    return $false
}

function Handle-Special([object]$src, [object]$rule, [System.Text.RegularExpressions.Match]$m, [string]$t, [string]$msg) {
    $S = $script:S
    switch ($rule.Id) {
        'modload' {
            $name = $m.Groups['key'].Value
            $dt = To-Dt $script:pDate $t
            $S.ModsLoaded++
            if ($S.ModsLoaded -eq 1) {
                $S.ModFirstT = $dt
                if ($S.Phase -notlike 'Loading game data*') { Set-Phase 'Loading game data (mods)' $dt }
            }
            $S.ModLast = $name; $S.ModLastT = $dt
            if ($S.ModOrder.Count -lt 5000) { $S.ModOrder.Add($name) }
            $gap = 0.0
            if ($dt -and $S.ModPrevT) { $gap = ($dt - $S.ModPrevT).TotalSeconds }
            if ($gap -ge 3) { $S.ModSlow.Add(@{ Name=$name; Secs=$gap; N=$S.ModsLoaded }) }
            $S.ModPrevT = $dt; $S.ModPrevName = $name
            # order check against mods.cfg
            $k = $name.ToLowerInvariant()
            if ($script:CfgIdx.Count -gt 0) {
                if ($script:CfgIdx.ContainsKey($k)) {
                    $ix = $script:CfgIdx[$k]
                    if ($S.ContainsKey('LastIdx') -and $ix -lt $S.LastIdx -and $S.Mismatch.Count -lt 60) { $S.Mismatch.Add(('#{0} "{1}" loaded after cfg position {2} but sits at {3}' -f $S.ModsLoaded, $name, $S.LastIdx, $ix)) }
                    if (-not $S.ContainsKey('LastIdx') -or $ix -gt $S.LastIdx) { $S.LastIdx = $ix }
                } elseif ($S.Mismatch.Count -lt 60) { $S.Mismatch.Add(('#{0} "{1}" is not named in mods.cfg' -f $S.ModsLoaded, $name)) }
            }
            $total = $script:Cfg.Count
            if ($script:ShowRaw) { Emit $src $t 1 $msg; return }
            if ($gap -ge 5) { Emit $src $t 2 ('slow mod: "' + $name + '" took ' + ('{0:0}' -f $gap) + 's  (#' + $S.ModsLoaded + ')') }
            elseif ($S.ModsLoaded % 100 -eq 0 -or $S.ModsLoaded -eq 1) {
                $pct = ''; if ($total -gt 0) { $pct = ' / ' + $total + ('  ({0:0}%)' -f (100.0 * $S.ModsLoaded / $total)) }
                Emit $src $t 1 ('mods loaded: ' + $S.ModsLoaded + $pct + '   last: ' + $name)
            }
        }
        'coreload' { $S.CoreMods.Add($m.Groups['key'].Value); if ($script:ShowRaw -or $script:MinLvl -eq 0) { Emit $src $t 1 $msg } }
        'thread'   { $S.Threads++; if ($script:ShowRaw -or $script:MinLvl -eq 0) { Emit $src $t 0 $msg } }
        'sess' {
            if ($msg -like 'Session start*') { Write-Line ((Col 'green') + ('          ' + $script:G.dot + ' save system: session start')) }
            else { Write-Line ((Col 'green') + ('          ' + $script:G.dot + ' save system: exit (game shut down cleanly)')); $S.CleanExit = $true }
        }
    }
}

function Check-LoadOrder {
    $S = $script:S
    if ($script:Cfg.Count -eq 0) { return }
    $loaded = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($n in $S.ModOrder) { [void]$loaded.Add($n.ToLowerInvariant()) }
    $notLoaded = New-Object System.Collections.Generic.List[string]
    foreach ($k in $script:Cfg) {
        $b = $k; if ($b.EndsWith('.mod', 'OrdinalIgnoreCase')) { $b = $b.Substring(0, $b.Length - 4) }
        if (-not $loaded.Contains($b.ToLowerInvariant())) { $notLoaded.Add($b) }
    }
    $S.NotLoaded = $notLoaded
    if ($S.Mismatch.Count -eq 0 -and $notLoaded.Count -eq 0) {
        Write-Line ((Col 'green') + ('          ' + $script:G.dot + ' load order check: all ' + $S.ModsLoaded + ' mods loaded in exactly the mods.cfg order.'))
    } else {
        if ($S.Mismatch.Count -gt 0) { Write-Line ((Col 'byellow') + ('          ! load order check: ' + $S.Mismatch.Count + ' difference(s) from mods.cfg (press m for the list)')) }
        if ($notLoaded.Count -gt 0) { Write-Line ((Col 'byellow') + ('          ! ' + $notLoaded.Count + ' mods.cfg entries never loaded (file missing or name differs). First: ' + (($notLoaded | Select-Object -First 5) -join ', '))) }
    }
}
#endregion

#region ---------------------------------------------------------------- discovery, tailing
$script:Sources = New-Object System.Collections.Generic.List[object]
$script:SrcByPath = @{}
$script:KenshiDir = ''
$script:WorkshopDir = ''
$script:LogDirOverride = ''
$script:DustDirs = $null
$script:LastScan = [datetime]::MinValue
$script:LastDustScan = [datetime]::MinValue

# A real Kenshi root has data\gamedata.base / data\mods.cfg or the game's logs. kenshi_x64.exe alone is NOT enough:
# RE_Kenshi\kenshi_x64.exe is a patched copy that lives in a subfolder with none of those.
function Test-KenshiDir([string]$d) {
    if (-not $d) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { return $false }
        return ((Test-Path -LiteralPath (Join-Path $d 'data\mods.cfg')) -or (Test-Path -LiteralPath (Join-Path $d 'data\gamedata.base')) -or (Test-Path -LiteralPath (Join-Path $d 'kenshi_info.log')))
    } catch { return $false }
}

# Given any folder (for example the folder the running exe lives in), walk up to the real Kenshi root.
function Resolve-KenshiRoot([string]$d) {
    if (-not $d) { return '' }
    $cur = $d
    for ($i = 0; $i -lt 4 -and $cur; $i++) {
        if (Test-KenshiDir $cur) { return $cur }
        $parent = ''
        try { $parent = Split-Path -Parent $cur } catch { $parent = '' }
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return ''
}

function Find-Kenshi {
    if ($KenshiPath) { $r = Resolve-KenshiRoot $KenshiPath; if ($r) { return (Resolve-Path -LiteralPath $r).Path } else { return '' } }
    $cands = New-Object System.Collections.Generic.List[string]
    try { foreach ($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) { $pp = $null; try { $pp = $p.Path } catch { }; if ($pp) { $cands.Add((Split-Path -Parent $pp)) } } } catch { }
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
            if (Test-Path -LiteralPath $vdf) {
                foreach ($l in (Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue)) {
                    if ($l -match '"path"\s+"([^"]+)"') { $libs.Add(($Matches[1] -replace '\\\\', '\')) }
                }
            }
        }
        foreach ($l in $libs) { $cands.Add((Join-Path $l 'steamapps\common\Kenshi')) }
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -ne 'Fixed') { continue }
            $r = $d.RootDirectory.FullName
            foreach ($rel in @('Steam', 'SteamLibrary', 'Program Files (x86)\Steam', 'Games\Steam', 'Games\SteamLibrary')) { $cands.Add((Join-Path $r ($rel + '\steamapps\common\Kenshi'))) }
        }
    }
    # the folder the script itself sits in (people drop it into the Kenshi folder)
    if ($PSScriptRoot) { $cands.Add($PSScriptRoot) }
    foreach ($c in $cands) { $r = Resolve-KenshiRoot $c; if ($r) { return $r } }
    return ''
}

function Get-Tag([string]$file) {
    $n = [System.IO.Path]::GetFileName($file); $l = $n.ToLowerInvariant()
    if ($l -eq 'kenshi_info.log') { return @{ Kind='info';  Tag='INFO'; Color='white' } }
    if ($l -eq 'kenshi.log')      { return @{ Kind='ogre';  Tag='OGRE'; Color='gray' } }
    if ($l -eq 're_kenshi_log.txt') { return @{ Kind='re';   Tag='RE';   Color='cyan' } }
    if ($l -eq 'mygui.log')       { return @{ Kind='mygui'; Tag='GUI';  Color='mag' } }
    if ($l -eq 'save.log')        { return @{ Kind='save';  Tag='SAVE'; Color='green' } }
    if ($l -like 'dust*') { return @{ Kind='dust'; Tag='DUST'; Color='yellow' } }
    $t = ($n -replace '\.(log|txt)$', '' -replace '[^A-Za-z0-9]', '')
    if ($t.Length -gt 5) { $t = $t.Substring(0, 5) }
    return @{ Kind='plain'; Tag=$t.ToUpperInvariant(); Color='blue' }
}

function Add-Source([string]$path, [bool]$fromEnd) {
    if ($script:SrcByPath.ContainsKey($path)) { return }
    $i = Get-Tag $path
    $s = [pscustomobject]@{ Name=[System.IO.Path]::GetFileName($path); Path=$path; Kind=$i.Kind; Tag=$i.Tag; Color=$i.Color; Pos=[long]0; Head=''; Rest=$null; Bytes=[long]0; Lines=0; Resets=0; Seen=$false; Err=0; Warn=0 }
    $script:Sources.Add($s); $script:SrcByPath[$path] = $s
    return
}

function Scan-Sources {
    $now = [datetime]::Now
    $dirs = New-Object System.Collections.Generic.List[string]
    if ($script:LogDirOverride) { $dirs.Add($script:LogDirOverride) } else { $dirs.Add($script:KenshiDir); $dirs.Add((Join-Path $script:KenshiDir 'logs')) }
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($d)) {
                $n = [System.IO.Path]::GetFileName($f).ToLowerInvariant()
                if ($n.EndsWith('.log') -or $n -eq 're_kenshi_log.txt' -or $n -eq 'fileiolog.txt') { Add-Source $f $false }
            }
        } catch { }
    }
    foreach ($x in $ExtraLog) { if ($x -and (Test-Path -LiteralPath $x)) { Add-Source (Resolve-Path -LiteralPath $x).Path $false } }
    # Workshop mods that write logs/ folders (Dust). Re-enumerate the folder list rarely, the files often.
    if (-not $script:LogDirOverride -and $script:WorkshopDir -and (Test-Path -LiteralPath $script:WorkshopDir)) {
        if ($null -eq $script:DustDirs -or ($now - $script:LastDustScan).TotalSeconds -gt 20) {
            $script:LastDustScan = $now
            $l = New-Object System.Collections.Generic.List[string]
            try { foreach ($d in [System.IO.Directory]::EnumerateDirectories($script:WorkshopDir)) { $ld = Join-Path $d 'logs'; if ([System.IO.Directory]::Exists($ld)) { $l.Add($ld) } } } catch { }
            $script:DustDirs = $l
        }
        foreach ($ld in $script:DustDirs) {
            try {
                foreach ($f in [System.IO.Directory]::EnumerateFiles($ld, '*.log')) {
                    if ($script:SrcByPath.ContainsKey($f)) { continue }
                    $age = ($now - [System.IO.File]::GetLastWriteTime($f)).TotalMinutes
                    $recent = $true
                    if ($script:S.Start) { $recent = ([System.IO.File]::GetLastWriteTime($f) -ge $script:S.Start.AddMinutes(-5)) } else { $recent = ($age -lt 180) }
                    if ($recent) { Add-Source $f $false }
                }
            } catch { }
        }
    }
}

# returns number of lines handled
function Read-Source([object]$src, [bool]$catchUp) {
    $fi = $null
    try { $fi = New-Object System.IO.FileInfo($src.Path); if (-not $fi.Exists) { return 0 } } catch { return 0 }
    $len = $fi.Length
    if ($len -eq $src.Pos -and $src.Seen) { return 0 }
    $fs = $null; $handled = 0
    try {
        $fs = New-Object System.IO.FileStream($src.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete), 65536)
        $len = $fs.Length
        # detect replacement/truncation: compare the first bytes with what we saw
        $hb = New-Object byte[] 48
        $fs.Seek(0, 'Begin') | Out-Null
        $hn = $fs.Read($hb, 0, 48)
        $head = [System.BitConverter]::ToString($hb, 0, $hn)
        $reset = $false
        if ($src.Seen -and ($len -lt $src.Pos -or ($src.Pos -ge 48 -and $hn -ge 48 -and $head -ne $src.Head))) { $reset = $true }
        if ($reset) {
            $src.Pos = 0; $src.Rest = $null; $src.Resets++
            if (-not $catchUp) { Write-Line ((Col 'byellow') + ('          ' + $script:G.arrow + ' ' + $src.Name + ' was restarted/truncated by the game (new run) - reading from the top')) }
        }
        if ($hn -ge 48) { $src.Head = $head }
        $src.Seen = $true
        $limit = 16MB; if ($catchUp) { $limit = [long]::MaxValue }
        while ($src.Pos -lt $len) {
            $want = [Math]::Min([long]8MB, $len - $src.Pos)
            $buf = New-Object byte[] ([int]$want)
            $fs.Seek($src.Pos, 'Begin') | Out-Null
            $got = $fs.Read($buf, 0, [int]$want)
            if ($got -le 0) { break }
            $src.Pos += $got; $src.Bytes += $got
            $data = $buf
            $dlen = $got
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
                Handle-Line $src $ln
                $handled++; $src.Lines++
            }
            if (-not $catchUp -and $src.Bytes -gt $limit) { break }
        }
    } catch {
        # file busy / vanished: try next poll
        if ($env:KC_DEBUG) { [Console]::Error.WriteLine('Read-Source ' + $src.Name + ': ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage) }
    } finally { if ($fs) { $fs.Dispose() } }
    return $handled
}
#endregion

#region ---------------------------------------------------------------- archive, process, events, post-mortem, summary
$script:ArcDir = $null
$script:ArcSnap = @{}
$script:LastSnap = [datetime]::MinValue
$script:Proc = $null
$script:ProcInfo = @{ Pid=0; Start=$null; Mem=0.0; Peak=0.0; Responding=$true; NotRespSince=$null; Threads=0; Exit=$null; ExitCode=$null; PMDue=$null; NativeCode=$null; NRTold=$false; Cmd=''; Uptime=$null }

# ---- native helpers (Windows only): exit code of a process we are watching, and a hook for "window closed"
$script:NativeOk = $null
$script:ProcHandle = [IntPtr]::Zero
function Ensure-Native {
    if ($null -ne $script:NativeOk) { return $script:NativeOk }
    $script:NativeOk = $false
    if (-not $script:IsWin) { return $false }
    try {
        if (-not ('KcProc' -as [type])) {
            Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class KcProc {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);
    delegate bool HandlerRoutine(uint ctrlType);
    static HandlerRoutine keep;
    public static volatile bool CloseRequested = false;
    public static ManualResetEvent Done = new ManualResetEvent(false);
    // PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE: allowed even for an elevated game
    public static IntPtr Open(int pid) { return OpenProcess(0x1000 | 0x100000, false, (uint)pid); }
    // returns 0 = still running, 1 = exited (code filled in), -1 = could not ask
    public static int Poll(IntPtr h, out int code) {
        code = 0; uint c;
        if (h == IntPtr.Zero) return -1;
        if (!GetExitCodeProcess(h, out c)) return -1;
        if (c == 259) return 0;
        code = unchecked((int)c); return 1;
    }
    public static void Close(IntPtr h) { if (h != IntPtr.Zero) CloseHandle(h); }
    public static void HookClose() {
        keep = new HandlerRoutine(OnCtrl);
        SetConsoleCtrlHandler(keep, true);
    }
    static bool OnCtrl(uint t) {
        // 2 = window closed, 5 = logoff, 6 = shutdown. Ctrl+C is left to PowerShell.
        if (t == 2 || t == 5 || t == 6) { CloseRequested = true; Done.WaitOne(4500); return true; }
        return false;
    }
}
'@
        }
        $script:NativeOk = $true
    } catch { Dbg ('Ensure-Native: ' + $_.Exception.Message) }
    return $script:NativeOk
}

function Arc-Open([datetime]$when) {
    if ($NoArchive) { return }
    try {
        $root = Join-Path $OutDir 'sessions'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $dir = Join-Path $root ($when.ToString('yyyy-MM-dd_HH-mm-ss'))
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'logs') | Out-Null
        $script:ArcDir = $dir; $script:ArcSnap = @{}
        if ($script:Transcript) { try { $script:Transcript.Dispose() } catch { } }
        $fs = New-Object System.IO.FileStream((Join-Path $dir 'console.txt'), [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $script:Transcript = New-Object System.IO.StreamWriter($fs, $script:Utf8)
        $script:Transcript.AutoFlush = $true
        if ($script:CfgPath -and (Test-Path -LiteralPath $script:CfgPath)) { Copy-Item -LiteralPath $script:CfgPath -Destination (Join-Path $dir 'mods.cfg') -Force -ErrorAction SilentlyContinue }
        # prune old sessions
        $all = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        if ($all.Count -gt $KeepSessions) { $all | Select-Object -Skip $KeepSessions | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } }
    } catch { $script:ArcDir = $null; Dbg ('Arc-Open: ' + $_.Exception.Message) }
}

function Arc-Snapshot([bool]$force) {
    if (-not $script:ArcDir) { return 0 }
    $n = 0
    foreach ($s in $script:Sources) {
        try {
            $fi = New-Object System.IO.FileInfo($s.Path)
            if (-not $fi.Exists) { continue }
            $sig = '' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
            if (-not $force -and $script:ArcSnap.ContainsKey($s.Path) -and $script:ArcSnap[$s.Path] -eq $sig) { continue }
            $dest = Join-Path (Join-Path $script:ArcDir 'logs') $s.Name
            $in = New-Object System.IO.FileStream($s.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try {
                $out = New-Object System.IO.FileStream($dest, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            } finally { $in.Dispose() }
            $script:ArcSnap[$s.Path] = $sig; $n++
        } catch { Dbg ('Arc-Snapshot ' + $s.Name + ': ' + $_.Exception.Message) }
    }
    $script:LastSnap = [datetime]::Now
    return $n
}

function Get-ProcMem($p) { try { return [double]$p.WorkingSet64 } catch { return 0.0 } }

function Proc-Poll {
    $pi = $script:ProcInfo
    $cur = $null
    try { $cur = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1 } catch { }
    if ($script:Proc -ne $null) {
        $gone = $false
        if ($script:NativeOk -and $script:ProcHandle -ne [IntPtr]::Zero) {
            $c = 0; $r = [KcProc]::Poll($script:ProcHandle, [ref]$c)
            if ($r -eq 1) { $gone = $true; $pi.NativeCode = $c }
            elseif ($r -eq 0) { $gone = $false }
            else { try { $script:Proc.Refresh(); if ($script:Proc.HasExited) { $gone = $true } } catch { $gone = $true } }
        } else {
            try { $script:Proc.Refresh(); if ($script:Proc.HasExited) { $gone = $true } } catch { $gone = $true }
        }
        if ($gone) { Proc-Exited }
    }
    if ($cur -ne $null -and $script:Proc -eq $null) { Proc-Started $cur }
    if ($script:Proc -ne $null) {
        try {
            $script:Proc.Refresh()
            $pi.Mem = Get-ProcMem $script:Proc
            if ($pi.Mem -gt $pi.Peak) { $pi.Peak = $pi.Mem }
            try { $pi.Threads = $script:Proc.Threads.Count } catch { }
            $resp = $true; try { $resp = $script:Proc.Responding } catch { }
            if (-not $resp) {
                if ($null -eq $pi.NotRespSince) { $pi.NotRespSince = [datetime]::Now }
                elseif (-not $pi.NRTold -and ([datetime]::Now - $pi.NotRespSince).TotalSeconds -ge 15) {
                    $pi.NRTold = $true
                    $why = 'game window is frozen'
                    if ($script:S.Phase -like 'Loading*' -or $script:S.Phase -like 'Launcher*' -or $script:S.Phase -like 'Launching*') { $why = 'normal while the launcher/mod loader is busy - only worry if it lasts minutes and the log stops moving' }
                    Write-Line ((Col 'byellow') + ('          ! kenshi_x64 not responding for ' + (Fmt-Span ([datetime]::Now - $pi.NotRespSince)) + ' (' + $why + ')'))
                }
            } else {
                if ($pi.NRTold) { Write-Line ((Col 'green') + ('          ' + $script:G.dot + ' kenshi_x64 responding again after ' + (Fmt-Span ([datetime]::Now - $pi.NotRespSince)))) }
                $pi.NotRespSince = $null; $pi.NRTold = $false
            }
            $pi.Responding = $resp
        } catch { }
    }
}

function Close-ProcHandle { if ($script:ProcHandle -ne [IntPtr]::Zero) { try { [KcProc]::Close($script:ProcHandle) } catch { }; $script:ProcHandle = [IntPtr]::Zero } }

function Switch-KenshiRoot([string]$root) {
    $script:KenshiDir = $root
    $script:CfgPath = Join-Path $root 'data\mods.cfg'
    $ws = Join-Path (Split-Path -Parent (Split-Path -Parent $root)) 'workshop\content\233860'
    if (Test-Path -LiteralPath $ws) { $script:WorkshopDir = $ws }
    Load-Cfg
    Scan-Sources
    Notice ('Kenshi folder is ' + $root + '  (' + $script:Sources.Count + ' log files, ' + $script:Cfg.Count + ' mods.cfg entries)') 'gray'
}

function Proc-Started($p) {
    $pi = $script:ProcInfo
    $script:Proc = $p
    try { [void]$p.Handle } catch { }
    # hold our own handle so the exit code survives the process
    if (Ensure-Native) { try { Close-ProcHandle; $script:ProcHandle = [KcProc]::Open($p.Id) } catch { $script:ProcHandle = [IntPtr]::Zero } }
    $pi.NativeCode = $null
    # RE_Kenshi runs kenshi_x64.exe from a subfolder: make sure we are pointed at the real Kenshi root
    try {
        $pp = $null; try { $pp = $p.Path } catch { }
        if ($pp -and -not $KenshiPath) {
            $root = Resolve-KenshiRoot (Split-Path -Parent $pp)
            if ($root -and $root -ne $script:KenshiDir) { Switch-KenshiRoot $root }
        }
    } catch { }
    $pi.Pid = $p.Id; $pi.Exit = $null; $pi.ExitCode = $null; $pi.Peak = 0.0; $pi.NRTold = $false; $pi.NotRespSince = $null; $pi.PMDue = $null; $pi.Cmd = ''
    try { $pi.Start = $p.StartTime } catch { $pi.Start = [datetime]::Now }
    # the previous session (if any) is finished now
    if ($script:S.Phase -ne 'Idle') { Finish-Session 'new game process' }
    $script:S = New-Session
    $script:S.Start = $pi.Start
    Arc-Open $pi.Start
    $script:Sources | ForEach-Object { }   # keep list; positions reset themselves when the game truncates the logs
    Write-Banner ('PROCESS STARTED   ' + $ProcessName + '.exe   PID ' + $p.Id + '   ' + $pi.Start.ToString('HH:mm:ss')) 'bgreen'
    if ($script:ArcDir) { Notice ('session archive: ' + $script:ArcDir) 'gray' }
    Set-Title ('Kenshi Console - running (PID ' + $p.Id + ')')
}

$script:ExitMeaning = @{
    '0'='clean exit'; '1'='generic failure exit (game called exit(1))'; '-1'='exit(-1) / forced termination'
    '-1073741819'='0xC0000005 ACCESS VIOLATION (bad pointer - the classic Kenshi crash; a mod/plugin/DLL or corrupt data)'
    '-1073740791'='0xC0000409 STACK BUFFER OVERRUN / fail-fast (the program aborted itself)'
    '-1073741795'='0xC000001D ILLEGAL INSTRUCTION'
    '-1073741571'='0xC00000FD STACK OVERFLOW'
    '-1073740940'='0xC0000374 HEAP CORRUPTION'
    '-1073741515'='0xC0000135 a DLL was not found'
    '-1073741701'='0xC000007B bad image / 32-64 bit DLL mismatch'
    '-1073741510'='0xC000013A closed by Ctrl-C / console close'
    '-529697949'='0xE06D7363 unhandled C++ exception'
    '-2147483645'='0x80000003 breakpoint / assertion'
    '-1073741676'='0xC0000094 integer divide by zero'
    '-1073741818'='0xC0000006 in-page I/O error (disk/driver problem reading a memory-mapped file)'
    '-1073740771'='0xC000041D unhandled exception in a callback'
}
function Describe-Exit($code) {
    if ($null -eq $code) { return 'exit code not readable (access denied or already gone)' }
    $k = [string][int]$code
    if ($script:ExitMeaning.ContainsKey($k)) { return $script:ExitMeaning[$k] }
    $u = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int]$code), 0)
    return ('exit code {0} (0x{1:X8})' -f $code, $u)
}

function Proc-Exited {
    $pi = $script:ProcInfo
    $code = $null
    if ($null -ne $pi.NativeCode) { $code = $pi.NativeCode }
    elseif ($script:NativeOk -and $script:ProcHandle -ne [IntPtr]::Zero) { $c = 0; if ([KcProc]::Poll($script:ProcHandle, [ref]$c) -eq 1) { $code = $c } }
    if ($null -eq $code) { try { $code = $script:Proc.ExitCode } catch { } }
    Close-ProcHandle
    try { $pi.Exit = $script:Proc.ExitTime } catch { $pi.Exit = [datetime]::Now }
    $pi.ExitCode = $code
    if ($pi.Exit -lt $pi.Start) { $pi.Exit = [datetime]::Now }
    $up = $pi.Exit - $pi.Start
    $script:Proc = $null
    # drain any last log lines, then wait a few seconds for Windows to write its crash events
    $pi.PMDue = [datetime]::Now.AddSeconds(4)
    $pi.Uptime = $up
    Write-Banner ('PROCESS EXITED   PID ' + $pi.Pid + '   ran ' + (Fmt-Span $up) + '   exit: ' + (Describe-Exit $code)) $(if ($code -eq 0) { 'bgreen' } else { 'bred' })
    Set-Title 'Kenshi Console - game exited'
}

function Get-SysEvents([datetime]$from, [datetime]$to, [bool]$wide) {
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $script:IsWin -or $NoSystemEvents) { return $out }
    try {
        $sys = Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$from; EndTime=$to; Level=@(1,2,3) } -ErrorAction SilentlyContinue
        foreach ($e in $sys) {
            $p = [string]$e.ProviderName
            $keep = $false
            if ($p -eq 'Microsoft-Windows-Kernel-Power' -and $e.Id -eq 41) { $keep = $true }
            elseif ($p -like 'Microsoft-Windows-WHEA*') { $keep = $true }
            elseif ($p -in @('nvlddmkm','amdkmdag','amdkmdap','atikmdag')) { $keep = $true }
            elseif ($p -eq 'Display' -and $e.Id -in @(4101)) { $keep = $true }
            elseif ($p -in @('disk','stornvme','storahci','iaStorA','Ntfs','Microsoft-Windows-Ntfs','volmgr','partmgr')) { $keep = $true }
            elseif ($p -eq 'EventLog' -and $e.Id -eq 6008) { $keep = $true }
            elseif ($p -like '*SystemErrorReporting*' -or ($p -eq 'BugCheck')) { $keep = $true }
            elseif ($p -eq 'Microsoft-Windows-Resource-Exhaustion-Detector') { $keep = $true }
            elseif ($p -eq 'Microsoft-Windows-DriverFrameworks-UserMode' -and $wide) { $keep = $false }
            if ($keep) { $out.Add(@{ T=$e.TimeCreated; Log='System'; Prov=$p; Id=$e.Id; Msg=(([string]$e.Message) -split "`n")[0].Trim() }) }
        }
    } catch { }
    try {
        $app = Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$from; EndTime=$to; Level=@(1,2,3) } -ErrorAction SilentlyContinue
        foreach ($e in $app) {
            $msg = [string]$e.Message
            if ($msg -match '(?i)kenshi|dust|RE_Kenshi|ogre|nvwgf|d3d11') {
                $p = [string]$e.ProviderName
                if ($p -in @('Application Error','Windows Error Reporting','Application Hang','.NET Runtime','SideBySide')) {
                    $out.Add(@{ T=$e.TimeCreated; Log='Application'; Prov=$p; Id=$e.Id; Msg=(($msg -split "`n" | Select-Object -First 6) -join ' | ') })
                }
            }
        }
    } catch { }
    return ($out | Sort-Object { $_.T })
}

function Get-DumpFiles([datetime]$since) {
    $found = New-Object System.Collections.Generic.List[string]
    $dirs = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) { $dirs.Add((Join-Path $env:LOCALAPPDATA 'Dust\crash_reports')); $dirs.Add((Join-Path $env:LOCALAPPDATA 'CrashDumps')); $dirs.Add((Join-Path $env:LOCALAPPDATA 'kenshi\crashreports')) }
    $dirs.Add($script:KenshiDir); $dirs.Add((Join-Path $script:KenshiDir 'crashes'))
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        try {
            foreach ($f in Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue) {
                if ($f.LastWriteTime -ge $since -and ($f.Extension -in @('.dmp','.mdmp','.txt','.log','.json','.zip','.crash') ) -and ($d -notlike '*Kenshi' -or $f.Extension -in @('.dmp','.mdmp') -or $f.Name -like '*crash*')) { $found.Add($f.FullName + '   (' + (Fmt-Bytes $f.Length) + ', ' + $f.LastWriteTime.ToString('HH:mm:ss') + ')') }
            }
        } catch { }
    }
    return $found
}

# ---- crash dump reading (Kenshi's own crashDump*.zip, or any minidump). Pure PowerShell, no tools needed.
function Read-MiniDump([byte[]]$b) {
    $r = @{ Ok=$false; Why='' }
    try {
        if ($b.Length -lt 32 -or $b[0] -ne 0x4D -or $b[1] -ne 0x44 -or $b[2] -ne 0x4D -or $b[3] -ne 0x50) { $r.Why = 'not a minidump'; return $r }
        $nStreams = [BitConverter]::ToInt32($b, 8); $dirRva = [BitConverter]::ToInt32($b, 12)
        $exc = -1; $mods = -1; $mem = -1
        for ($i = 0; $i -lt $nStreams; $i++) {
            $o = $dirRva + 12 * $i
            $type = [BitConverter]::ToInt32($b, $o); $rva = [BitConverter]::ToInt32($b, $o + 8)
            if ($type -eq 6) { $exc = $rva } elseif ($type -eq 4) { $mods = $rva } elseif ($type -eq 5) { $mem = $rva }
        }
        if ($exc -lt 0) { $r.Why = 'dump has no exception record'; return $r }
        $r.ThreadId = [BitConverter]::ToUInt32($b, $exc)
        $r.Code = [BitConverter]::ToUInt32($b, $exc + 8)
        $r.Addr = [BitConverter]::ToUInt64($b, $exc + 24)
        $np = [BitConverter]::ToInt32($b, $exc + 32)
        $r.Info0 = 0; $r.Info1 = [uint64]0
        if ($np -ge 2) { $r.Info0 = [BitConverter]::ToUInt64($b, $exc + 40); $r.Info1 = [BitConverter]::ToUInt64($b, $exc + 48) }
        $r.MemRva = $mem
        # registers at the moment of the fault (x64 CONTEXT: R12 at 0xD8, R13 at 0xE0)
        $r.R12 = [uint64]0; $r.R13 = [uint64]0; $r.Rdi = [uint64]0
        try {
            $cSize = [BitConverter]::ToInt32($b, $exc + 160); $cRva = [BitConverter]::ToInt32($b, $exc + 164)
            if ($cSize -ge 0x100) { $r.R12 = [BitConverter]::ToUInt64($b, $cRva + 0xD8); $r.R13 = [BitConverter]::ToUInt64($b, $cRva + 0xE0); $r.Rdi = [BitConverter]::ToUInt64($b, $cRva + 0xB0) }
        } catch { }
        $r.Module = ''; $r.Offset = [uint64]0
        if ($mods -ge 0) {
            $n = [BitConverter]::ToInt32($b, $mods)
            for ($i = 0; $i -lt $n; $i++) {
                $o = $mods + 4 + 108 * $i
                $base = [BitConverter]::ToUInt64($b, $o); $size = [BitConverter]::ToUInt32($b, $o + 8); $nrva = [BitConverter]::ToInt32($b, $o + 20)
                if ($r.Addr -ge $base -and $r.Addr -lt ($base + $size)) {
                    $len = [BitConverter]::ToInt32($b, $nrva)
                    $full = [System.Text.Encoding]::Unicode.GetString($b, $nrva + 4, $len)
                    $r.Module = ($full -split '[\\/]')[-1]; $r.Offset = $r.Addr - $base; $r.ModulePath = $full
                    break
                }
            }
        }
        $r.Ok = $true
    } catch { $r.Why = $_.Exception.Message }
    return $r
}

# read bytes out of the dump's memory snapshot (MemoryListStream). Returns $null if the range was not captured.
function Read-DumpMemory([byte[]]$b, [int]$memRva, [uint64]$addr, [int]$len) {
    if ($memRva -lt 0) { return $null }
    try {
        $n = [BitConverter]::ToInt32($b, $memRva)
        for ($i = 0; $i -lt $n; $i++) {
            $o = $memRva + 4 + 16 * $i
            $start = [BitConverter]::ToUInt64($b, $o); $size = [BitConverter]::ToUInt32($b, $o + 8); $rva = [BitConverter]::ToInt32($b, $o + 12)
            if ($addr -ge $start -and ($addr + [uint64]$len) -le ($start + [uint64]$size)) {
                $out = New-Object byte[] $len
                [Array]::Copy($b, [int]($rva + ($addr - $start)), $out, 0, $len)
                return ,$out
            }
        }
    } catch { }
    return $null
}

# The game function at kenshi_x64.exe+0x622A8A (build 1.0.65) builds a character's "death items" and writes into the item it
# made. If the entry points to a record that is missing or is not an item, the pointer is null and the game dies there.
# R13+0x40 holds the character's data record; R12 is the index of the bad entry in its death-items list.
function Describe-DeathItemsCrash($d, [byte[]]$b) {
    $out = New-Object System.Collections.Generic.List[string]
    $p = Read-DumpMemory $b $d.MemRva ($d.R13 + 0x40) 8
    if ($null -eq $p) { $out.Add('character record was not captured in the dump'); return $out }
    $rec = [BitConverter]::ToUInt64($p, 0)
    $h = Read-DumpMemory $b $d.MemRva $rec 0x60
    if ($null -eq $h) { $out.Add('character record was not captured in the dump'); return $out }
    $type = [BitConverter]::ToInt32($h, 0x50)
    $tn = switch ($type) { 1 { 'Character' } 76 { 'AnimalCharacter' } default { 'record type ' + $type } }
    $len = [int][BitConverter]::ToUInt64($h, 0x38); $cap = [BitConverter]::ToUInt64($h, 0x40)
    $name = $null
    if ($len -gt 0 -and $len -lt 200) {
        if ($cap -lt 16) { $name = [System.Text.Encoding]::UTF8.GetString($h, 0x28, [Math]::Min($len, 15)) }
        else { $np = Read-DumpMemory $b $d.MemRva ([BitConverter]::ToUInt64($h, 0x28)) $len; if ($null -ne $np) { $name = [System.Text.Encoding]::UTF8.GetString($np) } }
    }
    $idx = [int]($d.R12 -band 0xFFFF)
    if ($name) { $out.Add('character being built: "' + $name + '" (' + $tn + ')') }
    else { $out.Add('character being built: a ' + $tn + ' whose name has ' + $len + ' characters (name text was not captured; the length narrows it down)') }
    $out.Add('its death-items list has an entry (position ' + ($idx + 1) + ' in the merged list) that is missing or is not an item. Search your mods for this name; check each mod that edits its "death items".')
    return $out
}

# The game function at kenshi_x64.exe+0x376A40 (build 1.0.65) writes a town's saved state ("Town state ..."). At +0x69B94 it
# read a string from a "trade goods" entry whose item record pointer was null. R13 is the town object (name string at +0x18),
# RDI points at the text "trade goods" while the loop runs. This names the town only; the entry itself is not in the dump.
# Seen in 3 dumps: towns Ashlanders Camp (twice) and Spider Den (Behind Enemy Lines disabled), so it is not town-specific.
function Describe-TownStateCrash($d, [byte[]]$b) {
    $out = New-Object System.Collections.Generic.List[string]
    $k = Read-DumpMemory $b $d.MemRva $d.Rdi 11
    $isTrade = ($null -ne $k) -and ([System.Text.Encoding]::ASCII.GetString($k) -eq 'trade goods')
    $h = Read-DumpMemory $b $d.MemRva $d.R13 0x40
    $name = $null
    if ($null -ne $h) {
        $len = [BitConverter]::ToUInt64($h, 0x28); $cap = [BitConverter]::ToUInt64($h, 0x30)
        if ($len -gt 0 -and $len -lt 200) {
            if ($cap -lt 16) { $name = [System.Text.Encoding]::UTF8.GetString($h, 0x18, [int][Math]::Min($len, 15)) }
            else { $np = Read-DumpMemory $b $d.MemRva ([BitConverter]::ToUInt64($h, 0x18)) ([int]$len); if ($null -ne $np) { $name = [System.Text.Encoding]::UTF8.GetString($np) } }
        }
    }
    if (-not $isTrade) { $out.Add('the game was in its town-state writer (the "trade goods" text was not captured, so this is a weaker match)') }
    else { $out.Add('the game was saving (manual save or autosave) and read a town''s "trade goods" table') }
    if ($name) { $out.Add('first town it reached: "' + $name + '" - its trade-goods table holds an entry with no item behind it') }
    else { $out.Add('the town object was not captured in the dump') }
    $out.Add('the town is only where the save happened to stop; the empty entry is built for every town from the global "all trade goods" list, so look at the mods that edit that list, not at this town''s mod') 
    return $out
}

function Describe-NtCode([uint32]$c) {
    switch ($c) {
        3221225477 { return 'ACCESS VIOLATION' }
        3221225620 { return 'DIVIDE BY ZERO' }
        3221225725 { return 'STACK OVERFLOW' }
        3221226356 { return 'HEAP CORRUPTION' }
        3221226505 { return 'FAIL-FAST / stack buffer overrun' }
        3221225501 { return 'ILLEGAL INSTRUCTION' }
        3762504530 { return 'C++ exception (0xE06D7363)' }
        2147483651 { return 'BREAKPOINT' }
        default { return 'exception' }
    }
}

# returns lines describing the dump; $dumpPath may be a .zip (crashDump*.zip) or a .dmp
function Describe-CrashDump([string]$dumpPath) {
    $out = New-Object System.Collections.Generic.List[string]
    try {
        $bytes = $null; $inZip = @()
        if ($dumpPath.EndsWith('.zip', 'OrdinalIgnoreCase')) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $z = [System.IO.Compression.ZipFile]::OpenRead($dumpPath)
            try {
                foreach ($e in $z.Entries) {
                    $inZip += $e.FullName
                    if ($e.FullName -like '*.dmp' -and $null -eq $bytes) {
                        $ms = New-Object System.IO.MemoryStream; $st = $e.Open(); try { $st.CopyTo($ms) } finally { $st.Dispose() }; $bytes = $ms.ToArray()
                    }
                }
            } finally { $z.Dispose() }
            $out.Add('zip holds: ' + ($inZip -join ', '))
        } else { $bytes = [System.IO.File]::ReadAllBytes($dumpPath) }
        if ($null -eq $bytes) { $out.Add('no .dmp inside'); return $out }
        $d = Read-MiniDump $bytes
        if (-not $d.Ok) { $out.Add('could not read the dump: ' + $d.Why); return $out }
        $what = Describe-NtCode ([uint32]$d.Code)
        $how = ''
        if ($d.Code -eq 3221225477) {
            $kind = @{ 0='READ from'; 1='WRITE to'; 8='EXECUTE at' }
            $k = [string][int]$d.Info0
            $how = ' - ' + $(if ($kind.ContainsKey([int]$d.Info0)) { $kind[[int]$d.Info0] } else { 'touched' }) + ' address 0x' + ('{0:X}' -f $d.Info1)
            if ($d.Info1 -lt 65536) { $how += ' (a NULL pointer plus 0x' + ('{0:X}' -f $d.Info1) + ' - code used an object that does not exist)' }
        }
        $out.Add(('exception 0x{0:X8} {1}{2}' -f $d.Code, $what, $how))
        $where = '0x' + ('{0:X}' -f $d.Addr)
        if ($d.Module) { $where += '  =  ' + $d.Module + ' + 0x' + ('{0:X}' -f $d.Offset) }
        $out.Add('at ' + $where + '   (thread ' + $d.ThreadId + ')')
        if ($d.Module -and $d.Module -notlike 'kenshi_x64*' -and $d.Module -notlike 'ntdll*') { $out.Add('the faulting code is in ' + $d.Module + ' - that file (a plugin/DLL/driver) is the first suspect') }
        elseif ($d.Module -like 'kenshi_x64*') {
            if ($d.Offset -eq 0x622A8A) { foreach ($l in (Describe-DeathItemsCrash $d $bytes)) { $out.Add($l) } }
            elseif ($d.Offset -eq 0x69B94) { foreach ($l in (Describe-TownStateCrash $d $bytes)) { $out.Add($l) } }
            else { $out.Add('the faulting code is in the game itself, so a mod fed it bad data; the dump alone cannot name which mod') }
        }
    } catch { $out.Add('crash dump reading failed: ' + $_.Exception.Message) }
    return $out
}

function Get-CrashZips([datetime]$since) {
    $r = New-Object System.Collections.Generic.List[object]
    if (-not $script:KenshiDir) { return $r }
    try {
        foreach ($f in (Get-ChildItem -LiteralPath $script:KenshiDir -File -ErrorAction SilentlyContinue)) {
            if ($f.LastWriteTime -ge $since -and ($f.Name -like 'crashDump*.zip' -or $f.Extension -in @('.dmp', '.mdmp'))) { $r.Add($f) }
        }
    } catch { }
    return $r
}

function Post-Mortem {
    $pi = $script:ProcInfo; $S = $script:S
    $pi.PMDue = $null
    $script:Tee = New-Object System.Collections.Generic.List[string]
    $start = $pi.Start; $end = $pi.Exit; if (-not $end) { $end = [datetime]::Now }
    Write-Head 'POST-MORTEM'
    $code = $pi.ExitCode
    Write-Plain ('  Ran ............ ' + (Fmt-Span $pi.Uptime) + '   (' + $start.ToString('HH:mm:ss') + ' -> ' + $end.ToString('HH:mm:ss') + ')')
    Write-Plain ('  Exit ........... ' + (Describe-Exit $code))
    Write-Plain ('  Peak memory .... ' + (Fmt-Bytes $pi.Peak))
    Write-Plain ('  Phase at exit .. ' + $S.Phase)
    if ($S.NewGame) { Write-Plain ('  Last game start  ' + $S.NewGame) }
    if ($script:Sources.Count -eq 0) { Write-Plain ('  !! No log files were being followed (Kenshi folder used: ' + $script:KenshiDir + '). The counters below are empty because of that, not because the game was quiet.') 'bred' }
    if ($S.ModsLoaded -gt 0) {
        $nxt = ''
        if ($script:CfgIdx.Count -gt 0 -and $S.ModLast) {
            $k = $S.ModLast.ToLowerInvariant()
            if ($script:CfgIdx.ContainsKey($k)) { $ix = $script:CfgIdx[$k] + 1; if ($ix -lt $script:Cfg.Count) { $nxt = $script:Cfg[$ix] } }
        }
        Write-Plain ('  Mods loaded .... ' + $S.ModsLoaded + ' of ' + $script:Cfg.Count + '   last: ' + $S.ModLast + $(if ($nxt) { '   next in mods.cfg: ' + $nxt } else { '' }))
    }
    Write-Plain ('  Log counters ... errors ' + $S.Err + ', warnings ' + $S.Warn + ', hidden noise ' + $S.Noise)
    if ($S.ContainsKey('CleanExit') -and $S.CleanExit) { Write-Plain '  save.log ....... "Exit." was written - the game shut down through its normal path' 'green' }
    elseif ($S.Phase -ne 'Idle') { Write-Plain '  save.log ....... no "Exit." line - the game did NOT go through its normal shutdown' 'byellow' }

    if ($S.RecentOrder.Count -gt 0) {
        Write-Head 'Last distinct errors in the logs'
        foreach ($l in (Get-RecentLines 8)) { Write-Plain ('  ' + $l) 'red' }
    }
    Write-Head 'Last log lines before the end'
    $tail = $script:Ring.ToArray() | Select-Object -Last 14
    foreach ($l in $tail) { Write-Line ('  ' + $l) }

    $dumps = @(Get-DumpFiles ($start.AddSeconds(-5)))
    if ($dumps.Count -gt 0) { Write-Head 'Crash reports / dumps written during this run'; foreach ($d in $dumps) { Write-Plain ('  ' + $d) 'byellow' } }
    $dumpInfo = New-Object System.Collections.Generic.List[string]
    foreach ($cz in @(Get-CrashZips ($start.AddSeconds(-5)))) {
        Write-Head ('Crash dump: ' + $cz.Name)
        if ($script:ArcDir) { try { Copy-Item -LiteralPath $cz.FullName -Destination (Join-Path $script:ArcDir $cz.Name) -Force; Write-Plain ('  copy kept in the session folder: ' + (Join-Path $script:ArcDir $cz.Name)) 'green' } catch { } }
        foreach ($l in (Describe-CrashDump $cz.FullName)) { Write-Plain ('  ' + $l) 'bred'; $dumpInfo.Add($l) }
    }

    $ev = @()
    $hw = 0
    if ($script:IsWin -and -not $NoSystemEvents) {
        $ev = @(Get-SysEvents ($start.AddMinutes(-1)) ($end.AddMinutes(2)) $false)
        Write-Head ('Windows events during the run (' + $ev.Count + ')')
        if ($ev.Count -eq 0) { Write-Plain '  none of: app crash/hang, Kernel-Power 41, WHEA, GPU driver, disk/NVMe, bugcheck' 'gray' }
        foreach ($e in $ev) {
            $isHw = ($e.Prov -like 'Microsoft-Windows-Kernel-Power' -or $e.Prov -like 'Microsoft-Windows-WHEA*' -or $e.Prov -in @('nvlddmkm','amdkmdag','disk','stornvme','EventLog') -or $e.Prov -like '*SystemErrorReporting*')
            if ($isHw) { $hw++ }
            Write-Plain ('  ' + $e.T.ToString('HH:mm:ss') + '  ' + $e.Log.PadRight(11) + $e.Prov + ' #' + $e.Id + '  ' + (Trunc $e.Msg 200)) $(if ($isHw) { 'bred' } else { 'byellow' })
        }
    }

    # verdict: inferred, never claimed as proof
    Write-Head 'Reading of the evidence (inferred - not proof)'
    $v = New-Object System.Collections.Generic.List[string]
    $clean = ($code -eq 0) -and ($S.ContainsKey('CleanExit') -and $S.CleanExit) -and ($dumpInfo.Count -eq 0)
    if ($clean) { $v.Add('Clean shutdown: exit code 0 and the save system logged "Exit.". Nothing to chase.') }
    else {
        if ($hw -gt 0) { $v.Add('Hardware/system events were logged around the end (red lines above). A reboot, driver reset or storage error is not caused by a mod; check hardware first (your Commander Pro / PCIe history applies).') }
        if ($null -ne $code -and $code -ne 0) { $v.Add('The process died with ' + (Describe-Exit $code) + '.') }
        elseif ($null -eq $code) { $v.Add('Exit code could not be read.') }
        if ($S.Phase -like 'Loading game data*' -and $S.ModsLoaded -gt 0) { $v.Add('It ended while mods were loading, after "' + $S.ModLast + '" (#' + $S.ModsLoaded + '). The mod after it in mods.cfg is the first suspect; confirm with the Ogre/RE log and a dump.') }
        elseif ($S.Phase -like 'Launcher*') { $v.Add('It ended in the launcher, before the game started. That is usually a normal close (you closed it), not a crash.') }
        if ($pi.NotRespSince) { $v.Add('The window had been "not responding" for ' + (Fmt-Span ([datetime]::Now - $pi.NotRespSince)) + ' before the end: a hang, then killed.') }
        if ($S.Err -eq 0 -and $hw -eq 0 -and $dumps.Count -eq 0 -and $null -ne $code -and $code -ne 0) { $v.Add('No error was logged by the game and there is no dump: the logs cannot name a cause. Enable Windows crash dumps (WER LocalDumps for kenshi_x64.exe) to get one next time.') }
        if ($dumpInfo.Count -gt 0) {
            $v.Add('The crash dump (above) is the best evidence: trust its exception over the process exit code. the game''s own crash handler ends the process itself, so the exit code can differ from the real fault.')
            if ($S.NewGame) { $v.Add('A new game was started this run (' + $S.NewGame + '). If the crash came right after the world loaded, the start/character records of that start are suspects.') }
        }
        elseif ($dumps.Count -gt 0) { $v.Add('A dump/crash report exists (listed above). It holds the faulting module; send it over to be read.') }
        if ($v.Count -eq 0) { $v.Add('Closed without a clean "Exit." line but with no crash evidence. Likely closed from the launcher or killed from Task Manager.') }
    }
    foreach ($l in $v) { Write-Plain ('  - ' + $l) }
    $n = Arc-Snapshot $true
    Write-SessionSummary
    if ($script:ArcDir) {
        try {
            $rep = Join-Path $script:ArcDir 'postmortem.txt'
            $lines = @($script:Tee.ToArray())
            if ($lines.Count -eq 0) { $lines = @('(post-mortem produced no output)') }
            [System.IO.File]::WriteAllLines($rep, [string[]]$lines, $script:Utf8)
        } catch { }
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
        $sbefore = $script:Transcript; $script:Transcript = $null
        $text = New-Object System.Collections.Generic.List[string]
        $script:CaptureTo = $text
        Show-Summary $true
        $script:CaptureTo = $null
        $script:Transcript = $sbefore; $script:Quiet = $save
        [System.IO.File]::WriteAllLines((Join-Path $script:ArcDir 'summary.txt'), [string[]]$text, $script:Utf8)
    } catch { $script:CaptureTo = $null; Dbg ('Write-SessionSummary: ' + $_.Exception.Message + ' ' + $_.InvocationInfo.PositionMessage) }
}

# Keep the session folder current while the game runs, so a closed window or a hard kill still leaves everything behind.
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
            $head = @('Live tail written ' + $now.ToString('yyyy-MM-dd HH:mm:ss') + ' (last 300 visible console lines). If the game has ended, postmortem.txt holds the full verdict.')
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

#region ---------------------------------------------------------------- reports: summary, tallies, mods, trace, help
function Build-ModIndex {
    if ($null -ne $script:ModIndex) { return }
    $idx = @{}
    $roots = New-Object System.Collections.Generic.List[string]
    if ($script:KenshiDir) { $roots.Add((Join-Path $script:KenshiDir 'mods')) }
    if ($script:WorkshopDir) { $roots.Add($script:WorkshopDir) }
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }
        $isWs = ($r -eq $script:WorkshopDir)
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($r)) {
                try {
                    foreach ($f in [System.IO.Directory]::EnumerateFiles($d, '*.mod')) {
                        $k = [System.IO.Path]::GetFileNameWithoutExtension($f).ToLowerInvariant()
                        $id = 'local'; if ($isWs) { $id = 'ws:' + [System.IO.Path]::GetFileName($d) }
                        if (-not $idx.ContainsKey($k) -or ($idx[$k].Id -eq 'local' -and $isWs -eq $false)) { $idx[$k] = @{ Path=$f; Id=$id } }
                    }
                } catch { }
            }
        } catch { }
    }
    $script:ModIndex = $idx
}
function Mod-Label([string]$name) {
    Build-ModIndex
    $k = $name.ToLowerInvariant()
    if ($script:ModIndex.ContainsKey($k)) { return ($name + ' [' + $script:ModIndex[$k].Id + ']') }
    return $name
}

function Show-Tallies {
    $S = $script:S
    Write-Head 'Problem tallies (counted whether or not they were printed)'
    if ($S.Cats.Count -eq 0) { Write-Plain '  nothing counted yet' 'gray'; return }
    $rows = $S.Cats.Values | Sort-Object @{Expression={$_.Lvl};Descending=$true}, @{Expression={$_.Count};Descending=$true}
    Write-Plain ('  {0,8} {1,9}  {2}' -f 'COUNT', 'DISTINCT', 'WHAT') 'gray'
    foreach ($c in $rows) {
        $col = 'white'; if ($c.Lvl -ge 3) { $col = 'bred' } elseif ($c.Lvl -eq 2) { $col = 'byellow' } elseif ($c.Lvl -eq 0) { $col = 'gray' }
        $d = ''; if ($c.Distinct.Count -gt 0) { $d = Fmt-N $c.Distinct.Count }
        Write-Plain ('  {0,8} {1,9}  {2}' -f (Fmt-N $c.Count), $d, $c.Title) $col
        if ($c.Owners.Count -gt 0) {
            $top = $c.Owners.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6
            $txt = ($top | ForEach-Object { (Trunc $_.Key 44) + ' (' + $_.Value + ')' }) -join ', '
            Write-Plain ('  {0,8} {1,9}    owners: {2}' -f '', '', $txt) 'gray'
        }
    }
}

function Show-Mods {
    $S = $script:S
    Write-Head 'Mod loading'
    Write-Plain ('  Loaded: ' + $S.ModsLoaded + '   mods.cfg entries: ' + $script:Cfg.Count + '   core: ' + ($S.CoreMods -join ', '))
    if ($S.ModFirstT -and $S.ModLastT) {
        $dur = $S.ModLastT - $S.ModFirstT
        $per = ''; if ($S.ModsLoaded -gt 1 -and $dur.TotalSeconds -ge 30) { $per = ('   (avg {0:0.00}s per mod)' -f ($dur.TotalSeconds / $S.ModsLoaded)) }
        Write-Plain ('  Load time (first to last "Loaded mod" line): ' + (Fmt-Span $dur) + $per)
    }
    if ($S.ModSlow.Count -gt 0) {
        Write-Plain '  Slowest mods (gap before their "Loaded" line, 1 s resolution):'
        foreach ($x in ($S.ModSlow | Sort-Object { $_.Secs } -Descending | Select-Object -First 10)) { Write-Plain ('    {0,5:0}s  #{1,-5} {2}' -f $x.Secs, $x.N, $x.Name) }
    }
    if ($S.Mismatch.Count -gt 0) { Write-Plain ('  Load-order differences vs mods.cfg (' + $S.Mismatch.Count + '):') 'byellow'; foreach ($x in ($S.Mismatch | Select-Object -First 25)) { Write-Plain ('    ' + $x) 'byellow' } }
    elseif ($S.ModsLoaded -gt 0 -and $script:Cfg.Count -gt 0) { Write-Plain '  Load order matches mods.cfg for every mod that loaded.' 'green' }
    if ($S.ContainsKey('NotLoaded') -and $S.NotLoaded.Count -gt 0) {
        Write-Plain ('  In mods.cfg but never loaded (' + $S.NotLoaded.Count + '):') 'byellow'
        foreach ($x in ($S.NotLoaded | Select-Object -First 25)) { Write-Plain ('    ' + $x) 'byellow' }
        if ($S.NotLoaded.Count -gt 25) { Write-Plain ('    ... and ' + ($S.NotLoaded.Count - 25) + ' more') 'gray' }
    }
}

function Show-Recent {
    $S = $script:S
    Write-Head 'Most recent distinct errors'
    if ($S.RecentOrder.Count -eq 0) { Write-Plain '  none' 'green'; return }
    foreach ($l in (Get-RecentLines 20)) { Write-Plain ('  ' + $l) 'red' }
}

function Show-Summary([bool]$full) {
    $S = $script:S; $pi = $script:ProcInfo
    Write-Banner ('SESSION SUMMARY   ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) 'bcyan'
    $up = ''; if ($S.Start) { $up = Fmt-Span ([datetime]::Now - $S.Start) }
    Write-Plain ('  Game ........... ' + $(if ($script:Proc) { 'RUNNING  PID ' + $pi.Pid + '  up ' + $up + '  RAM ' + (Fmt-Bytes $pi.Mem) + '  peak ' + (Fmt-Bytes $pi.Peak) } else { 'not running' }))
    Write-Plain ('  Phase .......... ' + $S.Phase)
    if ($S.PhaseLog.Count -gt 0) { Write-Plain ('  Phase times .... ' + ($S.PhaseLog -join ' | ')) 'gray' }
    if ($S.NewGame) { Write-Plain ('  Game session ... ' + $S.NewGame) }
    Write-Plain ('  Log lines ...... ' + (Fmt-N $S.Lines) + '   errors ' + (Fmt-N $S.Err) + '   warnings ' + (Fmt-N $S.Warn) + '   hidden noise ' + (Fmt-N $S.Noise))
    Show-Mods
    Show-Tallies
    if ($full) {
        $rep = $S.ErrSig.GetEnumerator() | Where-Object { $_.Value -gt $ShowRepeats } | Sort-Object Value -Descending | Select-Object -First 12
        if ($rep) {
            Write-Head 'Most repeated error/warning lines (numbers normalised)'
            foreach ($r in $rep) { Write-Plain ('  {0,7}x  {1}' -f (Fmt-N $r.Value), (Trunc (($r.Key -split '\|', 2)[1]) 150)) 'yellow' }
        }
        Show-Recent
        Write-Head 'Log files followed'
        Write-Plain ('  {0,-26} {1,-6} {2,9} {3,9} {4,6} {5,6}' -f 'FILE', 'TAG', 'READ', 'LINES', 'ERR', 'WARN') 'gray'
        foreach ($so in $script:Sources) { Write-Plain ('  {0,-26} {1,-6} {2,9} {3,9} {4,6} {5,6}' -f (Trunc $so.Name 26), $so.Tag, (Fmt-Bytes $so.Bytes), (Fmt-N $so.Lines), $so.Err, $so.Warn) }
    }
    Write-Line ''
}

function Show-Help {
    Write-Head 'Kenshi Console - keys'
    $h = @(
        '  ?  this help                   q  quit (Ctrl+C also works)',
        '  s  session summary             w  problem tallies (what is flooding, who owns it)',
        '  m  mod loading / load order    e  recent errors',
        '  t  trace: which .mod files reference the missing skeletons/textures',
        '  h  Windows system events (last 2 h): crashes, GPU/disk/WHEA, Kernel-Power',
        '  l  cycle level filter  DBG > INF > WRN > ERR',
        '  v  show/hide noise lines (Ogre chatter, periodic stats)',
        '  r  raw mode: print every line, no grouping or suppression',
        '  p  pause/resume the screen (logging continues)',
        '  c  clear the screen            f  set include filter (regex, empty = off)',
        '  x  set exclude filter          a  save a snapshot of all logs now',
        '  o  open the session archive folder   i  info: paths, sources, settings')
    foreach ($l in $h) { Write-Plain $l }
    Write-Plain '  Colours: red = error, yellow = warning, white = info, gray = debug/noise.' 'gray'
    Write-Line ''
}

function Show-Info {
    Write-Head 'Info'
    Write-Plain ('  Kenshi folder .... ' + $script:KenshiDir)
    Write-Plain ('  Workshop folder .. ' + $script:WorkshopDir)
    Write-Plain ('  mods.cfg ......... ' + $script:CfgPath + '  (' + $script:Cfg.Count + ' entries)')
    Write-Plain ('  Output folder .... ' + $OutDir)
    Write-Plain ('  This session ..... ' + $(if ($script:ArcDir) { $script:ArcDir } else { '(no archive yet - starts with the game process)' }))
    Write-Plain ('  Level ............ ' + $script:LvlName[$script:MinLvl] + '   noise: ' + $script:ShowNoise + '   raw: ' + $script:ShowRaw + '   repeats shown: ' + $ShowRepeats)
    Write-Plain ('  Include / Exclude  ' + $(if ($script:RxInclude) { $script:RxInclude.ToString() } else { '-' }) + ' / ' + $(if ($script:RxExclude) { $script:RxExclude.ToString() } else { '-' }))
    Write-Plain ('  Console .......... PowerShell ' + $PSVersionTable.PSVersion + '   VT colours: ' + $script:UseColor + '   footer: ' + $script:Footer)
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

# ---- who references the missing files? byte search through the .mod files
function Ensure-Scanner {
    if ('KcScan' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading.Tasks;
public static class KcScan {
    public static int Done = 0;
    public static int Total = 0;
    public static Dictionary<string, List<int>> Run(string[] files, string[] needles) {
        Done = 0; Total = files.Length;
        byte[][] nb = new byte[needles.Length][];
        int maxLen = 3;
        bool[] tbl = new bool[1 << 24];
        for (int i = 0; i < needles.Length; i++) {
            nb[i] = Encoding.UTF8.GetBytes(needles[i].ToLowerInvariant());
            if (nb[i].Length > maxLen) maxLen = nb[i].Length;
            if (nb[i].Length >= 3) tbl[(nb[i][0] << 16) | (nb[i][1] << 8) | nb[i][2]] = true;
        }
        Dictionary<string, List<int>> result = new Dictionary<string, List<int>>(StringComparer.OrdinalIgnoreCase);
        ParallelOptions po = new ParallelOptions();
        po.MaxDegreeOfParallelism = 4;
        const int CH = 4 << 20;
        Parallel.ForEach(files, po, delegate (string f) {
            List<int> hits = new List<int>();
            try {
                using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16)) {
                    byte[] buf = new byte[CH + maxLen + 8];
                    bool[] found = new bool[nb.Length];
                    int carry = 0, read;
                    while ((read = fs.Read(buf, carry, CH)) > 0) {
                        int total = carry + read;
                        for (int i = carry; i < total; i++) { byte b = buf[i]; if (b >= 65 && b <= 90) buf[i] = (byte)(b + 32); }
                        for (int i = 0; i + 2 < total; i++) {
                            if (!tbl[(buf[i] << 16) | (buf[i + 1] << 8) | buf[i + 2]]) continue;
                            for (int n = 0; n < nb.Length; n++) {
                                if (found[n]) continue;
                                byte[] nd = nb[n];
                                if (nd.Length < 3 || i + nd.Length > total) continue;
                                int k = 0;
                                while (k < nd.Length && buf[i + k] == nd[k]) k++;
                                if (k == nd.Length) found[n] = true;
                            }
                        }
                        carry = Math.Min(maxLen - 1, total);
                        Buffer.BlockCopy(buf, total - carry, buf, 0, carry);
                    }
                    for (int n = 0; n < found.Length; n++) if (found[n]) hits.Add(n);
                }
            } catch { }
            lock (result) { if (hits.Count > 0) result[f] = hits; Done++; }
        });
        return result;
    }
}
'@ -ErrorAction Stop
        return $true
    } catch { Write-Plain ('  could not compile the scanner: ' + $_.Exception.Message) 'red'; return $false }
}

function Run-Trace {
    $S = $script:S
    Write-Head 'Trace: which mods reference the missing files'
    $needles = New-Object System.Collections.Generic.List[string]
    foreach ($id in @('skel', 'tex')) {
        if ($S.Cats.ContainsKey($id)) { foreach ($k in $S.Cats[$id].Distinct) { if ($k.Length -ge 4 -and $needles.Count -lt 120) { $needles.Add($k) } } }
    }
    if ($needles.Count -eq 0) { Write-Plain '  nothing to trace yet (no missing skeletons/textures counted). Mesh errors already name their mod.' 'gray'; return }
    Build-ModIndex
    $files = New-Object System.Collections.Generic.List[string]
    $nameOf = @{}
    if ($script:CfgIdx.Count -gt 0) {
        foreach ($e in $script:Cfg) {
            $b = $e; if ($b.EndsWith('.mod', 'OrdinalIgnoreCase')) { $b = $b.Substring(0, $b.Length - 4) }
            $k = $b.ToLowerInvariant()
            if ($script:ModIndex.ContainsKey($k)) { $p = $script:ModIndex[$k].Path; if (-not $nameOf.ContainsKey($p)) { $files.Add($p); $nameOf[$p] = $b } }
        }
    } else { foreach ($kv in $script:ModIndex.GetEnumerator()) { $files.Add($kv.Value.Path); $nameOf[$kv.Value.Path] = $kv.Key } }
    if ($files.Count -eq 0) { Write-Plain '  no .mod files found to search (is the Workshop folder reachable?)' 'byellow'; return }
    if (-not (Ensure-Scanner)) { return }
    $totalBytes = 0.0; foreach ($f in $files) { try { $totalBytes += (New-Object System.IO.FileInfo($f)).Length } catch { } }
    Write-Plain ('  searching ' + $files.Count + ' .mod files (' + (Fmt-Bytes $totalBytes) + ') for ' + $needles.Count + ' names ...') 'gray'
    $ps = [powershell]::Create()
    [void]$ps.AddScript({ param($f, $n) [KcScan]::Run([string[]]$f, [string[]]$n) }).AddArgument($files.ToArray()).AddArgument($needles.ToArray())
    $h = $ps.BeginInvoke()
    $t0 = [datetime]::Now
    while (-not $h.IsCompleted) {
        Start-Sleep -Milliseconds 700
        Draw-Footer (' tracing: ' + [KcScan]::Done + ' / ' + $files.Count + ' mods   ' + (Fmt-Span ([datetime]::Now - $t0)))
    }
    $res = $null
    try { $res = $ps.EndInvoke($h) } catch { Write-Plain ('  scan failed: ' + $_.Exception.Message) 'red' }
    $ps.Dispose()
    if ($null -eq $res -or $res.Count -eq 0) { Write-Plain '  scan finished, no hits (the names may be built at runtime or come from a game file outside the .mod files).' 'gray'; return }
    $dict = $res[0]
    $perMod = @{}; $perNeedle = @{}
    foreach ($kv in $dict.GetEnumerator()) {
        $mn = $nameOf[$kv.Key]
        $perMod[$mn] = $kv.Value.Count
        foreach ($ix in $kv.Value) { if (-not $perNeedle.ContainsKey($ix)) { $perNeedle[$ix] = New-Object System.Collections.Generic.List[string] }; $perNeedle[$ix].Add($mn) }
    }
    Write-Plain ('  done in ' + (Fmt-Span ([datetime]::Now - $t0)) + '. Mods that mention the most missing files:')
    foreach ($kv in ($perMod.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15)) { Write-Plain ('    {0,4}  {1}' -f $kv.Value, (Mod-Label $kv.Key)) 'byellow' }
    $none = 0
    foreach ($i in 0..($needles.Count - 1)) { if (-not $perNeedle.ContainsKey($i)) { $none++ } }
    Write-Plain ('  ' + ($needles.Count - $none) + ' of ' + $needles.Count + ' missing names found inside at least one .mod; ' + $none + ' not found in any (those come from the base game or a plugin).') 'gray'
    $tdir = $script:ArcDir
    if (-not $tdir) { $tdir = Join-Path $OutDir 'reports'; try { New-Item -ItemType Directory -Force -Path $tdir | Out-Null } catch { } }
    if ($tdir) {
        try {
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($i in 0..($needles.Count - 1)) { if ($perNeedle.ContainsKey($i)) { $lines.Add($needles[$i] + '  <-  ' + ($perNeedle[$i] -join '; ')) } else { $lines.Add($needles[$i] + '  <-  (no .mod mentions it)') } }
            [System.IO.File]::WriteAllLines((Join-Path $tdir 'trace.txt'), [string[]]$lines, $script:Utf8)
            Write-Plain ('  full list: ' + (Join-Path $tdir 'trace.txt')) 'gray'
        } catch { }
    }
    Write-Line ''
}
#endregion

#region ---------------------------------------------------------------- footer text, keys, analyze, main
function Footer-Text {
    $S = $script:S; $pi = $script:ProcInfo
    $parts = New-Object System.Collections.Generic.List[string]
    if ($script:Proc) { $parts.Add(' ' + $script:G.dot + ' RUNNING pid ' + $pi.Pid + ' ' + (Fmt-Span ([datetime]::Now - $pi.Start))) }
    else { $parts.Add(' o waiting for ' + $ProcessName + '.exe') }
    $ph = $S.Phase; if ($ph -like 'Loading game data*' -and $script:Cfg.Count -gt 0) { $ph = 'Loading mods ' + $S.ModsLoaded + '/' + $script:Cfg.Count } elseif ($ph -like 'IN GAME*') { $ph = 'IN GAME' }
    $parts.Add($ph)
    if ($script:Proc) { $parts.Add('RAM ' + (Fmt-Bytes $pi.Mem)) }
    $parts.Add('E ' + (Fmt-N $S.Err) + ' W ' + (Fmt-N $S.Warn))
    $miss = ''
    foreach ($k in @(@('badmesh', 'mesh'), @('skel', 'skel'), @('tex', 'tex'))) { if ($S.Cats.ContainsKey($k[0])) { $miss += $k[1] + ' ' + (Fmt-N $S.Cats[$k[0]].Count) + ' ' } }
    if ($miss) { $parts.Add('missing: ' + $miss.Trim()) }
    $flags = $script:LvlName[$script:MinLvl]
    if ($script:ShowRaw) { $flags += ' RAW' }; if ($script:ShowNoise) { $flags += ' +noise' }; if ($script:Paused) { $flags += ' PAUSED(' + $script:PauseQ.Count + ')' }
    if ($script:RxInclude) { $flags += ' inc' }; if ($script:RxExclude) { $flags += ' exc' }
    $parts.Add($flags)
    $parts.Add('? help')
    return ($parts -join (' ' + $script:G.sep + ' '))
}

function Flush-Pause { while ($script:PauseQ.Count -gt 0) { Out-Raw (($script:PauseQ.Dequeue()) + $script:R + "`n") } }

function Prompt-Line([string]$label) {
    Out-Raw ((Col 'bwhite') + $label + $script:R + ' ')
    $v = ''
    try { $v = [Console]::ReadLine() } catch { }
    return $v
}

function Handle-Key([System.ConsoleKeyInfo]$k) {
    $c = [string]$k.KeyChar
    switch -CaseSensitive ($c) {
        '?' { Show-Help }
        'q' { return $true }
        's' { Show-Summary $true }
        'w' { Show-Tallies }
        'm' { Show-Mods }
        'e' { Show-Recent }
        't' { Run-Trace }
        'h' { Show-SysEvents }
        'i' { Show-Info }
        'l' { $script:MinLvl = ($script:MinLvl + 1) % 4; Write-Plain ('  level filter: ' + $script:LvlName[$script:MinLvl] + ' and above') 'cyan' }
        'v' { $script:ShowNoise = -not $script:ShowNoise; Write-Plain ('  noise lines: ' + $(if ($script:ShowNoise) { 'SHOWN' } else { 'hidden' })) 'cyan' }
        'r' { $script:ShowRaw = -not $script:ShowRaw; Write-Plain ('  raw mode: ' + $(if ($script:ShowRaw) { 'ON (every line, no grouping)' } else { 'off' })) 'cyan' }
        'p' {
            $script:Paused = -not $script:Paused
            if (-not $script:Paused) { Flush-Pause; Write-Plain '  resumed' 'cyan' } else { Out-Raw ((Col 'cyan') + '  paused - logging continues in the background (p to resume)' + $script:R + "`n") }
        }
        'c' { try { Clear-Host } catch { }; Setup-Footer }
        'f' { $v = Prompt-Line 'include regex (empty = off):'; if ($v) { $script:RxInclude = New-Object System.Text.RegularExpressions.Regex($v, 'IgnoreCase') } else { $script:RxInclude = $null } }
        'x' { $v = Prompt-Line 'exclude regex (empty = off):'; if ($v) { $script:RxExclude = New-Object System.Text.RegularExpressions.Regex($v, 'IgnoreCase') } else { $script:RxExclude = $null } }
        'a' { $n = Arc-Snapshot $true; Write-Plain ('  snapshot: ' + $n + ' log file(s) copied to ' + $(if ($script:ArcDir) { $script:ArcDir } else { '(archive disabled)' })) 'cyan' }
        'o' { try { $d = Join-Path $OutDir 'sessions'; if ($script:IsWin) { Start-Process explorer.exe -ArgumentList ('"' + $d + '"') } } catch { } }
    }
    return $false
}

function Write-HeaderBanner {
    Write-Banner ('KENSHI CONSOLE ' + $script:Ver + '   ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) 'bcyan'
    Write-Plain ('  Kenshi ......... ' + $script:KenshiDir)
    Write-Plain ('  mods.cfg ....... ' + $(if ($script:Cfg.Count -gt 0) { [string]$script:Cfg.Count + ' entries' } else { 'not found' }))
    Write-Plain ('  Following ...... ' + (($script:Sources | ForEach-Object { $_.Tag }) -join ' '))
    Write-Plain ('  Saves to ....... ' + $OutDir)
    Write-Plain '  Read-only: this tool never writes into the Kenshi, Workshop or Steam folders.' 'gray'
    Write-Plain '  Keys: ? help   s summary   w tallies   m mods   t trace   e errors   l level   v noise   r raw   p pause   q quit' 'gray'
}

function Catch-Up {
    $script:Quiet = (-not $FromStart)
    $total = $script:Sources.Count; $i = 0
    foreach ($s in $script:Sources) {
        $i++
        if ($script:Interactive -and -not $Analyze) { Draw-Footer (' reading existing logs ' + $i + '/' + $total + ': ' + $s.Name) }
        [void](Read-Source $s $true)
    }
    $script:Quiet = $false
}

function Run-Analyze {
    $script:Footer = $false; $script:Interactive = $false
    if ($AnalyzeFolder) {
        $f = (Resolve-Path -LiteralPath $AnalyzeFolder -ErrorAction Stop).Path
        if (Test-Path -LiteralPath (Join-Path $f 'logs') -PathType Container) { $script:LogDirOverride = Join-Path $f 'logs' } else { $script:LogDirOverride = $f }
        $c = Join-Path $f 'mods.cfg'; if (Test-Path -LiteralPath $c) { $script:CfgPath = $c }
        $script:WorkshopDir = $script:WorkshopDir   # keep: lets owner labels resolve if present
    }
    Load-Cfg
    Scan-Sources
    if ($script:Sources.Count -eq 0) { Write-Plain 'No log files found to analyse.' 'red'; return }
    $stamp = [datetime]::Now.ToString('yyyyMMdd_HHmmss')
    $rdir = Join-Path $OutDir 'reports'; New-Item -ItemType Directory -Force -Path $rdir | Out-Null
    $rpath = Join-Path $rdir ('analysis_' + $stamp + '.txt')
    Write-Plain ('Analysing ' + $script:Sources.Count + ' log file(s) ...') 'cyan'
    $script:Quiet = $true
    $script:S.Start = $null
    foreach ($s in $script:Sources) { [void](Read-Source $s $true) }
    $script:Quiet = $false
    try {
        $fsr = New-Object System.IO.FileStream($rpath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $script:Transcript = New-Object System.IO.StreamWriter($fsr, $script:Utf8)
        $script:Transcript.AutoFlush = $true
        $script:Transcript.WriteLine('Kenshi Console analysis ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss') + '   source: ' + $(if ($AnalyzeFolder) { $AnalyzeFolder } else { $script:KenshiDir }))
    } catch { }
    $script:S.Phase = $(if ($script:S.Phase -eq 'Idle') { 'Idle (no start marker in the logs)' } else { $script:S.Phase })
    $cap = New-Object System.Collections.Generic.List[string]
    $script:CaptureTo = $null
    Show-Summary $true
    # ---- extra detail sections for the one-shot report
    Write-Head 'Per-log notes'
    foreach ($s in $script:Sources) {
        if ($s.Kind -in @('plain', 'dust', 'save')) {
            $note = ($s.Lines.ToString() + ' lines, ' + $s.Err + ' error(s), ' + $s.Warn + ' warning(s)')
            Write-Plain ('  ' + $s.Tag.PadRight(6) + $s.Name + ': ' + $note) $(if ($s.Err -gt 0) { 'byellow' } else { 'white' })
        }
    }
    if ($script:S.Cats.ContainsKey('badmesh')) {
        Write-Head 'Missing meshes by mod (the folder name in the error is the mod that references them)'
        $o = $script:S.Cats['badmesh'].Owners.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 25
        foreach ($kv in $o) { Write-Plain ('  {0,5}  {1}' -f $kv.Value, (Mod-Label $kv.Key)) 'byellow' }
    }
    if ($script:S.Cats.ContainsKey('missrec') -and $script:S.Cats['missrec'].Owners.Count -gt 0) {
        Write-Head '"modified by X does not exist": top mods'
        foreach ($kv in ($script:S.Cats['missrec'].Owners.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 25)) { Write-Plain ('  {0,5}  {1}' -f $kv.Value, $kv.Key) 'yellow' }
        Write-Plain '  (these are record edits whose target is missing: the mod was loaded before the mod that defines the record, or that mod is not installed)' 'gray'
    }
    if ($Trace) { Run-Trace }
    Write-Line ''
    Write-Plain ('Report saved: ' + $rpath) 'green'
    if ($script:Transcript) { try { $script:Transcript.Dispose() } catch { }; $script:Transcript = $null }
    return $rpath
}

function Main {
    # ---- environment
    try { $script:Interactive = (-not [Console]::IsOutputRedirected) } catch { $script:Interactive = $true }
    if (-not $script:Interactive) { $script:UseColor = $false; $script:Footer = $false }
    if ($script:Interactive) {
        try { [Console]::OutputEncoding = $script:Utf8 } catch { }
        if (-not (Enable-VT)) { $script:UseColor = $false; $script:Footer = $false }
    }
    if ($script:UseColor) { $script:R = $script:Esc + '[0m' }

    if ($DumpFile) {
        if (-not (Test-Path -LiteralPath $DumpFile)) { Write-Host ('File not found: ' + $DumpFile) -ForegroundColor Red; return }
        Write-Host ('Crash dump: ' + $DumpFile) -ForegroundColor Cyan
        foreach ($l in (Describe-CrashDump (Resolve-Path -LiteralPath $DumpFile).Path)) { Write-Host ('  ' + $l) }
        return
    }

    $script:KenshiDir = Find-Kenshi
    if (-not $script:KenshiDir -and -not $AnalyzeFolder) {
        Write-Host 'Could not find the Kenshi folder. Run again with -KenshiPath "C:\...\steamapps\common\Kenshi".' -ForegroundColor Red
        return
    }
    if ($script:KenshiDir) {
        $script:CfgPath = Join-Path $script:KenshiDir 'data\mods.cfg'
        $ws = Join-Path (Split-Path -Parent (Split-Path -Parent $script:KenshiDir)) 'workshop\content\233860'
        if (Test-Path -LiteralPath $ws) { $script:WorkshopDir = $ws }
    }
    if (-not $OutDir) {
        $base = $PSScriptRoot; if (-not $base) { $base = (Get-Location).Path }
        $script:OutDirResolved = Join-Path $base 'KenshiConsole-data'
    } else { $script:OutDirResolved = $OutDir }
    Set-Variable -Name OutDir -Value $script:OutDirResolved -Scope Script
    try { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null } catch { }

    if ($Analyze -or $AnalyzeFolder) {
        $rp = Run-Analyze
        return
    }

    # one copy at a time: two copies fought over the same session folder before
    $script:Mutex = $null
    if (-not $AllowMultiple) {
        $created = $false
        try { $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\KenshiConsoleSingleton', [ref]$created) } catch { $created = $true }
        if (-not $created) {
            Write-Host 'Another Kenshi Console is already running (look for its window). Close it first, or run with -AllowMultiple.' -ForegroundColor Yellow
            $script:Mutex = $null
            return
        }
    }
    [void](Ensure-Native)
    if ($script:NativeOk) { try { [KcProc]::HookClose() } catch { } }

    Load-Cfg
    Scan-Sources
    Write-HeaderBanner
    if ($script:Sources.Count -eq 0) {
        Write-Plain ('  !! No Kenshi log files found under ' + $script:KenshiDir + ' yet. Nothing will be saved until some appear.') 'bred'
        Write-Plain '     Start the game (it creates them) or run with -KenshiPath "C:\...\steamapps\common\Kenshi".' 'byellow'
    }
    Startup-HardwareCheck
    Setup-Footer
    Set-Title 'Kenshi Console'

    # is the game already running?
    Proc-Poll
    if ($script:Proc -eq $null) {
        Write-Plain ('  ' + $script:G.dot + ' ' + $ProcessName + '.exe is not running. Showing the end of the last run; launch Kenshi and this window follows it.') 'gray'
    }

    Write-Plain '  Reading existing logs ...' 'gray'
    Catch-Up
    if (-not $FromStart -and $Backlog -gt 0) {
        $tail = $script:Ring.ToArray() | Select-Object -Last $Backlog
        if ($tail) { Write-Line ((Col 'gray') + ('  ----- last ' + @($tail).Count + ' lines of the existing logs -----')); foreach ($l in $tail) { Out-Raw ($l + $script:R + "`n") } }
    }
    if ($script:S.Phase -ne 'Idle') {
        $s = $script:S
        Write-Line ((Col 'gray') + ('  ----- state: ' + $s.Phase + ' | mods loaded ' + $s.ModsLoaded + ' | errors ' + (Fmt-N $s.Err) + ' | warnings ' + (Fmt-N $s.Warn) + ' | s = full summary -----'))
        if ($s.ModsLoaded -gt 0 -and $s.Phase -notlike 'Loading*') { Check-LoadOrder }
    }
    if ($Quit) { Show-Summary $true; return }
    if (-not $script:Proc -and -not $NoArchive -and $script:S.Phase -ne 'Idle' -and -not $script:ArcDir) {
        try {
            $ifile = $script:Sources | Where-Object { $_.Kind -eq 'info' } | Select-Object -First 1
            if ($ifile) {
                $when = (Get-Item -LiteralPath $ifile.Path).LastWriteTime
                Arc-Open $when
                if ($script:ArcDir) { $n = Arc-Snapshot $true; Write-SessionSummary; Write-Plain ('  ' + $script:G.dot + ' last run saved before it can be overwritten: ' + $script:ArcDir) 'green' }
            }
        } catch { }
    }
    Write-Line ''
    Write-Plain (' ' + $script:G.arrow + ' live. Waiting for new log lines ...') 'bcyan'

    $lastFoot = [datetime]::MinValue; $lastProc = [datetime]::MinValue
    $quit = $false
    try {
        while (-not $quit) {
            $now = [datetime]::Now
            if ($MaxSeconds -gt 0 -and ($now - $script:RunStart).TotalSeconds -ge $MaxSeconds) { break }
            if (($now - $script:LastScan).TotalSeconds -ge 3) { $script:LastScan = $now; Scan-Sources }
            $got = 0
            foreach ($s in $script:Sources.ToArray()) { $got += Read-Source $s $false }
            if (($now - $lastProc).TotalSeconds -ge 1) { $lastProc = $now; Proc-Poll }
            if ($script:ProcInfo.PMDue -and $now -ge $script:ProcInfo.PMDue) {
                foreach ($s in $script:Sources.ToArray()) { [void](Read-Source $s $false) }
                Post-Mortem
            }
            if ($SnapshotSec -gt 0 -and $script:Proc -and ($now - $script:LastSnap).TotalSeconds -ge $SnapshotSec) { Persist-Live $false }
            if ($script:NativeOk -and [KcProc]::CloseRequested) { $quit = $true; Notice 'console window is closing - saving the session first' 'byellow' }
            if (($now - $lastFoot).TotalMilliseconds -ge 400) { $lastFoot = $now; Draw-Footer (Footer-Text) }
            # keys
            if ($script:Interactive) {
                try {
                    while ([Console]::KeyAvailable) {
                        $k = [Console]::ReadKey($true)
                        if (Handle-Key $k) { $quit = $true; break }
                    }
                } catch { }
            }
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
        Close-ProcHandle
        Reset-Footer
        if ($script:Transcript) { try { $script:Transcript.Dispose() } catch { } }
        Out-Raw ($script:R + "`n")
        if ($script:NativeOk) { try { [KcProc]::Done.Set() } catch { } }
        if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { }; try { $script:Mutex.Dispose() } catch { } }
    }
}

Main
#endregion
