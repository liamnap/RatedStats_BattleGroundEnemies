# Rated Stats — Battleground Enemies (BGE)

A Retail **battleground-only** enemy frames addon built for the Rated Stats ecosystem.

This addon gives you a compact, configurable enemy list in battlegrounds (including Rated BG / Blitz), designed to stay readable in real fights and to behave predictably with modern Blizzard UI restrictions.

Repo contents are intentionally simple: a `.toc` and a single Lua file (`battlegroundenemies.lua`), plus release/merge helper scripts.  
- `RatedStats_BattlegroundEnemies.toc`  
- `battlegroundenemies.lua`  
- `save-and-tag.js` / `merge-dev-to-main.sh`

---

## What it does

### Enemy frames that actually help in BGs
- Shows an enemy roster in a frame (rows / columns based on your settings).
- Per-row health display and dynamic updates when the game allows (scoreboard seeding + live unit bindings where available).
- Click-to-target support (where permitted by secure UI rules).

### “Chat-tab” style header + quick actions
- A top-left tab (like Blizzard chat windows) that appears on hover.
- Right-click menu actions for:
  - Lock / Unlock frame position
  - Open settings

### Visual clarity tuned for PvP
- Transparent background tinting by enemy faction color (stronger red/blue tint while keeping transparency).
- Out-of-range styling that doesn’t fight your eyes mid-fight.

### Rated Stats integration (optional but supported)
- Designed to plug into the Rated Stats family of addons.
- Supports showing Rated Stats PvP rank / achievement icon overlays when the Rated Stats achievement module is installed and enabled.

---

## Compatibility

- **Retail only**
- **Battleground-only scope** (not intended for arena frames)

Blizzard’s modern UI restrictions (secure templates, “secret” values, combat lockdown) mean some information cannot be read at all times, and some actions can’t happen during combat. This addon is built to degrade safely instead of throwing errors or tainting.

---

## Install

### CurseForge App
Install normally through CurseForge (project: “BattlegroundEnemies – Rated Stats version”).

### Manual
1. Download the release zip
2. Extract into:
   `World of Warcraft/_retail_/Interface/AddOns/`
3. Ensure the folder name matches the addon folder inside the zip
4. Restart the game

---

## Configuration

In-game settings are exposed through the addon’s UI entry and the frame’s right-click menu:
- Layout (rows/columns, sizes)
- Visual styling (background tint, transparency)
- Optional integration toggles (Rated Stats achievements/ranks)

---

## Known limitations (by design)

- In combat, frame sizing/position changes may be blocked (combat lockdown).
- Some unit data can be unavailable until the game exposes it (especially early in BGs or during mass joins/leaves).
- “Perfect” enemy tracking at all distances is intentionally not possible under modern Blizzard restrictions.

---

## Credits

Inspired by the original BattleGroundEnemies concept, but implemented and maintained as a Rated Stats-targeted battleground module.

---

## License

See repository for license details (if/when included).
