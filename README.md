# GnomeHunter

Guild ranking addon for World of Warcraft: **Forever** (Interface 16001). Tracks who in your guild kills the most gnomes in world PvP, with a weekly bounty system and nearby-target alerts.

---

## Features

- **Guild-wide ranking** — every player with the addon broadcasts their kill count via guild addon channel; everyone sees the same leaderboard
- **Weekly bounty** — guild officers can post a bounty on a specific player (name + race). Killing the bounty target awards **+10 bonus points** instead of 1
- **Proximity alerts** — when the bounty target appears on your nameplates, is targeted, or moused-over, you get a chat message, a raid-warning text on screen, and a sound
- **Minimap button** — quick access to the ranking window; right-click toggles alerts; drag to reposition
- **In-game GUI** — draggable window with top 15, bounty display, and filter toggles
- **Guild-only filter** — hide players who left the guild from the ranking

## Installation

1. Download and extract into `World of Warcraft\_forever_\Interface\AddOns\GnomeHunter\`
2. Enable in the AddOns menu at character select
3. Log in and type `/gnomo` or click the gnome head icon on the minimap

## Commands

| Command | Action |
|---|---|
| `/gnomo` | Show ranking in chat |
| `/gnomo ui` | Open/close the ranking window |
| `/gnomo sync` | Request fresh scores from the guild |
| `/gnomo guildonly` | Toggle "guild members only" filter |
| `/gnomo alerts` | Toggle bounty proximity alerts |
| `/gnomo minimap` | Show/hide the minimap button |
| `/gnomo bounty <nick> [race]` | **(officers)** Set the weekly bounty |
| `/gnomo bounty clear` | **(officers)** Remove the active bounty |
| `/gnomo test` | Simulate a kill on current target (debug) |
| `/gnomo testalert` | Fire a test proximity alert |
| `/gnomo resetme` | Zero your own score |
| `/gnomo status` | Debug info |
| `/gnomo build` | Show client version |

## How kill detection works

Based on the strategy used by Spy's Forever port:

- `COMBAT_LOG_EVENT_UNFILTERED` is empty on Forever — not used
- `PARTY_KILL` fires as a standalone event with `(attackerGUID, targetGUID)` — this is the gold standard for confirming your own killing blow on a player
- Unit race is cached via nameplates / target / mouseover scans
- When a `PARTY_KILL` matches your GUID as the attacker and the target was cached as Gnome (or is the current bounty), the kill is counted

For best results, enable enemy nameplates (`Esc > Options > Nameplates > Show Enemy Nameplates`) so bounty proximity alerts trigger more reliably.

## Requirements

- World of Warcraft: Forever client (Interface 16001)
- Active guild (for ranking sync and bounty broadcast)

## Credits

- Kill detection approach adapted from [Spy by Immolation/Slipjack](https://www.curseforge.com/wow/addons/spy) — their `Forever.lua` port is the reference for every addon that needs real combat data on this client
- Icon: Blizzard's `INV_Misc_Head_Gnome_01`
