# Loveless Mod Consoles

Live log consoles for heavily modded PC games. Each one is a single PowerShell script that sits **next to** the game: it follows the game's logs as you play, groups the noise, checks your mod setup before you launch, and explains what happened when the game crashes, with every session's logs saved before the game can overwrite them.

| Game | Folder | Status |
|---|---|---|
| Kingdom Come: Deliverance II | [`kcd2/`](kcd2/) | 1.1, used on a 130-mod install |
| Kenshi | [`kenshi/`](kenshi/) | 1.2, used on a ~1,400-mod install |
| Mass Effect 1 Legendary Edition | [`mass-effect-le/`](mass-effect-le/) | beta |

## What they do (all three)

- **Live window:** one line per event, colour-coded, with load phases and timings. Repeated errors are counted instead of flooding the screen.
- **Setup checks:** load order vs. what's on disk, game-version mismatches, missing or disabled mods.
- **Crash post-mortem:** exit code decoded, last mod or phase reached, crash dumps read, plus Windows hardware events (Kernel-Power, WHEA, GPU driver resets, disk errors), so a hardware problem isn't blamed on mods.
- **Session archive:** each run's logs are copied every 30 seconds, so even a hard reboot leaves evidence.
- **Read-only:** they never write into the game, Steam, Workshop or mod-manager folders. Everything goes into a data folder next to the script.

## Install

1. Download this repository (**Code → Download ZIP**) and unzip it anywhere, e.g. `C:\Tools\`.
2. Open the folder for your game and double-click its `Start-...Console.bat`.
3. Start the game (before or after, either works).

Requirements: Windows 10/11, Windows PowerShell 5.1 (built in) or PowerShell 7. The `.bat` launchers run the script with `-ExecutionPolicy Bypass` so Windows doesn't block it; read the script first if you like, since it's plain text.

Each folder's README lists the keys, options and limits for that game.

## Support

Found a bug or want a console for another game? Open an issue here, or ask in the [Loveless Gaming Discord](https://discord.gg/qcmgVa2Fx6). More mods and tools: [lovelessgaming.com](https://lovelessgaming.com).

## Credits

Made by Loveless Gaming, written with the help of Claude (Anthropic). MIT licensed: see [LICENSE](LICENSE).
