# GnomeHunter

Guild ranking addon for World of Warcraft: **Forever** (Interface 16001). Tracks who in your guild kills the most gnomes in world PvP, with weekly player bounties, enemy-guild tagging, proximity alerts, a guild chat announcer and a publishable ranking.

Current version: **v2.5.0**

---

## Features

### Ranking
- **Weekly + all-time rankings** — the weekly ranking resets every **Tuesday at 12:00 (Brasília, UTC-3)**; the all-time ranking never resets on its own. Switch between them with the `Semanal` / `Geral` tabs in the window. The week boundary uses the server clock (`GetServerTime`), so every client in the guild agrees on it.
- **Guild-wide leaderboard** — every player with the addon broadcasts their score via an invisible guild addon channel; everyone sees the same ranking with no spam on `/g`.
- **Kills and points tracked separately** — the UI shows raw kill count plus a "pts" breakdown (so bonus points from bounties stay visible without inflating the kill column).
- **Automatic deduplication** — resolves short-name and full-name entries to a single player via the guild roster (keeps the maximum, never sums duplicates).
- **Top 3 color-coded** gold / silver / bronze, your own row highlighted in yellow.
- **Guild-only filter** — hide players who left the guild from the ranking.

### Bounties
- **Weekly player bounty** — officers post a bounty on a specific enemy (name + optional race). Killing them awards **+10 bonus points**.
- **Enemy guild tag** — officers can tag an entire enemy guild. Killing any member of that guild awards **+1 bonus point** (stacks with player bounty and gnome kill).
- **Partial-name matching** — setting a bounty with the first name (`Bollha`) matches full-name targets (`Bollha Tall`). Exact match still works.
- **Officer-only enforcement** — bounty broadcasts (set, clear, guild reset) are rejected locally if the sender isn't rank 0 or 1 in the guild roster, so non-officers can't tamper even on crafted messages.
- **Persisted across logouts** — bounties carry a timestamp and are only overwritten by newer broadcasts. The known v2.3 bug where officers accidentally wiped active bounties on re-login is fixed.

### Proximity alerts
- When a bounty target (player or any member of the tagged guild) appears on your nameplates, is targeted, or moused over, you get a chat highlight, a raid-warning banner on screen, and a sound.
- 60-second cooldown per name to avoid spam.

### Guild chat integration (opt-in toggles)
- **Kill announcer** (default ON): posts every gnome kill, player-bounty kill and guild-bounty kill to `/g` with the victim's level. Example: `Bollha Tall abateu o gnomo Spikebolt [lvl 42] (+1 pt)`.
- **Death announcer** (default OFF): when you die in open-world PvP to an identified hostile player, posts a tombstone message. Skipped in dungeons/raids/BGs/arenas and on deaths with no identifiable killer (fall damage, PvE, residual DoT).
- **Ranking publisher**: `Publicar` button in the UI (publishes the selected tab) or `/gnomo publish [N] [geral]` sends the top N (max 20) of the weekly or all-time ranking plus active bounties to `/g`. Messages are spaced 0.35 s apart to dodge the server's rate limiter and preserve order.

### UI
- Dark red themed draggable window (360 × 616) with:
  - Header banner and gnome icon.
  - Your current score + rank card.
  - Bounty card with separate rows for player bounty and guild bounty.
  - Three bounty action buttons (officer-only): `Player`, `Guild`, `Clear`.
  - Checkboxes for guild-only filter, proximity alerts, and chat announcer.
  - 15-row ranking table with your row highlighted.
  - Bottom row: `Sync`, `Publicar`, `Reset` (officer-only global reset), `Help`.
- Draggable minimap button (left-click: ranking; right-click: toggle alerts; drag: reposition); positioned dynamically just outside the minimap border.

### Reliability
- Guild roster is treated as asynchronous — `GuildRoster()` is requested separately from reading, with scheduled retries at 1 s and 4 s via `C_Timer`.
- Sync replies (`REQ`, `BOUNTYREQ`, `GBREQ`) go via `WHISPER` addon channel direct to the asker instead of broadcasting to the whole guild, avoiding the server's addon-message rate limit when many clients answer at once.
- On login the client broadcasts its own score once, requests others, and retries the request 15 s later to catch slow loaders.

---

## Installation

1. Download and extract into `World of Warcraft\_forever_\Interface\AddOns\GnomeHunter\`.
2. Enable in the AddOns menu at character select.
3. Log in and type `/gnomo` or click the gnome head icon on the minimap.

---

## Commands

| Command | Action |
|---|---|
| `/gnomo` | Show the weekly ranking in chat |
| `/gnomo geral` | Show the all-time ranking in chat |
| `/gnomo ui` | Open/close the ranking window |
| `/gnomo sync` | Request fresh scores + bounties from the guild |
| `/gnomo guildonly` | Toggle "guild members only" filter |
| `/gnomo alerts` | Toggle bounty proximity alerts |
| `/gnomo announce` | Toggle automatic kill announcements to `/g` |
| `/gnomo deathannounce` | Toggle open-world-PvP death announcements (default OFF) |
| `/gnomo minimap` | Show/hide the minimap button |
| `/gnomo bounty <name> [race in brackets]` | **(officers)** Set the weekly player bounty. Example: `/gnomo bounty Bollha Tall [Human]` |
| `/gnomo bounty clear` | **(officers)** Remove the active player bounty |
| `/gnomo guildbounty <guild name>` | **(officers)** Tag an enemy guild |
| `/gnomo guildbounty clear` | **(officers)** Remove the guild tag |
| `/gnomo publish [N] [geral]` | Post top N (default 10, max 20) of the weekly (default) or all-time ranking + active bounties to `/g` |
| `/gnomo resetme` | Zero your own score locally |
| `/gnomo migrate` | Consolidate short-name / full-name duplicates in the local DB |
| `/gnomo roster` | Dump what the addon knows about the guild roster |
| `/gnomo me` | Dump what every name-resolution API returns for your character |
| `/gnomo status` | Debug info (cache sizes, bounty state, officer flag) |
| `/gnomo testalert` | Fire a test proximity alert |
| `/gnomo test` | Simulate a kill on the current target |
| `/gnomo build` | Show client version |
| `/gnomo help` | List every command |

---

## How kill detection works

Based on the strategy used by Spy's Forever port:

- `COMBAT_LOG_EVENT_UNFILTERED` is empty on Forever — not used.
- `PARTY_KILL` fires as a standalone event with `(attackerGUID, targetGUID)` — the gold standard for confirming your own killing blow on a player.
- Unit race, name (full `First Last`), guild and level are cached by GUID via nameplate / target / mouseover scans.
- When a `PARTY_KILL` matches your GUID as the attacker and the target was cached as Gnome (or matches the player/guild bounty), the kill is counted.
- `issecretvalue()` wrapper is used around every API return to handle identity-restricted battlegrounds where the client blanks out player data.

For best results, enable enemy nameplates (`Esc > Options > Nameplates > Show Enemy Nameplates`) so proximity alerts and level/race detection work reliably.

---

## How sync works (nothing shows in `/g`)

All synchronization traffic travels on the invisible `SendAddonMessage` channel — never in visible chat:

| Payload | Direction | Purpose |
|---|---|---|
| `SCORE:name:pts:kcount` | Broadcast or Whisper | A client's current all-time score |
| `WSCORE:name:weekId:pts:kcount` | Broadcast or Whisper | A client's score for the current week (ignored if `weekId` isn't the current week) |
| `REQ:name` | Broadcast | Asks everyone to reply with their score (replies go via Whisper) |
| `BOUNTY:name:race:setBy:setAt` | Broadcast or Whisper | Active player bounty |
| `BOUNTYCLR:timestamp` | Broadcast | Clears the player bounty |
| `BOUNTYREQ:` | Broadcast | Asks officers to send the current bounty (reply via Whisper) |
| `GBNTY:guildname:setBy:setAt` | Broadcast or Whisper | Active guild bounty |
| `GBCLR:timestamp` | Broadcast | Clears the guild bounty |
| `GBREQ:` | Broadcast | Asks officers to send the current guild bounty |
| `RESETALL:timestamp` | Broadcast | Officer-only full reset of the guild's ranking |

The only user-visible messages posted to `/g` are those you actively opt into (kill announcer, death announcer) or explicitly trigger (`Publicar` button / `/gnomo publish`).

---

## Requirements

- World of Warcraft: Forever client (Interface 16001).
- An active guild for ranking sync and bounty broadcast.

## Credits

- Kill detection approach adapted from [Spy by Immolation/Slipjack](https://www.curseforge.com/wow/addons/spy) — their `Forever.lua` port is the reference for every addon that needs real combat data on this client.
- Icon: Blizzard's `INV_Misc_Head_Gnome_01`.

## License

Released under the MIT License — see the repository for details.
