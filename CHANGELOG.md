# Changelog

All notable changes to GnomeHunter are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The GitHub Actions release workflow reads the section matching the release tag
(e.g. tag `v2.5.0` → section `## [2.5.0]`) and uploads it to CurseForge as the
changelog for that file. Keep the header format exactly as `## [X.Y.Z] - YYYY-MM-DD`.

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
