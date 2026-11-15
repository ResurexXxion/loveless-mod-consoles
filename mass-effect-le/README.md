# Mass Effect Console (ME1 Legendary Edition) — beta

A live log console, setup checker and crash post-mortem for a modded **Mass Effect 1 Legendary Edition** (Steam, mods installed with ME3Tweaks Mod Manager / M3). Same family as the Kenshi and KCD2 consoles.

> **Beta:** developed and tested by replaying real logs with a simulated game process; its first full runs on Windows are the real test. Feedback welcome.

## Use

1. Double-click `Start-MassEffectConsole.bat`. Start ME1 before or after, either works.
2. Leave the window open while you play. Press `q` to quit, `?` for keys.
3. After a crash the window prints a **POST-MORTEM** by itself. Everything is also saved to `data\sessions\<time>\`.

Other files:

| File | What it does |
|---|---|
| `Analyze-MassEffectLogs.bat` | One-shot report on the current logs. Drag an archived session folder onto it to analyse that run. |
| `Read-CrashDump.bat` | Drag a `MassEffect1.exe` `.dmp` onto it: exception, faulting module, ASIs loaded. |
| `Enable-CrashDumps.bat` | Optional, once, as administrator. Makes Windows write a dump when ME1 crashes (see below). `Enable-CrashDumps.bat remove` undoes it. It writes one registry key and shows it before asking. |

## What it follows

ME1 LE writes no engine log, so the console reads what the ASI layer writes in `Game\ME1\Binaries\Win64\Logs\`:

- `bink2w64_proxy.log` (ASI loader): which ASIs loaded, whether the core hook installed, and `OnDetach ... goodbye` on a normal shutdown.
- `AutoloadEnabler.log`: DLC_MOD scan, TFC/ISB registration, mount order.
- `TextureOverride.log`: every texture ALOT / Improved Static Lighting / AVC replaced. The names carry the level code, so the console can say which level was loading.

## What it adds beyond the logs

- **Setup check on every start**: proxy DLL pair, ASI list, DLC_MOD folders and their M3 records, `Coalesced_INT.bin`, Steam build id, `LoadOrder.Txt` age, ME1 graphics keys, free disk space, GPU.
- **Known-good diff**: after a clean run it saves a snapshot (`data\lastgood.json`). Next start it lists what changed: Steam patch, ASI added/removed, mod added/removed/changed, `Coalesced_INT.bin` overwritten. `g` shows it, `b` saves the current setup as known-good.
- **Boot findings**: core hook not installed (usual sign of a game patch), an ASI that registered but never attached, hooks created but not enabled, duplicate mount priorities, mounted count vs found count.
- **Process watch** of `MassEffect1.exe`: exit code decoded, RAM, not-responding, boot stuck (no log line for 60 s before autoload finishes). With an NVIDIA card it also tracks VRAM and temperature through `nvidia-smi` and warns when high-res texture packs are close to filling VRAM.
- **Crash evidence the logs lack**: Windows Application Error (faulting module and offset, mapped to "engine / ASI / GPU driver"), dumps from `%LOCALAPPDATA%\CrashDumps` or `data\dumps`, WER report folders, and hardware events (Kernel-Power 41, WHEA, GPU, disk).
- **Save protection**: copies `Documents\BioWare\Mass Effect Legendary Edition\Save\ME1` into `data\save-backups\` at launch, after every save the game writes, and at exit (last 20 kept, only when something changed). A save under 1 KB is flagged as truncated.

## Limits (read these)

- **A pure engine crash can still leave nothing in the logs.** Then the evidence is the exit code, the Windows Application Error event and, only if you ran `Enable-CrashDumps.bat`, a dump. The post-mortem says which of those exist and never claims a cause it cannot show: its "reading of the evidence" is inference.
- Level names: only `PRO10` (Eden Prime) and `NOR10` (SSV Normandy) are built in. Other levels show as codes (for example `ICE20`). Add your own in `data\levels.txt`, one per line: `ICE20=Noveria`.
- Read-only toward the game. It writes only to `data\` next to the script (and, if you ask it to, one registry key for crash dumps).

## Options

`-MinLevel Warn`, `-Include <regex>`, `-Exclude <regex>`, `-Raw`, `-FromStart`, `-NoSaveBackup`, `-NoGpu`, `-NoSystemEvents`, `-NoArchive`, `-GamePath "C:\...\Mass Effect Legendary Edition"`, `-SaveDir <path>`, `-Bless` (save the current setup as known-good and exit), `-DumpFile <path>`.
