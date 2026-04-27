# GoPlacement-AIO-UI

In-game GameObject placement and editing panel for AzerothCore (3.3.5) — built on
Eluna/ALE + AIO. Search the `gameobject_template` catalog by name, preview a
spawn 12 yards in front of you, nudge it around with on-screen buttons, then
save to the `gameobject` table without leaving the world.

Made for quick scene-dressing and patching up custom WMOs/zones. Not a Noggit
replacement — for fine 3D placement (full pitch/roll), use Noggit. This is the
tool when you just want to drop a mailbox 5 yards left and call it a day.

## Features

- **Search / Add** — search `gameobject_template` by name, scrollable list of
  up to 200 results showing entry, name, displayId, and type. Click to drop a
  preview spawn 12y in front of you.
- **Nearby (10y)** — auto-refreshing list of saved GameObjects within 10
  yards, with header showing live count. Click any row to enter edit mode on
  that GO.
- **6-axis movement** — Fwd / Back / Left / Right / Up / Down, one-click step
  per press, configurable step size (0.1 / 0.5 / 1 / 5 / 10 yards).
- **Yaw rotation** — Rot L / Rot R with step size 1° / 5° / 15° / 45° / 90°.
- **Scale** — clamped at minimum 0.2, configurable step (0.05 / 0.1 / 0.25 /
  0.5).
- **Snap to Ground** / **Snap to Me** / **Teleport to GO**.
- **Save** — writes a temp preview to the `gameobject` table, or persists edit
  changes to the existing row.
- **Drop Preview** / **Duplicate** / **Delete** (with two-click confirm).
- **Reads existing rotation quaternion** when editing a saved GO so it
  preserves any tilt previously set by Noggit or other tools.

## Screenshots

_(add your own)_

## Prerequisites

- AzerothCore-compatible WotLK 3.3.5 core
- [Eluna](https://github.com/ElunaLuaEngine/Eluna) or ALE Lua engine
- [AIO framework by Rochet2](https://github.com/Rochet2/AIO) installed and
  working on both server (in `lua_scripts/AIO_Server/`) and client (the
  `AIO_Client` AddOn folder in your WoW client)
- Standard `acore_world` schema with `gameobject` and `gameobject_template`
  tables (default)
- A character with GM rank ≥ 2 (configurable, see below)

## Installation

1. Drop the `GoPlacementUI/` folder into your server's
   `lua_scripts/AIO_Server/` directory:

   ```
   <core>/lua_scripts/AIO_Server/GoPlacementUI/
   ├── GoPlacementClient.lua
   └── GoPlacementServer.lua
   ```

2. Restart worldserver. The console should print:

   ```
   [GP-UI] Server handlers loaded under 'GoPlacementSrv'.
   ```

3. Log in to a GM character (rank 2+). You should see a chat toast:

   ```
   [GP] UI loaded (vX-…). Type /gp to open. Debug is OFF.
   ```

## Usage

| Command | Action |
| --- | --- |
| `/gp` or `/goplace` | Toggle the placement panel. |

### Workflow

1. **Find an entry**: type a name fragment in the Search/Add box, hit Find.
   Click any result row → preview spawns 12 yards forward of your character.
2. **Position it**: click Fwd/Back/Left/Right/Up/Down to nudge by the active
   Move step. Use Rot L/R for yaw, Scale -/+ to resize.
3. **Snap**: Snap to Ground drops it to terrain height. Snap to Me places it
   at your exact location and orientation.
4. **Commit**: click Save to write it to the `gameobject` table. The preview
   converts to a saved spawn.
5. **Edit existing**: switch to the Nearby tab, click any saved GO row to
   enter edit mode. Move/rotate/scale, then Save to update the DB row.
6. **Remove**: Drop Preview discards an unsaved preview. Delete (click twice
   to confirm) removes a saved GO from the world and deletes its `gameobject`
   row.

## Configuration

Edit the `CONFIG` table at the top of `GoPlacementServer.lua`:

```lua
local CONFIG = {
    GMLevel           = 2,      -- minimum GM rank to use /gp
    DefaultDistance   = 12.0,   -- yards in front of player for preview spawn
    NearbyRadius      = 10.0,   -- yards radius for the Nearby tab
    MaxNearbyRows     = 100,    -- cap on Nearby list size
    MaxSearchResults  = 200,    -- cap on Search list size
    PhaseMask         = 1,      -- phase to spawn into
    MinScale          = 0.2,    -- minimum allowed scale
    MaxScale          = 10.0,   -- maximum allowed scale
    LogToConsole      = true,
    DebugHandlers     = false,  -- log every AIO handler call to console
}
```

Client-side debug toggle is the **Toggle Debug** button in the panel itself,
or you can flip `DEBUG = true` at the top of `GoPlacementClient.lua` to start
in debug mode.

## Troubleshooting

**Boot toast doesn't show / `/gp` does nothing.**
The new client wasn't shipped. Wipe the AIO client cache and relog:
- Delete `WTF/Account/<ACCT>/<...>/SavedVariables/AIO_Client.lua` (and the
  `.bak`) on every character that connects to this server.
- Fully log out to character select, log back in. AIO will re-download.

**Search returns rows but the list is empty in the panel.**
Make sure you're on `vX-handler-arity` or later. AIO handlers always receive
`player` as the first argument; older versions of this addon had `Cli.X(rows)`
instead of `Cli.X(player, rows)` and silently dropped the data.

**Server console shows `[ALE]: Error loading lua_scripts/.../Client.lua. File
with same name already loaded from ...`**
Eluna/ALE keys scripts by basename. The files in this addon are named
`GoPlacementClient.lua` and `GoPlacementServer.lua` specifically to avoid
colliding with other AIO addons that might use bare `Client.lua` /
`Server.lua` (e.g. ClassLess). Don't rename them.

**The list won't render even though the server logs say rows were sent.**
This addon uses `UIPanelButtonTemplate` for list rows. If you're on a heavily
custom client that overrides that template, swap to plain `Button` frames.
Open an issue with your client's UI customizations.

**Pitch/Roll buttons missing.**
Intentionally removed. `PerformIngameSpawn` only takes yaw, and most Eluna
forks don't expose a usable `SetRotation`/`SetWorldRotation` on temp spawns,
so live preview tilt isn't reliable. Server still reads `rotation0..rotation3`
when entering edit mode on an existing tilted GO so your tilt isn't clobbered
when you Save edit changes.

## Permissions

GM rank ≥ 2 is required by default (configurable). Every handler validates
the caller's GM rank server-side, so a non-GM client AIO message can't
trigger spawns or DB writes.

## File-by-file

- `GoPlacementServer.lua` — handler table, SQL queries, spawn/despawn logic,
  euler→quaternion math, session state per player. Loads on server only.
  ~478 lines.
- `GoPlacementClient.lua` — AIO addon shipped to clients on connect. Frame
  layout, button wiring, scroll lists, slash command. ~423 lines.

## Credits

- Built on top of [AIO](https://github.com/Rochet2/AIO) by Rochet2.
- Despawn-cascade pattern (RemoveFromWorld(false) + nearest-player re-fetch)
  borrowed from BountifulFrontiers.

## License

_(your choice — MIT/GPL-2.0/Apache-2.0 are all common for AzerothCore mods)_
