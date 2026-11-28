# Changelog

All notable changes to GnomeHunter are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The GitHub Actions release workflow reads the section matching the release tag
(e.g. tag `v2.5.0` → section `## [2.5.0]`) and uploads it to CurseForge as the
changelog for that file. Keep the header format exactly as `## [X.Y.Z] - YYYY-MM-DD`.

## [2.8.0] - 2026-11-28

### Added
- Full in-game UI for guild events: new `Evento` tab on the ranking window with its own filter, state badge next to the tabs, and a dynamic footer showing the time until the event starts or ends
- `+ Novo` button next to the tabs opens a dedicated modal (not a one-field popup) with four fields — Nome, Data `YYYY-MM-DD`, Hora `HH:MM`, Duração `em horas` — with tab navigation, Enter submits, sensible defaults (data/hora prefill to one hour from now, duration 2h) and an explicit "Horário de Brasília (BRT, UTC-3)" notice
- `Cancelar` button next to `+ Novo` opens a confirmation popup and cancels the active event, propagating the clear to the guild
- Tab tooltip shows event name, BRT window, and status (ativo / cancelado / encerrado / aguardando início)
- Minimap button tooltip now reports the active or last event with its countdown

### Changed
- Officer buttons for events (`+ Novo`, `Cancelar`) follow the same hide-for-non-officers policy introduced in v2.7.0 for bounty/reset buttons
- `Semanal` / `Geral` / `Evento` tabs resized (62 / 48 / 56 px) to fit the third tab without clipping the KILLS header
- `BuildRankingList`, `ScoreStore` and `MyRankAndScore` accept `view="event"` natively — resolves the store of the active event or the last finished one

### Internal
- Added `GetDisplayEvent()` helper used by the UI and the minimap tooltip
- Hide-zero policy of the weekly tab now also applies to the event tab (only you and players who scored in the event appear)

## [2.7.0] - 2026-11-28

### Added
- Full-ranking sync: on login and on `/gnomo sync` / Sync button, the client asks up to 2 guild members (officers first, then whoever knows the most players) for their complete ranking, so scores of players who are currently offline are received too
- Addon-message protocol: `SYNCOK:n` (candidate reply to `REQ`), `SYNCREQ:` (pick a peer), `SYNC:view:weekId:resetAt:name,pts,kc,ep;...` (chunked dump, ≤250 bytes per message, 0.3 s apart, 30 s cooldown per requester)
- Per-player reset epoch (`GnomeHunterDB.epoch`): `/gnomo resetme` stamps a new epoch so the MAX merge on other clients doesn't bring the old score back
- A client that missed an officer `RESETALL` while offline adopts it when an officer sends a dump with a newer `resetAt`

### Changed
- `SCORE` and `WSCORE` now merge with MAX instead of overwriting — a stale or wiped client no longer pulls everyone's copy of its score down
- `/gnomo resetall` (local wipe) is now recoverable: the next sync restores every score via MAX
- Officer check for your own actions (`IsGuildOfficer`) now uses your guild rank (0 or 1) — the same rule every other client uses to accept officer messages. Before, it used `CanGuildInvite()`, so a non-officer with invite rights could set bounties or reset the ranking only on their own client, while an officer without invite rights couldn't use the buttons
- Officer buttons (`Player`, `Guild`, `Clear`, `Reset`) are hidden for non-officers instead of disabled; `Help` moves into the `Reset` slot. `Clear` was previously never disabled
- `/gnomo test` only previews the points a kill would give; it no longer records, syncs or announces a kill (anyone could farm points with it)

### Compatibility
- v2.6.x clients still answer `REQ` and receive `SCORE`/`WSCORE` as before; they're just never picked as full-sync peers
- A `/gnomo resetme` done on a v2.6.x client is not seen by v2.7 clients (they keep the higher value)

## [2.6.0] - 2026-11-27

### Added
- Officer-configurable guild events with a start datetime + duration (Brasília time, UTC-3), producing a dedicated ranking exclusive to the event window while the kills still count for weekly and all-time rankings
- Only one event active at a time; creating a new event cancels the previous one
- Event history keeps the 5 most recent events (FIFO)
- Guild chat announcements for event start (with end time in BRT) and end (naming the champion)
- Individual local kill log (`GnomeHunterDB.killLog`, rolling buffer of 5000 entries) tagged with `eventId`, `race`, `victim`, `lvl`, server time
- Slash commands: `/gnomo event create "Nome" YYYY-MM-DD HH:MM <horas>`, `/gnomo event cancel`, `/gnomo event info`, `/gnomo event help`
- Addon-message protocol for event sync: `EVENT`, `EVENTCLR`, `EVENTREQ`, `ESCORE` — all officer-only on destructive payloads (`IsRosterOfficer(sender)`)
- `TickEvents()` piggybacks on the existing 30s ticker to detect start/end transitions and fire the guild announcements

### Preserved
- Officer-only reset rule (`GNOMEHUNTER_RESETALL`) untouched; `RESETALL` does not clear event stores (events are independent of the ranking lifecycle)
- Full backward compatibility with v2.5.x clients — they ignore unknown event payloads and keep seeing weekly and all-time rankings as before

### Known gap
- In-game UI for event creation (popup with EditBoxes + button) is not in this release; event creation remains slash-only. The ranking "Evento" tab, countdown and announcements all work. UI follow-up tracked in PR #3 (draft).

## [2.5.0] - 2026-11-21

### Added
- Weekly ranking tab that resets every Tuesday at 12:00 Brasília time (UTC-3), synchronized across the guild using the server clock
- All-time ranking tab alongside the weekly view
- Guild-wide score broadcasting over an invisible guild addon channel (no spam on `/g`)
- Separate tracking of raw kills and bonus points (points breakdown stays visible without inflating the kill count)
- Color-coded top 3 (gold / silver / bronze) and own-row highlight
- Guild-only filter to hide players who have left the guild

### Changed
- Deduplication of short-name and full-name entries via guild roster (keeps the max, never sums duplicates)

## [2.4.17]

Earlier versions — see git history.
