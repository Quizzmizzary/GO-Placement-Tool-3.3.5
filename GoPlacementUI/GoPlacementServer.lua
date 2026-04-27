-- GoPlacementServer.lua
-- AIO-driven server handlers for the GO placement panel.
--
-- IMPORTANT:
-- This file is loaded ONLY on the server. It must NOT call AIO.AddAddon()
-- (that would ship the source to clients, where WorldDBQuery etc. are nil).
-- The matching client file (GoPlacementClient.lua) is the one that calls
-- AIO.AddAddon() to ship itself.
--
-- Despawn approach is borrowed from BountifulFrontiers.lua: call
-- :RemoveFromWorld(false) on the stored handle, then re-fetch a fresh handle
-- from the nearest player and call it again. The re-fetch fallback exists
-- because on this fork the stored handle's RemoveFromWorld doesn't always
-- actually drop the in-world GO.

local AIO = AIO or require("AIO")
local Srv = AIO.AddHandlers("GoPlacementSrv", {})

local CONFIG = {
    GMLevel           = 2,
    DefaultDistance   = 12.0,
    NearbyRadius      = 10.0,
    MaxNearbyRows     = 100,
    MaxSearchResults  = 200,
    PhaseMask         = 1,
    MinScale          = 0.2,
    MaxScale          = 10.0,
    LogToConsole      = true,
    DebugHandlers     = false,  -- print every incoming handler call
}

-- per-player session
local session = {}

local function isGM(player)
    return player and player:GetGMRank() >= CONFIG.GMLevel
end

local function logHandler(player, name, ...)
    if CONFIG.DebugHandlers then
        local args = { ... }
        for i, v in ipairs(args) do args[i] = tostring(v) end
        print(string.format("[GP-UI] handler %s from %s args=(%s)",
            name, player and player:GetName() or "?", table.concat(args, ", ")))
    end
end

local function sqlEscape(text) return (text:gsub("'", "''")) end

-- ---------------------------------------------------------------------------
-- Despawn (BF pattern: stored handle + nearest-from-player re-fetch fallback)
-- ---------------------------------------------------------------------------
local function despawnGO(state, player)
    -- Attempt 1: stored handle.
    if state.goRef then
        pcall(function()
            if state.goRef:IsInWorld() then
                state.goRef:RemoveFromWorld(false)
            end
        end)
    end

    -- Attempt 2: re-fetch via the nearest player. Belt-and-suspenders.
    local refPlayer = player
    if not refPlayer or not refPlayer:IsInWorld() then
        local players = GetPlayersInWorld()
        if players then
            for _, p in ipairs(players) do
                if p and p:IsInWorld() and p:GetMapId() == state.mapId then
                    local dx = p:GetX() - state.x
                    local dy = p:GetY() - state.y
                    if (dx * dx + dy * dy) <= 40000 then
                        refPlayer = p; break
                    end
                end
            end
        end
    end
    if refPlayer and state.entry then
        pcall(function()
            local fresh = refPlayer:GetNearestGameObject(60.0, state.entry)
            if fresh then fresh:RemoveFromWorld(false) end
        end)
    end
    state.goRef = nil
end

-- ---------------------------------------------------------------------------
-- Spawn helpers
-- ---------------------------------------------------------------------------
local function spawnTemp(entry, mapId, x, y, z, o)
    local ok, go = pcall(PerformIngameSpawn, 2, entry, mapId, 0, x, y, z, o,
                         false, 0, CONFIG.PhaseMask)
    if ok then return go end
    return nil
end

local function spawnSaved(entry, mapId, x, y, z, o)
    local ok, go = pcall(PerformIngameSpawn, 2, entry, mapId, 0, x, y, z, o,
                         true, 0, CONFIG.PhaseMask)
    if ok then return go end
    return nil
end

local function applyScale(go, scale)
    if go and scale and scale ~= 1.0 then
        pcall(function() go:SetScale(scale) end)
    end
end

-- ---------------------------------------------------------------------------
-- Full 3D rotation (yaw/pitch/roll → quaternion)
-- ---------------------------------------------------------------------------
local function eulerToQuat(yaw, pitch, roll)
    local cy = math.cos(yaw   * 0.5)
    local sy = math.sin(yaw   * 0.5)
    local cp = math.cos(pitch * 0.5)
    local sp = math.sin(pitch * 0.5)
    local cr = math.cos(roll  * 0.5)
    local sr = math.sin(roll  * 0.5)
    local qw = cr * cp * cy + sr * sp * sy
    local qx = sr * cp * cy - cr * sp * sy
    local qy = cr * sp * cy + sr * cp * sy
    local qz = cr * cp * sy - sr * sp * cy
    return qx, qy, qz, qw
end

local function quatToEuler(qx, qy, qz, qw)
    local sinr_cosp = 2 * (qw * qx + qy * qz)
    local cosr_cosp = 1 - 2 * (qx * qx + qy * qy)
    local roll = math.atan2(sinr_cosp, cosr_cosp)
    local sinp = 2 * (qw * qy - qz * qx)
    local pitch
    if math.abs(sinp) >= 1 then
        pitch = (sinp > 0 and 1 or -1) * (math.pi / 2)
    else
        pitch = math.asin(sinp)
    end
    local siny_cosp = 2 * (qw * qz + qx * qy)
    local cosy_cosp = 1 - 2 * (qy * qy + qz * qz)
    local yaw = math.atan2(siny_cosp, cosy_cosp)
    return yaw, pitch, roll
end

-- Try every Eluna rotation API name we know of, and also angle-based variants.
-- Returns true if SOME call didn't error. (Doesn't guarantee the visual changed
-- — fork may have a stub. But it's the best signal we have.)
local CACHED_ROT_METHOD = nil  -- name of the method that worked last time, if any
local TRIED_METHODS = false
local function applyRotation(go, yaw, pitch, roll)
    if not go then return false end
    local qx, qy, qz, qw = eulerToQuat(yaw, pitch or 0, roll or 0)
    -- Try angle-based variants too.
    local attempts = {
        { "SetRotation",         qx, qy, qz, qw },
        { "SetWorldRotation",    qx, qy, qz, qw },
        { "SetLocalRotation",    qx, qy, qz, qw },
        { "SetWorldRotationAngles", roll or 0, pitch or 0, yaw or 0 },
        { "SetRotationAngles",      roll or 0, pitch or 0, yaw or 0 },
        { "SetParentRotation",   qx, qy, qz, qw },
    }
    if CACHED_ROT_METHOD then
        -- Fast-path the known-good method first.
        for i, a in ipairs(attempts) do
            if a[1] == CACHED_ROT_METHOD then
                local ok = pcall(function() go[a[1]](go, a[2], a[3], a[4], a[5]) end)
                if ok then return true end
                -- It stopped working? Fall through to retry all.
                break
            end
        end
    end
    for _, a in ipairs(attempts) do
        local ok = pcall(function() go[a[1]](go, a[2], a[3], a[4], a[5]) end)
        if ok then
            if not TRIED_METHODS or CACHED_ROT_METHOD ~= a[1] then
                print("[GP-UI] Rotation method that worked: " .. a[1])
            end
            CACHED_ROT_METHOD = a[1]
            TRIED_METHODS = true
            return true
        end
    end
    if not TRIED_METHODS then
        print("[GP-UI] No rotation method on this fork accepted a call. " ..
              "Pitch/roll will only apply on Save.")
        TRIED_METHODS = true
    end
    return false
end

local function rebuildPreview(player, s)
    despawnGO(s, player)
    s.goRef = spawnTemp(s.entry, s.mapId, s.x, s.y, s.z, s.o)
    applyScale(s.goRef, s.scale)
    applyRotation(s.goRef, s.o, s.pitch, s.roll)
end

local function editRelocate(player, s)
    -- For saved GOs we ideally Relocate() and SaveToDB(); fall back to
    -- despawn+respawn if not available.
    local relocated = false
    if s.goRef then
        relocated = pcall(function() s.goRef:Relocate(s.x, s.y, s.z, s.o) end)
    end
    if not relocated then
        despawnGO(s, player)
        s.goRef = spawnTemp(s.entry, s.mapId, s.x, s.y, s.z, s.o)
    end
    applyScale(s.goRef, s.scale)
    applyRotation(s.goRef, s.o, s.pitch, s.roll)
end

-- ---------------------------------------------------------------------------
-- State send to client
-- ---------------------------------------------------------------------------
local function sendState(player)
    local s = session[player:GetGUIDLow()]
    local payload
    if not s then
        payload = { mode = "none" }
    else
        local px, py = player:GetX(), player:GetY()
        local dx, dy = (s.x or px) - px, (s.y or py) - py
        payload = {
            mode  = s.mode,
            entry = s.entry,
            x = s.x, y = s.y, z = s.z, o = s.o,
            pitch = s.pitch or 0, roll = s.roll or 0,
            scale = s.scale or 1.0,
            mapId = s.mapId,
            distance = math.sqrt(dx * dx + dy * dy),
            editGuidLow = s.editGuidLow,
        }
    end
    AIO.Handle(player, "GoPlacementCli", "State", payload)
end

local function sendToast(player, msg)
    AIO.Handle(player, "GoPlacementCli", "Toast", msg)
end

-- ===========================================================================
-- Handlers
-- ===========================================================================

function Srv.OnOpen(player)
    logHandler(player, "OnOpen")
    if not isGM(player) then
        sendToast(player, "GM rank " .. CONFIG.GMLevel .. "+ required.")
        return
    end
    sendState(player)
end

function Srv.Search(player, text)
    logHandler(player, "Search", text)
    if not isGM(player) then return end
    text = tostring(text or ""):sub(1, 80)
    if text == "" then
        AIO.Handle(player, "GoPlacementCli", "SearchResults", {})
        return
    end
    local q = string.format(
        "SELECT entry, type, displayId, name FROM gameobject_template WHERE name LIKE '%%%s%%' ORDER BY entry LIMIT %d",
        sqlEscape(text), CONFIG.MaxSearchResults)
    local res = WorldDBQuery(q)
    local rows = {}
    if res then
        repeat
            rows[#rows + 1] = {
                entry     = res:GetUInt32(0),
                type      = res:GetUInt32(1),
                displayId = res:GetUInt32(2),
                name      = res:GetString(3),
            }
        until not res:NextRow()
    end
    print(string.format("[GP-UI] Search '%s' → %d rows", text, #rows))
    AIO.Handle(player, "GoPlacementCli", "SearchResults", rows)
end

function Srv.ListNearby(player)
    logHandler(player, "ListNearby")
    if not isGM(player) then return end
    local mapId = player:GetMapId()
    local px, py, pz = player:GetX(), player:GetY(), player:GetZ()
    local r = CONFIG.NearbyRadius
    local q = string.format([[
        SELECT g.guid, g.id, t.name, g.position_x, g.position_y, g.position_z, g.orientation
        FROM gameobject g
        LEFT JOIN gameobject_template t ON t.entry = g.id
        WHERE g.map = %d
          AND g.position_x BETWEEN %f AND %f
          AND g.position_y BETWEEN %f AND %f
        LIMIT %d
    ]], mapId, px - r, px + r, py - r, py + r, CONFIG.MaxNearbyRows * 4)
    local res = WorldDBQuery(q)
    local rows = {}
    if res then
        repeat
            local gx, gy, gz = res:GetFloat(3), res:GetFloat(4), res:GetFloat(5)
            local dx, dy, dz = gx - px, gy - py, gz - pz
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d <= r then
                rows[#rows + 1] = {
                    guid  = res:GetUInt32(0),
                    entry = res:GetUInt32(1),
                    name  = res:GetString(2) or "?",
                    x = gx, y = gy, z = gz,
                    o = res:GetFloat(6),
                    dist = d,
                }
            end
        until not res:NextRow()
    end
    table.sort(rows, function(a, b) return a.dist < b.dist end)
    while #rows > CONFIG.MaxNearbyRows do rows[#rows] = nil end
    print(string.format("[GP-UI] ListNearby map=%d at (%.1f,%.1f) → %d rows",
        mapId, px, py, #rows))
    AIO.Handle(player, "GoPlacementCli", "NearbyResults", rows)
end

function Srv.Preview(player, entry, distance)
    logHandler(player, "Preview", entry, distance)
    if not isGM(player) then return end
    entry = tonumber(entry); if not entry then return end
    local dist = tonumber(distance) or CONFIG.DefaultDistance
    local guid = player:GetGUIDLow()
    if session[guid] then despawnGO(session[guid], player) end

    local px, py, pz = player:GetX(), player:GetY(), player:GetZ()
    local po = player:GetO()
    local goO = (po + math.pi) % (2 * math.pi)
    local x = px + math.cos(po) * dist
    local y = py + math.sin(po) * dist

    local s = {
        mode = "preview", entry = entry,
        x = x, y = y, z = pz, o = goO,
        pitch = 0, roll = 0,
        scale = 1.0, mapId = player:GetMapId(),
    }
    s.goRef = spawnTemp(entry, s.mapId, x, y, pz, goO)
    if not s.goRef then
        sendToast(player, "Spawn failed for entry " .. entry)
        session[guid] = nil
        sendState(player)
        return
    end
    session[guid] = s
    sendToast(player, string.format("Preview [%d] %.0fy forward.", entry, dist))
    sendState(player)
end

function Srv.SelectWorld(player, dbGuid)
    logHandler(player, "SelectWorld", dbGuid)
    if not isGM(player) then return end
    dbGuid = tonumber(dbGuid); if not dbGuid then return end
    local guid = player:GetGUIDLow()
    if session[guid] then despawnGO(session[guid], player) end

    local q = string.format(
        "SELECT id, position_x, position_y, position_z, orientation, map FROM gameobject WHERE guid = %d",
        dbGuid)
    local res = WorldDBQuery(q)
    if not res then
        sendToast(player, "World GO " .. dbGuid .. " not found.")
        return
    end
    local entry = res:GetUInt32(0)
    local x, y, z, o = res:GetFloat(1), res:GetFloat(2), res:GetFloat(3), res:GetFloat(4)
    local mapId = res:GetUInt32(5)
    local liveGO = nil
    pcall(function()
        liveGO = player:GetNearestGameObject(60.0, entry)
    end)
    local scale = 1.0
    if liveGO then
        local ok, val = pcall(function() return liveGO:GetScale() end)
        if ok and val then scale = val end
    end
    -- Read existing rotation quaternion so editing a tilted GO keeps its tilt.
    local pitch, roll = 0, 0
    pcall(function()
        local q2 = string.format(
            "SELECT rotation0, rotation1, rotation2, rotation3 FROM gameobject WHERE guid = %d",
            dbGuid)
        local r2 = WorldDBQuery(q2)
        if r2 then
            local qx = r2:GetFloat(0)
            local qy = r2:GetFloat(1)
            local qz = r2:GetFloat(2)
            local qw = r2:GetFloat(3)
            local _, p, rl = quatToEuler(qx, qy, qz, qw)
            pitch, roll = p or 0, rl or 0
        end
    end)
    session[guid] = {
        mode = "edit", editGuidLow = dbGuid, entry = entry,
        x = x, y = y, z = z, o = o,
        pitch = pitch, roll = roll,
        scale = scale, mapId = mapId, goRef = liveGO,
    }
    sendToast(player, string.format("Selected world GO #%d (entry %d)",
        dbGuid, entry))
    sendState(player)
end

function Srv.Move(player, axis, delta)
    logHandler(player, "Move", axis, delta)
    if not isGM(player) then return end
    delta = tonumber(delta); if not delta then return end
    local s = session[player:GetGUIDLow()]
    if not s then return end
    if axis == "u" then s.z = s.z + delta
    elseif axis == "d" then s.z = s.z - delta
    elseif axis == "f" then
        s.x = s.x + math.cos(s.o) * delta; s.y = s.y + math.sin(s.o) * delta
    elseif axis == "b" then
        s.x = s.x - math.cos(s.o) * delta; s.y = s.y - math.sin(s.o) * delta
    elseif axis == "l" then
        s.x = s.x + math.cos(s.o + math.pi / 2) * delta
        s.y = s.y + math.sin(s.o + math.pi / 2) * delta
    elseif axis == "r" then
        s.x = s.x + math.cos(s.o - math.pi / 2) * delta
        s.y = s.y + math.sin(s.o - math.pi / 2) * delta
    end
    if s.mode == "edit" then editRelocate(player, s) else rebuildPreview(player, s) end
    sendState(player)
end

function Srv.Rotate(player, axis, deg)
    logHandler(player, "Rotate", axis, deg)
    if not isGM(player) then return end
    -- Backwards-compat: if a single numeric arg was sent (old client), treat it as yaw.
    if type(axis) == "number" and deg == nil then
        deg = axis; axis = "yaw"
    end
    deg = tonumber(deg); if not deg then return end
    local s = session[player:GetGUIDLow()]
    if not s then return end
    local rad = math.rad(deg)
    if axis == "yaw" then
        s.o = (s.o + rad) % (2 * math.pi)
        -- Yaw is the only axis PerformIngameSpawn honors directly, so for
        -- previews we have to respawn; for saved GOs Relocate handles it.
        if s.mode == "edit" then editRelocate(player, s) else rebuildPreview(player, s) end
    else
        if axis == "pitch" then
            s.pitch = ((s.pitch or 0) + rad) % (2 * math.pi)
            if s.pitch >  math.pi then s.pitch = s.pitch - 2 * math.pi end
            if s.pitch < -math.pi then s.pitch = s.pitch + 2 * math.pi end
        elseif axis == "roll" then
            s.roll = ((s.roll or 0) + rad) % (2 * math.pi)
            if s.roll >  math.pi then s.roll = s.roll - 2 * math.pi end
            if s.roll < -math.pi then s.roll = s.roll + 2 * math.pi end
        end
        -- DON'T respawn for pitch/roll. PerformIngameSpawn only takes yaw, so
        -- a respawn would just look identical and cause flicker. Try the
        -- rotation API on the existing handle in case it's exposed; if not,
        -- the tilt is tracked in session and will apply when the user clicks
        -- Save (which writes rotation0..3 to gameobject).
        local applied = applyRotation(s.goRef, s.o, s.pitch, s.roll)
        if s.mode == "edit" then
            -- Edit-mode saved GOs sometimes do accept SetRotation; if it
            -- worked, great. Otherwise nothing visual changes until Save.
            if not applied and not s._tiltWarned then
                sendToast(player, "Pitch/Roll: live preview unsupported on this fork. Tilt will apply on Save.")
                s._tiltWarned = true
            end
        else
            if not applied and not s._tiltWarned then
                sendToast(player, "Pitch/Roll: live preview unsupported on this fork. Tilt will apply on Save.")
                s._tiltWarned = true
            end
        end
    end
    sendState(playe