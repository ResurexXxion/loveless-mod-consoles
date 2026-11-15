# Kenshi Console

A separate window that follows every Kenshi log live, groups the repeated noise, and tells you what happened when the game dies. Read-only: it never writes into the Kenshi, Workshop or Steam folders. Everything it saves goes to `KenshiConsole-data\` next to the script.

## Use
1. Put `KenshiConsole.ps1` and the `.bat` files in one folder (e.g. `C:\Tools\KenshiConsole\`).
2. Double-click `Start-KenshiConsole.bat`. Leave it open. Start Kenshi before or after; it follows the game and survives restarts.
3. Best in Windows Terminal. In the old console, add `-Ascii` for plain symbols.
4. `Analyze-KenshiLogs.bat` gives a one-shot report of the current logs. Drag an archived session folder onto it to analyze that run.

If Windows blocks the script, the .bat already uses `-ExecutionPolicy Bypass`. Running the .ps1 by hand: `powershell -ExecutionPolicy Bypass -File .\KenshiConsole.ps1`.

## What it follows
`kenshi_info.log`, `kenshi.log` (Ogre), `RE_Kenshi_log.txt`, `MyGUI.log`, `save.log`, SleepFix / BodyMorphCap / SentientSands / `_kenshi_fix1` logs, and Dust logs in the Workshop folder. New logs that appear are picked up automatically. Kenshi overwrites its logs on every launch; the tool detects that and starts from the top.

## What you see
- One line per event: `time TAG LVL message`. Red = error, yellow = warning, white = info, gray = debug.
- Phases with timings: launcher, Play pressed, mod loading, renderer, main menu, new game / load.
- Mod loading progress every 100 mods, slow mods (5 s+ gaps), and a check that the real load order equals `data\mods.cfg`, plus any cfg entry that never loaded.
- Floods are grouped: the first 3 lines of a problem are printed, the rest are counted (missing meshes, skeletons, textures, "modified by X does not exist", bad research requirements, MyGUI skins, squads with no faction). Press `w` for the tally with the mods responsible. Missing-mesh errors name the mod directly.
- A status bar on the bottom row: process state, phase, mods loaded, RAM, error/warning counts, filters.
- Process watch: start, "not responding" (with a note that this is normal while mods load), exit code with its meaning.

## When the game exits (post-mortem)
Runtime, exit code (decoded: 0xC0000005 access violation, stack overflow, heap corruption, and so on), phase and last mod loaded at exit (and the next mod in mods.cfg), whether `save.log` wrote its clean `Exit.`, last distinct errors, last log lines, any Dust/Windows crash dump written during the run (Kenshi's own `crashDump*.zip` is copied into the session folder and read: exception code, read/write, faulting module + offset), and Windows events for the run window: app crash/hang, Kernel-Power 41, WHEA, GPU driver, disk/NVMe, bugcheck. It ends with a reading of the evidence, labelled inferred. If hardware events show up, it says to check hardware before blaming mods.

At startup it also checks the last 3 days for hard resets, WHEA errors and bugchecks.

## Session archive
Every game run gets `KenshiConsole-data\sessions\<date_time>\` with copies of all logs (refreshed every 30 s while the game runs, so a hard reboot still leaves them), `console.txt` (everything shown), `summary.txt`, `postmortem.txt`, `mods.cfg` as it was. The last 30 sessions are kept (`-KeepSessions`). If the tool starts while old logs exist, it saves them before the next launch can overwrite them.

## Keys
`?` help, `s` summary, `w` tallies, `m` mod load/order, `e` recent errors, `t` trace (searches every `.mod` in mods.cfg for the names of missing skeletons/textures, so you learn which mod references them; reads several GB), `h` Windows events (2 h), `l` level, `v` noise, `r` raw, `p` pause, `c` clear, `f` include regex, `x` exclude regex, `a` snapshot now, `o` open archive folder, `i` info, `q` quit.

## Options
`-MinLevel Debug|Info|Warn|Error`, `-Include regex`, `-Exclude regex`, `-Raw`, `-FromStart`, `-Backlog N`, `-ShowRepeats N`, `-ShowMissingRecords`, `-NoFooter`, `-NoColor`, `-Ascii`, `-NoArchive`, `-NoSystemEvents`, `-SnapshotSec N`, `-KenshiPath`, `-OutDir`, `-ProcessName`, `-ExtraLog`, `-Analyze`, `-AnalyzeFolder`, `-Trace`, `-MaxSeconds`, `-AllowMultiple`, `-DumpFile <zip|dmp>`.

## Version history
**1.1 (2026-10-22).** The first version saved nothing for a real crash: with RE_Kenshi the game runs from `Kenshi\RE_Kenshi\kenshi_x64.exe`, and the console took that subfolder as the Kenshi folder, so it found no logs and no `mods.cfg`. Fixed:
- Kenshi folder is found by walking up to the folder that has `data\mods.cfg` / `gamedata.base` / the logs, and re-checked when the game starts.
- A loud red warning at startup if no log files are found.
- Only one console at a time (a second one says so and exits; `-AllowMultiple` overrides).
- Exit code is read straight from Windows with a handle opened at launch, not through PowerShell's Process object.
- Session folder is refreshed every 30 s (logs, `summary.txt`, `tail.txt`), and closing the window triggers a final save. Ctrl+C and `q` do too.
- `postmortem.txt` is the full post-mortem, not just the last log lines.
- `Read-CrashDump.bat` / `-DumpFile` reads any crashDump zip or `.dmp`.
- For the common `kenshi_x64.exe+0x622A8A` crash (a character's "death items" list holds an entry the game cannot turn into an item) the dump reader now prints the name of the character being built and the position of the bad entry (version 1.2).

## Limits
- Built and tested against one heavily modded Kenshi install (about 1,400 mods, RE_Kenshi). Other setups may log things it hasn't seen. If something misbehaves, `-NoSystemEvents` and the session folder are the fallbacks; please open an issue with what it printed.
- "Loaded mod" log lines have 1-second resolution, so per-mod load times are coarse.
- The post-mortem verdict is inference from evidence, never proof. A dump file is what names a faulting module.
- Noise rules (what is hidden) were built from real sessions of that install. Press `v` to see everything hidden, or `r` for raw.
- Korean text from SleepFix may not render in the old Windows console; use Windows Terminal or `-Ascii`.
