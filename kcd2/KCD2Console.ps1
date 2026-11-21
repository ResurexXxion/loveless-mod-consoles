<#
.SYNOPSIS
    KCD2 Console - live external log console, pre-flight checker, crash post-mortem and log analyzer for
    Kingdom Come: Deliverance II (Steam, Windows, Vortex-managed mods).

.DESCRIPTION
    Tails every KCD2-related log at once (kcd.log, kcd_launcher.log, KCSE.log, questnative.log, kcd2db.log,
    kcd2minimap.log, KCD2_HenrySenses/TPVCamera/CombatUse logs, KCD2DSListener.log and any other *.log it finds,
    including logs that mods write inside their own folder), parses each format, removes the noise, and shows what
    matters in a separate window with colours and a live status bar.

    * Understands the launch phases: boot, mod discovery, mod_order.txt applied, engine init, Lua scripts, main menu,
      loading a save, loading the level, IN GAME, quit. Times the phases it can time.
    * Reads the [Mod] lines: which mods were enabled (and in what order), which were disabled for the game version,
      which mod_order.txt entries were "not found", which manifests have an invalid ModId. Compares the enabled order
      with Mods\mod_order.txt, and with what is on disk.
    * Groups the repeated problems into categories (Lua errors per owning mod, bad config lines, unknown commands,
      item/table problems ...) so thousands of lines become a short table. Known harmless noise from the cheat mod,
      AutoHideHUD's mod.cfg and similar is counted but hidden.
    * "Mods used while saving": when a save loads, compares the mods the save was made with against the mods that
      are installed now (missing, new, changed version).
    * KCSE script-extender status: plugins found / registered / loaded, ASIs loaded, and a warning when the game was
      updated since the last run (plugins and ASIs break first).
    * Watches KingdomCome.exe: start, command line (-devmode), exit code, memory, "not responding", and samples
      GPU memory/temperature (nvidia-smi, if present) and free RAM so a crash can be read against them.
    * Watches the save folder: every autosave / quicksave / permanent save written, with size.
    * On exit: crash post-mortem (last log lines, last mod script initialised, Windows crash events, new dump files,
      hardware events: WHEA, Kernel-Power 41, nvlddmkm / TDR, disk / NVMe resets, a reboot during the run), with the
      project rule "no game error + hard crash = check hardware first".
    * kcd.log is overwritten on every launch. This tool keeps a copy of every session (and refreshes it while the game
      runs, so even a hard reboot leaves the last logs behind), plus a session.json used for run history and
      "what changed since last run".
    * Pre-flight: -Check (also key k) validates mod_order.txt against the Mods folder, manifests, version
      restrictions, KCSE plugins, ASIs, disk space, user.cfg before you launch.
    * -Overlaps / key u: finds files that more than one mod's .pak provides and says which mod wins.
    * -Commands / key /: lists the console commands that your mods register (read straight from their Lua).
    * Read-only toward the game: it never writes into the game folder, the Mods folder, the Vortex staging folder,
      or Steam. Everything it writes goes to its own data folder.

    Keys while running:  ? help   q quit   p pause   c clear   l level   v noise   r raw   s summary   w tallies
                         m mods / load order   e recent errors   k pre-flight   u pak overlaps   t find a file in mods
                         / mod commands   d run history   g hardware   h Windows events   a snapshot   o open folder
                         f include filter   x exclude filter   i info

.PARAMETER GamePath       KCD2 install folder. Auto-detected when omitted (running process, Steam libraries, common paths).
.PARAMETER OutDir         Where sessions, transcripts and reports go. Default: KCD2Console-data next to this script.
.PARAMETER MinLevel       Debug | Info | Warn | Error. Default Info.
.PARAMETER Include        Only show lines whose text matches this regex.
.PARAMETER Exclude        Hide lines whose text matches this regex.
.PARAMETER Raw            No grouping, no suppression, no noise filtering: every line, as written.
.PARAMETER FromStart      Replay the whole of the current logs on screen first (default: only the last -Backlog lines).
.PARAMETER Backlog        Lines of history to show at start. Default 25.
.PARAMETER ShowRepeats    How many times the same problem is printed before it is counted silently. Default 3.
.PARAMETER ShowCheatNoise Print the cheat mod's own indexing noise (duplicate item ids, "Failed to load data from XML database").
.PARAMETER Analyze        One-shot report on the current logs, then exit. No live tailing.
.PARAMETER AnalyzeFolder  One-shot report on an archived session folder (or any folder holding copies of the logs).
.PARAMETER Check          Pre-flight report (mod_order.txt, manifests, plugins, disk ...), then exit.
.PARAMETER Overlaps       Report files provided by more than one mod, then exit.
.PARAMETER Commands       List console commands registered by installed mods, then exit.
.PARAMETER History        Table of archived runs (and what changed between the last two), then exit.
.PARAMETER NoColor / NoFooter / NoArchive / NoSystemEvents / NoModScan / NoHardware / NoSaveWatch / Ascii   Switch features off.
.PARAMETER Beep           Sound a beep on a crash, a hang, or a VRAM-full warning.
.PARAMETER SnapshotSec    While the game runs, refresh the session copy of the logs every N seconds. 0 = off. Default 30.
.PARAMETER ProcessName    Game process name without .exe. Default KingdomCome.
.PARAMETER ExtraLog       Extra log files to follow.
.PARAMETER StagingPath    Vortex staging folder (to compare its mod_order.txt with the deployed one). Auto-detected.
.PARAMETER SavePath       Saved Games\kingdomcome2 folder. Auto-detected.

.EXAMPLE
    .\KCD2Console.ps1
.EXAMPLE
    .\KCD2Console.ps1 -Check
.EXAMPLE
    .\KCD2Console.ps1 -Analyze
.EXAMPLE
    .\KCD2Console.ps1 -MinLevel Warn -Exclude 'XPMonitor'
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$OutDir,
    [ValidateSet('Debug','Info','Warn','Error')][string]$MinLevel = 'Info',
    [string]$Include,
    [string]$Exclude,
    [string]$ProcessName = 'KingdomCome',
    [string[]]$ExtraLog = @(),
    [string]$StagingPath,
    [string]$SavePath,
    [int]$Backlog = 25,
    [int]$ShowRepeats = 3,
    [int]$PollMs = 250,
    [int]$SnapshotSec = 30,
    [int]$HwSec = 10,
    [switch]$FromStart,
    [switch]$Raw,
    [switch]$ShowCheatNoise,
    [switch]$NoColor,
    [switch]$NoFooter,
    [switch]$NoArchive,
    [switch]$NoSystemEvents,
    [switch]$NoModScan,
    [switch]$NoHardware,
    [switch]$NoSaveWatch,
    [switch]$Ascii,
    [switch]$Beep,
    [switch]$Analyze,
    [string]$AnalyzeFolder,
    [switch]$Check,
    [switch]$Overlaps,
    [switch]$Commands,
    [switch]$History,
    [string]$FindFile,
    [int]$KeepSessions = 40,
    [int]$MaxSeconds = 0,    # exit by itself after N seconds (0 = run until q); handy for scheduled/automated runs
    [switch]$Quit,           # test hook: read everything once, print, exit
    [switch]$AllowMultiple,  # skip the one-copy-at-a-time lock
    [string]$DumpFile        # read this crash dump (.dmp / .zip containing one) and print what it says
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:Ver     = '1.1'
$script:IsWin   = ($env:OS -eq 'Windows_NT')
$script:Utf8    = New-Object System.Text.UTF8Encoding($false)
$script:RunStart = [datetime]::Now
$script:Ci      = [System.Globalization.CultureInfo]::InvariantCulture

#region ---------------------------------------------------------------- output layer
$script:Esc = [string][char]27
$script:UseColor  = (-not $NoColor)
$script:Footer    = (-not $NoFooter)
$script:Interactive = $true
$script:Live      = $false         # true once the initial catch-up is over: lines without a timestamp get wall-clock time
$script:Quiet     = $false         # true while catching up: render but do not print
$script:Paused    = $false
$script:PauseQ    = New-Object System.Collections.Generic.Queue[string]
$script:Ring      = New-Object System.Collections.Generic.List[string]   # rendered visible lines (for backlog)
$script:Transcript = $null
$script:CaptureTo = $null
$script:Tee = $null
$script:WinH = 0
$script:FooterOverride = ''

$script:SGR = @{
    reset='0'; bold='1'; dim='2'; rev='7'; red='31'; green='32'; yellow='33'; blue='34'; mag='35'; cyan='36'; white='97'
    gray='90'; bred='1;31'; bgreen='1;32'; byellow='1;33'; bcyan='1;36'; bmag='1;35'; bwhite='1;97'; errbg='41;97'
}
function Col([string]$name) { if ($script:UseColor -and $script:SGR.ContainsKey($name)) { return ($script:Esc + '[' + $script:SGR[$name] + 'm') } return '' }
$script:R = ''   # reset, set after VT check

if ($Ascii) { $script:G = @{ dot='*'; bar='='; arrow='>'; star='*'; up='^'; sep='|'; ell='...'; rep='x'; ok='+'; bad='!' } }
else        { $script:G = @{ dot=[string][char]0x25CF; bar=[string][char]0x2550; arrow=[string][char]0x25B6; star=[string][char]0x2605; up=[string][char]0x2191; sep=[string][char]0x2502; ell=[string][char]0x2026; rep=[string][char]0x00D7; ok=[string][char]0x2713; bad='!' } }

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
function Pad([string]$s, [int]$n) { if ($null -eq $s) { $s = '' }; if ($s.Length -ge $n) { return $s }; return $s.PadRight($n) }

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
function Do-Beep([int]$n = 2) { if ($Beep -and $script:Interactive) { try { for ($i = 0; $i -lt $n; $i++) { [Console]::Beep(880, 180) } } catch { } } }

# small helpers used all over
function Jget($o, [string]$name, $default = $null) {
    if ($null -eq $o) { return $default }
    try { $p = $o.PSObject.Properties[$name]; if ($null -ne $p -and $null -ne $p.Value) { return $p.Value } } catch { }
    return $default
}
function Ci-Child([string]$dir, [string]$name) {
    # find a child (file or folder) by name ignoring case; '' when absent. (Windows is case-insensitive anyway; this keeps tests on other systems honest.)
    if (-not $dir) { return '' }
    try {
        $p = [System.IO.Path]::Combine($dir, $name)
        if ([System.IO.File]::Exists($p) -or [System.IO.Directory]::Exists($p)) { return $p }
        if (-not [System.IO.Directory]::Exists($dir)) { return '' }
        foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries($dir)) { if ([System.IO.Path]::GetFileName($e) -ieq $name) { return $e } }
    } catch { }
    return ''
}
function PJ([string]$a, [string]$b) { return [System.IO.Path]::Combine($a, $b) }
function Safe-Len([string]$p) { try { return (New-Object System.IO.FileInfo($p)).Length } catch { return 0 } }
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
        Start = $null; Phase = 'Idle'; PhaseSince = [datetime]::Now; PhaseLog = (New-Object System.Collections.Generic.List[string]); PhaseDt = $null
        Lines = 0; Noise = 0; Err = 0; Warn = 0
        LogSeen = $false; LogSeenAt = [datetime]::MinValue; LogStart = $null; InHeader = $false
        Build = ''; GameVer = ''; ExtVer = ''; Cmdline = ''; DevMode = $false; Exe = ''; Gpu = ''; VramMB = 0; RamMB = 0; SteamBuild = ''
        Dlc = (New-Object System.Collections.Generic.List[string])
        ModsFound = 0; ModsEnabledN = 0
        EnabledOrder = (New-Object System.Collections.Generic.List[string])
        EnabledSet = (New-Object 'System.Collections.Generic.HashSet[string]')
        Discovered = (New-Object 'System.Collections.Generic.HashSet[string]')
        WildMods = @{}
        Disabled = (New-Object System.Collections.Generic.List[string])
        NotFound = (New-Object System.Collections.Generic.List[string])
        BadModId = (New-Object System.Collections.Generic.List[string])
        OrderDiff = (New-Object System.Collections.Generic.List[string])
        NotLoaded = (New-Object System.Collections.Generic.List[string])
        LuaInit = (New-Object System.Collections.Generic.List[string]); LuaInitLast = ''; LuaInitFirstSeen = $false
        Cats = @{}; ErrSig = @{}; Tags = @{}
        Loads = (New-Object System.Collections.Generic.List[object])      # each: Save, Type, Ver, At, DoneAt
        LoadOpen = $null
        SaveModsCur = $null; SaveModsExpect = 0; SaveModsLists = (New-Object System.Collections.Generic.List[object])
        SaveDiff = (New-Object System.Collections.Generic.List[string])
        SavesWritten = 0; LastEntities = 0; MaxEntities = 0
        Levels = (New-Object System.Collections.Generic.List[string])
        Pauses = 0
        Pso = (New-Object System.Collections.Generic.List[string])
        MenuAt = $null; MenuSeen = $false; MenuSecs = 0.0; GameplayCount = 0; FirstGameplay = $null
        CleanExit = $false; QuitReason = ''; QuitCode = $null
        Kc = @{ Ver=''; Build=''; GameVer=''; Found=(New-Object System.Collections.Generic.List[string]); Registered=(New-Object System.Collections.Generic.List[string]); Loaded=(New-Object System.Collections.Generic.List[string]); Asi=(New-Object System.Collections.Generic.List[string]); Ready=$false; Total=0; Events=(New-Object System.Collections.Generic.List[string]); FirstTs=$null; ReadyTs=$null; DataLoadedTs=$null; PreDataTs=$null }
        Comp = 0; CompList = (New-Object System.Collections.Generic.List[string])
        Mismatch = (New-Object System.Collections.Generic.List[string])
        Milestones = (New-Object System.Collections.Generic.List[string])
        RecentMap = @{}; RecentOrder = (New-Object System.Collections.Generic.List[string])
        LastLuaOwner = ''; LastLines = 0
        SaveFiles = (New-Object System.Collections.Generic.List[string])
        OrderPending = $false
    }
}
$script:S = New-Session

function Get-Cat([string]$id, [string]$title, [int]$lvl) {
    if ($script:S.Cats.ContainsKey($id)) { return $script:S.Cats[$id] }
    $c = @{ Id=$id; Title=$title; Lvl=$lvl; Count=0; Printed=0; Distinct=(New-Object 'System.Collections.Generic.HashSet[string]'); Owners=@{}; First=''; Last=''; Told=$false; Samples=(New-Object System.Collections.Generic.List[string]) }
    $script:S.Cats[$id] = $c
    return $c
}

# rule: Id, Kind, Rx, Mode (flood|show|count|hide|pass|special), Lvl (0-3 or -1 = from line), Title
# named groups: key (distinct item), owner (who is responsible)
function New-Rule([string]$id,[string]$kind,[string]$rx,[string]$mode,[int]$lvl,[string]$title) {
    return [pscustomobject]@{ Id=$id; Kind=$kind; Rx=(New-Object System.Text.RegularExpressions.Regex($rx, 'Compiled')); Mode=$mode; Lvl=$lvl; Title=$title }
}
$script:Rules = @{}
function Add-Rule($r) { if (-not $script:Rules.ContainsKey($r.Kind)) { $script:Rules[$r.Kind] = New-Object System.Collections.Generic.List[object] } $script:Rules[$r.Kind].Add($r) }
function Rl([string]$id,[string]$kind,[string]$rx,[string]$mode,[int]$lvl,[string]$title) { Add-Rule (New-Rule $id $kind $rx $mode $lvl $title) }

# ================= kcd.log (the engine log; no timestamps on most lines) =================
# --- lifecycle / mod loader: special
Rl 'logstart'    'kcd' '^Log Started at (?<d>\d{4}-\d\d-\d\d)\s+(?<t>\d\d:\d\d:\d\d)' 'special' 1 'Log opened'
Rl 'builddesc'   'kcd' '^\* description: (?<key>\S+)' 'special' 1 'Build'
Rl 'cmdline'     'kcd' "^Cmdline: '(?<key>.*)'\s*$" 'special' 1 'Command line'
Rl 'exepath'     'kcd' '^Executable: (?<key>.+?)\s*$' 'special' 1 'Executable'
Rl 'ramtotal'    'kcd' '^Total system physical memory: (?<key>\d+) MB' 'special' 1 'RAM'
Rl 'gpuline'     'kcd' '^- (?<key>.+?) \(vendor = 0x(?<v>[0-9a-fA-F]+), device = 0x(?<dv>[0-9a-fA-F]+)\)\s*$' 'special' 1 'GPU'
Rl 'vramline'    'kcd' '^\s+- Dedicated video memory: (?<key>\d+) MB' 'special' 1 'VRAM'
Rl 'dispver'     'kcd' '^Displayed build info: (?<key>\S+)' 'special' 1 'Game version'
Rl 'extver'      'kcd' '^Extended build info:\s+(?<key>\S+)' 'special' 1 'Game build'
Rl 'steamid'     'kcd' "^\[Steam\] Successfully initialized Steam API, user_id=\d+='(?<u>[^']*)', build_id=(?<key>\d+)" 'special' 1 'Steam'
Rl 'dlcline'     'kcd' '^\[\d+ (?<key>\w+)\] \d+, \w+, active: (?<act>[YN]), free: (?<free>[YN]), save: [YN]' 'special' 1 'DLC'
Rl 'modsdir'     'kcd' "^Mods dir is '(?<key>[^']*)'" 'special' 1 'Mods dir'
Rl 'modsfound'   'kcd' '^\[Mod\] (?<key>\d+) mods loaded from ' 'special' 1 'Mods found'
Rl 'modenable'   'kcd' "^\[Mod\] '(?<path>mods/(?<key>[^']+))' (?:is not limited to any game version|supports game version '(?<gv>[^']*)' by wildcard '(?<wc>[^']*)'), it will be enabled" 'special' 1 'Mod enabled'
Rl 'moddisabled' 'kcd' "^\[Mod\] '(?<path>mods/(?<key>[^']+))' (?<why>.*will be disabled.*)$" 'special' 3 'Mod disabled by the game'
Rl 'modnover'    'kcd' "^\[Mod\] '(?<path>mods/(?<key>[^']+))' has no version restrictions in manifest" 'special' 0 'Mod discovered'
Rl 'modsenabled' 'kcd' '^\[Mod\] (?<key>\d+) mods enabled' 'special' 1 'Mods enabled'
Rl 'modnotfound' 'kcd' '^\[Mod\] (?<key>\S+) not found\s*$' 'special' 3 'mod_order.txt entry with no mod'
Rl 'badmodid'    'kcd' '^Mod (?<path>mods/(?<key>[^/]+)/mod\.manifest) has invalid ModId' 'special' 3 'Invalid ModId'
Rl 'modhdr'      'kcd' '^\[Mod\] (Loading mods)' 'hide' 0 'Mod loader chatter'
Rl 'basecfg'     'kcd' '^Loading base cfg files' 'special' 1 'Base cfg'
Rl 'usercfg'     'kcd' '^Loading user cfg files' 'special' 1 'User cfg'
Rl 'rendinit'    'kcd' '^Renderer initialization' 'special' 1 'Renderer'
Rl 'startvid'    'kcd' '^Starting startup video' 'special' 1 'Startup video'
Rl 'luainit'     'kcd' '^Loading lua init script for mod (?<key>\S+) \.\.\.' 'special' 1 'Lua init'
Rl 'mainmenu'    'kcd' "^PlayVideoOnly 'main_menu" 'special' 1 'Main menu video'
Rl 'evt'         'kcd' '^\[DEBUG\] EventSystemListener: actionName\[(?<act>\w+)\] eventName\[(?<key>\w+)\]' 'special' 0 'Game event'
Rl 'loadsave'    'kcd' "^Loading saved game '(?<key>[^']+)' (?<type>\w+), created by '(?<ver>[^']*)', ver\. (?<sv>\d+)" 'special' 1 'Loading save'
Rl 'savemodshdr' 'kcd' '^Mods used while saving \((?<key>\d+)\):' 'special' 1 'Save mod list'
Rl 'savemod'     'kcd' "^\* mod '(?<key>.*)', author: '(?<author>.*)', desc: '.*', ver: '(?<ver>[^']*)'\s*$" 'special' 1 'Save mod entry'
Rl 'level'       'kcd' '^={3,} Loading level (?<key>\S+) ={3,}' 'special' 1 'Level'
Rl 'pso'         'kcd' "^={3,} Precached (?<key>\d+) (?<kind>Graphics|Compute) PSOs(?: \(PrecachingMode = '(?<mode>\w+)'\))? out of \d+ PSOs in (?<secs>[\d\.]+) seconds" 'special' 1 'PSO precache'
Rl 'saveent'     'kcd' '^SaveEntities: (?<key>\d+) entities saved' 'special' 1 'Save written'
Rl 'quit'        'kcd' '^CSystem::Quit invoked from thread (?<th>\d+) \(main is \d+\), reason: (?<key>.*?), exit code: (?<code>-?\d+)' 'special' 1 'Quit'
# --- boilerplate (hidden, counted)
Rl 'pakopen'     'kcd' "^(Pak '|Skipping pak file|Pak files in|\s+'[^']+\.pak' \d+ B$)" 'hide' 0 'Pak open / listing'
Rl 'cfgload'     'kcd' "^Loading config file '" 'hide' 0 'Config files loaded'
Rl 'dllload'     'kcd' "^Loading '[^']+\.dll' \.\.\.|^Loading Game DLL|^Game DLL is loaded|^GameStartup is created|^Initializing the game|^The game is initialized|^Run: begin" 'hide' 0 'Engine DLL loading'
Rl 'gfxopen'     'kcd' '^CryGFxFileOpener::OpenFile\(\)' 'hide' 0 'UI (GFx) file opens'
Rl 'luafile'     'kcd' '^Loading file \[' 'hide' 0 'Lua files loaded'
Rl 'mfx'         'kcd' '^\[MFX\]' 'hide' 0 'Material FX libraries'
Rl 'cryinit'     'kcd' '^(Initializing module|Discovered layout comb|Music probe|Music Manager|Initializing the (Sound|Music)|Sound Module|Init 3D|Initializing (DirectInput|Animation|AI|additional|default)|GfxLoader|\s+Loaded glyphs|\s+Added font mapping|Input device added|IBM enhanced|Stream Engine|Font initialization|Network initialization|Lobby initialization|MovieSystem|Console initialization|Time initialization|Input initialization|AI initialization|Entity system|LiveCreate|Dynamic Response|Script System|Physics initialization|Using FreeType|Loading GDK|Quatmosphere|FMOD version|About to initialize FMOD|CryAudioImplFmod|Audio driver|-- |<Audio>|Sign in the default|Prefab templates|Ansel init|Destroying the splash|BinkVideoPlayer|Timestamp:|Active GPUs|NVAPI|Rendering Debug|- (Pix|NVidia|Debug|GPU|DRED)|Creating rendering device|Running machine spec|Windows 11|System language|Windows Directory|Local time is|\d+MB physical|\d+MB system|Available Windows drive|PageFile usage|Current display mode|CVar sys_PakPriority|No file ''package.txt''|GameDir:|User folder is|PluginManager|Is Steamdeck|Create Bugsplat|BugSplat initialized|Using Microsoft|Logging video adapters|getDSPBufferSize|Pak files)' 'hide' 0 'Engine init chatter'
Rl 'locale'      'kcd' '^(<Localization>|\[Localization\]|CharacterManager::OnFacialsPakChanged|<ThreadConfigInfo>)' 'hide' 0 'Localisation / thread config'
Rl 'platform'    'kcd' '^(\[(Pros|Steam|net|Plaion telemetry)\]|Plaion telemetry|\[Network Version\]|\[PlayerProfiles\]|\s+Profile \d)' 'hide' 0 'Platform / profile chatter'
Rl 'psoaux'      'kcd' '^PSO PRECACHING:|^Loading brush list|^Terrain: Waiting' 'hide' 0 'PSO / terrain streaming chatter'
Rl 'saveprop'    'kcd' '^SaveEntityProperties:' 'hide' 0 'Save entity properties'
Rl 'autocfg'     'kcd' '^<<<\[AutoCfg Loader\]>>>' 'hide' 0 'AutoCfgOnSpawn loader chatter'
Rl 'xpmon'       'kcd' '^\[\d+:\d+\]\[XPMonitor\]' 'hide' 0 'XP Monitor gain lines'
Rl 'heartbeat'   'kcd' '^\[arrow_arc\] heartbeat' 'hide' 0 'Arrow Arc heartbeat'
Rl 'modpaks'     'kcd' '^\[Mod\] Opening paks in ' 'hide' 0 'Mod pak opens'
Rl 'tablepatch'  'kcd' "^Table '(?<key>[^']+)' is patched by '[^']*__(?<owner>[A-Za-z0-9]+(?:_[A-Za-z0-9]+)*)', lines added: \d+" 'hide' 0 'Table patches applied (per mod)'
Rl 'locpatch'    'kcd' "^\[Mod\] Loading localization patch" 'hide' 0 'Localisation patches loaded'
Rl 'musicmat'    'kcd' '^music_\w+ has \d+ item\(s\)|^Sequence Music Engine' 'hide' 0 'Music tables'
Rl 'hwdump'      'kcd' '^\s*-{1,3} (Adapter index|Feature level|Displays connected|Suitable rendering device|System memory|Dedicated video memory|Windows \d|\(Authentic|\(Genuine|Proposed spec)|^\s*-{3} \d+ MB|^network hostname|^\s+ip:|^DLC list:' 'hide' 0 'Hardware dump in the boot header'
Rl 'cheatinit'   'kcd' '^Cheat:|^\[INFO\] Loaded KCD2 Cheat|^Enhanced GI initialized' 'hide' 0 'Mod start-up banners'
Rl 'cvarecho'    'kcd' '^\s{2,}\w+ = .* \[[A-Z_,]*\]\s*$' 'hide' 0 'CVar overrides echoed by mods'
Rl 'camp_dbg'    'kcd' '^\[DJB_Camping\] DEBUG:' 'hide' 0 'Camping mod debug'
Rl 'ls_dbg'      'kcd' '^LegendarySwords DEBUG:' 'hide' 0 'Legendary Swords debug'
Rl 'elemlisten'  'kcd' '^\[DEBUG\] (ElementListener|\d+: )' 'hide' 0 'UI element events'
# --- cheat mod's own indexing noise (counted; -ShowCheatNoise prints it)
Rl 'ch_dupid'    'kcd' '^\[WARN\] Skipping duplicated item id' 'hide' 1 'Cheat mod: duplicate item id while indexing (its own noise; the game applies the overrides)'
Rl 'ch_skip'     'kcd' '^\[WARN\] Skipping item: ' 'hide' 1 'Cheat mod: item skipped while indexing'
Rl 'ch_xmlfail'  'kcd' '^\[ERROR\] Failed to load data from XML database \[(?<key>[^\]]+)\]' 'hide' 1 'Cheat mod: "Failed to load data from XML database" (a file whose items were already indexed)'
Rl 'ch_xmlwarn'  'kcd' '^\[WARN\] Found \[\d+\] warnings while loading item XML databases' 'hide' 1 'Cheat mod: item XML warning total'
Rl 'ch_autoexec' 'kcd' '^\[WARN\] Autoexe file' 'hide' 1 'Cheat mod: autoexec.txt is empty'
Rl 'ch_bucket'   'kcd' '^\[ERROR\] No bucket for soul' 'hide' 1 'Cheat mod: "No bucket for soul"'
Rl 'ch_dbg'      'kcd' '^\[DEBUG\] (Cheat:|cheat_\w+\.lua loaded|Loading |Done loading|Finished loading|Returning loaded|Loaded \[|init\w+Database|Loading XML localization|Found |Version context)' 'hide' 0 'Cheat mod debug chatter'
Rl 'ch_info'     'kcd' '^\[INFO\] (cheat timer|Running Autoexec)' 'hide' 0 'Cheat mod timer chatter'
# --- config problems
Rl 'cfgknown'    'kcd' "^\[Error\] 'mods/autohidehud/mod\.cfg' ->" 'count' 1 'AutoHideHUD mod.cfg: lines the game cannot parse (documented as harmless)'
Rl 'cfgcomment'  'kcd' "^\[Error\] '(?<owner>[^']+)' -> invalid configuration line: '(?:#.*|\s*)'\s*$" 'count' 1 'Comment lines in a mod .cfg that the game cannot parse (harmless)'
Rl 'cfgbad'      'kcd' "^\[Error\] '(?<owner>[^']+)' -> invalid configuration line: '(?<key>.*)'" 'flood' 2 'Config line the game did not understand (the setting may not apply)'
Rl 'unkcmd'      'kcd' '^\[Warning\] Unknown command: (?<key>\S+)' 'flood' 2 'Console command not recognised (a cfg or mod calls a command this game version does not have)'
# --- scripts
Rl 'luaerr'      'kcd' '^\[(?<dt>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (?<owner>[^\s\]]+)\.ERROR\]\s*(?<key>.*)$' 'show' 3 'Lua script errors (owner = the mod that logged it)'
Rl 'luawarn'     'kcd' '^\[(?<dt>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (?<owner>[^\s\]]+)\.(?:WARN|WARNING)\]\s*(?<key>.*)$' 'show' 2 'Lua script warnings (owner = the mod that logged it)'
Rl 'luainfo'     'kcd' '^\[(?<dt>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (?<owner>[^\s\]]+)\.(?:INFO|DEBUG)\]\s*(?<key>.*)$' 'pass' 1 'Lua script log lines'
Rl 'luastack'    'kcd' '^LUA call stack' 'count' 2 'Engine printed a Lua call stack (usually follows a script error)'
Rl 'luagen'      'kcd' '(?i)(attempt to (call|index|perform|compare|concatenate|arithmetic)|bad argument #\d|\bstack traceback\b|\bLua error\b|lua (syntax|runtime) error|\.lua:\d+:)' 'show' 3 'Other script errors'
# --- engine / hardware
Rl 'gpu'         'kcd' '(?i)(device (was )?(removed|hung|lost)|DXGI_ERROR|GPU (crash|hang|fault|timeout)|out of (video )?memory|D3D12.*(error|fail)|\bTDR\b|Aftermath.*(crash|dump|fault))' 'show' 3 'GPU / D3D12 device problem (driver or hardware, not a mod)'
Rl 'oom'         'kcd' '(?i)(bad_alloc|allocation (failed|error)|cannot allocate|not enough memory)' 'show' 3 'Memory allocation failure'
Rl 'fatal'       'kcd' '(?i)(\bassert(ion)?\b.*fail|\bFATAL\b|unhandled exception|access violation|CrashHandler|fatal error)' 'show' 3 'Engine assertion / fatal error'
Rl 'savefail'    'kcd' '(?i)(save(game)? (failed|error)|failed to (save|load) (game|saved)|corrupt(ed)? (save|data|pak)|can''?t (open|read|write) (save|file))' 'show' 3 'Save / load failure'
Rl 'pakfail'     'kcd' '(?i)(\bpak\b.*(failed|corrupt|cannot open|error)|failed to open pak|bad (zip|pak))' 'show' 3 'Pak file problem'
Rl 'missfile'    'kcd' '(?i)(file not found|cannot open file|failed to open file|missing (texture|file|asset|resource)|unable to load)' 'flood' 2 'File / asset not found'
Rl 'itemfail'    'kcd' '^\[ERROR\] Failed: name=' 'show' 3 'Item add failed (cheat/give/Companion)'
# --- the mods you actually care about (counted, still printed)
Rl 'ppc'         'kcd' '^\[(?<owner>PerkProgression|PerkMigration|PerkConfig)\]' 'pass' 1 'Perk Progression Controller (KCSE plugin) lines'
Rl 'comp'        'kcd' '^\[(?<owner>QuestTravel|AICompanion|FollowMe|BlackBear)\]' 'pass' 1 'Companion / follower mods'

# ================= KCSE.log =================
Rl 'kc_scan'     'kcse' '^\s*(Mod folder:|Scanning:|Directory does not exist)' 'hide' 0 'KCSE: plugin folder scan'
Rl 'kc_hdr'      'kcse' '^KCSE v(?<key>\S+) \| (?<store>\w+) \| version (?<ver>\S+) \| build (?<build>\S+) \| ts (?<ts>\S+)' 'special' 1 'KCSE header'
Rl 'kc_found'    'kcse' '^\s*Found DLL: (?<key>.+?)\s*$' 'special' 0 'KCSE: DLL found'
Rl 'kc_reg'      'kcse' '^\s*Registered plugin: (?<key>.+?) v(?<ver>\S+) by (?<author>.+?)\s*$' 'special' 1 'KCSE: plugin registered'
Rl 'kc_total'    'kcse' '^Total plugins found: (?<key>\d+)' 'special' 1 'KCSE: total'
Rl 'kc_asi'      'kcse' '^Loaded ASI: (?<key>.+?)\s*$' 'special' 1 'KCSE: ASI loaded'
Rl 'kc_pload'    'kcse' '^Loaded (?<key>.+?)\s*$' 'special' 1 'KCSE: plugin loaded'
Rl 'kc_ready'    'kcse' '^Ready\.\s*$' 'special' 1 'KCSE ready'
Rl 'kc_evt'      'kcse' '^(?<key>PreDataLoaded|DataLoaded|LoadGame|SaveGame)\s*$' 'special' 1 'KCSE game event'
Rl 'kc_fail'     'kcse' '(?i)(fail|error|unsupported|mismatch|could not|cannot|not compatible|unknown (version|build)|missing|invalid|pattern not found|failed to hook|hooks? (failed|error))' 'show' 3 'KCSE problem (a plugin or ASI did not load, or the game build is not recognised)'

# ================= questnative.log (KCD2 Companion native layer) =================
Rl 'qn_start'    'qn' '^QuestNative (?<key>\S+) starting' 'special' 1 'Companion native'
Rl 'qn_http'     'qn' '^http: listening on (?<key>\S+)' 'special' 1 'Companion panel'
Rl 'qn_act'      'qn' '^overlay (?<key>(?!shown|hidden)[a-z_]+) (?<rest>\S.*)$' 'special' 1 'Companion action'
Rl 'qn_noise'    'qn' '^(WHGame\.dll at|gEnv at|hooked |DirectInput W hooked|overlay: (swap chain|window procedure|the game reads|mouse buttons|D3D12|language|ImGui))' 'hide' 0 'Companion native init chatter'

# ================= kcd2minimap.log =================
Rl 'mm_pak'      'mm' '^(pak: v|status: frames=)' 'hide' 0 'Minimap periodic state'
Rl 'mm_ui'       'mm' '^(menu (opened|closed)|letterbox|minimap (hidden|shown)|objective finished|pushed \d+)' 'hide' 0 'Minimap UI events'
Rl 'mm_guard'    'mm' '^crash guard armed' 'hide' 1 'Minimap crash guard armed (not a crash)'

# ================= tkhquang tools (HenrySenses / TPVCamera / CombatUse) =================
Rl 'tk_hook'     'tkh' '^(hook::|Signature health|input::Input: Starting|Async logging|Logger initialized|-{5,}|={5,})' 'hide' 0 'KCD2Tools init chatter'

# ================= DualSense listener =================
Rl 'ds_ev'       'ds' '^(\w+_event|\w+_footstep|listener_\w+|combat_audio|weapon_event|horse_event)\b' 'hide' 0 'DualSense per-sound events'
Rl 'ds_start'    'ds' '^automatic Bridge started' 'hide' 0 'DualSense bridge started'
Rl 'ds_loop'     'ds' '^automatic Bridge stopped exit_code=(?<key>-?\d+); restarting' 'flood' 2 'DualSense bridge keeps stopping and restarting (is DSX closed? pad on USB? port 29756 free?)'

# ================= kcd2db.log =================
Rl 'db_noise'    'db' '^(Loaded \d+ entries|Data saved|LuaDB loading completed|Registered LuaDB method|SQLite database opened|Found |Scanning|Version context|Game Started)' 'hide' 0 'LuaDB chatter'

# ================= kcd_launcher.log =================
Rl 'ln_start'    'launcher' '^Build info:\s*$' 'special' 1 'Launcher started'
Rl 'ln_ok'       'launcher' '^(?!.*(?i:error|fail|cannot|could not|exception|missing|not found)).*$' 'hide' 0 'Launcher chatter'

$script:RxErr  = New-Object System.Text.RegularExpressions.Regex('(?i)(^error\b|\[(error|err|fatal|crit\w*)\]|\b(fatal|exception|crash(ed)?|access violation|assertion|unhandled|stack overflow)\b|(?<![\w=])error[:!]|\bfail(ed|ure)?\b(?!\s*[=s_])|\babort(ed)?\b)', 'Compiled')
$script:RxWarn = New-Object System.Text.RegularExpressions.Regex('(?i)(^warn|\[warn\w*\]|\bwarning\b|\bdeprecated\b|\bnot found\b|\bmissing\b|\bcannot\b|\bcould not\b|\binvalid\b)', 'Compiled')
$script:RxKcse  = New-Object System.Text.RegularExpressions.Regex('^\[(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)(?:\.\d+)?\]\s+\[(\w+)\]\s?(.*)$', 'Compiled')
$script:RxQn    = New-Object System.Text.RegularExpressions.Regex('^(\d\d:\d\d:\d\d)(?:\.\d+)?\s+\[(\w+)\]\s?(.*)$', 'Compiled')
$script:RxMm    = New-Object System.Text.RegularExpressions.Regex('^\[t\+(\d+)ms\]\s?(.*)$', 'Compiled')
$script:RxTkh   = New-Object System.Text.RegularExpressions.Regex('^\[(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)(?:\.\d+)?\]\s+\[(\w+)\s*\]\s+::\s?(.*)$', 'Compiled')
$script:RxDs    = New-Object System.Text.RegularExpressions.Regex('^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)(?:\.\d+)?\s+(.*)$', 'Compiled')
$script:RxDb    = New-Object System.Text.RegularExpressions.Regex('^\[(\w+)\s*\]\s?(.*)$', 'Compiled')
$script:RxLuaTs = New-Object System.Text.RegularExpressions.Regex('^\[(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) ', 'Compiled')
$script:RxPlainTs = New-Object System.Text.RegularExpressions.Regex('^\[?(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d:\d\d)', 'Compiled')
$script:RxTag   = New-Object System.Text.RegularExpressions.Regex('^(?:\[(?:INFO|DEBUG|WARN|WARNING|ERROR|Info|Debug|Warn|Warning|Error)\]\s*)?\[(?<owner>[A-Za-z0-9_][A-Za-z0-9_ \.\-]{1,32})\]', 'Compiled')
$script:RxNorm  = New-Object System.Text.RegularExpressions.Regex('0x[0-9A-Fa-f]+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\d+(\.\d+)?', 'Compiled')
$script:RxScriptOwner = New-Object System.Text.RegularExpressions.Regex('(?i)scripts?/(?:mods/)?(?<owner>[A-Za-z0-9_\-]+)/', 'Compiled')
$script:TagSkip = @{ 'info'=1; 'debug'=1; 'warn'=1; 'warning'=1; 'error'=1 }

function Guess-Level([string]$m) {
    if ($script:RxErr.IsMatch($m)) { return 3 }
    if ($script:RxWarn.IsMatch($m)) { return 2 }
    return 1
}
function Norm-Sig([string]$m) { return $script:RxNorm.Replace($m, 'N') }
function Lvl-FromWord([string]$w) {
    switch ($w.ToLowerInvariant()) {
        'error' { return 3 } 'err' { return 3 } 'fatal' { return 3 } 'critical' { return 3 } 'crit' { return 3 }
        'warning' { return 2 } 'warn' { return 2 }
        'debug' { return 0 } 'trace' { return 0 } 'verbose' { return 0 }
        default { return 1 }
    }
}

# parse one raw line into pT (time) pL (level 0-3) pM (message) pDate; always returns $true
$script:pT = ''; $script:pL = 1; $script:pM = ''; $script:pDate = ''
function Parse-Line([object]$src, [string]$line) {
    $script:pDate = ''
    switch ($src.Kind) {
        'kcd' {
            $script:pM = $line
            $script:pT = ''
            if ($script:Live) { $script:pT = [datetime]::Now.ToString('HH:mm:ss') }
            $c0 = ''; if ($line.Length -gt 0) { $c0 = $line[0] }
            if ($c0 -eq '[') {
                $lt = $script:RxLuaTs.Match($line)
                if ($lt.Success) { $script:pDate = $lt.Groups[1].Value; $script:pT = $lt.Groups[2].Value }
                if     ($line.StartsWith('[ERROR]') -or $line.StartsWith('[Error]')) { $script:pL = 3; return $true }
                elseif ($line.StartsWith('[WARN]') -or $line.StartsWith('[Warning]') -or $line.StartsWith('[WARNING]')) { $script:pL = 2; return $true }
                elseif ($line.StartsWith('[DEBUG]')) { $script:pL = 0; return $true }
                elseif ($line.StartsWith('[INFO]')) { $script:pL = 1; return $true }
            }
            $g = Guess-Level $line
            if ($g -lt 3 -and $line.Length -gt 12) { $h = $line.Substring(0, [Math]::Min(48, $line.Length)); if ($h.IndexOf('DEBUG', [StringComparison]::Ordinal) -ge 0) { $g = 0 } }
            $script:pL = $g
            return $true
        }
        'kcse' {
            $m = $script:RxKcse.Match($line)
            if (-not $m.Success) { $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line; return $true }
            $script:pDate = $m.Groups[1].Value; $script:pT = $m.Groups[2].Value; $script:pM = $m.Groups[4].Value
            $script:pL = Lvl-FromWord $m.Groups[3].Value
            return $true
        }
        'qn' {
            $m = $script:RxQn.Match($line)
            if (-not $m.Success) { $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line; return $true }
            $script:pT = $m.Groups[1].Value; $script:pM = $m.Groups[3].Value
            $script:pL = Lvl-FromWord $m.Groups[2].Value
            return $true
        }
        'mm' {
            $m = $script:RxMm.Match($line)
            if (-not $m.Success) { $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line; return $true }
            $ms = [double]$m.Groups[1].Value
            if ($src.T0 -le 0) { $src.T0 = $ms }
            $sec = ($ms - $src.T0) / 1000.0
            if ($sec -lt 0) { $src.T0 = $ms; $sec = 0 }
            $script:pT = ('+{0:00}:{1:00}' -f [Math]::Floor($sec / 60), [Math]::Floor($sec % 60))
            $script:pM = $m.Groups[2].Value
            $script:pL = Guess-Level $script:pM
            return $true
        }
        'tkh' {
            $m = $script:RxTkh.Match($line)
            if (-not $m.Success) { $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line; return $true }
            $script:pDate = $m.Groups[1].Value; $script:pT = $m.Groups[2].Value; $script:pM = $m.Groups[4].Value
            $script:pL = Lvl-FromWord $m.Groups[3].Value
            return $true
        }
        'ds' {
            $m = $script:RxDs.Match($line)
            if (-not $m.Success) { $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line; return $true }
            $script:pDate = $m.Groups[1].Value; $script:pT = $m.Groups[2].Value; $script:pM = $m.Groups[3].Value
            $script:pL = Guess-Level $script:pM
            if ($script:pL -eq 3 -and $script:pM -match '^\w+_event') { $script:pL = 1 }
            return $true
        }
        'db' {
            $m = $script:RxDb.Match($line)
            if (-not $m.Success) { $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line; return $true }
            $script:pT = ''; $script:pM = $m.Groups[2].Value
            $script:pL = Lvl-FromWord $m.Groups[1].Value
            return $true
        }
        'launcher' {
            $script:pT = ''; $script:pM = $line; $script:pL = Guess-Level $line
            return $true
        }
        default {
            $m = $script:RxPlainTs.Match($line)
            if ($m.Success) { $script:pDate = $m.Groups[1].Value; $script:pT = $m.Groups[2].Value } else { $script:pT = '' }
            $script:pM = $line; $script:pL = Guess-Level $line
            return $true
        }
    }
}
#endregion

#region ---------------------------------------------------------------- emit, aggregate, lifecycle
$script:GameDir = ''; $script:ModsDir = ''; $script:BinDir = ''; $script:ExePath = ''; $script:SaveDir = ''; $script:StageDir = ''
$script:CfgPath = ''
$script:Order = New-Object System.Collections.Generic.List[string]
$script:OrderIdx = @{}        # exact (case-sensitive) -> index
$script:OrderIdxCI = @{}      # lower -> index
$script:OrderInfo = @{ Bom=$false; Crlf=$false; Dups=(New-Object System.Collections.Generic.List[string]); Blank=0; Spaces=(New-Object System.Collections.Generic.List[string]) }
$script:Manifests = $null     # folder name (lower) -> info
$script:ManifestByName = $null

function Load-Order {
    $script:Order.Clear(); $script:OrderIdx = @{}; $script:OrderIdxCI = @{}
    $script:OrderInfo = @{ Bom=$false; Crlf=$false; Dups=(New-Object System.Collections.Generic.List[string]); Blank=0; Spaces=(New-Object System.Collections.Generic.List[string]) }
    if (-not $script:CfgPath -or -not [System.IO.File]::Exists($script:CfgPath)) { return }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($script:CfgPath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $script:OrderInfo.Bom = $true }
        $text = $script:Utf8.GetString($bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        if ($text.Contains("`r`n")) { $script:OrderInfo.Crlf = $true }
        $i = 0
        foreach ($raw in $text.Split("`n")) {
            $l = $raw.TrimEnd("`r")
            if ($l.Trim() -eq '') { $script:OrderInfo.Blank++; continue }
            if ($l -ne $l.Trim()) { $script:OrderInfo.Spaces.Add($l) }
            $n = $l.Trim()
            if ($script:OrderIdx.ContainsKey($n)) { $script:OrderInfo.Dups.Add($n); continue }
            $script:Order.Add($n)
            $script:OrderIdx[$n] = $i
            $k = $n.ToLowerInvariant(); if (-not $script:OrderIdxCI.ContainsKey($k)) { $script:OrderIdxCI[$k] = $i }
            $i++
        }
    } catch { Dbg ('Load-Order: ' + $_.Exception.Message) }
}

function To-Dt([string]$d, [string]$t) {
    if (-not $d -or -not $t) { return $null }
    $r = [datetime]::MinValue
    if ([datetime]::TryParseExact(($d + ' ' + $t), 'yyyy-MM-dd HH:mm:ss', $script:Ci, 'None', [ref]$r)) { return $r }
    return $null
}
function Now-Dt { if ($script:Live) { return [datetime]::Now } return $null }

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
    if ($null -eq $dt -and $script:Live) { $dt = $now }
    $prev = $S.Phase
    $took = ''
    if ($S.PhaseDt -and $dt -and $dt -ge $S.PhaseDt) { $took = Fmt-Span ($dt - $S.PhaseDt) }
    elseif ($script:Live -and $S.Phase -ne 'Idle') { $took = Fmt-Span ($now - $S.PhaseSince) }
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
        $ov = $null
        $o = $m.Groups['owner']; if ($o.Success) { $ov = $o.Value }
        elseif ($id -like 'lua*') { $so = $script:RxScriptOwner.Match($msg); if ($so.Success) { $ov = $so.Groups['owner'].Value } }
        if ($ov) { if ($c.Owners.ContainsKey($ov)) { $c.Owners[$ov] = $c.Owners[$ov] + 1 } else { $c.Owners[$ov] = 1 } }
    }
    if ($c.Samples.Count -lt 5) { $c.Samples.Add($msg) }
    return $c
}

function Tag-Hit([string]$tag, [int]$lvl) {
    $T = $script:S.Tags
    if (-not $T.ContainsKey($tag)) { $T[$tag] = @{ N=0; E=0; W=0 } }
    $e = $T[$tag]; $e.N++
    if ($lvl -ge 3) { $e.E++ } elseif ($lvl -eq 2) { $e.W++ }
}

function Visible([int]$lvl, [string]$msg) {
    if ($lvl -lt $script:MinLvl) { return $false }
    if ($script:RxInclude -and -not $script:RxInclude.IsMatch($msg)) { return $false }
    if ($script:RxExclude -and $script:RxExclude.IsMatch($msg)) { return $false }
    return $true
}

# Compact a long Lua error line: "owner  file:line  <- fn < fn < fn"
$script:RxLuaFrame = New-Object System.Text.RegularExpressions.Regex("(?<f>[\w/\.\-]+\.lua): in function (?:'(?<fn>[^']+)'|<(?<loc>[^>]*)>)", 'Compiled')
$script:RxLuaHead  = New-Object System.Text.RegularExpressions.Regex('^(?<f>[\w/\.\-]+\.lua):(?<ln>\d+):\s*(?<rest>.*?)(?:\s*Please run with.*)?$', 'Compiled')
function Format-LuaErr([string]$owner, [string]$key) {
    $head = ''
    $idx = $key.IndexOf('stack traceback:', [StringComparison]::Ordinal)
    $pre = $key; if ($idx -ge 0) { $pre = $key.Substring(0, $idx) }
    $mh = $script:RxLuaHead.Match($pre.Trim())
    if ($mh.Success) { $head = $mh.Groups['f'].Value + ':' + $mh.Groups['ln'].Value + '  ' + $mh.Groups['rest'].Value.Trim() } else { $head = $pre.Trim() }
    $chain = New-Object System.Collections.Generic.List[string]
    if ($idx -ge 0) {
        foreach ($f in $script:RxLuaFrame.Matches($key.Substring($idx))) {
            $fn = $f.Groups['fn'].Value; if (-not $fn) { $fn = '<' + $f.Groups['loc'].Value + '>' }
            $file = ($f.Groups['f'].Value -split '/')[-1]
            $chain.Add($file + ':' + $fn)
            if ($chain.Count -ge 5) { break }
        }
    }
    $s = '[' + $owner + '] ' + $head
    if ($chain.Count -gt 0) { $s += '   <- ' + ($chain -join ' < ') }
    return $s
}

function Handle-Line([object]$src, [string]$line) {
    $S = $script:S
    if ($line.Length -eq 0) { return }
    if ($line[$line.Length - 1] -eq "`r") { $line = $line.Substring(0, $line.Length - 1); if ($line.Length -eq 0) { return } }
    $S.Lines++
    if ($src.Kind -eq 'kcd') { $script:RawTail.Add($line); if ($script:RawTail.Count -gt 300) { $script:RawTail.RemoveRange(0, 100) } }
    [void](Parse-Line $src $line)
    $t = $script:pT; $lvl = $script:pL; $msg = $script:pM
    $rule = $null; $m = $null
    if ($script:Rules.ContainsKey($src.Kind)) {
        foreach ($r in $script:Rules[$src.Kind]) { $mm = $r.Rx.Match($msg); if ($mm.Success) { $rule = $r; $m = $mm; break } }
    }
    # per-mod chatter tally (bracket tag at the start of a kcd.log line)
    if ($src.Kind -eq 'kcd' -and $line.Length -gt 3 -and $line[0] -eq '[') {
        $tm = $script:RxTag.Match($line)
        if ($tm.Success) { $tg = $tm.Groups['owner'].Value; if (-not $script:TagSkip.ContainsKey($tg.ToLowerInvariant())) { Tag-Hit $tg $lvl } }
    }

    if ($rule -ne $null -and $rule.Mode -eq 'special') { Handle-Special $src $rule $m $t $msg; return }

    if ($rule -ne $null) {
        $eff = $rule.Lvl; if ($eff -lt 0) { $eff = $lvl }
        $mode = $rule.Mode
        if ($ShowCheatNoise -and $rule.Id -like 'ch_*') { $mode = 'pass' }
        $c = Cat-Hit $rule.Id $rule.Title $eff $m $msg
        if ($c.First -eq '') { $c.First = $t }; $c.Last = $t
        if ($rule.Id -like 'lua*' -and $m.Groups['owner'].Success) { Tag-Hit $m.Groups['owner'].Value $eff; $S.LastLuaOwner = $m.Groups['owner'].Value }
        if ($eff -ge 3) { $S.Err++; $src.Err++ } elseif ($eff -eq 2) { $S.Warn++; $src.Warn++ }
        $disp = $msg
        if (($rule.Id -eq 'luaerr' -or $rule.Id -eq 'luawarn') -and $m.Groups['owner'].Success) { $disp = Format-LuaErr $m.Groups['owner'].Value $m.Groups['key'].Value }
        if ($eff -ge 3 -and ($mode -eq 'show' -or $mode -eq 'pass')) { Push-Recent $src $t $disp }
        if ($script:ShowRaw) { if (Visible 0 $msg) { Emit $src $t $eff $msg }; return }
        switch ($mode) {
            'hide'  { $S.Noise++; if ($script:ShowNoise -and (Visible 0 $msg)) { Emit $src $t 0 $msg }; return }
            'count' { return }
            'pass'  { if (Visible $eff $msg) { Emit $src $t $eff $disp }; return }
            'flood' {
                if ($c.Printed -lt $ShowRepeats) {
                    if (Visible $eff $msg) { $c.Printed++; Emit $src $t $eff $disp }
                } elseif (-not $c.Told) {
                    $c.Told = $true
                    if (Visible $eff $msg) { Notice ($script:G.up + ' "' + $c.Title + '": more of these are counted silently  (w = tallies)') 'gray' }
                }
                return
            }
            'show' {
                $sig = $rule.Id + '|' + (Norm-Sig $msg)
                $n = 1; if ($S.ErrSig.ContainsKey($sig)) { $n = $S.ErrSig[$sig] + 1 }; $S.ErrSig[$sig] = $n
                if (-not (Visible $eff $msg)) { return }
                if ($n -le $ShowRepeats) { Emit $src $t $eff $disp }
                elseif ($n -eq $ShowRepeats + 1) { Notice ($script:G.up + ' identical lines now counted silently (w = tallies)') 'gray' }
                return
            }
        }
        return
    }

    # no rule: the boot header is a wall of hardware/engine text; keep only what rules picked out
    if ($src.Kind -eq 'kcd' -and ($S.InHeader -or (-not $S.MenuSeen -and $lvl -le 1 -and -not $script:ShowRaw))) { $S.Noise++; if ($script:ShowNoise -and (Visible 0 $msg)) { Emit $src $t 0 $msg }; return }
    if ($lvl -ge 3) { $S.Err++; $src.Err++ } elseif ($lvl -eq 2) { $S.Warn++; $src.Warn++ }
    if ($lvl -ge 2) {
        $owner = $null; $tm = $null
        if ($src.Kind -eq 'kcd') { $tm = $script:RxTag.Match($msg); if ($tm.Success -and -not $script:TagSkip.ContainsKey($tm.Groups['owner'].Value.ToLowerInvariant())) { $owner = $tm.Groups['owner'].Value } }
        $cat = Cat-Hit ('other' + $lvl + ':' + $src.Kind) ($(if ($lvl -ge 3) { 'Other errors' } else { 'Other warnings' }) + ' (' + $src.Name + ')') $lvl $tm $msg
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
    if ($lvl -eq 0) { $S.Noise++ }
    if (Visible $lvl $msg) { Emit $src $t $lvl $msg }
}

function Push-Recent([object]$src, [string]$t, [string]$msg) {
    $S = $script:S
    $sig = $src.Tag + '|' + (Norm-Sig $msg)
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

# ---- begin a new run. $why = 'log' | 'launcher' | 'process'
function Begin-Run([string]$why, [object]$dt) {
    $S = $script:S
    if ($S.Phase -ne 'Idle' -and ($why -eq 'log' -and $S.LogSeen)) {
        Finish-Session 'new launch detected in the log'
        $S = $script:S
    }
    if ($why -eq 'launcher' -and $S.Phase -ne 'Idle') {
        if ($S.LogSeen) {
            # a launcher line that comes after kcd.log was already read is the same run, unless the game really restarted
            if (-not $script:Live) { return $false }
            if (([datetime]::Now - $S.LogSeenAt).TotalSeconds -lt 120) { return $false }
            Finish-Session 'new launch detected (launcher log)'; $S = $script:S
        } else { return $false }
    }
    if (-not $S.Start) { if ($dt) { $S.Start = $dt } else { $S.Start = [datetime]::Now } }
    return $true
}

function Handle-Special([object]$src, [object]$rule, [System.Text.RegularExpressions.Match]$m, [string]$t, [string]$msg) {
    $S = $script:S
    $id = $rule.Id
    if ($S.OrderPending -and @('usercfg', 'rendinit', 'startvid', 'luainit', 'mainmenu', 'loadsave', 'level', 'quit', 'evt') -contains $id) { $S.OrderPending = $false; Check-LoadOrder }
    switch ($id) {
        'logstart' {
            $dt = To-Dt $m.Groups['d'].Value $m.Groups['t'].Value
            [void](Begin-Run 'log' $dt)
            $S = $script:S
            $S.LogSeen = $true; $S.LogSeenAt = [datetime]::Now; $S.LogStart = $dt; $S.InHeader = $true
            if ($dt) { $S.Start = $dt }
            Load-Order
            if (-not $script:ArcDir -and $script:Live -and -not $NoArchive) { Arc-Open $(if ($dt) { $dt } else { [datetime]::Now }) }
            Write-Banner ('KCD2 START   ' + $(if ($dt) { $dt.ToString('yyyy-MM-dd HH:mm:ss') } else { [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss') }) + '   (mod_order.txt: ' + $script:Order.Count + ' entries)') 'bgreen'
            Set-Phase 'Booting (log opened)' $dt
        }
        'ln_start' {
            if (Begin-Run 'launcher' $null) {
                $S = $script:S
                if ($S.Phase -eq 'Idle') {
                    Load-Order
                    Write-Banner ('KCD2 LAUNCHER   ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) 'bgreen'
                    Set-Phase 'Launcher starting' $null
                }
            }
        }
        'builddesc' { $S.Build = $m.Groups['key'].Value }
        'cmdline' {
            $S.Cmdline = $m.Groups['key'].Value
            $S.DevMode = ($S.Cmdline -match '(?i)-devmode')
            if (-not $S.DevMode) { Notice '! started WITHOUT -devmode (the dev console and exec-based cfg commands are unavailable)' 'byellow' }
        }
        'exepath' { $S.Exe = $m.Groups['key'].Value }
        'ramtotal' { $S.RamMB = [int]$m.Groups['key'].Value }
        'gpuline' { if (-not $S.Gpu -and $m.Groups['key'].Value -notmatch 'Basic Render') { $S.Gpu = $m.Groups['key'].Value } }
        'vramline' { if ($S.VramMB -eq 0) { $S.VramMB = [int]$m.Groups['key'].Value } }
        'extver' { $S.ExtVer = $m.Groups['key'].Value }
        'steamid' { $S.SteamBuild = $m.Groups['key'].Value }
        'dlcline' { if ($m.Groups['act'].Value -eq 'Y') { $S.Dlc.Add($m.Groups['key'].Value) } }
        'dispver' {
            $S.GameVer = $m.Groups['key'].Value
            Write-Line ((Col 'gray') + ('          game ' + $S.GameVer + '  build ' + $S.ExtVer + '  (' + $S.Build + ')  GPU ' + $S.Gpu + ' ' + $S.VramMB + ' MB  RAM ' + $S.RamMB + ' MB  devmode ' + $(if ($S.DevMode) { 'on' } else { 'OFF' }))) $true
            Check-GameUpdate
        }
        'modsdir' { $S.InHeader = $false; Set-Phase 'Discovering mods' $null }
        'modsfound' { $S.ModsFound = [int]$m.Groups['key'].Value }
        'modnover' { [void]$S.Discovered.Add($m.Groups['key'].Value) }
        'modenable' {
            $k = $m.Groups['key'].Value
            $S.EnabledOrder.Add($k); [void]$S.EnabledSet.Add($k); [void]$S.Discovered.Add($k)
            if ($m.Groups['wc'].Success -and $m.Groups['wc'].Value) { $S.WildMods[$k] = $m.Groups['wc'].Value }
        }
        'moddisabled' {
            $k = $m.Groups['key'].Value
            $S.Disabled.Add($k + '  (' + $m.Groups['why'].Value.Trim() + ')')
            [void]$S.Discovered.Add($k)
            $c = Cat-Hit 'moddisabled' 'Mod DISABLED by the game (its manifest does not support this game version)' 3 $m $msg
            $S.Err++
            Push-Recent $src $t ('mod disabled: ' + $k)
            Emit $src $t 3 ('mod DISABLED by the game: ' + (Mod-Label $k) + ' - ' + $m.Groups['why'].Value.Trim())
        }
        'modsenabled' {
            $S.ModsEnabledN = [int]$m.Groups['key'].Value
            Set-Phase ('Mod order applied: ' + $S.ModsEnabledN + ' enabled') $null
            $S.OrderPending = $true      # the per-mod 'will be enabled' lines come AFTER this count line; check once they are all in
        }
        'modnotfound' {
            $k = $m.Groups['key'].Value
            $S.NotFound.Add($k); $S.Err++
            [void](Cat-Hit 'modnotfound' 'mod_order.txt entry with no matching mod' 3 $m $msg)
            $hint = Hint-NotFound $k
            Push-Recent $src $t ('mod_order.txt entry not found: ' + $k)
            Emit $src $t 3 ('mod_order.txt lists "' + $k + '" but the game found no mod with that id.' + $hint)
        }
        'badmodid' {
            $k = $m.Groups['key'].Value
            $S.BadModId.Add($k); $S.Warn++
            [void](Cat-Hit 'badmodid' 'Manifest ModId has characters other than lowercase letters and underscore' 2 $m $msg)
            Emit $src $t 2 ('invalid ModId in mods/' + $k + '/mod.manifest (only lowercase letters and underscore are accepted; it may not match its mod_order.txt entry)')
        }
        'basecfg' { Set-Phase 'Loading game config, paks and tables' $null }
        'usercfg' { Set-Phase 'Applying mod .cfg and user.cfg' $null }
        'rendinit' { Set-Phase 'Engine init (renderer, audio, input)' $null }
        'startvid' { Set-Phase 'Startup video' $null }
        'luainit' {
            $k = $m.Groups['key'].Value
            if (-not $S.LuaInitFirstSeen) { $S.LuaInitFirstSeen = $true; Set-Phase 'Mod Lua scripts initialising' $null }
            $S.LuaInit.Add($k); $S.LuaInitLast = $k
        }
        'mainmenu' { if ($S.Phase -notlike 'MAIN MENU*' -and $S.Phase -notlike 'IN GAME*' -and $S.Phase -notlike 'Loading*') { Set-Phase 'MAIN MENU (menu video playing)' $null } }
        'evt' { Handle-Event $src $m.Groups['key'].Value $t }
        'loadsave' {
            $name = $m.Groups['key'].Value -replace '^%USER%/saves/', ''
            $ld = @{ Save=$name; Type=$m.Groups['type'].Value; Ver=$m.Groups['ver'].Value; At=(Now-Dt); DoneAt=$null; Secs=$null }
            $S.Loads.Add($ld); $S.LoadOpen = $ld
            Set-Phase ('Loading save ' + $name) $null
            Notice ('save: ' + $name + '  (' + $m.Groups['type'].Value + ', written by game ' + $m.Groups['ver'].Value + ')') 'cyan'
            if ($S.ExtVer -and $m.Groups['ver'].Value -and $m.Groups['ver'].Value -ne $S.ExtVer) { Notice ('! this save was written by build ' + $m.Groups['ver'].Value + ' but the game is ' + $S.ExtVer + ' (normal after a patch; keep a backup of the save)') 'byellow' }
        }
        'savemodshdr' { $S.SaveModsCur = New-Object System.Collections.Generic.List[object]; $S.SaveModsExpect = [int]$m.Groups['key'].Value }
        'savemod' {
            if ($null -ne $S.SaveModsCur) {
                $S.SaveModsCur.Add(@{ Name=$m.Groups['key'].Value; Author=$m.Groups['author'].Value; Ver=$m.Groups['ver'].Value })
                if ($S.SaveModsCur.Count -ge $S.SaveModsExpect) { Finish-SaveMods }
            }
        }
        'level' {
            $k = $m.Groups['key'].Value
            $S.Levels.Add($k)
            Set-Phase ('Loading level ' + $k) $null
        }
        'pso' {
            $secs = [double]::Parse($m.Groups['secs'].Value, $script:Ci)
            $psoTxt = ('shader PSO precache: ' + (Fmt-N ([double]$m.Groups['key'].Value)) + ' ' + $m.Groups['kind'].Value.ToLowerInvariant() + ' PSOs in ' + ('{0:0.0}' -f $secs) + ' s')
            $S.Pso.Add($psoTxt)
            if ($secs -ge 1.0 -or $script:ShowRaw) { Emit $src $t 1 $psoTxt }
        }
        'saveent' {
            $n = [int]$m.Groups['key'].Value
            $S.SavesWritten++; $S.LastEntities = $n; if ($n -gt $S.MaxEntities) { $S.MaxEntities = $n }
            Write-Line ((Col 'green') + ('          ' + $script:G.dot + ' game saved (' + (Fmt-N $n) + ' entities)')) $true
        }
        'quit' {
            $code = [int]$m.Groups['code'].Value
            $S.QuitReason = $m.Groups['key'].Value; $S.QuitCode = $code
            $S.CleanExit = ($code -eq 0)
            $normal = ($S.QuitReason -match 'ExitGame')
            Set-Phase 'EXITING' $null
            if ($S.CleanExit -and $normal) { Write-Line ((Col 'green') + ('          ' + $script:G.dot + ' normal quit: ' + $S.QuitReason + ', exit code 0')) $true }
            else { Write-Line ((Col 'byellow') + ('          ! quit: ' + $S.QuitReason + ', exit code ' + $code)) $true }
        }
        'qn_start' { Notice ('Companion native layer ' + $m.Groups['key'].Value + ' started') 'gray' }
        'qn_http'  { Notice ('Companion panel: http://' + $m.Groups['key'].Value) 'gray' }
        'qn_act' {
            $S.Comp++
            $S.CompList.Add($t + ' ' + $m.Groups['key'].Value + ' ' + (Trunc $m.Groups['rest'].Value 120))
            [void](Cat-Hit 'companion' 'Companion actions (give / me / etc.)' 1 $m $msg)
            if ($S.CompList.Count -gt 200) { $S.CompList.RemoveAt(0) }
            if (Visible 1 $msg) { Emit $src $t 1 $msg }
        }
        default { Handle-Kcse $src $id $m $t $msg }
    }
}

function Handle-Event([object]$src, [string]$ev, [string]$t) {
    $S = $script:S
    switch ($ev) {
        'OnSystemStarted' {
            if (-not $S.MenuSeen) {
                $S.MenuSeen = $true
                if ($script:Live) { $S.MenuAt = [datetime]::Now }
                $boot = ''
                if ($S.LogStart -and $script:Live) { $boot = ' Boot took ' + (Fmt-Span ([datetime]::Now - $S.LogStart)) + '.' }
                Set-Phase 'MAIN MENU' $null
                Write-Line ((Col 'bgreen') + ('          ' + $script:G.star + ' Reached main menu.  Mods enabled: ' + $S.ModsEnabledN + ' of ' + $script:Order.Count + ' in mod_order.txt.' + $boot)) $true
            } else { Set-Phase 'MAIN MENU' $null }
        }
        'OnLoadingComplete' { Set-Phase 'World loaded (streaming in)' $null }
        'OnGameplayStarted' {
            $S.GameplayCount++
            $secs = $null
            if ($S.LoadOpen -and $S.LoadOpen.At -and $script:Live) { $secs = ([datetime]::Now - $S.LoadOpen.At).TotalSeconds; $S.LoadOpen.Secs = $secs; $S.LoadOpen.DoneAt = [datetime]::Now }
            $S.LoadOpen = $null
            $x = ''; if ($null -ne $secs) { $x = '  (load took ' + (Fmt-Span ([timespan]::FromSeconds($secs))) + ')' }
            Set-Phase 'IN GAME' $null
            Write-Line ((Col 'bgreen') + ('          ' + $script:G.star + ' Gameplay started' + $x)) $true
        }
        'OnQuickLoadingStart' {
            $ld = @{ Save='(quick load)'; Type='QuickLoad'; Ver=''; At=(Now-Dt); DoneAt=$null; Secs=$null }
            $S.Loads.Add($ld); $S.LoadOpen = $ld
            Set-Phase 'Loading save (quick load)' $null
        }
        'OnGamePause' { $S.Pauses++; $S.Noise++ }
        default { $S.Noise++ }
    }
}

# ---- KCSE.log handlers
function Handle-Kcse([object]$src, [string]$id, [System.Text.RegularExpressions.Match]$m, [string]$t, [string]$msg) {
    $S = $script:S; $K = $S.Kc
    $dt = To-Dt $script:pDate $t
    switch ($id) {
        'kc_hdr' {
            $K.Ver = $m.Groups['key'].Value; $K.GameVer = $m.Groups['ver'].Value; $K.Build = $m.Groups['build'].Value; $K.FirstTs = $dt
            Notice ('KCSE v' + $K.Ver + ' for game ' + $K.GameVer + ' build ' + $K.Build + ' (' + $m.Groups['store'].Value + ')') 'gray'
            if ($S.GameVer -and $K.GameVer -and $K.GameVer -ne $S.GameVer) { Notice ('! KCSE reports game version ' + $K.GameVer + ' but the game says ' + $S.GameVer) 'byellow' }
        }
        'kc_found' { $K.Found.Add($m.Groups['key'].Value) }
        'kc_reg'   { $K.Registered.Add($m.Groups['key'].Value + ' v' + $m.Groups['ver'].Value + ' by ' + $m.Groups['author'].Value) }
        'kc_total' { $K.Total = [int]$m.Groups['key'].Value }
        'kc_asi'   { $K.Asi.Add($m.Groups['key'].Value) }
        'kc_pload' { $K.Loaded.Add($m.Groups['key'].Value) }
        'kc_ready' {
            $K.Ready = $true; $K.ReadyTs = $dt
            $bad = New-Object System.Collections.Generic.List[string]
            if ($K.Found.Count -gt $K.Registered.Count) { $bad.Add(($K.Found.Count - $K.Registered.Count).ToString() + ' DLL(s) found but not registered') }
            if ($K.Registered.Count -gt $K.Loaded.Count) { $bad.Add(($K.Registered.Count - $K.Loaded.Count).ToString() + ' plugin(s) registered but not loaded') }
            $line = 'KCSE ready: ' + $K.Registered.Count + ' plugin(s) registered, ' + $K.Loaded.Count + ' loaded, ' + $K.Asi.Count + ' ASI(s) loaded'
            if ($bad.Count -gt 0) { Write-Line ((Col 'byellow') + ('          ! ' + $line + '  - ' + ($bad -join '; '))) $true }
            else { Write-Line ((Col 'green') + ('          ' + $script:G.dot + ' ' + $line)) $true }
            Check-Plugins
        }
        'kc_evt' {
            $ev = $m.Groups['key'].Value
            switch ($ev) {
                'PreDataLoaded' { $K.PreDataTs = $dt }
                'DataLoaded' {
                    $K.DataLoadedTs = $dt
                    if ($K.FirstTs -and $dt) { Notice ('KCSE: game data loaded ' + (Fmt-Span ($dt - $K.FirstTs)) + ' after launch') 'gray' }
                }
                'LoadGame' { $K.Events.Add($t + ' LoadGame') }
                'SaveGame' { $K.Events.Add($t + ' SaveGame'); [void](Cat-Hit 'kcsesave' 'KCSE: SaveGame events' 1 $null $msg) }
            }
            if ($K.Events.Count -gt 100) { $K.Events.RemoveAt(0) }
        }
    }
}

function Hint-NotFound([string]$k) {
    Build-ManifestIndex
    $kl = $k.ToLowerInvariant()
    if ($script:Manifests.ContainsKey($kl)) {
        $mi = $script:Manifests[$kl]
        if ($mi.Folder -cne $k) { return ('  A folder "' + $mi.Folder + '" exists: mod_order.txt is case-sensitive, fix the spelling.') }
        if ($mi.Id -and $mi.Id -cne $k) { return ('  The folder exists but its manifest modid is "' + $mi.Id + '".') }
        return '  The folder exists; check that it holds a valid mod.manifest.'
    }
    foreach ($mi in $script:Manifests.Values) { if ($mi.Id -and $mi.Id.ToLowerInvariant() -eq $kl) { return ('  Folder "' + $mi.Folder + '" has modid "' + $mi.Id + '".') } }
    return '  No folder or manifest with that name is in the Mods folder (removed mod still listed? Vortex deploy pending?).'
}

# ---- the enabled order the game reports vs mod_order.txt vs what is on disk
function Check-LoadOrder {
    $S = $script:S
    if ($script:Order.Count -eq 0) { return }
    $S.OrderDiff.Clear(); $S.NotLoaded.Clear()
    $enCI = @{}
    foreach ($e in $S.EnabledOrder) { $enCI[$e.ToLowerInvariant()] = $true }
    # 1. listed but not enabled
    foreach ($o in $script:Order) {
        if ($S.EnabledSet.Contains($o)) { continue }
        $why = 'not enabled'
        if ($enCI.ContainsKey($o.ToLowerInvariant())) { $why = 'enabled under a different capitalisation' }
        elseif ($S.NotFound -contains $o) { $why = 'not found (no mod with that id)' }
        else { foreach ($d in $S.Disabled) { if ($d.StartsWith($o + ' ') -or $d.StartsWith($o + "`t")) { $why = 'disabled by the game: ' + $d.Substring($o.Length).Trim() } } }
        $S.NotLoaded.Add($o + '  - ' + $why)
    }
    # 2. enabled but not listed (never expected)
    foreach ($e in $S.EnabledOrder) { if (-not $script:OrderIdx.ContainsKey($e)) { $S.OrderDiff.Add('"' + $e + '" was enabled but is not (exactly) in mod_order.txt') } }
    # 3. sequence: enabled order must follow the file order
    $last = -1; $lastName = ''
    foreach ($e in $S.EnabledOrder) {
        if ($script:OrderIdx.ContainsKey($e)) {
            $ix = $script:OrderIdx[$e]
            if ($ix -lt $last -and $S.OrderDiff.Count -lt 60) { $S.OrderDiff.Add('"' + $e + '" (file position ' + ($ix + 1) + ') was enabled after "' + $lastName + '" (file position ' + ($last + 1) + ')') }
            else { $last = $ix; $lastName = $e }
        }
    }
    $zz = ''
    if ($script:Order.Count -gt 0) {
        $zi = $script:Order.IndexOf('zzz_merge_patch')
        if ($zi -ge 0 -and $zi -ne $script:Order.Count - 1) { $zz = 'zzz_merge_patch is at position ' + ($zi + 1) + ' of ' + $script:Order.Count + ' - it must be LAST so its merged files win' }
    }
    if ($S.OrderDiff.Count -eq 0 -and $S.NotLoaded.Count -eq 0 -and -not $zz) {
        Write-Line ((Col 'green') + ('          ' + $script:G.dot + ' load order check: all ' + $S.EnabledOrder.Count + ' enabled mods follow mod_order.txt exactly.')) $true
    } else {
        if ($S.OrderDiff.Count -gt 0) { Write-Line ((Col 'byellow') + ('          ! load order check: ' + $S.OrderDiff.Count + ' difference(s) from mod_order.txt (m for the list)')) $true }
        if ($S.NotLoaded.Count -gt 0) { Write-Line ((Col 'byellow') + ('          ! ' + $S.NotLoaded.Count + ' mod_order.txt entr' + $(if ($S.NotLoaded.Count -eq 1) { 'y' } else { 'ies' }) + ' not enabled. First: ' + (($S.NotLoaded | Select-Object -First 3) -join ' | '))) $true }
        if ($zz) { Write-Line ((Col 'byellow') + ('          ! ' + $zz)) $true }
    }
    if ($script:ModsDir) {
        Build-ManifestIndex
        $un = New-Object System.Collections.Generic.List[string]
        foreach ($mi in $script:Manifests.Values) { if (-not $S.EnabledSet.Contains($mi.Folder) -and -not ($enCI.ContainsKey($mi.Folder.ToLowerInvariant()))) { $un.Add($mi.Folder) } }
        if ($un.Count -gt 0) { Write-Line ((Col 'byellow') + ('          ! ' + $un.Count + ' mod folder(s) on disk are not enabled: ' + (($un | Sort-Object | Select-Object -First 6) -join ', ') + $(if ($un.Count -gt 6) { ' ...' } else { '' }))) $true }
    }
}

# ---- "Mods used while saving": compare with what is installed / enabled now
function Norm-Name([string]$s) { return ([regex]::Replace($s.ToLowerInvariant(), '[^a-z0-9]', '')) }
function Finish-SaveMods {
    $S = $script:S
    $list = $S.SaveModsCur; $S.SaveModsCur = $null
    if ($null -eq $list) { return }
    $S.SaveModsLists.Add($list)
    $saveName = ''; if ($S.Loads.Count -gt 0) { $saveName = $S.Loads[$S.Loads.Count - 1].Save }
    Build-ManifestIndex
    if ($script:Manifests.Count -eq 0) {
        Notice ('save was made with ' + $list.Count + ' mods (mod folder not readable here, so no comparison)') 'gray'
        return
    }
    # installed + enabled names. A mod counts as active when its folder is enabled (log) or, without the log, present.
    $active = @{}
    foreach ($mi in $script:Manifests.Values) {
        $on = $true
        if ($S.EnabledSet.Count -gt 0) { $on = ($S.EnabledSet.Contains($mi.Folder) -or $S.EnabledSet.Contains($mi.Id)) }
        $nm = Norm-Name $mi.Name
        if ($nm) { $active[$nm] = @{ Mi=$mi; On=$on } }
        $nf = Norm-Name $mi.Folder; if ($nf -and -not $active.ContainsKey($nf)) { $active[$nf] = @{ Mi=$mi; On=$on } }
    }
    $missing = New-Object System.Collections.Generic.List[string]
    $off = New-Object System.Collections.Generic.List[string]
    $verdiff = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($sm in $list) {
        $nm = Norm-Name $sm.Name; $seen[$nm] = $true
        $hit = $null
        if ($active.ContainsKey($nm)) { $hit = $active[$nm] }
        elseif ($nm.Length -ge 6) { foreach ($kv in $active.GetEnumerator()) { $k2 = $kv.Key; if ($k2.Length -ge 6 -and ($k2.Contains($nm) -or $nm.Contains($k2))) { $hit = $kv.Value; break } } }
        if ($hit) { $seen[(Norm-Name $hit.Mi.Folder)] = $true; $seen[(Norm-Name $hit.Mi.Name)] = $true }
        if (-not $hit) { $missing.Add($sm.Name + $(if ($sm.Ver) { ' ' + $sm.Ver } else { '' })) }
        else {
            $a = $hit
            if (-not $a.On) { $off.Add($sm.Name) }
            elseif ($sm.Ver -and $a.Mi.Ver -and $sm.Ver -ne $a.Mi.Ver -and $sm.Ver -ne 'Unknown') { $verdiff.Add($sm.Name + ' ' + $sm.Ver + ' -> ' + $a.Mi.Ver) }
        }
    }
    $added = New-Object System.Collections.Generic.List[string]
    foreach ($mi in ($script:Manifests.Values | Sort-Object Folder)) {
        $on = $true; if ($S.EnabledSet.Count -gt 0) { $on = ($S.EnabledSet.Contains($mi.Folder) -or $S.EnabledSet.Contains($mi.Id)) }
        if (-not $on) { continue }
        $nm = Norm-Name $mi.Name; $nf = Norm-Name $mi.Folder
        if (-not $seen.ContainsKey($nm) -and -not $seen.ContainsKey($nf)) { $added.Add($(if ($mi.Name) { $mi.Name } else { $mi.Folder })) }
    }
    $S.SaveDiff.Clear()
    foreach ($x in $missing) { $S.SaveDiff.Add('in the save, NOT installed now: ' + $x) }
    foreach ($x in $off)     { $S.SaveDiff.Add('in the save, installed but NOT enabled now: ' + $x) }
    foreach ($x in $verdiff) { $S.SaveDiff.Add('version changed since the save: ' + $x) }
    foreach ($x in $added)   { $S.SaveDiff.Add('enabled now, not in the save (new since it was written): ' + $x) }
    $head = 'save ' + $saveName + ' was written with ' + $list.Count + ' mods'
    if ($S.SaveDiff.Count -eq 0) { Write-Line ((Col 'green') + ('          ' + $script:G.dot + ' ' + $head + '; the same mods (and versions) are active now.')) $true }
    else {
        Write-Line ((Col 'byellow') + ('          ! ' + $head + '; ' + $missing.Count + ' missing, ' + $off.Count + ' disabled, ' + $verdiff.Count + ' changed version, ' + $added.Count + ' new. Press m for the list.')) $true
        if ($missing.Count -gt 0) { Write-Line ((Col 'byellow') + ('            missing now: ' + (($missing | Select-Object -First 6) -join ', ') + $(if ($missing.Count -gt 6) { ' ...' } else { '' }))) $true }
        if ($missing.Count -gt 0 -or $off.Count -gt 0) { Write-Line ((Col 'gray') + '            (removing a mod that added items, scripts or quest data from a live save can break it; script-only mods are usually safe)') $true }
    }
}
#endregion

#region ---------------------------------------------------------------- game discovery, manifests, state, tailing
$script:Sources = New-Object System.Collections.Generic.List[object]
$script:SrcByPath = @{}
$script:LogDirOverride = ''
$script:LastScan = [datetime]::MinValue
$script:LastModLogScan = [datetime]::MinValue
$script:ModLogDirs = $null
$script:RunLogStart = $null
$script:ReadOnlyRun = $false      # report modes must not touch state.json
$script:NoUpdateCheck = $false
$script:PrimaryNames = @('kcd.log', 'kcd_launcher.log', 'kcse.log', 'questnative.log')

# A real KCD2 root has Bin\<flavour>\KingdomCome.exe (and Data / Mods / kcd.log). The exe alone is not enough to prove the root.
function Test-GameDir([string]$d) {
    if (-not $d) { return $false }
    try {
        if (-not [System.IO.Directory]::Exists($d)) { return $false }
        $bin = Ci-Child $d 'Bin'
        if (-not $bin) { return $false }
        foreach ($sd in [System.IO.Directory]::EnumerateDirectories($bin)) { if (Ci-Child $sd 'KingdomCome.exe') { return $true } }
        if ((Ci-Child $d 'kcd.log') -or (Ci-Child $d 'Mods')) { return $true }
    } catch { }
    return $false
}
function Resolve-GameRoot([string]$d) {
    if (-not $d) { return '' }
    $cur = $d
    for ($i = 0; $i -lt 5 -and $cur; $i++) {
        if (Test-GameDir $cur) { return $cur }
        $parent = ''
        try { $parent = Split-Path -Parent $cur } catch { $parent = '' }
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return ''
}

function Find-Game {
    if ($GamePath) { $r = Resolve-GameRoot $GamePath; if ($r) { return (Resolve-Path -LiteralPath $r).Path } else { return '' } }
    $cands = New-Object System.Collections.Generic.List[string]
    try { foreach ($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) { $pp = $null; try { $pp = $p.Path } catch { }; if ($pp) { $cands.Add((Split-Path -Parent $pp)) } } } catch { }
    if ($PSScriptRoot) { $cands.Add($PSScriptRoot) }
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
        foreach ($l in $libs) { $cands.Add((Join-Path $l 'steamapps\common\KingdomComeDeliverance2')) }
        $cands.Add('C:\Steam\steamapps\common\KingdomComeDeliverance2')
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -ne 'Fixed') { continue }
            $r = $d.RootDirectory.FullName
            foreach ($rel in @('Steam', 'SteamLibrary', 'Program Files (x86)\Steam', 'Games\Steam', 'Games\SteamLibrary')) { $cands.Add((Join-Path $r ($rel + '\steamapps\common\KingdomComeDeliverance2'))) }
        }
    }
    foreach ($c in $cands) { $r = Resolve-GameRoot $c; if ($r) { return $r } }
    return ''
}

function Set-GameDirs([string]$root) {
    $script:GameDir = $root
    $md = Ci-Child $root 'Mods'; if (-not $md) { $md = PJ $root 'Mods' }
    $script:ModsDir = $md
    $cp = Ci-Child $md 'mod_order.txt'; if (-not $cp) { $cp = PJ $md 'mod_order.txt' }
    $script:CfgPath = $cp
    $script:BinDir = ''
    $bin = Ci-Child $root 'Bin'
    if ($bin) {
        try { foreach ($sd in [System.IO.Directory]::EnumerateDirectories($bin)) { $e = Ci-Child $sd 'KingdomCome.exe'; if ($e) { $script:BinDir = $sd; $script:ExePath = $e; break } } } catch { }
        if (-not $script:BinDir) { $script:BinDir = PJ $bin 'Win64MasterMasterSteamPGO' }
    }
    # saves
    $sv = ''
    if ($SavePath) { $sv = $SavePath }
    else {
        $home1 = $env:USERPROFILE; if (-not $home1) { $home1 = [Environment]::GetFolderPath('UserProfile') }
        foreach ($c in @((PJ (PJ $home1 'Saved Games') 'kingdomcome2'), (PJ (PJ $home1 'Saved Games') 'KingdomCome2'))) { $x = $c; if ([System.IO.Directory]::Exists($x)) { $sv = $x; break } }
        if (-not $sv) {
            $sg = Ci-Child $home1 'Saved Games'
            if ($sg) { $x = Ci-Child $sg 'kingdomcome2'; if ($x) { $sv = $x } }
        }
    }
    $script:SaveDir = $sv
    # Vortex staging (for the mod_order.txt that Vortex would deploy)
    $st = ''
    if ($StagingPath) { $st = $StagingPath }
    else {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        if ($docs) { $x = PJ $docs 'KCD2 Mods'; if ([System.IO.Directory]::Exists($x)) { $st = $x } }
        if (-not $st) {
            foreach ($j in @((Ci-Child $md 'vortex.deployment.kingdomcomedeliverance2-mod.json'), (Ci-Child $root 'vortex.deployment.kingdomcomedeliverance2-root.json'))) {
                if (-not $j) { continue }
                try { $o = (Get-Content -LiteralPath $j -Raw -ErrorAction Stop) | ConvertFrom-Json; $sp = Jget $o 'stagingPath' ''; if ($sp -and [System.IO.Directory]::Exists($sp)) { $st = $sp; break } } catch { }
            }
        }
    }
    $script:StageDir = $st
}

# ---------------- mod manifests
function Read-Manifest([string]$dir) {
    $mf = Ci-Child $dir 'mod.manifest'
    $folder = [System.IO.Path]::GetFileName($dir)
    $info = @{ Folder=$folder; Id=''; Name=''; Ver=''; Author=''; Supports=(New-Object System.Collections.Generic.List[string]); HasManifest=$false; Paks=0; Plugins=(New-Object System.Collections.Generic.List[string]); Dir=$dir }
    if ($mf) {
        $info.HasManifest = $true
        try {
            $x = [System.IO.File]::ReadAllText($mf)
            $g = { param($tag) $mm = [regex]::Match($x, '(?is)<' + $tag + '\b[^>]*>\s*(.*?)\s*</' + $tag + '>'); if ($mm.Success) { return $mm.Groups[1].Value.Trim() } else { return '' } }
            $info.Id = & $g 'modid'; $info.Name = & $g 'name'; $info.Ver = & $g 'version'; $info.Author = & $g 'author'
            foreach ($mm in [regex]::Matches($x, '(?is)<(?:kcd_version|game_version|version_id)\b[^>]*>\s*([^<]+?)\s*</')) { $info.Supports.Add($mm.Groups[1].Value) }
        } catch { }
    }
    try {
        $dd = Ci-Child $dir 'Data'
        if ($dd) { $info.Paks = @([System.IO.Directory]::EnumerateFiles($dd, '*.pak')).Count }
        $kp = Ci-Child $dir 'KCSE'
        if ($kp) { $pp = Ci-Child $kp 'Plugins'; if ($pp) { foreach ($f in [System.IO.Directory]::EnumerateFiles($pp, '*.dll')) { $info.Plugins.Add([System.IO.Path]::GetFileName($f)) } } }
    } catch { }
    return $info
}
function Build-ManifestIndex {
    if ($null -ne $script:Manifests) { return }
    $idx = @{}
    if ($script:ModsDir -and [System.IO.Directory]::Exists($script:ModsDir)) {
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($script:ModsDir)) {
                $fn = [System.IO.Path]::GetFileName($d)
                $mi = Read-Manifest $d
                $idx[$fn.ToLowerInvariant()] = $mi
            }
        } catch { }
    }
    $script:Manifests = $idx
}
function Reset-ManifestIndex { $script:Manifests = $null }
function Mod-Label([string]$id) {
    Build-ManifestIndex
    $k = $id.ToLowerInvariant()
    if ($script:Manifests.ContainsKey($k)) {
        $mi = $script:Manifests[$k]
        $s = $id
        if ($mi.Name -and $mi.Name.ToLowerInvariant() -ne $k) { $s += ' (' + $mi.Name; if ($mi.Ver) { $s += ' ' + $mi.Ver }; $s += ')' }
        elseif ($mi.Ver) { $s += ' (' + $mi.Ver + ')' }
        return $s
    }
    return $id
}

# ---------------- persistent state (last build, last run) -- lives in the console's own data folder
function State-Path { return (PJ $OutDir 'state.json') }
function Get-State {
    $p = State-Path
    $o = $null
    try { if ([System.IO.File]::Exists($p)) { $o = (Get-Content -LiteralPath $p -Raw -ErrorAction Stop) | ConvertFrom-Json } } catch { }
    return $o
}
function Save-State([hashtable]$kv) {
    if ($script:ReadOnlyRun) { return }
    try {
        $cur = Get-State
        $h = [ordered]@{}
        if ($cur) { foreach ($p in $cur.PSObject.Properties) { $h[$p.Name] = $p.Value } }
        foreach ($k in $kv.Keys) { $h[$k] = $kv[$k] }
        [System.IO.File]::WriteAllText((State-Path), ($h | ConvertTo-Json -Depth 4), $script:Utf8)
    } catch { Dbg ('Save-State: ' + $_.Exception.Message) }
}

function Get-WhgameStamp {
    $r = @{ Size=0; Time=''; Exe=0; ExeTime='' }
    try {
        if ($script:BinDir) {
            $w = Ci-Child $script:BinDir 'WHGame.dll'
            if ($w) { $fi = New-Object System.IO.FileInfo($w); $r.Size = $fi.Length; $r.Time = $fi.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') }
            if ($script:ExePath) { $fi2 = New-Object System.IO.FileInfo($script:ExePath); $r.Exe = $fi2.Length; $r.ExeTime = $fi2.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') }
        }
    } catch { }
    return $r
}

# game updated since the last run? KCSE plugins and the ASIs depend on the executable layout, so they break first.
function Check-GameUpdate {
    if ($script:NoUpdateCheck) { return }
    $S = $script:S
    $st = Get-State
    $stamp = Get-WhgameStamp
    $prevExt = [string](Jget $st 'ExtVer' '')
    $prevSz = [double](Jget $st 'WhgameSize' 0)
    $prevTime = [string](Jget $st 'WhgameTime' '')
    $changed = New-Object System.Collections.Generic.List[string]
    if ($prevExt -and $S.ExtVer -and $prevExt -ne $S.ExtVer) { $changed.Add('build ' + $prevExt + ' -> ' + $S.ExtVer) }
    if ($prevSz -gt 0 -and $stamp.Size -gt 0 -and ([double]$stamp.Size -ne $prevSz -or ($prevTime -and $stamp.Time -and $prevTime -ne $stamp.Time))) { $changed.Add('WHGame.dll changed (' + (Fmt-Bytes $prevSz) + ' ' + $prevTime + ' -> ' + (Fmt-Bytes $stamp.Size) + ' ' + $stamp.Time + ')') }
    if ($changed.Count -gt 0) {
        $S.Milestones.Add('GAME UPDATED: ' + ($changed -join '; '))
        Write-Line ((Col 'bred') + ('          ! GAME UPDATED since the last run: ' + ($changed -join '; '))) $true
        Write-Line ((Col 'byellow') + '            KCSE plugins (LuaUtils, MCM, PTF Extender, Horse Route Follow, Perk Progression) and the .asi files (Minimap, questnative, kcd2db, TPVCamera ...) depend on the exe: expect them to fail first. Watch the KCSE lines below.') $true
    }
    Save-State @{ ExtVer=$S.ExtVer; Build=$S.Build; GameVer=$S.GameVer; WhgameSize=$stamp.Size; WhgameTime=$stamp.Time; SeenAt=[datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss') }
}

function Get-PluginDisk {
    $r = @{ Dlls=(New-Object System.Collections.Generic.List[object]); Asi=(New-Object System.Collections.Generic.List[string]) }
    try {
        Build-ManifestIndex
        foreach ($mi in $script:Manifests.Values) { foreach ($p in $mi.Plugins) { $r.Dlls.Add(@{ Mod=$mi.Folder; File=$p }) } }
        if ($script:BinDir -and [System.IO.Directory]::Exists($script:BinDir)) { foreach ($f in [System.IO.Directory]::EnumerateFiles($script:BinDir, '*.asi')) { $r.Asi.Add([System.IO.Path]::GetFileName($f)) } }
        if ($script:GameDir) {
            $kp = Ci-Child $script:GameDir 'KCSE'
            if ($kp) { $pp = Ci-Child $kp 'Plugins'; if ($pp) { foreach ($f in [System.IO.Directory]::EnumerateFiles($pp, '*.dll')) { $r.Dlls.Add(@{ Mod='(KCSE\Plugins)'; File=[System.IO.Path]::GetFileName($f) }) } } }
        }
    } catch { }
    return $r
}

# at "KCSE Ready": compare what is on disk with what KCSE actually loaded
function Check-Plugins {
    $S = $script:S; $K = $S.Kc
    if (-not $script:GameDir) { return }
    $d = Get-PluginDisk
    $foundCI = @{}; foreach ($x in $K.Found) { $foundCI[$x.ToLowerInvariant()] = $true }
    $asiCI = @{}; foreach ($x in $K.Asi) { $asiCI[$x.ToLowerInvariant()] = $true }
    $probs = New-Object System.Collections.Generic.List[string]
    foreach ($a in $d.Asi) { if (-not $asiCI.ContainsKey($a.ToLowerInvariant())) { $probs.Add('ASI on disk but not loaded by KCSE: ' + $a) } }
    foreach ($p in $d.Dlls) { if (-not $foundCI.ContainsKey($p.File.ToLowerInvariant())) { $probs.Add('plugin DLL on disk but KCSE did not list it: ' + $p.File + ' (' + $p.Mod + ')') } }
    if ($S.EnabledSet.Count -gt 0) {
        foreach ($p in $d.Dlls) {
            if ($p.Mod -notlike '(*' -and -not $S.EnabledSet.Contains($p.Mod)) {
                if ($foundCI.ContainsKey($p.File.ToLowerInvariant())) { $probs.Add('plugin ' + $p.File + ' sits in mod "' + $p.Mod + '" which the game does not count as enabled, but KCSE found and loaded it anyway (KCSE scans every mod folder)') }
                else { $probs.Add('plugin ' + $p.File + ' sits in mod "' + $p.Mod + '" which is NOT enabled; KCSE scans every mod folder, so it may still load') }
            }
        }
    }
    foreach ($x in $probs) { Write-Line ((Col 'byellow') + ('            ! ' + $x)) $true; [void]$S.Milestones.Add('plugin: ' + $x) }
}

# ---------------- log sources
function Get-Tag([string]$file) {
    $n = [System.IO.Path]::GetFileName($file); $l = $n.ToLowerInvariant()
    if ($l -eq 'kcd.log')              { return @{ Kind='kcd';      Tag='GAME'; Color='white' } }
    if ($l -eq 'kcd_launcher.log')     { return @{ Kind='launcher'; Tag='LNCH'; Color='gray' } }
    if ($l -eq 'kcse.log')             { return @{ Kind='kcse';     Tag='KCSE'; Color='cyan' } }
    if ($l -eq 'questnative.log')      { return @{ Kind='qn';       Tag='COMP'; Color='green' } }
    if ($l -eq 'kcd2minimap.log')      { return @{ Kind='mm';       Tag='MMAP'; Color='mag' } }
    if ($l -eq 'kcd2db.log')           { return @{ Kind='db';       Tag='DB';   Color='blue' } }
    if ($l -eq 'kcd2_henrysenses.log') { return @{ Kind='tkh';      Tag='SENS'; Color='yellow' } }
    if ($l -eq 'kcd2_tpvcamera.log')   { return @{ Kind='tkh';      Tag='TPV';  Color='yellow' } }
    if ($l -eq 'kcd2_combatuse.log')   { return @{ Kind='tkh';      Tag='CMBT'; Color='yellow' } }
    if ($l -like 'kcd2dslistener*' -or $l -like 'ds5horsefeedback*') { return @{ Kind='ds'; Tag='DS'; Color='mag' } }
    $t = ($n -replace '\.(log|txt)$', '' -replace '[^A-Za-z0-9]', '')
    if ($t.Length -gt 4) { $t = $t.Substring(0, 4) }
    return @{ Kind='plain'; Tag=$t.ToUpperInvariant(); Color='blue' }
}

function Get-RunLogStart {
    if ($null -ne $script:RunLogStart) { return $script:RunLogStart }
    $script:RunLogStart = [datetime]::MinValue
    try {
        $dirs = @($script:LogDirOverride, $script:GameDir)
        foreach ($d in $dirs) {
            if (-not $d) { continue }
            $f = Ci-Child $d 'kcd.log'
            if (-not $f) { continue }
            $sr = New-Object System.IO.StreamReader((New-Object System.IO.FileStream($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))))
            try {
                for ($i = 0; $i -lt 12; $i++) {
                    $l = $sr.ReadLine(); if ($null -eq $l) { break }
                    $mm = [regex]::Match($l, 'Log Started at (\d{4}-\d\d-\d\d)\s+(\d\d:\d\d:\d\d)')
                    if ($mm.Success) { $dt = To-Dt $mm.Groups[1].Value $mm.Groups[2].Value; if ($dt) { $script:RunLogStart = $dt }; break }
                }
            } finally { $sr.Dispose() }
            break
        }
    } catch { }
    return $script:RunLogStart
}

function Add-Source([string]$path, [bool]$stale) {
    if ($script:SrcByPath.ContainsKey($path)) { return }
    $i = Get-Tag $path
    $len = [long]0; try { $len = (New-Object System.IO.FileInfo($path)).Length } catch { }
    $s = [pscustomobject]@{ Name=[System.IO.Path]::GetFileName($path); Path=$path; Kind=$i.Kind; Tag=$i.Tag; Color=$i.Color; Pos=[long]0; Head=''; Rest=$null; Bytes=[long]0; Lines=0; Resets=0; Seen=$false; Err=0; Warn=0; T0=[double]0; Stale=$false; SkipFirst=$false; Big=$false }
    if ($stale) { $s.Pos = $len; $s.Stale = $true }
    elseif ($len -gt 6MB) { $s.Pos = $len - 1MB; $s.SkipFirst = $true; $s.Big = $true }
    $script:Sources.Add($s); $script:SrcByPath[$path] = $s
}

function Add-LogDir([string]$d, [bool]$allowStale) {
    if (-not $d -or -not [System.IO.Directory]::Exists($d)) { return }
    $ref = Get-RunLogStart
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($d, '*.log')) {
            if ($script:SrcByPath.ContainsKey($f)) { continue }
            $n = [System.IO.Path]::GetFileName($f).ToLowerInvariant()
            $stale = $false
            if ($allowStale -and $script:PrimaryNames -notcontains $n -and -not $script:LogDirOverride) {
                if ($ref -gt [datetime]::MinValue) { $stale = ([System.IO.File]::GetLastWriteTime($f) -lt $ref.AddMinutes(-5)) }
            }
            Add-Source $f $stale
        }
    } catch { }
}

function Scan-Sources {
    $now = [datetime]::Now
    if ($script:LogDirOverride) { Add-LogDir $script:LogDirOverride $false }
    elseif ($script:GameDir) {
        Add-LogDir $script:GameDir $true
        $kl = Ci-Child $script:GameDir 'KCSE'; if ($kl) { $kl2 = Ci-Child $kl 'logs'; if ($kl2) { Add-LogDir $kl2 $true } }
        if ($script:BinDir) {
            Add-LogDir $script:BinDir $true
            $dst = Ci-Child $script:BinDir 'KCD2DS_Tools'; if ($dst) { Add-LogDir $dst $true }
        }
        # logs that mods write inside their own folders (re-enumerated rarely)
        if ($script:ModsDir -and [System.IO.Directory]::Exists($script:ModsDir)) {
            if ($null -eq $script:ModLogDirs -or ($now - $script:LastModLogScan).TotalSeconds -gt 20) {
                $script:LastModLogScan = $now
                $l = New-Object System.Collections.Generic.List[string]
                try {
                    foreach ($d in [System.IO.Directory]::EnumerateDirectories($script:ModsDir)) {
                        $l.Add($d)
                        $ld = Ci-Child $d 'logs'; if ($ld -and [System.IO.Directory]::Exists($ld)) { $l.Add($ld) }
                    }
                } catch { }
                $script:ModLogDirs = $l
            }
            foreach ($d in $script:ModLogDirs) { Add-LogDir $d $true }
        }
    }
    foreach ($x in $ExtraLog) { if ($x -and (Test-Path -LiteralPath $x)) { Add-Source (Resolve-Path -LiteralPath $x).Path $false } }
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
        if ($src.Seen -and ($len -lt $src.Pos -or ($src.Pos -ge 48 -and $hn -ge 48 -and $src.Head -and $head -ne $src.Head))) { $reset = $true }
        if ($reset) {
            $src.Pos = 0; $src.Rest = $null; $src.Resets++; $src.Stale = $false; $src.SkipFirst = $false; $src.T0 = [double]0
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
            if ($src.SkipFirst) {
                # started in the middle of a big file: drop the partial first line
                $nl = $text.IndexOf("`n")
                if ($nl -ge 0) { $text = $text.Substring($nl + 1) } else { $text = '' }
                $src.SkipFirst = $false
            }
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

#region ---------------------------------------------------------------- archive, process, hardware, saves, events, dumps, post-mortem
$script:ArcDir = $null
$script:ArcOpenedAt = [datetime]::MinValue
$script:ArcSnap = @{}
$script:LastSnap = [datetime]::MinValue
$script:Proc = $null
$script:BsInfo = $null
$script:ProcInfo = @{ Pid=0; Start=$null; Mem=0.0; Priv=0.0; Peak=0.0; PeakPriv=0.0; Responding=$true; NotRespSince=$null; Threads=0; Handles=0; Exit=$null; ExitCode=$null; PMDue=$null; NativeCode=$null; NRTold=$false; Uptime=$null; LastExitPid=0 }
$script:RawTail = New-Object System.Collections.Generic.List[string]
$script:Hw = @{ Samples=(New-Object System.Collections.Generic.List[object]); Last=[datetime]::MinValue; LastSys=[datetime]::MinValue; Smi=$null; SmiChecked=$false; PeakVram=0.0; VramTotal=0.0; PeakTemp=0.0; MinFree=[double]::MaxValue; FreeNow=0.0; TotalNow=0.0; Vram=0.0; Temp=0.0; Util=0.0; Watt=0.0; WarnAt=@{}; PrivStart=0.0; PrivStartAt=$null; InGameAt=$null; Timeline=(New-Object System.Collections.Generic.List[object]); TlLast=[datetime]::MinValue }

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
    if ($script:ArcDir -and ([datetime]::Now - $script:ArcOpenedAt).TotalSeconds -lt 30) { return }
    try {
        $root = PJ $OutDir 'sessions'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $dir = PJ $root ($when.ToString('yyyy-MM-dd_HH-mm-ss'))
        if ([System.IO.Directory]::Exists($dir)) { $dir = $dir + '_' + [datetime]::Now.ToString('ss') }
        New-Item -ItemType Directory -Force -Path (PJ $dir 'logs') | Out-Null
        $script:ArcDir = $dir; $script:ArcSnap = @{}; $script:ArcOpenedAt = [datetime]::Now
        if ($script:Transcript) { try { $script:Transcript.Dispose() } catch { } }
        $fs = New-Object System.IO.FileStream((PJ $dir 'console.txt'), [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $script:Transcript = New-Object System.IO.StreamWriter($fs, $script:Utf8)
        $script:Transcript.AutoFlush = $true
        # what the load order and the mods looked like for this run
        if ($script:CfgPath -and [System.IO.File]::Exists($script:CfgPath)) { Copy-Item -LiteralPath $script:CfgPath -Destination (PJ $dir 'mod_order.txt') -Force -ErrorAction SilentlyContinue }
        foreach ($cn in @('user.cfg', 'system.cfg')) {
            $cf = Ci-Child $script:GameDir $cn
            if ($cf) { try { Copy-Item -LiteralPath $cf -Destination (PJ $dir $cn) -Force -ErrorAction SilentlyContinue } catch { } }
        }
        try {
            Reset-ManifestIndex; Build-ManifestIndex
            $ml = New-Object System.Collections.Generic.List[string]
            $ml.Add('folder|modid|name|version|author|supports')
            foreach ($mi in ($script:Manifests.Values | Sort-Object Folder)) { $ml.Add(($mi.Folder + '|' + $mi.Id + '|' + $mi.Name + '|' + $mi.Ver + '|' + $mi.Author + '|' + ($mi.Supports -join ','))) }
            [System.IO.File]::WriteAllLines((PJ $dir 'mods_snapshot.txt'), [string[]]$ml, $script:Utf8)
        } catch { }
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
            if ($s.Stale -and -not $force) { continue }
            $sig = '' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
            if (-not $force -and $script:ArcSnap.ContainsKey($s.Path) -and $script:ArcSnap[$s.Path] -eq $sig) { continue }
            # very big, long-stale chatter logs (the DualSense listener) are not worth copying whole: keep the last 4 MB
            $dest = PJ (PJ $script:ArcDir 'logs') $s.Name
            $in = New-Object System.IO.FileStream($s.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try {
                if ($in.Length -gt 24MB) { $in.Seek($in.Length - 4MB, 'Begin') | Out-Null }
                $out = New-Object System.IO.FileStream($dest, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            } finally { $in.Dispose() }
            $script:ArcSnap[$s.Path] = $sig; $n++
        } catch { Dbg ('Arc-Snapshot ' + $s.Name + ': ' + $_.Exception.Message) }
    }
    $script:LastSnap = [datetime]::Now
    return $n
}

# ---------------- process watching
function Get-ProcMem($p) { try { return [double]$p.WorkingSet64 } catch { return 0.0 } }
function Get-ProcPriv($p) { try { return [double]$p.PrivateMemorySize64 } catch { return 0.0 } }

function Proc-Poll {
    $pi = $script:ProcInfo
    $cur = $null
    try { $cur = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) | Select-Object -First 1 } catch { }
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
    if ($cur -ne $null -and $script:Proc -eq $null) {
        # After a crash Windows keeps the dead process listed while anything still holds a handle to it (BugSplat, Steam, us).
        # Treating that corpse as a new launch reset the peaks and hardware samples and made a second, empty session folder.
        $corpse = $false
        try { if ($pi.LastExitPid -and $cur.Id -eq $pi.LastExitPid) { $corpse = $true } } catch { }
        if (-not $corpse) { try { if ($cur.HasExited) { $corpse = $true } } catch { } }
        if ($corpse) { try { $cur.Dispose() } catch { } } else { Proc-Started $cur }
    }
    if ($script:Proc -ne $null) {
        try {
            $script:Proc.Refresh()
            $pi.Mem = Get-ProcMem $script:Proc
            $pi.Priv = Get-ProcPriv $script:Proc
            if ($pi.Mem -gt $pi.Peak) { $pi.Peak = $pi.Mem }
            if ($pi.Priv -gt $pi.PeakPriv) { $pi.PeakPriv = $pi.Priv }
            try { $pi.Threads = $script:Proc.Threads.Count; $pi.Handles = $script:Proc.HandleCount } catch { }
            $resp = $true; try { $resp = $script:Proc.Responding } catch { }
            if (-not $resp) {
                if ($null -eq $pi.NotRespSince) { $pi.NotRespSince = [datetime]::Now }
                elseif (-not $pi.NRTold -and ([datetime]::Now - $pi.NotRespSince).TotalSeconds -ge 15) {
                    $pi.NRTold = $true
                    $why = 'game window is frozen'
                    if ($script:S.Phase -like 'Loading*' -or $script:S.Phase -like 'Booting*' -or $script:S.Phase -like 'Mod*' -or $script:S.Phase -like 'Engine*' -or $script:S.Phase -like 'Startup*' -or $script:S.Phase -like 'World*') { $why = 'normal for short spells while a save or level is loading - worry only if it lasts minutes and the log stops moving' }
                    Write-Line ((Col 'byellow') + ('          ! KingdomCome not responding for ' + (Fmt-Span ([datetime]::Now - $pi.NotRespSince)) + ' (' + $why + ')')) $true
                    Do-Beep 3
                }
            } else {
                if ($pi.NRTold) { Write-Line ((Col 'green') + ('          ' + $script:G.dot + ' KingdomCome responding again after ' + (Fmt-Span ([datetime]::Now - $pi.NotRespSince)))) $true }
                $pi.NotRespSince = $null; $pi.NRTold = $false
            }
            $pi.Responding = $resp
        } catch { }
    }
}

function Close-ProcHandle { if ($script:ProcHandle -ne [IntPtr]::Zero) { try { [KcProc]::Close($script:ProcHandle) } catch { }; $script:ProcHandle = [IntPtr]::Zero } }

function Switch-GameRoot([string]$root) {
    Set-GameDirs $root
    Reset-ManifestIndex
    Load-Order
    Scan-Sources
    Notice ('KCD2 folder is ' + $root + '  (' + $script:Sources.Count + ' log files, ' + $script:Order.Count + ' mod_order.txt entries)') 'gray'
}

function Proc-Started($p) {
    $pi = $script:ProcInfo
    $script:Proc = $p
    try { [void]$p.Handle } catch { }
    # hold our own handle so the exit code survives the process
    if (Ensure-Native) { try { Close-ProcHandle; $script:ProcHandle = [KcProc]::Open($p.Id) } catch { $script:ProcHandle = [IntPtr]::Zero } }
    $pi.NativeCode = $null
    try {
        $pp = $null; try { $pp = $p.Path } catch { }
        if ($pp -and -not $GamePath) {
            $root = Resolve-GameRoot (Split-Path -Parent $pp)
            if ($root -and $root -ne $script:GameDir) { Switch-GameRoot $root }
        }
    } catch { }
    $pi.Pid = $p.Id; $pi.Exit = $null; $pi.ExitCode = $null; $pi.Peak = 0.0; $pi.PeakPriv = 0.0; $pi.NRTold = $false; $pi.NotRespSince = $null; $pi.PMDue = $null
    try { $pi.Start = $p.StartTime } catch { $pi.Start = [datetime]::Now }
    # Is the log we are already reading this process's own log? (console started while the game runs, or the log won the race against the process poll)
    $keep = ($script:S.Phase -ne 'Idle' -and $script:S.LogSeen -and $script:S.LogStart -and ($script:S.LogStart -ge $pi.Start.AddSeconds(-10)))
    if ($keep) { $script:S.Start = $pi.Start }
    else {
        if ($script:S.Phase -ne 'Idle') { Finish-Session 'new game process' }
        $script:S = New-Session
        $script:S.Start = $pi.Start
        $script:RawTail.Clear()
    }
    $script:Hw.Samples.Clear(); $script:Hw.PeakVram = 0.0; $script:Hw.PeakTemp = 0.0; $script:Hw.MinFree = [double]::MaxValue; $script:Hw.WarnAt = @{}; $script:Hw.PrivStart = 0.0; $script:Hw.PrivStartAt = $null; $script:BsInfo = $null; $script:Hw.InGameAt = $null; $script:Hw.Timeline.Clear(); $script:Hw.TlLast = [datetime]::MinValue
    Arc-Open $pi.Start
    Write-Banner ($(if ($keep) { 'ATTACHED TO RUNNING GAME   ' } else { 'PROCESS STARTED   ' }) + $ProcessName + '.exe   PID ' + $p.Id + '   ' + $pi.Start.ToString('HH:mm:ss')) 'bgreen'
    if ($script:ArcDir) { Notice ('session archive: ' + $script:ArcDir) 'gray' }
    Set-Title ('KCD2 Console - running (PID ' + $p.Id + ')')
    Save-State @{ RunStart=$pi.Start.ToString('yyyy-MM-dd HH:mm:ss'); RunPid=$p.Id; RunEnd=''; RunExit='' }
}

$script:ExitMeaning = @{
    '0'='clean exit'; '1'='generic failure exit (game called exit(1))'; '-1'='exit(-1) / forced termination'
    '-1073741819'='0xC0000005 ACCESS VIOLATION (bad pointer: a mod/plugin/ASI patching the exe wrongly, corrupt data, or a driver)'
    '-1073740791'='0xC0000409 STACK BUFFER OVERRUN / fail-fast (the program aborted itself)'
    '-1073741795'='0xC000001D ILLEGAL INSTRUCTION'
    '-1073741571'='0xC00000FD STACK OVERFLOW'
    '-1073740940'='0xC0000374 HEAP CORRUPTION'
    '-1073741784'='0xC0000028 BAD STACK (the stack was invalid or corrupt while an exception was being handled; native code - an ASI, a KCSE plugin or the engine - is more likely than a Lua/data mod, and only the dump can name the module)'
    '-1073741823'='0xC0000001 unsuccessful (a fatal NT status; look at the dump)'
    '-1073741801'='0xC0000017 OUT OF MEMORY (no memory/commit left)'
    '-1073741502'='0xC0000142 a DLL failed to initialise'
    '-1073741515'='0xC0000135 a DLL was not found'
    '-1073741701'='0xC000007B bad image / 32-64 bit DLL mismatch'
    '-1073741510'='0xC000013A closed by Ctrl-C / console close'
    '-529697949'='0xE06D7363 unhandled C++ exception'
    '-2147483645'='0x80000003 breakpoint / assertion'
    '-1073741676'='0xC0000094 integer divide by zero'
    '-1073741818'='0xC0000006 in-page I/O error (disk/driver problem reading a memory-mapped file - the game maps its .pak files)'
    '-1073740771'='0xC000041D unhandled exception in a callback'
    '-1073740286'='0xC0000402 / driver-reported device failure'
    '-2005270523'='0x887A0005 DXGI_ERROR_DEVICE_REMOVED (the GPU driver reset or the card dropped out)'
    '-2005270521'='0x887A0007 DXGI_ERROR_DEVICE_RESET'
    '-2005270522'='0x887A0006 DXGI_ERROR_DEVICE_HUNG (a GPU job did not finish: TDR)'
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
    $pi.LastExitPid = $pi.Pid
    try { $script:Proc.Dispose() } catch { }
    $script:Proc = $null
    # drain any last log lines, then wait a few seconds for Windows to write its crash events
    $pi.PMDue = [datetime]::Now.AddSeconds(4)
    $pi.Uptime = $up
    Write-Banner ('PROCESS EXITED   PID ' + $pi.Pid + '   ran ' + (Fmt-Span $up) + '   exit: ' + (Describe-Exit $code)) $(if ($code -eq 0) { 'bgreen' } else { 'bred' })
    if ($code -ne 0) { Do-Beep 3 }
    Set-Title 'KCD2 Console - game exited'
    Save-State @{ RunEnd=$pi.Exit.ToString('yyyy-MM-dd HH:mm:ss'); RunExit=[string]$code }
}

# ---------------- hardware: GPU memory/temperature, free RAM, process memory trend
function Get-SmiPath {
    if ($script:Hw.SmiChecked) { return $script:Hw.Smi }
    $script:Hw.SmiChecked = $true
    $cands = @()
    try { $c = Get-Command nvidia-smi -ErrorAction SilentlyContinue; if ($c) { $cands += $c.Source } } catch { }
    if ($script:IsWin) { $cands += 'C:\Windows\System32\nvidia-smi.exe'; $cands += 'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe' }
    foreach ($c in $cands) { if ($c -and [System.IO.File]::Exists($c)) { $script:Hw.Smi = $c; break } }
    return $script:Hw.Smi
}
function Run-Smi {
    $exe = Get-SmiPath
    if (-not $exe) { return $null }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = '--query-gpu=memory.used,memory.total,temperature.gpu,utilization.gpu,power.draw --format=csv,noheader,nounits'
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit(2500)) { try { $p.Kill() } catch { }; return $null }
        $txt = $p.StandardOutput.ReadToEnd().Trim()
        $f = ($txt -split "`n")[0] -split ','
        if ($f.Count -lt 4) { return $null }
        $o = @{ Used=0.0; Total=0.0; Temp=0.0; Util=0.0; Watt=0.0 }
        $vals = @(); foreach ($x in $f) { $d = 0.0; if ([double]::TryParse($x.Trim(), [System.Globalization.NumberStyles]::Float, $script:Ci, [ref]$d)) { $vals += $d } else { $vals += 0.0 } }
        $o.Used = $vals[0]; $o.Total = $vals[1]; $o.Temp = $vals[2]; $o.Util = $vals[3]; if ($vals.Count -ge 5) { $o.Watt = $vals[4] }
        return $o
    } catch { return $null }
}
function Warn-Once([string]$key, [int]$minutes, [string]$text) {
    $w = $script:Hw.WarnAt
    if ($w.ContainsKey($key) -and ([datetime]::Now - $w[$key]).TotalMinutes -lt $minutes) { return }
    $w[$key] = [datetime]::Now
    Write-Line ((Col 'byellow') + ('          ! ' + $text)) $true
    $script:S.Milestones.Add((Get-Date).ToString('HH:mm:ss') + ' ' + $text)
    Do-Beep 2
}
function Hw-Poll {
    if ($NoHardware -or -not $script:Proc) { return }
    $now = [datetime]::Now
    if (($now - $script:Hw.Last).TotalSeconds -lt $HwSec) { return }
    $script:Hw.Last = $now
    $H = $script:Hw
    $smi = Run-Smi
    if ($smi) {
        $H.Vram = $smi.Used; $H.VramTotal = $smi.Total; $H.Temp = $smi.Temp; $H.Util = $smi.Util; $H.Watt = $smi.Watt
        if ($smi.Used -gt $H.PeakVram) { $H.PeakVram = $smi.Used }
        if ($smi.Temp -gt $H.PeakTemp) { $H.PeakTemp = $smi.Temp }
        if ($smi.Total -gt 0 -and ($smi.Used / $smi.Total) -ge 0.97) { Warn-Once 'vram' 5 ('GPU memory almost full: ' + ('{0:0.0}' -f ($smi.Used / 1024)) + ' of ' + ('{0:0.0}' -f ($smi.Total / 1024)) + ' GB. Expect texture-streaming stutter; a texture/tree/building mod set that is heavy for 10 GB can also end in a device-removed crash.') }
        if ($smi.Temp -ge 86) { Warn-Once 'temp' 5 ('GPU temperature ' + $smi.Temp + ' C') }
    }
    if ($script:IsWin -and ($now - $H.LastSys).TotalSeconds -ge 15) {
        $H.LastSys = $now
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $H.FreeNow = [double]$os.FreePhysicalMemory / 1024.0; $H.TotalNow = [double]$os.TotalVisibleMemorySize / 1024.0
            if ($H.FreeNow -lt $H.MinFree) { $H.MinFree = $H.FreeNow }
            if ($H.FreeNow -lt 3072) { Warn-Once 'ram' 5 ('Windows has only ' + ('{0:0.0}' -f ($H.FreeNow / 1024)) + ' GB of free RAM left') }
        } catch { }
    }
    $pi = $script:ProcInfo
    $H.Samples.Add(@{ T=$now; Vram=$H.Vram; Temp=$H.Temp; Util=$H.Util; Free=$H.FreeNow; WS=$pi.Mem; Priv=$pi.Priv })
    if ($H.Samples.Count -gt 360) { $H.Samples.RemoveRange(0, 60) }
    # memory curve: one point every 5 minutes, kept for the post-mortem and session.json
    if (($now - $H.TlLast).TotalMinutes -ge 5) {
        $H.TlLast = $now
        $H.Timeline.Add(@{ T=$now; Priv=$pi.Priv; WS=$pi.Mem; Vram=$H.Vram; Free=$H.FreeNow; Phase=$script:S.Phase })
        if ($H.Timeline.Count -gt 200) { $H.Timeline.RemoveRange(0, 50) }
    }
    # memory growth (leak-like) over half an hour of PLAY: the clock starts 5 min after the world is up, so loading and streaming do not count
    if ($script:S.Phase -ne 'IN GAME') { $H.InGameAt = $null; $H.PrivStartAt = $null }
    elseif ($null -eq $H.InGameAt) { $H.InGameAt = $now }
    elseif ($null -eq $H.PrivStartAt) {
        if (($now - $H.InGameAt).TotalMinutes -ge 5) { $H.PrivStartAt = $now; $H.PrivStart = $pi.Priv }
    }
    elseif (($now - $H.PrivStartAt).TotalMinutes -ge 30) {
        $grow = ($pi.Priv - $H.PrivStart) / 1MB
        if ($grow -gt 1500) { Warn-Once 'grow' 60 ('KingdomCome private memory grew by ' + ('{0:0}' -f $grow) + ' MB in the last 30 min of play (now ' + (Fmt-Bytes $pi.Priv) + '). A mod that leaks, or just a long session; a restart clears it.') }
        $H.PrivStartAt = $now; $H.PrivStart = $pi.Priv
    }
}

# ---------------- save folder watcher
$script:SaveSeen = @{}
$script:SaveBaselined = $false
$script:LastSaveScan = [datetime]::MinValue
function Get-SaveFiles {
    $r = New-Object System.Collections.Generic.List[object]
    if (-not $script:SaveDir) { return $r }
    $sv = Ci-Child $script:SaveDir 'saves'
    if (-not $sv) { return $r }
    try {
        foreach ($pl in [System.IO.Directory]::EnumerateDirectories($sv)) {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($pl, '*.whs')) {
                $fi = New-Object System.IO.FileInfo($f)
                $r.Add(@{ Path=$f; Name=([System.IO.Path]::GetFileName($pl) + '/' + $fi.Name); Len=$fi.Length; Time=$fi.LastWriteTime })
            }
        }
    } catch { }
    return $r
}
function Watch-Saves {
    if ($NoSaveWatch -or -not $script:SaveDir) { return }
    $now = [datetime]::Now
    if (($now - $script:LastSaveScan).TotalSeconds -lt 3) { return }
    $script:LastSaveScan = $now
    $files = Get-SaveFiles
    if (-not $script:SaveBaselined) {
        foreach ($f in $files) { $script:SaveSeen[$f.Path] = @{ Len=$f.Len; Time=$f.Time; Stable=2 } }
        $script:SaveBaselined = $true
        return
    }
    foreach ($f in $files) {
        $old = $null; if ($script:SaveSeen.ContainsKey($f.Path)) { $old = $script:SaveSeen[$f.Path] }
        if ($null -eq $old -or $old.Len -ne $f.Len -or $old.Time -ne $f.Time) {
            $script:SaveSeen[$f.Path] = @{ Len=$f.Len; Time=$f.Time; Stable=0; Prev=$(if ($old) { $old.Len } else { [long]0 }) }
            continue
        }
        if ($old.Stable -lt 1) {
            $old.Stable = 1
            if ($old.Stable -ge 1) {
                $txt = 'SAVE written: ' + $f.Name + '  ' + (Fmt-Bytes $f.Len)
                $prev = 0; try { $prev = [double]$old.Prev } catch { }
                if ($prev -gt 0) { $d = $f.Len - $prev; $txt += '  (' + $(if ($d -ge 0) { '+' } else { '-' }) + (Fmt-Bytes ([Math]::Abs($d))) + ' vs the previous version of this slot)' }
                $col = 'green'
                if ($f.Len -lt 1024) { $txt += '  ! EMPTY/TINY SAVE'; $col = 'bred' }
                elseif ($prev -gt 0 -and $f.Len -lt ($prev * 0.5)) { $txt += '  ! much smaller than before'; $col = 'byellow' }
                Write-Line ((Col $col) + ('          ' + $script:G.dot + ' ' + $txt)) $true
                $script:S.SaveFiles.Add($now.ToString('HH:mm:ss') + ' ' + $f.Name + ' ' + (Fmt-Bytes $f.Len))
                try { $drv = [System.IO.Path]::GetPathRoot($script:SaveDir); if ($drv) { $di = New-Object System.IO.DriveInfo($drv); if ($di.AvailableFreeSpace -lt 10GB) { Warn-Once 'disk' 30 ('only ' + (Fmt-Bytes $di.AvailableFreeSpace) + ' free on ' + $drv + ' (saves are big; a full disk corrupts them)') } } } catch { }
            }
        }
    }
}

# ---------------- Windows events, dumps, crash dump reading
function Get-LastBoot {
    if (-not $script:IsWin) { return $null }
    try { return (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { return $null }
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
            elseif ($p -in @('disk','stornvme','storahci','iaStorA','Ntfs','Microsoft-Windows-Ntfs','volmgr','partmgr','storport')) { $keep = $true }
            elseif ($p -eq 'EventLog' -and $e.Id -eq 6008) { $keep = $true }
            elseif ($p -like '*SystemErrorReporting*' -or ($p -eq 'BugCheck')) { $keep = $true }
            elseif ($p -eq 'Microsoft-Windows-Resource-Exhaustion-Detector') { $keep = $true }
            elseif ($p -like '*Corsair*' -or ([string]$e.Message) -match '(?i)commander pro|corsair') { $keep = $true }
            if ($keep) { $out.Add(@{ T=$e.TimeCreated; Log='System'; Prov=$p; Id=$e.Id; Msg=(([string]$e.Message) -split "`n")[0].Trim() }) }
        }
    } catch { }
    try {
        $app = Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$from; EndTime=$to; Level=@(1,2,3) } -ErrorAction SilentlyContinue
        foreach ($e in $app) {
            $msg = [string]$e.Message
            if ($msg -match '(?i)KingdomCome|WHGame|BugSplat|nvwgf2umx|d3d12|fmod') {
                $p = [string]$e.ProviderName
                if ($p -in @('Application Error','Windows Error Reporting','Application Hang','.NET Runtime','SideBySide','BugSplat')) {
                    $out.Add(@{ T=$e.TimeCreated; Log='Application'; Prov=$p; Id=$e.Id; Msg=(($msg -split "`n" | Select-Object -First 6) -join ' | ') })
                }
            }
        }
    } catch { }
    return ($out | Sort-Object { $_.T })
}
function Is-HwEvent($e) {
    return ($e.Prov -like 'Microsoft-Windows-Kernel-Power' -or $e.Prov -like 'Microsoft-Windows-WHEA*' -or $e.Prov -in @('nvlddmkm','amdkmdag','disk','stornvme','storport','EventLog','Display') -or $e.Prov -like '*SystemErrorReporting*' -or $e.Prov -like '*Corsair*' -or ([string]$e.Msg) -match '(?i)commander pro|corsair')
}

function Get-DumpFiles([datetime]$since) {
    $found = New-Object System.Collections.Generic.List[string]
    $dirs = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) {
        $dirs.Add((PJ $env:LOCALAPPDATA 'CrashDumps')); $dirs.Add((PJ $env:LOCALAPPDATA 'BugSplat')); $dirs.Add((PJ $env:LOCALAPPDATA 'KingdomCome2'))
        $dirs.Add((PJ $env:LOCALAPPDATA 'Warhorse')); $dirs.Add((PJ $env:LOCALAPPDATA 'Temp'))
    }
    if ($script:GameDir) {
        $dirs.Add($script:GameDir); $dirs.Add((PJ $script:GameDir 'BugSplatAttachments')); $dirs.Add((PJ $script:GameDir 'Bin'))
        if ($script:BinDir) { $dirs.Add($script:BinDir); $dirs.Add((PJ $script:BinDir 'BugSplatAttachments')) }
    }
    if ($script:SaveDir) { $dirs.Add($script:SaveDir); $dirs.Add((PJ $script:SaveDir 'crashes')) }
    foreach ($d in $dirs) {
        if (-not [System.IO.Directory]::Exists($d)) { continue }
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($d)) {
                $fi = New-Object System.IO.FileInfo($f)
                if ($fi.LastWriteTime -lt $since) { continue }
                $ext = $fi.Extension.ToLowerInvariant()
                $nm = $fi.Name.ToLowerInvariant()
                $isTemp = ($d -like '*Temp')
                $ok = $false
                if ($ext -in @('.dmp', '.mdmp')) { $ok = $true }
                elseif ($nm -match 'bugsplat|crash|dump|minidump|kingdomcome.*report') { $ok = ($ext -in @('.zip', '.txt', '.xml', '.json', '.log', '.crash', '.bsrpt')) }
                if ($isTemp -and $nm -notmatch 'bugsplat|kingdom\s*come|whgame') { $ok = $false }
                if ($ok) { $found.Add($fi.FullName + '   (' + (Fmt-Bytes $fi.Length) + ', ' + $fi.LastWriteTime.ToString('HH:mm:ss') + ')') }
            }
        } catch { }
    }
    return $found
}

# ---- minidump reader (pure PowerShell). Works on any Windows .dmp, including BugSplat's.
function Read-MiniDump([byte[]]$b) {
    $r = @{ Ok=$false; Why='' }
    try {
        if ($b.Length -lt 32 -or $b[0] -ne 0x4D -or $b[1] -ne 0x44 -or $b[2] -ne 0x4D -or $b[3] -ne 0x50) { $r.Why = 'not a minidump'; return $r }
        $nStreams = [BitConverter]::ToInt32($b, 8); $dirRva = [BitConverter]::ToInt32($b, 12)
        $exc = -1; $mods = -1
        for ($i = 0; $i -lt $nStreams; $i++) {
            $o = $dirRva + 12 * $i
            $type = [BitConverter]::ToInt32($b, $o); $rva = [BitConverter]::ToInt32($b, $o + 8)
            if ($type -eq 6) { $exc = $rva } elseif ($type -eq 4) { $mods = $rva }
        }
        if ($exc -lt 0) { $r.Why = 'dump has no exception record'; return $r }
        $r.ThreadId = [BitConverter]::ToUInt32($b, $exc)
        $r.Code = [BitConverter]::ToUInt32($b, $exc + 8)
        $r.Addr = [BitConverter]::ToUInt64($b, $exc + 24)
        $np = [BitConverter]::ToInt32($b, $exc + 32)
        $r.Info0 = 0; $r.Info1 = [uint64]0
        if ($np -ge 2) { $r.Info0 = [BitConverter]::ToUInt64($b, $exc + 40); $r.Info1 = [BitConverter]::ToUInt64($b, $exc + 48) }
        $r.Module = ''; $r.Offset = [uint64]0; $r.Modules = New-Object System.Collections.Generic.List[string]
        if ($mods -ge 0) {
            $n = [BitConverter]::ToInt32($b, $mods)
            for ($i = 0; $i -lt $n; $i++) {
                $o = $mods + 4 + 108 * $i
                $base = [BitConverter]::ToUInt64($b, $o); $size = [BitConverter]::ToUInt32($b, $o + 8); $nrva = [BitConverter]::ToInt32($b, $o + 20)
                $len = [BitConverter]::ToInt32($b, $nrva)
                $full = [System.Text.Encoding]::Unicode.GetString($b, $nrva + 4, $len)
                $short = ($full -split '[\\/]')[-1]
                $r.Modules.Add($short)
                if ($r.Addr -ge $base -and $r.Addr -lt ($base + $size) -and -not $r.Module) { $r.Module = $short; $r.Offset = $r.Addr - $base; $r.ModulePath = $full }
            }
        }
        $r.Ok = $true
    } catch { $r.Why = $_.Exception.Message }
    return $r
}
function Describe-NtCode([uint32]$c) {
    switch ($c) {
        3221225477 { return 'ACCESS VIOLATION' }
        3221225620 { return 'DIVIDE BY ZERO' }
        3221225725 { return 'STACK OVERFLOW' }
        3221226356 { return 'HEAP CORRUPTION' }
        3221226505 { return 'FAIL-FAST / stack buffer overrun' }
        3221225501 { return 'ILLEGAL INSTRUCTION' }
        3765269347 { return 'C++ exception (0xE06D7363)' }
        3762504530 { return 'unhandled .NET exception (0xE0434352)' }
        2147483651 { return 'BREAKPOINT' }
        2289434629 { return 'DXGI_ERROR_DEVICE_REMOVED (0x887A0005)' }
        default { return 'exception' }
    }
}
# who owns a module name?
function Classify-Module([string]$name) {
    $l = $name.ToLowerInvariant()
    if ($l -eq 'kingdomcome.exe' -or $l -eq 'whgame.dll') { return 'the game itself. A mod fed it bad data, or a plugin/ASI patched its code wrongly (compare the offset with earlier crashes: the same offset again means the same cause).' }
    if ($l -like '*.asi') { return 'an ASI mod (' + $name + ') - the first suspect. It hooks the exe, so a game patch breaks it.' }
    if ($l -match '^(nvwgf2umx|nvlddmkm|nvapi64|nvngx|nvcuda|nvoglv64|nvd3dumx)') { return 'the NVIDIA graphics driver. Not a mod: driver version, VRAM exhaustion, GPU overclock/undervolt or hardware.' }
    if ($l -match '^(amdxc64|atidxx64|amdxx|amdvlk|amd_ags|amd_fidelityfx)') { return 'AMD graphics driver / FidelityFX (FSR).' }
    if ($l -match '^(libxess|igd|ig9icd|igxe)') { return 'Intel graphics / XeSS.' }
    if ($l -match '^(d3d12|dxgi|d3d11|d3dcompiler|dxcompiler|dxil)') { return 'the Microsoft Direct3D runtime: usually a GPU/driver reset (device removed) underneath.' }
    if ($l -match '^(fmod|fmodstudio|quatmosphere)') { return 'the FMOD audio engine (a sound bank/mod, or the audio device went away).' }
    if ($l -match '^(bink2w64)') { return 'the Bink video player.' }
    if ($l -match '^(steam_api64|gameoverlayrenderer64|steamclient64)') { return 'Steam (overlay/API).' }
    if ($l -match '(rtss|msiafterburner|discord|overlay|reshade|dxvk|special_?k|nvidia ?share|nvspcap|obs-?graphics|gfxhook)') { return 'an overlay / injection tool (' + $name + '): close it and retest.' }
    if ($l -match '^(ntdll|kernelbase|kernel32|ucrtbase|msvcp|vcruntime|msvcrt|combase|win32u|user32)') { return 'a Windows runtime DLL: the real cause is whoever called it (look at the log tail and the other evidence).' }
    return 'a module that is not part of the base game (' + $name + '); find which mod ships it.'
}

# returns lines describing the dump; $dumpPath may be a .zip (containing a .dmp) or a .dmp
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
                    if (($e.FullName -like '*.dmp' -or $e.FullName -like '*.mdmp') -and $null -eq $bytes) {
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
            $how = ' - ' + $(if ($kind.ContainsKey([int]$d.Info0)) { $kind[[int]$d.Info0] } else { 'touched' }) + ' address 0x' + ('{0:X}' -f $d.Info1)
            if ($d.Info1 -lt 65536) { $how += ' (a NULL pointer plus 0x' + ('{0:X}' -f $d.Info1) + ' - code used an object that does not exist)' }
        }
        $out.Add(('exception 0x{0:X8} {1}{2}' -f $d.Code, $what, $how))
        $where = '0x' + ('{0:X}' -f $d.Addr)
        if ($d.Module) { $where += '  =  ' + $d.Module + ' + 0x' + ('{0:X}' -f $d.Offset) }
        $out.Add('at ' + $where + '   (thread ' + $d.ThreadId + ')')
        if ($d.Module) { $out.Add('that is ' + (Classify-Module $d.Module)) }
        else { $out.Add('the faulting address is not inside any module the dump lists (a jump into freed/unmapped memory: typical of a bad hook or a stale pointer)') }
        # which mod-supplied native modules were loaded (ASI + KCSE plugin DLLs)
        $nat = @($d.Modules | Where-Object { $_ -match '(?i)\.asi$' -or $_ -match '(?i)^(LuaUtils|MCM|ModLimitFix|PTFextender|CfgImportExport|PerkDiagnostic|kcd2_autotravel)\.dll$' })
        if ($nat.Count -gt 0) { $out.Add('mod-supplied native code loaded in the process: ' + ($nat -join ', ')) }
    } catch { $out.Add('crash dump reading failed: ' + $_.Exception.Message) }
    return $out
}
function Get-CrashFiles([datetime]$since) {
    $r = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Get-DumpFiles $since)) {
        $p = ($line -split '   \(')[0]
        $ext = [System.IO.Path]::GetExtension($p).ToLowerInvariant()
        if ($ext -in @('.dmp', '.mdmp', '.zip')) { try { $r.Add((New-Object System.IO.FileInfo($p))) } catch { } }
    }
    return $r
}

# ---- BugSplat's own log (Temp\bugsplat_*.log): when its handler fired, the crash address, the dump it wrote, the GPU flag
function Read-BugSplatLog([string]$path) {
    $r = @{ Ok=$false; Time=''; Mfa=''; Dump=''; DeviceRemoved=''; Gpu='' }
    try {
        $txt = ''
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try { $sr = New-Object System.IO.StreamReader($fs); try { $txt = $sr.ReadToEnd() } finally { $sr.Dispose() } } finally { $fs.Dispose() }
        $m = [regex]::Match($txt, '(?<t>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s+Entered Unhandled Exception Filter')
        if ($m.Success) { $r.Time = $m.Groups['t'].Value }
        $m = [regex]::Match($txt, '(?m)MFA:\s*(?<a>\S+)')
        if ($m.Success) { $r.Mfa = $m.Groups['a'].Value }
        $m = [regex]::Match($txt, '(?m)Minidump:\s*(?<p>.+?\.(?:dmp|mdmp))\s*$')
        if (-not $m.Success) { $m = [regex]::Match($txt, '(?m)(?<p>[A-Za-z]:\\[^\r\n]*?\.(?:dmp|mdmp))') }
        if ($m.Success) { $r.Dump = $m.Groups['p'].Value.Trim() }
        $m = [regex]::Match($txt, '"Device Removed":"(?<d>[^"]*)"')
        if ($m.Success) { $r.DeviceRemoved = $m.Groups['d'].Value }
        $m = [regex]::Match($txt, '"GPU Info":"(?<g>[^"]*)"')
        if ($m.Success) { $r.Gpu = $m.Groups['g'].Value }
        $r.Ok = ($r.Time -ne '' -or $r.Mfa -ne '' -or $r.Dump -ne '')
    } catch { }
    return $r
}
# BugSplat prints the dump path with {username} unresolved and a ':' in the file name that Windows cannot store: find the real file by its unique tail
function Find-BugSplatDump([string]$p) {
    if (-not $p) { return $null }
    try {
        $u = $env:USERNAME; if (-not $u) { $u = $env:USER }
        $q = $p
        if ($u) { $q = $q -replace '\{username\}', $u }
        if ([System.IO.File]::Exists($q)) { return $q }
        $i = $q.LastIndexOf('\'); if ($i -lt 0) { $i = $q.LastIndexOf('/') }
        if ($i -lt 0) { return $null }
        $dir = $q.Substring(0, $i); $leaf = $q.Substring($i + 1)
        if (-not [System.IO.Directory]::Exists($dir) -and $env:LOCALAPPDATA) { $dir = PJ $env:LOCALAPPDATA 'Temp' }
        if (-not [System.IO.Directory]::Exists($dir)) { return $null }
        $tail = [regex]::Match($leaf, '[^\s:]+\.(?:dmp|mdmp)$')
        if (-not $tail.Success) { return $null }
        $best = $null
        foreach ($f in [System.IO.Directory]::GetFiles($dir, '*' + $tail.Value)) {
            $fi = New-Object System.IO.FileInfo($f)
            if ($null -eq $best -or $fi.LastWriteTime -gt $best.LastWriteTime) { $best = $fi }
        }
        if ($best) { return $best.FullName }
    } catch { }
    return $null
}
function Describe-Mfa([string]$mfa) {
    $m = [regex]::Match($mfa, '^(?<mod>[^!]+)!(?<off>[0-9A-Fa-f]+)$')
    if (-not $m.Success) { return '' }
    $mod = $m.Groups['mod'].Value
    $off = $m.Groups['off'].Value.TrimStart('0'); if ($off -eq '') { $off = '0' }
    $nm = $mod; if ($nm -notmatch '\.') { $nm = $nm + '.dll' }
    $txt = '= ' + $mod + ' + 0x' + $off + ' : ' + (Classify-Module $nm)
    if ($mod -match '(?i)^ntdll$') { $txt = $txt + ' ntdll is where Windows dispatches and unwinds every exception, so this address alone does not name the culprit; the dump holds the original fault.' }
    return $txt
}
function Tail-File([string]$path, [int]$n) {
    $out = New-Object System.Collections.Generic.List[string]
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $take = [int][Math]::Min($fs.Length, 16384)
            [void]$fs.Seek($fs.Length - $take, [System.IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] $take
            $got = $fs.Read($buf, 0, $buf.Length)
            $t = [System.Text.Encoding]::UTF8.GetString($buf, 0, $got)
            $ls = @($t -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
            foreach ($l in @($ls | Select-Object -Last $n)) { $out.Add([string]$l) }
        } finally { $fs.Dispose() }
    } catch { }
    return ,$out
}

function Post-Mortem {
    $pi = $script:ProcInfo; $S = $script:S
    $pi.PMDue = $null
    if ($S.OrderPending) { $S.OrderPending = $false; Check-LoadOrder }
    $script:Tee = New-Object System.Collections.Generic.List[string]
    $start = $pi.Start; $end = $pi.Exit; if (-not $end) { $end = [datetime]::Now }
    Write-Head 'POST-MORTEM'
    $code = $pi.ExitCode
    Write-Plain ('  Ran ............ ' + (Fmt-Span $pi.Uptime) + '   (' + $start.ToString('HH:mm:ss') + ' -> ' + $end.ToString('HH:mm:ss') + ')')
    Write-Plain ('  Exit ........... ' + (Describe-Exit $code))
    Write-Plain ('  Peak memory .... working set ' + (Fmt-Bytes $pi.Peak) + ', private ' + (Fmt-Bytes $pi.PeakPriv))
    if ($script:Hw.PeakVram -gt 0) { Write-Plain ('  GPU ............ peak VRAM ' + ('{0:0.0}' -f ($script:Hw.PeakVram / 1024)) + ' of ' + ('{0:0.0}' -f ($script:Hw.VramTotal / 1024)) + ' GB, peak temp ' + $script:Hw.PeakTemp + ' C') }
    if ($script:Hw.MinFree -lt [double]::MaxValue) { Write-Plain ('  System RAM ..... lowest free ' + ('{0:0.0}' -f ($script:Hw.MinFree / 1024)) + ' GB') }
    Write-Plain ('  Phase at exit .. ' + $S.Phase)
    if ($S.GameVer) { Write-Plain ('  Game ........... ' + $S.GameVer + ' (' + $S.ExtVer + ')' + $(if ($S.DevMode) { '  -devmode' } else { '' })) }
    if ($S.Loads.Count -gt 0) { Write-Plain ('  Last save load . ' + $S.Loads[$S.Loads.Count - 1].Save) }
    if ($S.Levels.Count -gt 0) { Write-Plain ('  Level .......... ' + $S.Levels[$S.Levels.Count - 1]) }
    if ($script:Sources.Count -eq 0) { Write-Plain ('  !! No log files were being followed (KCD2 folder used: ' + $script:GameDir + '). The counters below are empty because of that, not because the game was quiet.') 'bred' }
    if ($S.ModsEnabledN -gt 0) { Write-Plain ('  Mods ........... ' + $S.ModsEnabledN + ' enabled (' + $script:Order.Count + ' in mod_order.txt)' + $(if ($S.LuaInitLast) { '   last Lua init: ' + $S.LuaInitLast } else { '' })) }
    Write-Plain ('  Log counters ... errors ' + $S.Err + ', warnings ' + $S.Warn + ', hidden noise ' + $S.Noise)
    if ($S.CleanExit) { Write-Plain ('  Quit line ...... "' + $S.QuitReason + '" exit code ' + $S.QuitCode + ' - the game shut down through its normal path') 'green' }
    elseif ($S.QuitReason) { Write-Plain ('  Quit line ...... "' + $S.QuitReason + '" exit code ' + $S.QuitCode) 'byellow' }
    elseif ($S.Phase -ne 'Idle' -and $code -eq 0) { Write-Plain '  Quit line ...... none, but the exit code is 0: the game closed itself normally (not every normal close writes the line)' 'gray' }
    elseif ($S.Phase -ne 'Idle') { Write-Plain '  Quit line ...... none - kcd.log has no "CSystem::Quit" line and the exit code is not 0, so the game did NOT go through its normal shutdown' 'byellow' }
    if ($S.Milestones.Count -gt 0) { Write-Head 'Flags raised during this run'; foreach ($x in ($S.Milestones | Select-Object -Last 12)) { Write-Plain ('  ' + $x) 'byellow' } }

    if ($S.RecentOrder.Count -gt 0) {
        Write-Head 'Last distinct errors in the logs'
        foreach ($l in (Get-RecentLines 8)) { Write-Plain ('  ' + $l) 'red' }
    }
    Write-Head 'Last 14 raw lines of kcd.log (nothing filtered out)'
    foreach ($l in ($script:RawTail.ToArray() | Select-Object -Last 14)) { Write-Line ('  ' + (Trunc $l 200)) }
    $hs = @($script:Hw.Samples.ToArray() | Select-Object -Last 4)
    if ($hs.Count -gt 0) {
        Write-Head 'Last hardware samples before the end'
        foreach ($x in $hs) { Write-Plain ('  ' + $x.T.ToString('HH:mm:ss') + '  VRAM ' + ('{0:0.0}' -f ($x.Vram / 1024)) + ' GB   GPU ' + $x.Temp + ' C ' + $x.Util + '%   RAM free ' + ('{0:0.0}' -f ($x.Free / 1024)) + ' GB   game private ' + (Fmt-Bytes $x.Priv)) 'gray' }
    }

    $mt = @($script:Hw.Timeline.ToArray())
    if ($mt.Count -gt 0) {
        Write-Head 'Memory over the run (one point every 5 min)'
        foreach ($x in @($mt | Select-Object -Last 14)) { Write-Plain ('  ' + $x.T.ToString('HH:mm') + '  game private ' + (Fmt-Bytes $x.Priv) + '   working set ' + (Fmt-Bytes $x.WS) + '   VRAM ' + ('{0:0.0}' -f ($x.Vram / 1024)) + ' GB   RAM free ' + ('{0:0.0}' -f ($x.Free / 1024)) + ' GB   ' + $x.Phase) 'gray' }
        Write-Plain ('  last reading before the end: game private ' + (Fmt-Bytes $pi.Priv) + ', working set ' + (Fmt-Bytes $pi.Mem)) 'gray'
    }

    $dumps = @(Get-DumpFiles ($start.AddSeconds(-5)))
    if ($dumps.Count -gt 0) { Write-Head 'Crash reports / dumps written during this run'; foreach ($d in $dumps) { Write-Plain ('  ' + $d) 'byellow' } }
    $dumpInfo = New-Object System.Collections.Generic.List[string]
    $bsHint = $null; $bsLine = ''; $bsGone = ''
    foreach ($d in $dumps) {
        $bp = ($d -split '   \(')[0]
        if ([System.IO.Path]::GetFileName($bp) -notlike 'bugsplat*.log') { continue }
        $bs = Read-BugSplatLog $bp
        if (-not $bs.Ok) { continue }
        Write-Head 'BugSplat crash report (the game''s own crash handler)'
        if ($bs.Time) { Write-Plain ('  handler fired ..... ' + $bs.Time) }
        if ($bs.Mfa) { Write-Plain ('  crash address ..... ' + $bs.Mfa + '  ' + (Describe-Mfa $bs.Mfa)) 'byellow' }
        if ($bs.DeviceRemoved) { Write-Plain ('  GPU device removed  ' + $bs.DeviceRemoved + $(if ($bs.DeviceRemoved -eq 'No') { '   (the D3D12 device was still fine: not a GPU driver reset)' } else { '   (the GPU driver reset or the card dropped out)' })) }
        $dp = Find-BugSplatDump $bs.Dump
        if ($dp) {
            $bsHint = $dp
            $dsz = ''; try { $dsz = Fmt-Bytes ((New-Object System.IO.FileInfo($dp)).Length) } catch { }
            Write-Plain ('  dump file ......... ' + $dp + '  (' + $dsz + ')  - read below') 'green'
        } elseif ($bs.Dump) {
            $bsGone = $bs.Dump
            Write-Plain ('  dump file ......... ' + $bs.Dump + '  - no longer on disk (BugSplat removes it once sent, or Temp was cleaned)') 'byellow'
        }
        $script:BsInfo = @{ Mfa=$bs.Mfa; Time=$bs.Time; DeviceRemoved=$bs.DeviceRemoved; DumpFile=$(if ($dp) { $dp } else { '' }); DumpNamed=$bs.Dump }
        $bsLine = 'BugSplat (the game''s crash handler) caught an unhandled exception' + $(if ($bs.Time) { ' at ' + $bs.Time } else { '' }) + $(if ($bs.Mfa) { '; crash address ' + $bs.Mfa } else { '' }) + $(if ($bs.DeviceRemoved) { '; GPU device removed: ' + $bs.DeviceRemoved } else { '' }) + '.'
    }
    $cfiles = New-Object System.Collections.Generic.List[object]
    foreach ($cz in @(Get-CrashFiles ($start.AddSeconds(-5)))) { $cfiles.Add($cz) }
    if ($bsHint) {
        $have = $false
        foreach ($cz in $cfiles.ToArray()) { if ($cz.FullName -eq $bsHint) { $have = $true } }
        if (-not $have) { try { $cfiles.Add((New-Object System.IO.FileInfo($bsHint))) } catch { } }
    }
    foreach ($cz in @($cfiles.ToArray() | Select-Object -First 3)) {
        Write-Head ('Crash dump: ' + $cz.Name)
        if ($script:ArcDir) { try { Copy-Item -LiteralPath $cz.FullName -Destination (PJ $script:ArcDir $cz.Name) -Force; Write-Plain ('  copy kept in the session folder: ' + (PJ $script:ArcDir $cz.Name)) 'green' } catch { } }
        foreach ($l in (Describe-CrashDump $cz.FullName)) { Write-Plain ('  ' + $l) 'bred'; $dumpInfo.Add($l) }
    }

    $pls = @($script:Sources.ToArray() | Where-Object { $_.Kind -in @('kcse', 'qn', 'mm', 'db', 'tkh') -and -not $_.Stale })
    if ($pls.Count -gt 0) {
        $shown = $false
        foreach ($sx in $pls) {
            $tlines = Tail-File $sx.Path 3
            if ($tlines.Count -eq 0) { continue }
            if (-not $shown) { Write-Head 'Last lines of the plugin / ASI logs (who was still talking at the end)'; $shown = $true }
            $when = ''; try { $when = ([System.IO.File]::GetLastWriteTime($sx.Path)).ToString('HH:mm:ss') } catch { }
            Write-Plain ('  ' + $sx.Name + '   (last written ' + $when + ')') 'gray'
            foreach ($l in $tlines) { Write-Plain ('      ' + (Trunc $l 170)) }
        }
    }

    $ev = @(); $hw = 0
    $boot = Get-LastBoot
    $rebooted = ($boot -and $boot -gt $start)
    if ($script:IsWin -and -not $NoSystemEvents) {
        $ev = @(Get-SysEvents ($start.AddMinutes(-1)) ($end.AddMinutes(2)) $false)
        Write-Head ('Windows events during the run (' + $ev.Count + ')')
        if ($ev.Count -eq 0) { Write-Plain '  none of: app crash/hang, Kernel-Power 41, WHEA, GPU driver / TDR, disk/NVMe, bugcheck, Corsair' 'gray' }
        foreach ($e in $ev) {
            $isHw = Is-HwEvent $e
            if ($isHw) { $hw++ }
            Write-Plain ('  ' + $e.T.ToString('HH:mm:ss') + '  ' + $e.Log.PadRight(11) + $e.Prov + ' #' + $e.Id + '  ' + (Trunc $e.Msg 200)) $(if ($isHw) { 'bred' } else { 'byellow' })
        }
        if ($rebooted) { Write-Plain ('  Windows was restarted at ' + $boot.ToString('HH:mm:ss') + ', after the game started.') 'bred' }
    }

    # verdict: inferred, never claimed as proof
    Write-Head 'Reading of the evidence (inferred - not proof)'
    $v = New-Object System.Collections.Generic.List[string]
    $clean = ($code -eq 0) -and ($dumpInfo.Count -eq 0)
    if ($clean) {
        if ($S.CleanExit) { $v.Add('Clean shutdown: exit code 0 and the log has the normal CSystem::Quit line. Nothing to chase.') }
        else { $v.Add('Exit code 0: the game closed itself normally. The log has no CSystem::Quit line, which not every normal close writes. Nothing to chase.') }
    }
    else {
        if ($hw -gt 0 -or $rebooted) { $v.Add('Hardware/system events were logged around the end (red lines above). A reboot, driver reset or storage error is not caused by a mod: check hardware first (temperatures, drivers, RAM stability, RGB/fan controllers, PCIe and storage devices).') }
        if ($null -ne $code -and $code -ne 0) { $v.Add('The process died with ' + (Describe-Exit $code) + '.') }
        elseif ($null -eq $code) { $v.Add('Exit code could not be read.') }
        if ($S.Phase -like 'Mod Lua*' -and $S.LuaInitLast) { $v.Add('It ended while mod Lua scripts were initialising; the last one started was "' + $S.LuaInitLast + '" - first suspect (confirm by disabling it).') }
        elseif ($S.Phase -like 'Loading level*' -or $S.Phase -like 'Loading save*') { $v.Add('It ended while a save/level was loading. Compare the "Mods used while saving" check (m) and the hardware samples: VRAM full or a removed mod that the save references are the usual causes.') }
        elseif ($S.Phase -like 'Booting*' -or $S.Phase -like 'Launcher*' -or $S.Phase -like 'Discovering*') { $v.Add('It ended during boot, before mods were applied. That points at the install, an ASI/KCSE plugin after a patch, or the process being closed from the launcher.') }
        if ($S.Milestones | Where-Object { $_ -like 'GAME UPDATED*' }) { $v.Add('The game was updated since the last run. KCSE plugins and ASIs break first after a patch: check the KCSE lines and the ASI list before blaming content mods.') }
        if ($S.Kc.Total -gt 0 -and -not $S.Kc.Ready) { $v.Add('KCSE never reached "Ready." - a script-extender plugin failed during start-up.') }
        if ($script:Hw.VramTotal -gt 0 -and ($script:Hw.PeakVram / $script:Hw.VramTotal) -ge 0.97) { $v.Add('GPU memory was full (peak ' + ('{0:0.0}' -f ($script:Hw.PeakVram / 1024)) + ' of ' + ('{0:0.0}' -f ($script:Hw.VramTotal / 1024)) + ' GB). A D3D12 device-removed crash is plausible; lighter textures/vegetation mods or the streaming budget (sys_budget_videomem) are the levers.') }
        if ($script:Hw.MinFree -lt 2048) { $v.Add('Windows ran very low on free RAM (' + ('{0:0.0}' -f ($script:Hw.MinFree / 1024)) + ' GB): out-of-memory is possible.') }
        if ($pi.NotRespSince) { $v.Add('The window had been "not responding" for ' + (Fmt-Span ([datetime]::Now - $pi.NotRespSince)) + ' before the end: a hang, then killed.') }
        if ($S.LastLuaOwner -and $S.Err -gt 0) { $v.Add('The last Lua owner to log an error was "' + $S.LastLuaOwner + '" (' + (Mod-Label $S.LastLuaOwner) + '). A script error rarely kills the game by itself, but it is the last mod-side evidence.') }
        if ($S.Err -eq 0 -and $hw -eq 0 -and -not $rebooted -and $dumps.Count -eq 0 -and $null -ne $code -and $code -ne 0) { $v.Add('No error was logged by the game, there is no dump and no hardware event: the logs cannot name a cause. After the next crash look in %TEMP% for "Kingdom Come*.dmp" (BugSplat''s own dump) and copy it somewhere safe before anything cleans Temp.') }
        if ($bsLine) { $v.Add($bsLine) }
        if ($dumpInfo.Count -gt 0) { $v.Add('The crash dump (above) is the best evidence: trust its faulting module over the process exit code.') }
        elseif ($bsGone) { $v.Add('BugSplat wrote a dump but it is no longer on disk, so the faulting module cannot be named. Without the dump the logs only narrow it down (see the memory curve, the last lines of the plugin logs and what you did last).') }
        elseif ($dumps.Count -gt 0) { $v.Add('A dump/crash report exists (listed above). It holds the faulting module; run this console with -DumpFile <path> or send it over to be read.') }
        if (-not $S.LogSeen) { $v.Add('No kcd.log lines were read for this run (log missing, unreadable, or the game died before it wrote anything). Folder used: ' + $script:GameDir) }
        if ($v.Count -eq 0) { $v.Add('Closed without a CSystem::Quit line but with no crash evidence. Likely closed from Task Manager or the launcher window.') }
    }
    foreach ($l in $v) { Write-Plain ('  - ' + $l) }
    [void](Arc-Snapshot $true)
    Write-SessionSummary
    Write-SessionJson $true
    if ($script:ArcDir) {
        try {
            $rep = PJ $script:ArcDir 'postmortem.txt'
            $lines = @($script:Tee.ToArray())
            if ($lines.Count -eq 0) { $lines = @('(post-mortem produced no output)') }
            [System.IO.File]::WriteAllLines($rep, [string[]]$lines, $script:Utf8)
        } catch { }
        Notice ('logs of this run saved: ' + $script:ArcDir) 'green'
    }
    $script:Tee = $null
    Write-Line ''
    Write-Plain ('  Waiting for the next launch of ' + $ProcessName + '.exe ... (q = quit, ? = help, d = run history)') 'gray'
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
        [System.IO.File]::WriteAllLines((PJ $script:ArcDir 'summary.txt'), [string[]]$text, $script:Utf8)
    } catch { $script:CaptureTo = $null; Dbg ('Write-SessionSummary: ' + $_.Exception.Message + ' ' + $_.InvocationInfo.PositionMessage) }
}

# machine-readable result of a run: used by run history and "what changed since last run"
function Write-SessionJson([bool]$final) {
    if (-not $script:ArcDir) { return }
    try {
        $S = $script:S; $pi = $script:ProcInfo
        $cats = [ordered]@{}
        foreach ($c in ($S.Cats.Values | Sort-Object { -$_.Count })) { $cats[$c.Id] = @{ Count=$c.Count; Lvl=$c.Lvl; Title=$c.Title } }
        $lua = [ordered]@{}
        foreach ($cid in @('luaerr', 'luawarn', 'luagen')) { if ($S.Cats.ContainsKey($cid)) { foreach ($kv in $S.Cats[$cid].Owners.GetEnumerator()) { if ($lua.Contains($kv.Key)) { $lua[$kv.Key] = $lua[$kv.Key] + $kv.Value } else { $lua[$kv.Key] = $kv.Value } } } }
        $o = [ordered]@{
            Tool = ('KCD2Console ' + $script:Ver)
            Written = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
            Final = $final
            Start = $(if ($S.Start) { $S.Start.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
            End = $(if ($pi.Exit) { $pi.Exit.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
            Phase = $S.Phase
            GameVer = $S.GameVer; ExtVer = $S.ExtVer; Build = $S.Build; DevMode = $S.DevMode
            ModsFound = $S.ModsFound; ModsEnabledN = $S.ModsEnabledN
            ModsEnabled = @($S.EnabledOrder.ToArray())
            Disabled = @($S.Disabled.ToArray()); NotFound = @($S.NotFound.ToArray()); BadModId = @($S.BadModId.ToArray())
            Errors = $S.Err; Warnings = $S.Warn; Noise = $S.Noise
            Cats = $cats; LuaOwners = $lua
            SavesWritten = $S.SavesWritten; MaxEntities = $S.MaxEntities
            Loads = @($S.Loads | ForEach-Object { @{ Save=$_.Save; Secs=$_.Secs } })
            Levels = @($S.Levels.ToArray())
            CleanExit = $S.CleanExit; QuitReason = $S.QuitReason; ExitCode = $pi.ExitCode
            PeakMemMB = [Math]::Round([Math]::Max([double]$pi.Peak, [double]$pi.Mem) / 1MB); PeakPrivMB = [Math]::Round([Math]::Max([double]$pi.PeakPriv, [double]$pi.Priv) / 1MB)
            LastPrivMB = [Math]::Round([double]$pi.Priv / 1MB)
            ExitOk = ($null -ne $pi.ExitCode -and [string]$pi.ExitCode -eq '0')
            MemTimeline = @($script:Hw.Timeline.ToArray() | ForEach-Object { $_.T.ToString('HH:mm') + ' private ' + [string][Math]::Round([double]$_.Priv / 1MB) + ' MB, working set ' + [string][Math]::Round([double]$_.WS / 1MB) + ' MB, VRAM ' + [string][Math]::Round([double]$_.Vram) + ' MB, ' + $_.Phase })
            BugSplat = $script:BsInfo
            PeakVramMB = [Math]::Round($script:Hw.PeakVram); PeakTempC = $script:Hw.PeakTemp
            KcsePlugins = @($S.Kc.Registered.ToArray()); KcseAsi = @($S.Kc.Asi.ToArray())
            Milestones = @($S.Milestones.ToArray())
        }
        [System.IO.File]::WriteAllText((PJ $script:ArcDir 'session.json'), ($o | ConvertTo-Json -Depth 6), $script:Utf8)
    } catch { Dbg ('Write-SessionJson: ' + $_.Exception.Message + ' ' + $_.InvocationInfo.PositionMessage) }
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
        Write-SessionJson $false
        try {
            $tail = @($script:Ring.ToArray() | Select-Object -Last 300 | ForEach-Object { Strip-Ansi $_ })
            $head = @('Live tail written ' + $now.ToString('yyyy-MM-dd HH:mm:ss') + ' (last 300 visible console lines). If the game has ended, postmortem.txt holds the full verdict.')
            $raw = @('--- last 60 raw kcd.log lines ---') + @($script:RawTail.ToArray() | Select-Object -Last 60)
            [System.IO.File]::WriteAllLines((PJ $script:ArcDir 'tail.txt'), [string[]]($head + $tail + $raw), $script:Utf8)
        } catch { }
    }
}

function Finish-Session([string]$why) {
    if ($script:S.Phase -eq 'Idle') { return }
    if ($script:ArcDir) { [void](Arc-Snapshot $true) }
    Write-SessionSummary
    Write-SessionJson $true
    $script:S = New-Session
    $script:ArcDir = $null
    if ($script:Transcript) { try { $script:Transcript.Dispose() } catch { }; $script:Transcript = $null }
}
#endregion

#region ---------------------------------------------------------------- reports, pre-flight, pak overlaps, commands, history
function Row([string[]]$cells, [int[]]$w) {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $cells.Count; $i++) {
        $c = $cells[$i]; if ($null -eq $c) { $c = '' }
        if ($i -lt $cells.Count - 1 -and $i -lt $w.Count) { [void]$sb.Append((Pad (Trunc $c $w[$i]) ($w[$i] + 1))) } else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}
function Top-Owners($c, [int]$n) {
    if (-not $c.Owners -or $c.Owners.Count -eq 0) { return '' }
    $p = @($c.Owners.GetEnumerator() | Sort-Object { -$_.Value } | Select-Object -First $n | ForEach-Object { $_.Key + $script:G.rep + (Fmt-N $_.Value) })
    $more = ''; if ($c.Owners.Count -gt $n) { $more = ' +' + ($c.Owners.Count - $n) + ' more' }
    return (($p -join ', ') + $more)
}
function Lvl-Name([int]$l) { if ($l -ge 0 -and $l -le 3) { return $script:LvlName[$l] } return '???' }

function Show-Tallies([int]$top = 25) {
    $S = $script:S
    Write-Head 'Problem categories this run (hidden-noise categories included)'
    $cats = @($S.Cats.Values | Where-Object { $_.Count -gt 0 } | Sort-Object @{Expression={ if ($_.Lvl -ge 2) { 0 } else { 1 } }}, @{Expression={ -$_.Count }})
    if ($cats.Count -eq 0) { Write-Plain '  nothing counted yet' 'gray'; return }
    Write-Plain ('  ' + (Row @('lvl', 'count', 'distinct', 'what', 'mostly from') @(4, 8, 9, 46))) 'gray'
    foreach ($c in ($cats | Select-Object -First $top)) {
        $col = $script:LvlCol[[Math]::Max(0, [Math]::Min(3, $c.Lvl))]
        $d = ''; if ($c.Distinct.Count -gt 0) { $d = Fmt-N $c.Distinct.Count }
        Write-Plain ('  ' + (Row @((Lvl-Name $c.Lvl), (Fmt-N $c.Count), $d, $c.Title, (Top-Owners $c 3)) @(4, 8, 9, 46))) $col
    }
    if ($cats.Count -gt $top) { Write-Plain ('  ... and ' + ($cats.Count - $top) + ' smaller categories') 'gray' }
    # Lua errors by owner
    $own = @{}
    foreach ($cid in @('luaerr', 'luawarn', 'luagen')) { if ($S.Cats.ContainsKey($cid)) { foreach ($kv in $S.Cats[$cid].Owners.GetEnumerator()) { if ($own.ContainsKey($kv.Key)) { $own[$kv.Key] += $kv.Value } else { $own[$kv.Key] = $kv.Value } } } }
    if ($own.Count -gt 0) {
        Write-Head 'Lua script problems by owning mod'
        foreach ($kv in ($own.GetEnumerator() | Sort-Object { -$_.Value } | Select-Object -First 15)) { Write-Plain ('  ' + (Pad (Fmt-N $kv.Value) 8) + (Mod-Label $kv.Key)) 'red' }
    }
    # chatty tags
    $tags = @($S.Tags.GetEnumerator() | Sort-Object { -$_.Value.N } | Select-Object -First 10)
    if ($tags.Count -gt 0) {
        Write-Head 'Chattiest log tags ([Tag] prefix) - who fills the log'
        Write-Plain ('  ' + (Row @('tag', 'lines', 'err', 'warn') @(28, 9, 6))) 'gray'
        foreach ($t in $tags) { Write-Plain ('  ' + (Row @($t.Key, (Fmt-N $t.Value.N), (Fmt-N $t.Value.E), (Fmt-N $t.Value.W)) @(28, 9, 6))) $(if ($t.Value.E -gt 0) { 'byellow' } else { 'gray' }) }
    }
}

function Show-Recent {
    Write-Head 'Most recent distinct problems (newest last)'
    $l = @(Get-RecentLines 25)
    if ($l.Count -eq 0) { Write-Plain '  none' 'green'; return }
    foreach ($x in $l) { Write-Plain ('  ' + (Trunc $x 230)) 'red' }
}

function Read-OrderFile([string]$path) {
    $r = New-Object System.Collections.Generic.List[string]
    try {
        $t = $script:Utf8.GetString([System.IO.File]::ReadAllBytes($path))
        if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
        foreach ($l in $t.Split("`n")) { $x = $l.Trim(); if ($x -ne '') { $r.Add($x) } }
    } catch { }
    return $r
}

function Show-Mods {
    $S = $script:S
    Build-ManifestIndex
    Write-Head ('Mods: ' + $S.ModsEnabledN + ' enabled by the game, ' + $script:Order.Count + ' in mod_order.txt, ' + $script:Manifests.Count + ' folders on disk')
    if ($S.EnabledOrder.Count -gt 0) {
        Write-Plain '  Load order the game actually used (a later mod overrides an earlier one):' 'gray'
        $i = 0
        foreach ($e in $S.EnabledOrder) {
            $i++
            $fl = New-Object System.Collections.Generic.List[string]
            if ($S.WildMods.ContainsKey($e)) { $fl.Add('wildcard ' + $S.WildMods[$e]) }
            if ($S.LuaInit -contains $e) { $fl.Add('lua') }
            $mi = $null; $k = $e.ToLowerInvariant(); if ($script:Manifests.ContainsKey($k)) { $mi = $script:Manifests[$k] }
            if ($mi -and $mi.Plugins.Count -gt 0) { $fl.Add('plugin: ' + ($mi.Plugins -join ',')) }
            $tg = $null; if ($S.Tags.ContainsKey($e)) { $tg = $S.Tags[$e] } elseif ($mi -and $mi.Name -and $S.Tags.ContainsKey($mi.Name)) { $tg = $S.Tags[$mi.Name] }
            if ($tg -and $tg.E -gt 0) { $fl.Add([string]$tg.E + ' err') }
            Write-Plain ('  ' + (Pad ([string]$i) 4) + (Pad (Mod-Label $e) 58) + ($fl -join '  ')) $(if ($e -eq 'zzz_merge_patch') { 'cyan' } else { '' })
        }
    } else { Write-Plain '  (kcd.log has not been read yet, so the enabled list is empty. Showing mod_order.txt instead.)' 'byellow'; $i = 0; foreach ($e in $script:Order) { $i++; Write-Plain ('  ' + (Pad ([string]$i) 4) + (Mod-Label $e)) } }
    if ($S.Disabled.Count -gt 0) { Write-Head 'Disabled by the game (version restriction)'; foreach ($d in $S.Disabled) { Write-Plain ('  ' + $d) 'bred' } }
    if ($S.NotFound.Count -gt 0) { Write-Head 'In mod_order.txt but the game found no such mod'; foreach ($d in $S.NotFound) { Write-Plain ('  ' + $d + (Hint-NotFound $d)) 'bred' } }
    if ($S.BadModId.Count -gt 0) { Write-Head 'Manifest with an invalid ModId (only lowercase letters and _ are allowed)'; foreach ($d in $S.BadModId) { Write-Plain ('  ' + $d) 'byellow' } }
    if ($S.OrderDiff.Count -gt 0) { Write-Head 'Enabled order differs from mod_order.txt'; foreach ($d in $S.OrderDiff) { Write-Plain ('  ' + $d) 'byellow' } }
    if ($S.NotLoaded.Count -gt 0) { Write-Head 'Listed in mod_order.txt but not enabled'; foreach ($d in $S.NotLoaded) { Write-Plain ('  ' + $d) 'byellow' } }
    if ($S.SaveDiff.Count -gt 0) { Write-Head 'Mods used while saving vs mods now (last save loaded)'; foreach ($d in $S.SaveDiff) { Write-Plain ('  ' + $d) $(if ($d -like 'in the save, NOT*') { 'bred' } else { 'byellow' }) } }
    # disk folders not enabled
    $enCI = @{}; foreach ($e in $S.EnabledOrder) { $enCI[$e.ToLowerInvariant()] = $true }
    $un = @($script:Manifests.Values | Where-Object { -not $enCI.ContainsKey($_.Folder.ToLowerInvariant()) } | Sort-Object Folder)
    if ($un.Count -gt 0 -and $S.EnabledOrder.Count -gt 0) { Write-Head 'Mod folders on disk that are not enabled'; foreach ($m in $un) { Write-Plain ('  ' + (Mod-Label $m.Folder)) 'gray' } }
    Write-Head 'mod_order.txt file'
    if (-not [System.IO.File]::Exists($script:CfgPath)) { Write-Plain ('  missing: ' + $script:CfgPath) 'bred' }
    else {
        $o = $script:OrderInfo
        Write-Plain ('  ' + $script:CfgPath + '   (' + $script:Order.Count + ' entries, ' + $(if ($o.Crlf) { 'CRLF' } else { 'LF' }) + $(if ($o.Bom) { ', UTF-8 BOM' } else { '' }) + ')')
        if ($o.Dups.Count -gt 0) { Write-Plain ('  duplicate entries (ignored): ' + ($o.Dups -join ', ')) 'byellow' }
        if ($o.Spaces.Count -gt 0) { Write-Plain ('  entries with leading/trailing spaces: ' + $o.Spaces.Count) 'byellow' }
        $zi = $script:Order.IndexOf('zzz_merge_patch')
        if ($zi -ge 0) { Write-Plain ('  zzz_merge_patch is at position ' + ($zi + 1) + ' of ' + $script:Order.Count + $(if ($zi -eq $script:Order.Count - 1) { ' (last: correct)' } else { '  - NOT last' })) $(if ($zi -eq $script:Order.Count - 1) { 'green' } else { 'bred' }) }
        if ($script:StageDir) {
            $sf = Ci-Child $script:StageDir 'mod_order.txt'
            if ($sf) {
                $so = Read-OrderFile $sf
                $same = ($so.Count -eq $script:Order.Count)
                if ($same) { for ($j = 0; $j -lt $so.Count; $j++) { if ($so[$j] -cne $script:Order[$j]) { $same = $false; break } } }
                if ($same) { Write-Plain '  Vortex staging copy of mod_order.txt is identical.' 'green' }
                else {
                    Write-Plain ('  Vortex staging copy differs (' + $so.Count + ' entries vs ' + $script:Order.Count + '): the next Vortex deploy would rewrite the live file.') 'byellow'
                    $a = @($so | Where-Object { -not $script:OrderIdx.ContainsKey($_) }); $b = @($script:Order | Where-Object { $so -cnotcontains $_ })
                    if ($a.Count -gt 0) { Write-Plain ('    only in staging: ' + (Trunc ($a -join ', ') 200)) 'gray' }
                    if ($b.Count -gt 0) { Write-Plain ('    only in live:    ' + (Trunc ($b -join ', ') 200)) 'gray' }
                }
            }
        }
    }
}

function Show-Hardware {
    $H = $script:Hw
    Write-Head 'Hardware'
    if ($H.VramTotal -gt 0) {
        Write-Plain ('  GPU memory now ' + ('{0:0.0}' -f ($H.Vram / 1024)) + ' / ' + ('{0:0.0}' -f ($H.VramTotal / 1024)) + ' GB   peak this run ' + ('{0:0.0}' -f ($H.PeakVram / 1024)) + ' GB   temp ' + $H.Temp + ' C (peak ' + $H.PeakTemp + ')   util ' + $H.Util + '%   power ' + $H.Watt + ' W')
    } else { Write-Plain '  no GPU samples yet (nvidia-smi missing, -NoHardware, or the game is not running)' 'gray' }
    if ($H.TotalNow -gt 0) { Write-Plain ('  System RAM free ' + ('{0:0.0}' -f ($H.FreeNow / 1024)) + ' of ' + ('{0:0.0}' -f ($H.TotalNow / 1024)) + ' GB   lowest this run ' + $(if ($H.MinFree -lt [double]::MaxValue) { ('{0:0.0}' -f ($H.MinFree / 1024)) } else { '-' }) + ' GB') }
    $pi = $script:ProcInfo
    if ($script:Proc) { Write-Plain ('  KingdomCome.exe: working set ' + (Fmt-Bytes $pi.Mem) + ' (peak ' + (Fmt-Bytes $pi.Peak) + '), private ' + (Fmt-Bytes $pi.Priv) + ', ' + $pi.Threads + ' threads, ' + $pi.Handles + ' handles, ' + $(if ($pi.Responding) { 'responding' } else { 'NOT RESPONDING' })) }
    $sm = @($H.Samples.ToArray() | Select-Object -Last 12)
    if ($sm.Count -gt 0) {
        Write-Plain ''
        Write-Plain ('  ' + (Row @('time', 'VRAM GB', 'GPU C', 'GPU %', 'RAM free GB', 'game private') @(9, 9, 7, 7, 13))) 'gray'
        foreach ($x in $sm) { Write-Plain ('  ' + (Row @($x.T.ToString('HH:mm:ss'), ('{0:0.0}' -f ($x.Vram / 1024)), [string]$x.Temp, [string]$x.Util, ('{0:0.0}' -f ($x.Free / 1024)), (Fmt-Bytes $x.Priv)) @(9, 9, 7, 7, 13))) }
    }
    Write-Plain ''
    Write-Plain '  Rule: a hard crash with no game error is hardware until proven otherwise (check drivers, temperatures, RGB/fan controllers and PCIe devices).' 'gray'
}

function Show-SysEvents {
    Write-Head 'Windows events (last 6 hours, game-relevant only)'
    if (-not $script:IsWin) { Write-Plain '  not on Windows' 'gray'; return }
    $ev = @(Get-SysEvents ([datetime]::Now.AddHours(-6)) ([datetime]::Now.AddMinutes(1)) $true)
    if ($ev.Count -eq 0) { Write-Plain '  none (no app crash/hang, Kernel-Power 41, WHEA, GPU driver reset, disk error, bugcheck or Corsair event)' 'green'; return }
    foreach ($e in $ev) { Write-Plain ('  ' + $e.T.ToString('MM-dd HH:mm:ss') + '  ' + (Pad $e.Log 12) + $e.Prov + ' #' + $e.Id + '  ' + (Trunc $e.Msg 170)) $(if (Is-HwEvent $e) { 'bred' } else { 'byellow' }) }
}

function Show-Summary([bool]$final = $false) {
    $S = $script:S; $pi = $script:ProcInfo
    Write-Head ('KCD2 run summary' + $(if ($final) { ' (final)' } else { '' }) + '   ' + [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))
    if ($S.Phase -eq 'Idle' -and -not $S.LogSeen) { Write-Plain '  No run seen yet. Start the game; this window will follow it.' 'gray'; return }
    $up = ''
    if ($script:Proc -and $S.Start) { $up = '   (run time ' + (Fmt-Span (([datetime]::Now) - $S.Start)) + ')' } elseif ($pi.Uptime) { $up = '   (ran ' + (Fmt-Span $pi.Uptime) + ')' }
    Write-Plain ('  Phase ........... ' + $S.Phase + $up)
    Write-Plain ('  Game ............ ' + $(if ($S.GameVer) { $S.GameVer } else { '?' }) + '  build ' + $(if ($S.ExtVer) { $S.ExtVer } else { '?' }) + '  ' + $(if ($S.DevMode) { '-devmode ON' } else { 'devmode off' }) + $(if ($S.Cmdline) { '   cmdline: ' + (Trunc $S.Cmdline 80) } else { '' }))
    if ($S.Gpu) { Write-Plain ('  Machine ......... ' + $S.Gpu + ', ' + $S.VramMB + ' MB VRAM, ' + $S.RamMB + ' MB RAM') }
    Write-Plain ('  Mods ............ ' + $S.ModsEnabledN + ' enabled of ' + $S.ModsFound + ' found; mod_order.txt has ' + $script:Order.Count + '; disabled by game ' + $S.Disabled.Count + ', not found ' + $S.NotFound.Count + ', bad ModId ' + $S.BadModId.Count)
    if ($S.PhaseLog.Count -gt 0) { Write-Plain ('  Phase timings ... ' + (($S.PhaseLog | Select-Object -Last 8) -join ' | ')) }
    if ($S.MenuAt -and $S.Start -and $S.MenuAt -ge $S.Start -and ($S.MenuAt - $S.Start).TotalMinutes -lt 30) { Write-Plain ('  Boot to menu .... ' + (Fmt-Span ($S.MenuAt - $S.Start))) }
    if ($S.Loads.Count -gt 0) {
        $ls = @($S.Loads | ForEach-Object { $_.Save + $(if ($null -ne $_.Secs) { ' (' + (Fmt-Span ([timespan]::FromSeconds($_.Secs))) + ')' } else { '' }) })
        Write-Plain ('  Saves loaded .... ' + $S.Loads.Count + ': ' + (Trunc ($ls -join ', ') 150))
    }
    if ($S.Levels.Count -gt 0) { Write-Plain ('  Levels .......... ' + (($S.Levels | Select-Object -Last 4) -join ', ')) }
    if ($S.Pso.Count -gt 0) { Write-Plain ('  PSO precache .... ' + (($S.Pso | Select-Object -Last 2) -join ' | ')) }
    Write-Plain ('  Saves written ... ' + $S.SavesWritten + $(if ($S.MaxEntities -gt 0) { '   (largest: ' + (Fmt-N $S.MaxEntities) + ' entities)' } else { '' }))
    Write-Plain ('  KCSE ............ ' + $(if ($S.Kc.Ver) { 'v' + $S.Kc.Ver + '  ' } else { 'no KCSE.log lines  ' }) + $S.Kc.Registered.Count + ' plugins registered, ' + $S.Kc.Loaded.Count + ' loaded, ' + $S.Kc.Asi.Count + ' ASI' + $(if ($S.Kc.Ready) { ', ready' } else { ', NOT ready' }))
    if ($S.Comp -gt 0) { Write-Plain ('  Companion mod ... ' + $S.Comp + ' log lines') }
    Write-Plain ('  Log lines ....... errors ' + (Fmt-N $S.Err) + '   warnings ' + (Fmt-N $S.Warn) + '   hidden noise ' + (Fmt-N $S.Noise) + '   total ' + (Fmt-N $S.Lines))
    if ($script:Proc) { Write-Plain ('  Process ......... PID ' + $pi.Pid + '  ' + (Fmt-Bytes $pi.Mem) + ' (peak ' + (Fmt-Bytes $pi.Peak) + ')') }
    elseif ($pi.Exit) { Write-Plain ('  Process ......... exited ' + $pi.Exit.ToString('HH:mm:ss') + ' - ' + (Describe-Exit $pi.ExitCode)) }
    if ($S.CleanExit) { Write-Plain '  Shutdown ........ clean (CSystem::Quit seen)' 'green' }
    elseif ($pi.Exit -and $null -ne $pi.ExitCode -and [string]$pi.ExitCode -eq '0') { Write-Plain '  Shutdown ........ exit code 0 (closed normally; no CSystem::Quit line was written)' 'green' }
    if ($S.Milestones.Count -gt 0) { Write-Plain '  Flags:' 'byellow'; foreach ($x in ($S.Milestones | Select-Object -Last 10)) { Write-Plain ('    ' + (Trunc $x 200)) 'byellow' } }
    Show-Tallies 10
    if ($S.SaveDiff.Count -gt 0) { Write-Head 'Mods vs the loaded save'; foreach ($d in ($S.SaveDiff | Select-Object -First 12)) { Write-Plain ('  ' + $d) 'byellow' } }
}

function Show-Help {
    Write-Head 'Keys'
    $k = @(
        '?  this help                    q  quit                     p  pause / resume output',
        's  run summary                  w  problem tallies          m  mods and load order',
        'e  recent distinct problems     g  hardware (GPU/RAM)       h  Windows events (6 h)',
        'k  pre-flight check             u  pak overlaps (which mod wins)   t  find a file inside mods',
        '/  console commands your mods add   d  run history and changes since last run',
        'v  show / hide noise            r  raw mode on/off          l  cycle minimum level',
        'f  include filter (regex)       x  exclude filter (regex)   c  clear screen',
        'a  copy logs to the session folder now   o  open the data folder   i  paths and settings',
        'b  toggle beep on crash/hang'
    )
    foreach ($l in $k) { Write-Plain ('  ' + $l) }
    Write-Head 'Command line (same things, no live window)'
    foreach ($l in @('-Check          pre-flight report, then exit (exit code 2 = failures, 1 = warnings)', '-Analyze        report on the current logs, then exit', '-AnalyzeFolder  report on an archived session folder', '-Overlaps       files provided by more than one mod', '-Commands       console commands registered by mods', '-History        run table and what changed between the last two runs', '-FindFile <rx>  which mods ship a path matching the regex', '-DumpFile <p>   read a crash dump (.dmp or the BugSplat .zip)', '-MinLevel Warn | -Include <rx> | -Exclude <rx> | -Raw | -FromStart | -Beep')) { Write-Plain ('  ' + $l) }
}

function Show-Info {
    Write-Head 'Paths and settings'
    foreach ($p in @(@('Console', $script:Ver), @('PowerShell', $PSVersionTable.PSVersion.ToString()), @('Game folder', $script:GameDir), @('Executable', $script:ExePath), @('mod_order.txt', $script:CfgPath), @('Vortex staging', $script:StageDir), @('Saves', $script:SaveDir), @('Data folder', $OutDir), @('Session archive', $script:ArcDir), @('Min level', $script:LvlName[$script:MinLvl]), @('Raw / noise shown', ([string]$script:ShowRaw + ' / ' + [string]$script:ShowNoise)), @('Include', $Include), @('Exclude', $Exclude))) {
        Write-Plain ('  ' + (Pad $p[0] 18) + $p[1])
    }
    Write-Head ('Log files followed (' + $script:Sources.Count + ')')
    foreach ($s in $script:Sources) { Write-Plain ('  ' + (Pad $s.Tag 6) + (Pad $s.Name 34) + (Pad (Fmt-N $s.Lines) 10) + $(if ($s.Stale) { 'stale (older run)' } elseif ($s.Big) { 'big: tail only' } else { '' }) + $(if ($s.Resets -gt 0) { '  restarted x' + $s.Resets } else { '' })) 'gray' }
}

# ---------------- run history
function Get-Sessions {
    $r = New-Object System.Collections.Generic.List[object]
    $root = PJ $OutDir 'sessions'
    if (-not [System.IO.Directory]::Exists($root)) { return $r }
    foreach ($d in ([System.IO.Directory]::EnumerateDirectories($root) | Sort-Object)) {
        $j = PJ $d 'session.json'
        if (-not [System.IO.File]::Exists($j)) { continue }
        try { $o = (Get-Content -LiteralPath $j -Raw -ErrorAction Stop) | ConvertFrom-Json; $r.Add(@{ Dir=$d; J=$o; Name=[System.IO.Path]::GetFileName($d) }) } catch { }
    }
    return $r
}
function Compare-Sessions($a, $b) {
    $out = New-Object System.Collections.Generic.List[string]
    $ga = [string](Jget $a 'GameVer' ''); $gb = [string](Jget $b 'GameVer' '')
    $ea = [string](Jget $a 'ExtVer' ''); $eb = [string](Jget $b 'ExtVer' '')
    if ($ga -ne $gb -or $ea -ne $eb) { $out.Add('GAME UPDATED: ' + $ga + ' ' + $ea + ' -> ' + $gb + ' ' + $eb) }
    $ma = @(Jget $a 'ModsEnabled' @()); $mb = @(Jget $b 'ModsEnabled' @())
    $ad = @($mb | Where-Object { $ma -cnotcontains $_ }); $rm = @($ma | Where-Object { $mb -cnotcontains $_ })
    if ($ad.Count -gt 0) { $out.Add('mods added: ' + ($ad -join ', ')) }
    if ($rm.Count -gt 0) { $out.Add('mods removed: ' + ($rm -join ', ')) }
    if ($ad.Count -eq 0 -and $rm.Count -eq 0 -and $ma.Count -gt 1) {
        $same = $true; for ($i = 0; $i -lt $ma.Count; $i++) { if ($ma[$i] -cne $mb[$i]) { $same = $false; break } }
        if (-not $same) { $out.Add('same mods, different order') }
    }
    $la = Jget $a 'LuaOwners' $null; $lb = Jget $b 'LuaOwners' $null
    if ($lb) {
        foreach ($p in $lb.PSObject.Properties) {
            $before = 0; if ($la) { $q = $la.PSObject.Properties[$p.Name]; if ($q) { $before = [double]$q.Value } }
            if ($before -eq 0 -and [double]$p.Value -gt 0) { $out.Add('NEW Lua errors from ' + $p.Name + ' (' + $p.Value + ')') }
            elseif ($before -gt 0 -and [double]$p.Value -gt ($before * 3) -and [double]$p.Value -gt 20) { $out.Add('Lua errors from ' + $p.Name + ' grew ' + $before + ' -> ' + $p.Value) }
        }
    }
    if ($la) { foreach ($p in $la.PSObject.Properties) { if (-not ($lb -and $lb.PSObject.Properties[$p.Name])) { $out.Add('Lua errors gone: ' + $p.Name) } } }
    $ka = @(Jget $a 'KcsePlugins' @()); $kb = @(Jget $b 'KcsePlugins' @())
    $kd = @($ka | Where-Object { $kb -cnotcontains $_ }); $ke = @($kb | Where-Object { $ka -cnotcontains $_ })
    if ($kd.Count -gt 0) { $out.Add('KCSE plugin no longer registered: ' + ($kd -join '; ')) }
    if ($ke.Count -gt 0) { $out.Add('KCSE plugin newly registered: ' + ($ke -join '; ')) }
    $ca = @(Jget $a 'Disabled' @()); $cb = @(Jget $b 'Disabled' @())
    if ($cb.Count -ne $ca.Count) { $out.Add('mods disabled by the game: ' + $ca.Count + ' -> ' + $cb.Count) }
    return $out
}
function Show-History([int]$n = 15) {
    Write-Head 'Run history (archived sessions)'
    $all = @(Get-Sessions)
    if ($all.Count -eq 0) { Write-Plain ('  none yet in ' + (PJ $OutDir 'sessions')) 'gray'; return }
    Write-Plain ('  ' + (Row @('started', 'game', 'mods', 'ran', 'err', 'warn', 'exit', 'peak VRAM', 'end') @(17, 12, 5, 9, 7, 7, 11, 10))) 'gray'
    foreach ($s in ($all | Select-Object -Last $n)) {
        $j = $s.J
        $ran = ''; try { $st = [datetime]::Parse([string](Jget $j 'Start' '')); $en = [string](Jget $j 'End' ''); if ($en) { $ran = Fmt-Span (([datetime]::Parse($en)) - $st) } else { $ran = '?' } } catch { }
        $ec = Jget $j 'ExitCode' $null
        $clean = [bool](Jget $j 'CleanExit' $false)
        $zero = ($null -ne $ec -and [string]$ec -eq '0')
        $end = 'abnormal'; $col = 'bred'
        if ($clean) { $end = 'clean'; $col = 'green' }
        elseif ($zero) { $end = 'exit 0'; $col = 'green' }
        elseif (-not (Jget $j 'Final' $false)) { $end = 'cut off'; $col = 'byellow' }
        elseif ($null -eq $ec -or [string]$ec -eq '') { $end = 'no Quit line'; $col = 'byellow' }
        $es = ''; if ($null -ne $ec) { $es = [string]$ec }
        Write-Plain ('  ' + (Row @(([string](Jget $j 'Start' '')), ([string](Jget $j 'GameVer' '')), ([string](Jget $j 'ModsEnabledN' '')), $ran, (Fmt-N ([double](Jget $j 'Errors' 0))), (Fmt-N ([double](Jget $j 'Warnings' 0))), $es, $(if ([double](Jget $j 'PeakVramMB' 0) -gt 0) { ('{0:0.0}' -f ([double](Jget $j 'PeakVramMB' 0) / 1024)) + ' GB' } else { '' }), $end) @(17, 12, 5, 9, 7, 7, 11, 10))) $col
    }
    if ($all.Count -ge 2) {
        $a = $all[$all.Count - 2].J; $b = $all[$all.Count - 1].J
        Write-Head ('What changed between the last two runs  (' + $all[$all.Count - 2].Name + '  ->  ' + $all[$all.Count - 1].Name + ')')
        $d = Compare-Sessions $a $b
        if ($d.Count -eq 0) { Write-Plain '  nothing notable: same game build, same mods and order, no new Lua error sources' 'green' }
        else { foreach ($x in $d) { Write-Plain ('  ' + $x) $(if ($x -like 'GAME UPDATED*' -or $x -like 'NEW Lua*') { 'bred' } else { 'byellow' }) } }
    }
    $bad = @($all | Where-Object { -not [bool](Jget $_.J 'CleanExit' $false) -and -not ([string](Jget $_.J 'ExitCode' '') -eq '0') })
    if ($bad.Count -gt 0) { Write-Plain '' ; Write-Plain ('  ' + $bad.Count + ' of ' + $all.Count + ' archived runs ended with a non-zero exit code or without any recorded exit. Each has postmortem.txt in its folder. ("exit 0" with no Quit line is a normal close.)') 'byellow' }
}

# ---------------- pre-flight
function Test-VerMatch([string]$gv, [string]$pat) {
    if (-not $pat) { return $true }
    $p = $pat.Trim()
    return ($gv -like $p)
}
function Pf([string]$lvl, [string]$text) {
    switch ($lvl) {
        'ok'   { $script:PfOk++;   Write-Plain ('  [ OK ] ' + $text) 'green' }
        'warn' { $script:PfWarn++; Write-Plain ('  [WARN] ' + $text) 'byellow' }
        'fail' { $script:PfFail++; Write-Plain ('  [FAIL] ' + $text) 'bred' }
        default { Write-Plain ('  [info] ' + $text) 'gray' }
    }
}
function Run-Preflight {
    $script:PfOk = 0; $script:PfWarn = 0; $script:PfFail = 0
    Write-Banner 'PRE-FLIGHT CHECK  (read-only: nothing is changed)' 'bcyan'
    if (-not $script:GameDir) { Pf 'fail' 'KCD2 folder not found. Use -GamePath "C:\Steam\steamapps\common\KingdomComeDeliverance2".'; return 2 }
    Reset-ManifestIndex; Build-ManifestIndex; Load-Order
    Write-Head 'Install'
    Pf 'ok' ('game folder ' + $script:GameDir)
    if ($script:ExePath -and [System.IO.File]::Exists($script:ExePath)) { Pf 'ok' ('executable ' + $script:ExePath) } else { Pf 'fail' 'KingdomCome.exe not found under Bin' }
    $st = Get-State
    $gver = [string](Jget $st 'GameVer' ''); $ext = [string](Jget $st 'ExtVer' '')
    if (-not $gver -and $script:S.GameVer) { $gver = $script:S.GameVer }
    $gnum = ''; $mm = [regex]::Match($gver, '\d+(\.\d+)+'); if ($mm.Success) { $gnum = $mm.Value }
    if ($gver) { Pf 'info' ('last game version seen in a log: ' + $gver + $(if ($ext) { ' (' + $ext + ')' } else { '' })) } else { Pf 'info' 'no game version recorded yet (run the game once with the console open)' }
    $stamp = Get-WhgameStamp
    $pSz = [double](Jget $st 'WhgameSize' 0); $pTm = [string](Jget $st 'WhgameTime' '')
    if ($stamp.Size -gt 0 -and $pSz -gt 0) {
        if ([double]$stamp.Size -ne $pSz -or ($pTm -and $pTm -ne $stamp.Time)) { Pf 'warn' ('WHGame.dll changed since the last logged run (' + $pTm + ' -> ' + $stamp.Time + '): the game was patched. KCSE plugins and ASIs may need updating before launch.') }
        else { Pf 'ok' 'WHGame.dll is the same as at the last logged run (no patch since)' }
    }
    if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) { Pf 'warn' 'the game is running right now; changes to Mods or mod_order.txt take effect only on the next launch' }
    $lastEnd = [string](Jget $st 'RunEnd' ''); $lastStart = [string](Jget $st 'RunStart' '')
    if ($lastStart -and -not $lastEnd) { Pf 'warn' ('the last run (' + $lastStart + ') has no recorded end: this console was closed or the PC went down while the game ran') }
    $ss = @(Get-Sessions)
    if ($ss.Count -gt 0) {
        $l = $ss[$ss.Count - 1]
        if (-not [bool](Jget $l.J 'CleanExit' $false) -and -not ([string](Jget $l.J 'ExitCode' '') -eq '0')) { Pf 'warn' ('last archived run ' + $l.Name + ' ended with exit code ' + [string](Jget $l.J 'ExitCode' '(none recorded)') + ' and no normal Quit line (see postmortem.txt in that folder)') }
        else { Pf 'ok' ('last archived run ' + $l.Name + ' ended cleanly') }
    }
    Write-Head 'mod_order.txt'
    if (-not [System.IO.File]::Exists($script:CfgPath)) { Pf 'fail' ('missing: ' + $script:CfgPath + ' (no mod will load)') }
    else {
        Pf 'ok' ($script:Order.Count.ToString() + ' entries in ' + $script:CfgPath)
        $o = $script:OrderInfo
        if ($o.Bom) { Pf 'warn' 'file starts with a UTF-8 BOM; the first entry may not match its mod. Re-save as UTF-8 without BOM.' }
        if ($o.Dups.Count -gt 0) { Pf 'warn' ('duplicate entries: ' + ($o.Dups -join ', ')) }
        if ($o.Spaces.Count -gt 0) { Pf 'warn' ('entries with leading/trailing spaces: ' + (($o.Spaces | ForEach-Object { '"' + $_ + '"' }) -join ', ')) }
        $zi = $script:Order.IndexOf('zzz_merge_patch')
        if ($zi -ge 0 -and $zi -eq $script:Order.Count - 1) { Pf 'ok' 'zzz_merge_patch is last' }
        elseif ($zi -ge 0) { Pf 'fail' ('zzz_merge_patch is at ' + ($zi + 1) + ' of ' + $script:Order.Count + ' - it must be last or its merged files lose to later mods') }
        else { Pf 'info' 'no zzz_merge_patch entry (your merged keybind/Lua/hit_reaction patch is not in the order)' }
    }
    Write-Head 'Entries vs mod folders'
    $byFolder = @{}; $byId = @{}
    foreach ($mi in $script:Manifests.Values) { $byFolder[$mi.Folder] = $mi; if ($mi.Id) { $byId[$mi.Id] = $mi } }
    $bad = 0
    foreach ($e in $script:Order) {
        if ($byFolder.ContainsKey($e) -or $byId.ContainsKey($e)) { continue }
        $bad++
        Pf 'fail' ('"' + $e + '" has no mod.' + (Hint-NotFound $e))
    }
    if ($bad -eq 0) { Pf 'ok' 'every mod_order.txt entry matches a mod folder or modid (case-sensitive)' }
    $enabledSet = @{}; foreach ($e in $script:Order) { $enabledSet[$e] = $true }
    $notListed = @($script:Manifests.Values | Where-Object { -not $enabledSet.ContainsKey($_.Folder) -and (-not $_.Id -or -not $enabledSet.ContainsKey($_.Id)) } | Sort-Object Folder)
    if ($notListed.Count -gt 0) { Pf 'warn' ($notListed.Count.ToString() + ' mod folder(s) are on disk but not in mod_order.txt, so they will NOT load: ' + (Trunc (($notListed | ForEach-Object { $_.Folder }) -join ', ') 300)) }
    else { Pf 'ok' 'no stray mod folders (everything on disk is listed)' }
    Write-Head 'Manifests'
    $nm = 0; $badid = 0; $restr = 0; $nopak = 0
    foreach ($mi in ($script:Manifests.Values | Sort-Object Folder)) {
        $listed = ($enabledSet.ContainsKey($mi.Folder) -or ($mi.Id -and $enabledSet.ContainsKey($mi.Id)))
        if (-not $mi.HasManifest) { $nm++; Pf $(if ($listed) { 'fail' } else { 'warn' }) ($mi.Folder + ': no mod.manifest' + $(if ($listed) { ' but it is listed' } else { '' })); continue }
        if ($mi.Id -and $mi.Id -cnotmatch '^[a-z_]+$') { $badid++; Pf 'warn' ($mi.Folder + ': modid "' + $mi.Id + '" has characters other than lowercase letters and _ (game logs "invalid ModId"; digits only warn, capitals break the match)') }
        if ($listed -and $gnum -and $mi.Supports.Count -gt 0) {
            $okv = $false; foreach ($sp in $mi.Supports) { if (Test-VerMatch $gnum $sp) { $okv = $true } }
            if (-not $okv) { $restr++; Pf 'fail' ($mi.Folder + ' (' + $mi.Name + ' ' + $mi.Ver + ') supports only ' + ($mi.Supports -join ', ') + ' - the game (' + $gnum + ') will DISABLE it') }
        }
        if ($listed -and $mi.Paks -eq 0 -and $mi.Plugins.Count -eq 0) { $nopak++ }
    }
    if ($nm -eq 0 -and $badid -eq 0 -and $restr -eq 0) { Pf 'ok' ('all ' + $script:Manifests.Count + ' manifests read; versions are compatible with ' + $(if ($gnum) { $gnum } else { 'the game (version unknown, not checked)' })) }
    if ($nopak -gt 0) { Pf 'info' ($nopak.ToString() + ' listed mod(s) have no Data\*.pak and no plugin DLL (config/loose-file mods are fine)') }
    Write-Head 'Script extender (KCSE), plugins, ASIs'
    $d = Get-PluginDisk
    if ($d.Dlls.Count -eq 0 -and $d.Asi.Count -eq 0) { Pf 'info' 'no KCSE plugin DLLs or ASI files found' }
    foreach ($p in $d.Dlls) {
        $en = $true; if ($p.Mod -notlike '(*') { $en = $enabledSet.ContainsKey($p.Mod) -or ($byFolder.ContainsKey($p.Mod) -and $byFolder[$p.Mod].Id -and $enabledSet.ContainsKey($byFolder[$p.Mod].Id)) }
        if ($en) { Pf 'info' ('plugin ' + $p.File + '  (' + $p.Mod + ')') } else { Pf 'warn' ('plugin ' + $p.File + ' is in mod "' + $p.Mod + '" which is not in mod_order.txt; KCSE scans every mod folder, so it may still load') }
    }
    foreach ($a in $d.Asi) { Pf 'info' ('ASI ' + $a) }
    if ($d.Dlls.Count + $d.Asi.Count -gt 0) { Pf 'info' 'these hook the game exe: after any game patch they are the first things to break. Update them before blaming content mods.' }
    $kdir = Ci-Child $script:GameDir 'KCSE'
    if (-not $kdir -and $d.Dlls.Count -gt 0) { Pf 'warn' 'plugins exist but there is no KCSE folder in the game folder (script extender not installed?)' }
    Write-Head 'Settings, saves, disk'
    $uc = Ci-Child $script:GameDir 'user.cfg'
    if ($uc) {
        $lines = @(Get-Content -LiteralPath $uc -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('--') -and -not $_.Trim().StartsWith('//') })
        Pf 'info' ('user.cfg: ' + $lines.Count + ' active line(s)' + $(if ($lines.Count -gt 0) { ' - ' + (Trunc (($lines | Select-Object -First 6) -join ' ; ') 200) } else { '' }))
        foreach ($l in $lines) { if ($l -match '(?i)^\s*(r_displayinfo|sys_budget_videomem|e_view_dist_ratio|wh_pl_showfirecursor)\b') { Pf 'info' ('user.cfg sets: ' + $l.Trim()) } }
    } else { Pf 'info' 'no user.cfg' }
    try { $drv = [System.IO.Path]::GetPathRoot($script:GameDir); $di = New-Object System.IO.DriveInfo($drv); if ($di.AvailableFreeSpace -lt 15GB) { Pf 'warn' ('only ' + (Fmt-Bytes $di.AvailableFreeSpace) + ' free on ' + $drv + ' (shader cache and logs need room)') } else { Pf 'ok' ((Fmt-Bytes $di.AvailableFreeSpace) + ' free on ' + $drv) } } catch { }
    if ($script:SaveDir -and [System.IO.Directory]::Exists($script:SaveDir)) {
        $sf = @(Get-SaveFiles)
        if ($sf.Count -gt 0) {
            $newest = $sf | Sort-Object { $_.Time } -Descending | Select-Object -First 1
            $tiny = @($sf | Where-Object { $_.Len -lt 1024 })
            Pf 'ok' ($sf.Count.ToString() + ' save file(s); newest ' + $newest.Name + ' ' + $newest.Time.ToString('yyyy-MM-dd HH:mm') + ' ' + (Fmt-Bytes $newest.Len))
            if ($tiny.Count -gt 0) { Pf 'warn' ($tiny.Count.ToString() + ' save file(s) under 1 KB (empty/corrupt): ' + (($tiny | ForEach-Object { $_.Name }) -join ', ')) }
            try { $dr2 = [System.IO.Path]::GetPathRoot($script:SaveDir); $di2 = New-Object System.IO.DriveInfo($dr2); if ($di2.AvailableFreeSpace -lt 5GB) { Pf 'warn' ('only ' + (Fmt-Bytes $di2.AvailableFreeSpace) + ' free where saves are written') } } catch { }
        } else { Pf 'info' ('no .whs saves under ' + $script:SaveDir) }
    } else { Pf 'info' 'save folder not found (Saved Games\kingdomcome2)' }
    if ($script:StageDir) {
        $sfp = Ci-Child $script:StageDir 'mod_order.txt'
        if ($sfp) {
            $so = Read-OrderFile $sfp
            $same = ($so.Count -eq $script:Order.Count); if ($same) { for ($j = 0; $j -lt $so.Count; $j++) { if ($so[$j] -cne $script:Order[$j]) { $same = $false; break } } }
            if ($same) { Pf 'ok' 'Vortex staging mod_order.txt matches the live one' }
            else { Pf 'warn' ('Vortex staging mod_order.txt differs from the live one (' + $so.Count + ' vs ' + $script:Order.Count + ' entries): the next Vortex deploy will overwrite the live file') }
        }
    }
    Write-Head 'Logs left over from the last run'
    $kl = Ci-Child $script:GameDir 'kcd.log'
    if ($kl) {
        try {
            $fi = New-Object System.IO.FileInfo($kl)
            Pf 'info' ('kcd.log written ' + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + ', ' + (Fmt-Bytes $fi.Length))
            $txt = ''; $fs = New-Object System.IO.FileStream($kl, 'Open', 'Read', 'ReadWrite'); try { $n = [int][Math]::Min([long]200000, $fs.Length); $fs.Seek(-$n, 'End') | Out-Null; $b = New-Object byte[] $n; [void]$fs.Read($b, 0, $n); $txt = $script:Utf8.GetString($b) } finally { $fs.Dispose() }
            if ($txt -match 'CSystem::Quit invoked') { Pf 'ok' 'kcd.log ends with a normal CSystem::Quit' } else { Pf 'info' 'kcd.log has no CSystem::Quit at its end: a crash, a kill, a PC reset, a normal window close (not every normal close writes it) or the game is still running. The exit code in the run history (d) settles it.' }
        } catch { }
    }
    Write-Line ''
    $col = 'green'; if ($script:PfFail -gt 0) { $col = 'bred' } elseif ($script:PfWarn -gt 0) { $col = 'byellow' }
    Write-Plain ('  Result: ' + $script:PfOk + ' ok, ' + $script:PfWarn + ' warning(s), ' + $script:PfFail + ' failure(s)') $col
    if ($script:PfFail -gt 0) { return 2 } elseif ($script:PfWarn -gt 0) { return 1 } else { return 0 }
}

# ---------------- pak index: overlaps and file search
$script:PakIndex = $null
$script:PakMods = $null
$script:PakNote = ''
$script:PakBad = $null
function Get-ModLoadList {
    # (folder, dir) in load order: mod_order.txt first, then folders not listed (they would not load; flagged)
    $r = New-Object System.Collections.Generic.List[object]
    Build-ManifestIndex
    $byId = @{}; foreach ($mi in $script:Manifests.Values) { if ($mi.Id) { $byId[$mi.Id] = $mi } }
    $seen = @{}
    foreach ($e in $script:Order) {
        $mi = $null; $k = $e.ToLowerInvariant()
        if ($script:Manifests.ContainsKey($k)) { $mi = $script:Manifests[$k] } elseif ($byId.ContainsKey($e)) { $mi = $byId[$e] }
        if ($mi -and -not $seen.ContainsKey($mi.Folder)) { $seen[$mi.Folder] = $true; $r.Add(@{ Name=$e; Dir=$mi.Dir; Listed=$true; Mi=$mi }) }
    }
    foreach ($mi in ($script:Manifests.Values | Sort-Object Folder)) { if (-not $seen.ContainsKey($mi.Folder)) { $r.Add(@{ Name=$mi.Folder; Dir=$mi.Dir; Listed=$false; Mi=$mi }) } }
    return $r
}
function Build-PakIndex {
    if ($null -ne $script:PakIndex) { return }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $idx = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]'
    $mods = @(Get-ModLoadList)
    $script:PakMods = $mods
    $script:PakBad = $null
    $n = 0; $pk = 0; $badpaks = New-Object System.Collections.Generic.List[string]
    foreach ($m in $mods) {
        $n++
        $dd = Ci-Child $m.Dir 'Data'
        if (-not $dd) { continue }
        foreach ($p in ([System.IO.Directory]::EnumerateFiles($dd, '*.pak') | Sort-Object)) {
            $pk++
            try {
                $z = [System.IO.Compression.ZipFile]::OpenRead($p)
                try {
                    foreach ($e in $z.Entries) {
                        $fn = $e.FullName
                        if ($fn.EndsWith('/')) { continue }
                        $key = $fn.Replace('\', '/').ToLowerInvariant()
                        $l = $null
                        if (-not $idx.TryGetValue($key, [ref]$l)) { $l = New-Object System.Collections.Generic.List[object]; $idx[$key] = $l }
                        $l.Add(@{ Order=$n; Mod=$m.Name; Listed=$m.Listed; Pak=[System.IO.Path]::GetFileName($p); Len=$e.Length })
                    }
                } finally { $z.Dispose() }
            } catch { $badpaks.Add([System.IO.Path]::GetFileName($p) + ' (' + $m.Name + '): ' + $_.Exception.Message) }
        }
    }
    $script:PakIndex = $idx
    $script:PakNote = ('indexed ' + $pk + ' pak(s) from ' + $mods.Count + ' mod folder(s): ' + (Fmt-N $idx.Count) + ' distinct file paths')
    if ($badpaks.Count -gt 0) { $script:PakNote += '; ' + $badpaks.Count + ' unreadable pak(s)'; $script:PakBad = $badpaks }
}
function Overlap-Kind([string]$path) {
    if ($path -match '(^|/)table__[^/]+\.xml$') { return 'merge' }          # the game patches tables mod-by-mod (log: "Table ... is patched by")
    if ($path -match '\.(lua)$') { return 'lua' }
    if ($path -match '\.(dds|png|tga|jpg|jpeg)$') { return 'tex' }
    if ($path -match '\.(xml|cfg|json|txt|tbl)$') { return 'data' }
    return 'other'
}
function Run-Overlaps {
    Write-Banner 'PAK OVERLAPS - the same file path inside more than one mod (later mod in load order wins)' 'bcyan'
    if (-not $script:ModsDir) { Write-Plain '  no Mods folder known' 'bred'; return }
    $t0 = [datetime]::Now
    $script:PakIndex = $null; Build-PakIndex
    Write-Plain ('  ' + $script:PakNote + '   (' + (Fmt-Span ([datetime]::Now - $t0)) + ')') 'gray'
    if ($script:PakBad) { foreach ($b in ($script:PakBad | Select-Object -First 5)) { Write-Plain ('  unreadable: ' + $b) 'byellow' } }
    $groups = @{}      # mod set key -> list
    $tot = 0; $same = 0
    foreach ($kv in $script:PakIndex.GetEnumerator()) {
        $vals = @($kv.Value | Where-Object { $_.Listed })     # mods that are not in mod_order.txt never load, so they cannot win or lose
        if ($vals.Count -lt 2) { continue }
        $mods = @($vals | ForEach-Object { $_.Mod } | Select-Object -Unique)
        if ($mods.Count -lt 2) { continue }
        $tot++
        $sizes = @($vals | ForEach-Object { $_.Len } | Select-Object -Unique)
        $ident = ($sizes.Count -eq 1)
        if ($ident) { $same++ }
        $kind = Overlap-Kind $kv.Key
        $gk = ($mods -join ' > ')
        if (-not $groups.ContainsKey($gk)) { $groups[$gk] = @{ Mods=$mods; Files=(New-Object System.Collections.Generic.List[object]) } }
        $groups[$gk].Files.Add(@{ Path=$kv.Key; Kind=$kind; Ident=$ident })
    }
    if ($tot -eq 0) { Write-Plain '  No file is provided by more than one mod.' 'green'; return }
    $rep = New-Object System.Collections.Generic.List[string]
    Write-Plain ('  ' + (Fmt-N $tot) + ' overlapping file path(s); ' + (Fmt-N $same) + ' have the same size in every mod (probably identical, harmless).') 'byellow'
    $real = 0
    foreach ($g in ($groups.Values | Sort-Object { -$_.Files.Count })) {
        $files = $g.Files
        $conf = @($files | Where-Object { $_.Kind -ne 'merge' -and -not $_.Ident })
        $mrg = @($files | Where-Object { $_.Kind -eq 'merge' })
        $idn = @($files | Where-Object { $_.Kind -ne 'merge' -and $_.Ident })
        $winner = $g.Mods[$g.Mods.Count - 1]
        $head = ($g.Mods -join '  <  ') + '     winner: ' + $winner
        $col = 'gray'; if ($conf.Count -gt 0) { $col = 'byellow'; $real++ }
        Write-Head $head
        $rep.Add('== ' + $head)
        $summ = @(); if ($conf.Count) { $summ += ($conf.Count.ToString() + ' real conflict(s)') }; if ($mrg.Count) { $summ += ($mrg.Count.ToString() + ' table file(s) the game merges') }; if ($idn.Count) { $summ += ($idn.Count.ToString() + ' same-size') }
        Write-Plain ('  ' + ($summ -join ', ')) $col
        foreach ($f in ($conf | Select-Object -First 8)) { Write-Plain ('    ' + (Pad $f.Kind 6) + $f.Path) $col }
        if ($conf.Count -gt 8) { Write-Plain ('    ... and ' + ($conf.Count - 8) + ' more') 'gray' }
        foreach ($f in $files) { $rep.Add('  ' + $f.Kind + $(if ($f.Ident) { ' (same size)' } else { '' }) + '  ' + $f.Path) }
    }
    Write-Line ''
    Write-Plain '  How to read this: "merge" = table__*.xml files the game combines entry by entry (fine); everything else is replaced whole by the later mod, so the earlier mod''s version of that file is dead.' 'gray'
    Write-Plain '  Lua/keybind/hit_reaction conflicts are why zzz_merge_patch exists: it must stay last, and needs rebuilding when one of those mods updates.' 'gray'
    if ($real -eq 0) { Write-Plain '  No real (different-content) conflicts.' 'green' }
    try {
        $rd = PJ $OutDir 'reports'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
        $rf = PJ $rd ('overlaps-' + [datetime]::Now.ToString('yyyyMMdd-HHmmss') + '.txt')
        [System.IO.File]::WriteAllLines($rf, [string[]]$rep, $script:Utf8)
        Write-Plain ('  full list: ' + $rf) 'gray'
    } catch { }
}
function Run-FindFile([string]$rx) {
    Write-Banner ('FIND FILE IN MODS: ' + $rx) 'bcyan'
    if (-not $rx) { Write-Plain '  empty pattern' 'byellow'; return }
    try { $re = New-Object System.Text.RegularExpressions.Regex($rx, 'IgnoreCase') } catch { Write-Plain ('  bad regex: ' + $_.Exception.Message) 'bred'; return }
    if ($null -eq $script:PakIndex) { Build-PakIndex }
    Write-Plain ('  ' + $script:PakNote) 'gray'
    $n = 0
    foreach ($kv in ($script:PakIndex.GetEnumerator() | Sort-Object Key)) {
        if (-not $re.IsMatch($kv.Key)) { continue }
        $n++
        if ($n -gt 60) { continue }
        $mods = @($kv.Value | ForEach-Object { $_.Mod + $(if (-not $_.Listed) { ' [NOT IN ORDER]' } else { '' }) })
        $col = ''; if ($kv.Value.Count -gt 1) { $col = 'byellow' }
        Write-Plain ('  ' + $kv.Key) $col
        Write-Plain ('      ' + ($mods -join '  <  ') + $(if ($kv.Value.Count -gt 1) { '    (last wins)' } else { '' })) 'gray'
    }
    if ($n -eq 0) { Write-Plain '  nothing matches' 'gray' } elseif ($n -gt 60) { Write-Plain ('  ... ' + ($n - 60) + ' more matches (narrow the pattern)') 'gray' }
}

# ---------------- console commands registered by mods (read from their Lua)
function Run-Commands {
    Write-Banner 'CONSOLE COMMANDS REGISTERED BY INSTALLED MODS  (type them in the ~ console; devmode needed)' 'bcyan'
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    if (-not $script:ModsDir) { Write-Plain '  no Mods folder known' 'bred'; return }
    $mods = @(Get-ModLoadList)
    $rxCmd = New-Object System.Text.RegularExpressions.Regex('AddCCommand\s*\(\s*["'']([^"'']+)["'']\s*,\s*["'']([^"'']*)["'']\s*(?:,\s*["'']([^"'']*)["''])?', 'IgnoreCase')
    $rxLine = New-Object System.Text.RegularExpressions.Regex('(?m)^\s*(?:bind\s+\S+\s+|alias\s+)?([A-Za-z_][\w\.]*)\s*=\s*([^\r\n#;]+?)\s*$')
    $found = 0
    foreach ($m in $mods) {
        $cmds = New-Object System.Collections.Generic.List[string]
        $dd = Ci-Child $m.Dir 'Data'
        if ($dd) {
            foreach ($p in ([System.IO.Directory]::EnumerateFiles($dd, '*.pak') | Sort-Object)) {
                try {
                    $z = [System.IO.Compression.ZipFile]::OpenRead($p)
                    try {
                        foreach ($e in $z.Entries) {
                            if (-not $e.FullName.EndsWith('.lua', 'OrdinalIgnoreCase') -or $e.Length -gt 3MB -or $e.Length -eq 0) { continue }
                            $sr = New-Object System.IO.StreamReader($e.Open(), $script:Utf8)
                            try { $txt = $sr.ReadToEnd() } finally { $sr.Dispose() }
                            foreach ($mm in $rxCmd.Matches($txt)) {
                                $help = ''; if ($mm.Groups[3].Success) { $h2 = ($mm.Groups[3].Value -replace '\$\d', '' -replace '\\n', ' ').Trim(); if ($h2) { $help = ' - ' + $h2 } }
                                $cmds.Add($mm.Groups[1].Value + $help + '    [' + (($e.FullName -split '[\\/]')[-1]) + ']')
                            }
                        }
                    } finally { $z.Dispose() }
                } catch { }
            }
        }
        # loose Lua next to the mod (rare)
        if ($cmds.Count -gt 0) {
            $found += $cmds.Count
            Write-Head (Mod-Label $m.Name)
            $uc = @($cmds | Sort-Object -Unique)
            foreach ($c in ($uc | Select-Object -First 40)) { Write-Plain ('  ' + $c) }
            if ($uc.Count -gt 40) { Write-Plain ('  ... and ' + ($uc.Count - 40) + ' more') 'gray' }
        }
    }
    if ($found -eq 0) { Write-Plain '  none found (mods that add commands do it with System.AddCCommand in Lua; scripts compiled into plugins are not visible here)' 'gray' }
    else { Write-Line ''; Write-Plain ('  ' + $found + ' command registration(s). Mods that expose commands through KCSE plugins (MCM, Perk Progression ...) are not listed.') 'gray' }
    # mod config files that set cvars
    $cfgs = New-Object System.Collections.Generic.List[string]
    foreach ($m in $mods) {
        try { foreach ($f in [System.IO.Directory]::EnumerateFiles($m.Dir, '*.cfg')) { $cfgs.Add($m.Name + '\' + [System.IO.Path]::GetFileName($f) + ' (' + @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*\w+' -and $_ -notmatch '^\s*(--|//)' }).Count + ' lines)') } } catch { }
    }
    if ($cfgs.Count -gt 0) { Write-Head 'Mod .cfg files (loaded at start-up; they set cvars / run console commands)'; foreach ($c in $cfgs) { Write-Plain ('  ' + $c) 'gray' } }
}

function Startup-HardwareCheck {
    if ($NoHardware) { return }
    $smi = Run-Smi
    if ($smi) { Notice ('GPU: ' + ('{0:0.0}' -f ($smi.Used / 1024)) + ' / ' + ('{0:0.0}' -f ($smi.Total / 1024)) + ' GB used, ' + $smi.Temp + ' C (sampled every ' + $HwSec + ' s while the game runs)') 'gray' }
    else { Notice 'GPU sampling off: nvidia-smi not found (VRAM-full and temperature warnings unavailable)' 'gray' }
}
#endregion

#region ---------------------------------------------------------------- UI: footer, keys, banner, catch-up, analyze, main
function Footer-Text {
    $S = $script:S; $pi = $script:ProcInfo; $H = $script:Hw
    $p = New-Object System.Collections.Generic.List[string]
    $p.Add(' KCD2')
    if ($script:Proc) { $p.Add('PID ' + $pi.Pid + ' ' + (Fmt-Span ([datetime]::Now - $pi.Start))) }
    else { $p.Add('game not running') }
    $p.Add($S.Phase)
    if ($S.GameVer) { $p.Add($S.GameVer) }
    if ($S.ModsEnabledN -gt 0) { $p.Add('mods ' + $S.ModsEnabledN + '/' + $script:Order.Count) }
    $p.Add('E ' + (Fmt-N $S.Err) + ' W ' + (Fmt-N $S.Warn))
    if ($script:Proc) {
        $p.Add('RAM ' + (Fmt-Bytes $pi.Priv))
        if ($H.VramTotal -gt 0) { $p.Add('VRAM ' + ('{0:0.0}' -f ($H.Vram / 1024)) + '/' + ('{0:0.0}' -f ($H.VramTotal / 1024)) + ' ' + $H.Temp + 'C') }
        if (-not $pi.Responding) { $p.Add('NOT RESPONDING') }
    }
    $fl = ''
    if ($script:Paused) { $fl += ' PAUSED(' + $script:PauseQ.Count + ')' }
    if ($script:ShowRaw) { $fl += ' RAW' }
    if ($script:ShowNoise) { $fl += ' NOISE' }
    if ($script:MinLvl -gt 1) { $fl += ' >=' + $script:LvlName[$script:MinLvl] }
    if ($script:RxInclude -or $script:RxExclude) { $fl += ' FILTER' }
    if ($fl) { $p.Add($fl.Trim()) }
    $p.Add('? help')
    return ($p -join ' | ')
}

function Flush-Pause {
    $n = 0
    while ($script:PauseQ.Count -gt 0) { Out-Raw ($script:PauseQ.Dequeue() + $script:R + "`n"); $n++ }
    return $n
}

function Prompt-Line([string]$prompt) {
    Out-Raw ((Col 'bwhite') + $prompt + $script:R + ' ')
    $s = ''
    try { $s = [Console]::ReadLine() } catch { $s = '' }
    if ($null -eq $s) { $s = '' }
    return $s.Trim()
}

function Set-Beep([bool]$on) { Set-Variable -Name Beep -Scope Script -Value ([System.Management.Automation.SwitchParameter]::new($on)) }

function Handle-Key([System.ConsoleKeyInfo]$k) {
    $c = [string]$k.KeyChar
    switch -CaseSensitive ($c) {
        '?' { Show-Help }
        'q' { $script:QuitNow = $true }
        'Q' { $script:QuitNow = $true }
        's' { Show-Summary $false }
        'w' { Show-Tallies 40 }
        'm' { Show-Mods }
        'e' { Show-Recent }
        'g' { Show-Hardware }
        'h' { Show-SysEvents }
        'i' { Show-Info }
        'd' { Show-History }
        'k' { [void](Run-Preflight) }
        'u' { Run-Overlaps }
        '/' { Run-Commands }
        't' { $rx = Prompt-Line 'regex for a path inside the mods (e.g. perk|\.lua$|table__item):'; if ($rx) { Run-FindFile $rx } }
        'f' {
            $rx = Prompt-Line 'show only lines matching regex (empty = off):'
            try { if ($rx) { $script:RxInclude = New-Object System.Text.RegularExpressions.Regex($rx, 'IgnoreCase') } else { $script:RxInclude = $null }; Notice ('include filter: ' + $(if ($rx) { $rx } else { 'off' })) 'bwhite' } catch { Notice ('bad regex: ' + $_.Exception.Message) 'bred' }
        }
        'x' {
            $rx = Prompt-Line 'hide lines matching regex (empty = off):'
            try { if ($rx) { $script:RxExclude = New-Object System.Text.RegularExpressions.Regex($rx, 'IgnoreCase') } else { $script:RxExclude = $null }; Notice ('exclude filter: ' + $(if ($rx) { $rx } else { 'off' })) 'bwhite' } catch { Notice ('bad regex: ' + $_.Exception.Message) 'bred' }
        }
        'v' { $script:ShowNoise = -not $script:ShowNoise; Notice ('hidden noise lines are now ' + $(if ($script:ShowNoise) { 'SHOWN' } else { 'hidden' })) 'bwhite' }
        'r' { $script:ShowRaw = -not $script:ShowRaw; Notice ('raw mode ' + $(if ($script:ShowRaw) { 'ON: every line, no grouping' } else { 'off' })) 'bwhite' }
        'l' { $script:MinLvl = ($script:MinLvl + 1) % 4; Notice ('minimum level: ' + @('Debug', 'Info', 'Warn', 'Error')[$script:MinLvl]) 'bwhite' }
        'p' {
            $script:Paused = -not $script:Paused
            if ($script:Paused) { Out-Raw ((Col 'byellow') + '          -- output paused (p to resume; logs keep being read and counted) --' + $script:R + "`n") }
            else { $n = Flush-Pause; Out-Raw ((Col 'byellow') + ('          -- resumed (' + $n + ' lines were held) --') + $script:R + "`n") }
        }
        'c' { Out-Raw ($script:Esc + '[2J' + $script:Esc + '[H'); $script:Ring.Clear(); if ($script:Footer) { Setup-Footer } }
        'a' { Persist-Live $true; Notice $(if ($script:ArcDir) { 'logs copied to ' + $script:ArcDir } else { 'no active session folder (start the game, or -NoArchive is set)' }) 'green' }
        'o' { try { if ($script:IsWin) { Start-Process explorer.exe -ArgumentList ('"' + $OutDir + '"') } else { Notice ('data folder: ' + $OutDir) 'gray' } } catch { Notice ('could not open: ' + $_.Exception.Message) 'bred' } }
        'b' { Set-Beep (-not [bool]$Beep); Notice ('beep on crash / hang / VRAM full: ' + $(if ($Beep) { 'ON' } else { 'off' })) 'bwhite' }
        default { }
    }
}

function Write-HeaderBanner {
    Write-Banner ('KCD2 CONSOLE ' + $script:Ver + '   Kingdom Come: Deliverance II') 'bcyan'
    Write-Plain ('  Game folder ..... ' + $(if ($script:GameDir) { $script:GameDir } else { 'NOT FOUND (use -GamePath)' })) $(if ($script:GameDir) { '' } else { 'bred' })
    Write-Plain ('  mod_order.txt ... ' + $(if ([System.IO.File]::Exists($script:CfgPath)) { [string]$script:Order.Count + ' entries' + $(if ($script:OrderInfo.Bom) { ' (BOM!)' } else { '' }) + $(if ($script:OrderInfo.Dups.Count) { ', ' + $script:OrderInfo.Dups.Count + ' duplicate(s)' } else { '' }) } else { 'missing' }))
    Write-Plain ('  Following ....... ' + $script:Sources.Count + ' log files' + $(if (@($script:Sources | Where-Object { $_.Stale }).Count) { ' (' + @($script:Sources | Where-Object { $_.Stale }).Count + ' older than the last run: skipped to end)' } else { '' }))
    Write-Plain ('  Data folder ..... ' + $OutDir + $(if ($NoArchive) { '   (archive OFF)' } else { '   (every run is copied here, even if the game crashes)' }))
    Write-Plain ('  Filter .......... level >= ' + $script:LvlName[$script:MinLvl] + $(if ($Include) { ', include /' + $Include + '/' } else { '' }) + $(if ($Exclude) { ', exclude /' + $Exclude + '/' } else { '' }) + $(if ($Raw) { ', RAW' } else { '' }) + '     ? = keys, k = pre-flight, q = quit') 'gray'
    Startup-HardwareCheck
}

function Catch-Up {
    $script:Quiet = (-not $FromStart)
    $ordered = @($script:Sources | Sort-Object @{Expression={ if ($_.Kind -eq 'kcd') { 0 } elseif ($_.Kind -eq 'launcher') { 1 } else { 2 } }}, Name)
    foreach ($sx in $ordered) { [void](Read-Source $sx $true) }
    $script:Quiet = $false
    if (-not $FromStart -and $Backlog -gt 0 -and $script:Ring.Count -gt 0) {
        Write-Line ((Col 'gray') + ('---- last ' + [Math]::Min($Backlog, $script:Ring.Count) + ' lines already in the logs (before this console started) ----') + $script:R)
        $take = @($script:Ring.ToArray() | Select-Object -Last $Backlog)
        foreach ($l in $take) { Out-Raw ($l + $script:R + "`n") }
        Write-Line ((Col 'gray') + '---- live from here ----' + $script:R)
    }
}

function Run-Analyze([string]$folder) {
    $script:ReadOnlyRun = $true
    if ($folder) {
        if (-not [System.IO.Directory]::Exists($folder)) { Write-Plain ('folder not found: ' + $folder) 'bred'; return 2 }
        $lg = Ci-Child $folder 'logs'
        if ($lg -and [System.IO.Directory]::Exists($lg)) { $script:LogDirOverride = $lg } else { $script:LogDirOverride = $folder }
        $script:NoUpdateCheck = $true
        $mo = Ci-Child $folder 'mod_order.txt'; if ($mo) { $script:CfgPath = $mo; Load-Order }
        Write-Banner ('ANALYSIS OF ARCHIVED RUN  ' + $folder) 'bcyan'
        $pm = Ci-Child $folder 'postmortem.txt'
        if ($pm) { Write-Plain ('  (this run already has a post-mortem: ' + $pm + ')') 'gray' }
    } else { Write-Banner 'ANALYSIS OF THE CURRENT LOGS' 'bcyan' }
    Scan-Sources
    if ($script:Sources.Count -eq 0) { Write-Plain '  No log files found. Is -GamePath right?' 'bred'; return 2 }
    $script:Quiet = $true
    $ordered = @($script:Sources | Sort-Object @{Expression={ if ($_.Kind -eq 'kcd') { 0 } elseif ($_.Kind -eq 'launcher') { 1 } else { 2 } }}, Name)
    foreach ($sx in $ordered) { [void](Read-Source $sx $true) }
    $script:Quiet = $false
    if ($script:S.OrderPending) { $script:S.OrderPending = $false; Check-LoadOrder }
    Write-Plain ('  Read ' + $script:Sources.Count + ' log file(s), ' + (Fmt-N $script:S.Lines) + ' lines: ' + (($script:Sources | Where-Object { $_.Lines -gt 0 } | ForEach-Object { $_.Name + ' ' + (Fmt-N $_.Lines) }) -join ', ')) 'gray'
    Show-Summary $true
    Show-Mods
    Show-Recent
    $rt = @($script:RawTail.ToArray() | Select-Object -Last 12)
    if ($rt.Count -gt 0) { Write-Head 'Last 12 lines of kcd.log'; foreach ($l in $rt) { Write-Plain ('  ' + (Trunc $l 200)) 'gray' } }
    if (-not $script:S.CleanExit -and $script:S.LogSeen) { Write-Plain '' ; Write-Plain '  kcd.log has no CSystem::Quit line. That can be a crash, a kill, a PC reset, a normal window close (not every normal close writes the line) or a game that is still running; the exit code in the run history (d) settles it.' 'gray' }
    return 0
}

function Do-Quit-Cleanup {
    try { if ($script:ProcInfo.PMDue -and $script:S.Phase -ne 'Idle') { Post-Mortem } } catch { }
}

function Main {
    $script:Interactive = $true
    try { if ([Console]::IsOutputRedirected) { $script:Interactive = $false } } catch { }
    $oneShot = ($Analyze -or $AnalyzeFolder -or $Check -or $Overlaps -or $Commands -or $History -or $FindFile -or $DumpFile)
    if ($oneShot) { $script:Footer = $false }
    if (-not $script:Interactive) { $script:Footer = $false }
    try { [Console]::OutputEncoding = $script:Utf8 } catch { }
    $vt = Enable-VT
    if (-not $vt -or -not $script:Interactive) { $script:UseColor = $false }
    $script:R = Col 'reset'
    if (-not $OutDir) {
        $base = $PSScriptRoot; if (-not $base) { $base = (Get-Location).Path }
        $script:OutDir = PJ $base 'KCD2Console-data'
        Set-Variable -Name OutDir -Scope Script -Value (PJ $base 'KCD2Console-data')
    }
    try { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null } catch { Write-Plain ('cannot create data folder ' + $OutDir + ': ' + $_.Exception.Message) 'bred' }

    if ($DumpFile) {
        Write-Banner ('CRASH DUMP  ' + $DumpFile) 'bcyan'
        if (-not [System.IO.File]::Exists($DumpFile)) { Write-Plain 'file not found' 'bred'; return 2 }
        foreach ($l in (Describe-CrashDump $DumpFile)) { Write-Plain ('  ' + $l) }
        return 0
    }

    # game folder
    $root = ''
    if ($GamePath) { $root = Resolve-GameRoot $GamePath; if (-not $root) { $root = $GamePath } }
    else { $root = Find-Game }
    if ($root) { Set-GameDirs $root; Load-Order }
    else { Set-GameDirs ''; }

    if ($Check) { $script:ReadOnlyRun = $true; return (Run-Preflight) }
    if ($Overlaps) { $script:ReadOnlyRun = $true; Reset-ManifestIndex; Run-Overlaps; return 0 }
    if ($Commands) { $script:ReadOnlyRun = $true; Run-Commands; return 0 }
    if ($History) { $script:ReadOnlyRun = $true; Show-History 30; return 0 }
    if ($FindFile) { $script:ReadOnlyRun = $true; Reset-ManifestIndex; Run-FindFile $FindFile; return 0 }
    if ($Analyze) { return (Run-Analyze '') }
    if ($AnalyzeFolder) { return (Run-Analyze $AnalyzeFolder) }

    # live mode: one console at a time
    $mutex = $null
    if (-not $AllowMultiple) {
        try {
            $mk = 'KCD2Console_' + ([System.BitConverter]::ToString((New-Object System.Security.Cryptography.MD5CryptoServiceProvider).ComputeHash($script:Utf8.GetBytes($OutDir.ToLowerInvariant()))) -replace '-', '')
            $mutex = New-Object System.Threading.Mutex($false, $mk)
            if (-not $mutex.WaitOne(0)) { Write-Plain 'Another KCD2 Console is already running for this data folder (use -AllowMultiple to override).' 'byellow'; return 3 }
        } catch [System.Threading.AbandonedMutexException] { } catch { $mutex = $null }
    }
    $exit = 0
    $script:QuitNow = $false
    try {
        if ($script:Interactive) { Setup-Footer }
        Set-Title 'KCD2 Console - waiting for the game'
        Ensure-Native | Out-Null
        if ($script:NativeOk) { try { [KcProc]::HookClose() } catch { } }
        Scan-Sources
        Write-HeaderBanner
        Catch-Up
        $script:Live = $true
        $S = $script:S
        # a run that is in the logs but belongs to a game that is no longer running: archive it now (kcd.log is overwritten at the next launch)
        $running = $false; try { $running = [bool](Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) } catch { }
        if (-not $running -and $S.LogSeen -and -not $NoArchive) {
            $stamp = if ($S.LogStart) { $S.LogStart } else { [datetime]::Now }
            $key = $stamp.ToString('yyyy-MM-dd HH:mm:ss')
            $st = Get-State
            if ([string](Jget $st 'ArchivedLogStart' '') -ne $key) {
                Arc-Open $stamp
                if ($script:ArcDir) {
                    [void](Arc-Snapshot $true); Write-SessionSummary; Write-SessionJson $true
                    Notice ('previous run (log started ' + $key + ') had not been archived; copied to ' + $script:ArcDir) 'green'
                    if (-not $S.CleanExit) { Notice 'that run has no CSystem::Quit line (a crash, or a normal close that does not write it; its exit code was not seen because this console was not running). Press s for its summary, e for its last errors.' 'byellow' }
                    if ($script:Transcript) { try { $script:Transcript.Dispose() } catch { }; $script:Transcript = $null }
                    $script:ArcDir = $null
                    Save-State @{ ArchivedLogStart=$key }
                }
            }
        }
        if ($S.OrderPending) { $S.OrderPending = $false; Check-LoadOrder }
        if (-not $running) { Write-Plain ('  Waiting for ' + $ProcessName + '.exe ...  (the game can be started from Steam / Vortex now)') 'gray' }

        $started = [datetime]::Now
        $lastScan = [datetime]::Now; $lastProc = [datetime]::MinValue; $lastFooter = [datetime]::MinValue; $lastSnap = [datetime]::Now
        $first = $true
        $loopErr = 0
        while (-not $script:QuitNow) {
          try {
            $now = [datetime]::Now
            if ($script:NativeOk -and [KcProc]::CloseRequested) { $script:QuitNow = $true; break }
            if ($MaxSeconds -gt 0 -and ($now - $started).TotalSeconds -ge $MaxSeconds) { break }
            if (($now - $lastScan).TotalSeconds -ge 3) { Scan-Sources; $lastScan = $now }
            $n = 0
            foreach ($sx in $script:Sources.ToArray()) { $rs = @(Read-Source $sx $false); if ($rs.Count -gt 1) { Dbg ('pipeline leak in Read-Source ' + $sx.Name + ': ' + (($rs | Select-Object -First 3 | ForEach-Object { [string]$_ }) -join ' | ')) }; $n += [int]$rs[$rs.Count - 1] }
            if (($now - $lastProc).TotalSeconds -ge 1 -or $first) {
                $lastProc = $now
                Proc-Poll
                Watch-Saves
                Hw-Poll
                $first = $false
            }
            $pi = $script:ProcInfo
            if ($pi.PMDue -and $now -ge $pi.PMDue) {
                foreach ($sx in $script:Sources.ToArray()) { [void](Read-Source $sx $false) }
                Post-Mortem
                Set-Title 'KCD2 Console - waiting for the game'
            }
            if ($script:ArcDir -and $SnapshotSec -gt 0 -and ($now - $lastSnap).TotalSeconds -ge $SnapshotSec -and $script:Proc) { Persist-Live $false; $lastSnap = $now }
            if (($now - $lastFooter).TotalMilliseconds -ge 400) {
                $lastFooter = $now
                Draw-Footer (Footer-Text)
                if ($script:Proc) { Set-Title ('KCD2 Console - ' + $script:S.Phase + ' | E ' + $script:S.Err + ' W ' + $script:S.Warn) }
            }
            $did = $false
            if ($script:Interactive) {
                try {
                    while ([Console]::KeyAvailable) { $ki = [Console]::ReadKey($true); Handle-Key $ki; $did = $true; if ($script:QuitNow) { break } }
                } catch { }
            }
            if ($Quit) { break }
            if ($n -eq 0 -and -not $did) { Start-Sleep -Milliseconds $PollMs }
          } catch {
            # one bad iteration must not end the watch: say so (a few times), keep going
            $loopErr++
            if ($loopErr -le 5) { Notice ('internal error (continuing): ' + $_.Exception.Message + '  @ line ' + $_.InvocationInfo.ScriptLineNumber) 'bred' }
            Dbg ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
            if ($loopErr -gt 300) { throw }
            Start-Sleep -Milliseconds 500
          }
        }
    } catch {
        Write-Plain ('Console error: ' + $_.Exception.Message) 'bred'
        Write-Plain ('  ' + $_.InvocationInfo.PositionMessage) 'gray'
        if ($env:KC_DEBUG) { Write-Plain ($_.ScriptStackTrace) 'gray'; Write-Plain ($_.Exception.GetType().FullName) 'gray' }
        $exit = 1
    } finally {
        try {
            # leave nothing behind: finish the run in progress, whatever state it is in
            if ($script:ProcInfo.PMDue -and $script:S.Phase -ne 'Idle') { Post-Mortem }
            elseif ($script:ArcDir) { Persist-Live $true; Notice ('final logs saved: ' + $script:ArcDir) 'green' }
            Close-ProcHandle
        } catch { }
        try { if ($script:Transcript) { $script:Transcript.Dispose() } } catch { }
        try { Reset-Footer } catch { }
        try { if ($script:NativeOk) { [KcProc]::Done.Set() | Out-Null } } catch { }
        try { if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() } } catch { }
    }
    return $exit
}

$script:ExitCode = 0
try { $script:ExitCode = Main } catch { [Console]::Error.WriteLine('KCD2Console fatal: ' + $_.Exception.Message + ' ' + $_.InvocationInfo.PositionMessage); $script:ExitCode = 1 }
if ($script:ExitCode -is [array]) { $script:ExitCode = $script:ExitCode[-1] }
exit ([int]$script:ExitCode)
#endregion
