# KCD2 Console

A live log console, pre-flight checker and crash post-mortem for a modded **Kingdom Come: Deliverance II** (Steam, Windows; built around Vortex-managed mods and KCSE).

## Use
Put `KCD2Console.ps1` and `Start-KCD2Console.bat` in one folder (anywhere), double-click the .bat, then start the game. It finds the game folder itself (running process, script folder, Steam libraries). Its data goes to `KCD2Console-data` next to the script. It never writes into the game, Mods or Vortex folders.

## Live window
Follows kcd.log, kcd_launcher.log, KCSE.log, questnative.log, kcd2db.log, kcd2minimap.log, the HenrySenses/TPV/CombatUse logs, the DualSense logs and any other *.log (including ones mods write inside their own folder). Shows phases (boot, mod discovery, mod order applied, Lua init, main menu, loading save, loading level, in game), timings, and groups repeated problems (Lua errors per owning mod, bad config lines, cheat-mod indexing noise) into counted categories.

Checks it does on its own:
- Game updated since last run (build / WHGame.dll) -> warns that KCSE plugins and ASIs break first.
- Enabled order vs mod_order.txt vs folders on disk; `zzz_merge_patch` must be last; "not found" with a case/ModId hint; version-disabled mods.
- "Mods used while saving" vs mods installed now, on every save load.
- KCSE: plugins found / registered / loaded, ASIs, plugins sitting in disabled mods.
- Process: PID, exit code decoded, memory, "not responding", GPU memory/temperature (nvidia-smi), free RAM, memory growth, save files written (size, empty/shrunk warnings).
- On exit: post-mortem (last raw log lines, last mod Lua initialised, memory curve every 5 min, last lines of the plugin/ASI logs, Windows events: Kernel-Power 41, WHEA, nvlddmkm/TDR, disk/NVMe, reboot during the run, BugSplat's own crash log, the crash dump read for the faulting module) with the "hard crash + no game error = check hardware first" rule.
- A run counts as normal when the exit code is 0, even if kcd.log has no `CSystem::Quit` line (not every normal close writes it). Run history shows `exit 0`, `clean`, `abnormal` or `cut off`.
- Every run's logs are copied to `KCD2Console-data\sessions\<time>` (refreshed every 30 s, so a reboot still leaves them), with summary.txt, session.json, postmortem.txt. kcd.log is overwritten on each launch; this keeps it.

Keys: `?` help, `q` quit, `s` summary, `w` tallies, `m` mods/load order, `e` recent errors, `g` hardware, `h` Windows events, `k` pre-flight, `u` pak overlaps, `t` find a file inside mods, `/` mod console commands, `d` run history, `v` noise, `r` raw, `l` level, `f`/`x` filters, `p` pause, `c` clear, `a` copy logs now, `o` open data folder, `i` info, `b` beep.

## One-shot modes
`-Check` pre-flight (exit 2 = failures, 1 = warnings) | `-Analyze` | `-AnalyzeFolder <session folder>` | `-Overlaps` | `-Commands` | `-History` | `-FindFile <regex>` | `-DumpFile <.dmp or BugSplat .zip>`
Options: `-GamePath`, `-OutDir`, `-MinLevel Warn`, `-Include/-Exclude <regex>`, `-Raw`, `-FromStart`, `-Beep`, `-NoHardware`, `-NoSaveWatch`, `-NoArchive`, `-AllowMultiple`.

## Version history
**1.1 (2026-10-24)**, fixes found from the first real crash:
- Fixed: after a crash Windows keeps the dead game process listed for a few seconds; the console took it for a second launch, which zeroed the peak memory and hardware samples and made a duplicate session folder. It now ignores a process it already saw exit.
- Fixed: the dump search skipped BugSplat's dump (`Kingdom Come ... .dmp` in `%TEMP%`; the name has a space). It now finds it, and reads `bugsplat_*.log` (crash address, GPU device-removed flag, the dump it wrote).
- Fixed: the "memory grew" flag counted the initial load. The clock now starts 5 min after the world is up and measures 30 min of play; a 5-minute memory curve is kept in the post-mortem and session.json.
- Fixed: "no Quit line" was shown as an abnormal exit even when the exit code was 0.
- New: last lines of the plugin/ASI logs at death; exit codes 0xC0000028, 0xC0000001, 0xC0000017, 0xC0000142 decoded; the KCSE plugin in a not-enabled mod now says whether KCSE loaded it.
- To read a dump by hand: `powershell -File KCD2Console.ps1 -DumpFile "C:\Users\<you>\AppData\Local\Temp\Kingdom Come Deliverance II....dmp"` (copy it somewhere safe first; Temp gets cleaned).

## Limits
- Built and used on one heavily modded install (game 1.5.6, about 130 mods). Other setups may log things it hasn't seen; please open an issue with what it printed.
- Some Windows-only paths (rarer exit codes, certain Windows events, reading unusual crash dumps) were written against the documented APIs and tested with simulated processes and synthetic dumps.
- Mods whose code is inside a KCSE plugin DLL write nothing readable to the logs.
- A game update can change log wording; the console warns when the game build changes.
