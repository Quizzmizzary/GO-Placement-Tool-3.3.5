-- GoPlacementClient.lua  (will install as AIO_Server/GoPlacement/GoPlacementClient.lua)
-- AIO addon: GameObject placement panel UI for WoW 3.3.5.
-- Slash command: /gp  (also /goplace) opens the panel.

local AIO = AIO or require("AIO")

-- On the server: AIO.AddAddon() returns true, queues this file to ship to
-- clients on connect. We then `return` so server-only environments skip the
-- UI code below.
-- On the client: returns false; UI code runs.
if AIO.AddAddon() then return end

local Cli = AIO.AddHandlers("GoPlacementCli", {})

-- ---------------------------------------------------------------------------
-- Debug switch. Mirror every send/receive into chat so we can see whether the
-- AIO round-trip is actually happening. Set false once everything's wired.
-- ---------------------------------------------------------------------------
local DEBUG = false

local function dbg(msg)
    if DEBUG and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cFF888888[GP-dbg]|r " .. tostring(msg))
    end
end

local function toast(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700[GP]|r " .. tostring(msg))
    end
end

-- ---------------------------------------------------------------------------
-- Active step sizes
-- ---------------------------------------------------------------------------
local active = { move = 1.0, rot = 15, scale = 0.1 }
local mode = "search"     -- "search" or "nearby"
local lastState = nil

-- ---------------------------------------------------------------------------
-- Send wrapper with debug
-- ---------------------------------------------------------------------------
local function send(action, ...)
    dbg("-> Srv." .. action)
    AIO.Handle("GoPlacementSrv", action, ...)
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------
local function mkBtn(parent, label, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h); b:SetText(label); return b
end

local function mkBtnAt(parent, label, w, h, x, y, onClick)
    local b = mkBtn(parent, label, w, h)
    b:SetPoint("TOPLEFT", x, y)
    b:SetScript("OnClick", onClick)
    return b
end

local function mkLabel(parent, text, font)
    local f = parent:CreateFontString(nil, "ARTWORK", font or "GameFontNormal")
    f:SetText(text); return f
end

local function setStepActive(btn, isActive)
    if isActive then
        btn:LockHighlight()
        btn:SetNormalFontObject("GameFontHighlight")
    else
        btn:UnlockHighlight()
        btn:SetNormalFontObject("GameFontNormal")
    end
end

-- ---------------------------------------------------------------------------
-- Main frame  (taller and wider since we got rid of the d-pad)
-- ---------------------------------------------------------------------------
local F = CreateFrame("Frame", "GoPlacementUIFrame", UIParent)
F:SetSize(440, 640)
F:SetPoint("CENTER", 0, 0)
F:SetMovable(true); F:EnableMouse(true)
F:RegisterForDrag("LeftButton")
F:SetScript("OnDragStart", F.StartMoving)
F:SetScript("OnDragStop",  F.StopMovingOrSizing)
F:SetClampedToScreen(true)
F:Hide()
F:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})

local title = mkLabel(F, "GameObject Placement", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -16)

local close = CreateFrame("Button", nil, F, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -4, -4)
close:SetScript("OnClick", function() F:Hide() end)

-- ---------------------------------------------------------------------------
-- Tab bar
-- ---------------------------------------------------------------------------
local tabSearch = mkBtnAt(F, "Search / Add", 170, 22, 18, -42, function()
    setMode("search")
end)
local tabNearby = mkBtnAt(F, "Nearby (10y)", 170, 22, 196, -42, function()
    setMode("nearby")
end)

-- ---------------------------------------------------------------------------
-- Search panel
-- ---------------------------------------------------------------------------
local searchPanel = CreateFrame("Frame", nil, F)
searchPanel:SetPoint("TOPLEFT", 18, -72)
searchPanel:SetPoint("TOPRIGHT", -18, -72)
searchPanel:SetHeight(220)

local searchBox = CreateFrame("EditBox", "GoPlacementSearchBox", searchPanel, "InputBoxTemplate")
searchBox:SetSize(280, 24)
searchBox:SetPoint("TOPLEFT", 6, -4)
searchBox:SetAutoFocus(false)
searchBox:SetScript("OnEnterPressed", function(self)
    send("Search", self:GetText() or "")
    self:ClearFocus()
end)

local searchBtn = mkBtnAt(searchPanel, "Find", 60, 22, 290, -4, function()
    send("Search", searchBox:GetText() or "")
end)

-- Standard UIPanelButtonTemplate rows + a real FauxScrollFrame scroll bar.
local ROW_H = 18
local LIST_ROWS = 8
local ROW_W = 348  -- leaves room for the scroll bar on the right
local searchData = {}

local function makeListRow(parent, idx, yTop)
    local r = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    r:SetSize(ROW_W, ROW_H)
    r:SetPoint("TOPLEFT", 6, yTop - (idx - 1) * (ROW_H + 1))
    local fs = r:GetFontString()
    if fs then
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", r, "LEFT", 8, 0)
        fs:SetPoint("RIGHT", r, "RIGHT", -8, 0)
        fs:SetJustifyH("LEFT")
    end
    r.text = r
    r:SetText("")
    r:Hide()
    return r
end

-- Search scroll
local searchScroll = CreateFrame("ScrollFrame", "GoPlacementSearchScroll",
    searchPanel, "FauxScrollFrameTemplate")
searchScroll:SetPoint("TOPLEFT", 6, -34)
searchScroll:SetPoint("BOTTOMRIGHT", -28, 4)

local searchRows = {}
for i = 1, LIST_ROWS do
    searchRows[i] = makeListRow(searchPanel, i, -34)
end

local function fmtSearchRow(d)
    return string.format("[%d] %s  |cFF888888(disp %d, type %d)|r",
        d.entry or 0, d.name or "?", d.displayId or 0, d.type or 0)
end

local function refreshSearchScroll()
    local total = #searchData
    FauxScrollFrame_Update(searchScroll, total, LIST_ROWS, ROW_H + 1)
    local offset = FauxScrollFrame_GetOffset(searchScroll)
    for i = 1, LIST_ROWS do
        local r = searchRows[i]
        local d = searchData[i + offset]
        if d then
            r:SetText(fmtSearchRow(d))
            r:SetScript("OnClick", function() send("Preview", d.entry) end)
            r:Show()
        else
            r:Hide()
        end
    end
end

searchScroll:SetScript("OnVerticalScroll", function(self, off)
    FauxScrollFrame_OnVerticalScroll(self, off, ROW_H + 1, refreshSearchScroll)
end)

function Cli.SearchResults(player, rows)
    dbg("<- SearchResults: " .. (rows and #rows or 0) .. " rows")
    searchData = rows or {}
    refreshSearchScroll()
end

-- ---------------------------------------------------------------------------
-- Nearby panel
-- ---------------------------------------------------------------------------
local nearbyPanel = CreateFrame("Frame", nil, F)
nearbyPanel:SetPoint("TOPLEFT", 18, -72)
nearbyPanel:SetPoint("TOPRIGHT", -18, -72)
nearbyPanel:SetHeight(220)
nearbyPanel:Hide()

local nearbyHeader = mkLabel(nearbyPanel,
    "Saved GameObjects within 10y. Click a row to select.")
nearbyHeader:SetPoint("TOPLEFT", 6, -4)

local nearbyData = {}

local nearbyScroll = CreateFrame("ScrollFrame", "GoPlacementNearbyScroll",
    nearbyPanel, "FauxScrollFrameTemplate")
nearbyScroll:SetPoint("TOPLEFT", 6, -22)
nearbyScroll:SetPoint("BOTTOMRIGHT", -28, 4)

local nearbyRows = {}
for i = 1, LIST_ROWS do
    nearbyRows[i] = makeListRow(nearbyPanel, i, -22)
end

local function refreshNearbyScroll()
    local total = #nearbyData
    nearbyHeader:SetText(string.format(
        "Saved GameObjects within 10y (%d found). Click a row to select.", total))
    FauxScrollFrame_Update(nearbyScroll, total, LIST_ROWS, ROW_H + 1)
    local offset = FauxScrollFrame_GetOffset(nearbyScroll)
    for i = 1, LIST_ROWS do
        local r = nearbyRows[i]
        local d = nearbyData[i + offset]
        if d then
            r:SetText(string.format("[%d] %s  (%.1fy)",
                d.entry or 0, d.name or "?", d.dist or 0))
            r:SetScript("OnClick", function() send("SelectWorld", d.guid) end)
            r:Show()
        else
            r:Hide()
        end
    end
end

nearbyScroll:SetScript("OnVerticalScroll", function(self, off)
    FauxScrollFrame_OnVerticalScroll(self, off, ROW_H + 1, refreshNearbyScroll)
end)

function Cli.NearbyResults(player, rows)
    dbg("<- NearbyResults: " .. (rows and #rows or 0) .. " rows")
    nearbyData = rows or {}
    refreshNearbyScroll()
end

-- Auto-refresh while Nearby is the active tab
local nearbyTimer = 0
F:SetScript("OnUpdate", function(self, elapsed)
    if not self:IsShown() or mode ~= "nearby" then return end
    nearbyTimer = nearbyTimer + elapsed
    if nearbyTimer >= 2.0 then
        nearbyTimer = 0
        send("ListNearby")
    end
end)

-- Tab switching (declared as global so the tab buttons above can call it)
function setMode(m)
    mode = m
    if m == "search" then
        searchPanel:Show(); nearbyPanel:Hide()
        setStepActive(tabSearch, true); setStepActive(tabNearby, false)
    else
        searchPanel:Hide(); nearbyPanel:Show()
        setStepActive(tabSearch, false); setStepActive(tabNearby, true)
        nearbyTimer = 0
        send("ListNearby")
    end
end

-- ---------------------------------------------------------------------------
-- Selection / state readout
-- ---------------------------------------------------------------------------
local infoFrame = CreateFrame("Frame", nil, F)
infoFrame:SetPoint("TOPLEFT", 18, -300)
infoFrame:SetPoint("TOPRIGHT", -18, -300)
infoFrame:SetHeight(56)

local infoLine1 = mkLabel(infoFrame, "No active selection.", "GameFontHighlight")
infoLine1:SetPoint("TOPLEFT", 0, 0); infoLine1:SetPoint("RIGHT", 0, 0)
infoLine1:SetJustifyH("LEFT")
local infoLine2 = mkLabel(infoFrame, "", "GameFontNormalSmall")
infoLine2:SetPoint("TOPLEFT", 0, -16); infoLine2:SetPoint("RIGHT", 0, 0)
infoLine2:SetJustifyH("LEFT")
local infoLine3 = mkLabel(infoFrame, "", "GameFontNormalSmall")
infoLine3:SetPoint("TOPLEFT", 0, -32); infoLine3:SetPoint("RIGHT", 0, 0)
infoLine3:SetJustifyH("LEFT")

-- ---------------------------------------------------------------------------
-- Step-size selectors
-- ---------------------------------------------------------------------------
local stepFrame = CreateFrame("Frame", nil, F)
stepFrame:SetPoint("TOPLEFT", 18, -362)
stepFrame:SetPoint("TOPRIGHT", -18, -362)
stepFrame:SetHeight(72)

local function rowOfStepBtns(yOffset, label, options, applyFn)
    local lbl = mkLabel(stepFrame, label, "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 0, yOffset)
    local buttons, x = {}, 56
    for _, opt in ipairs(options) do
        local b = mkBtn(stepFrame, opt.label, opt.w or 38, 18)
        b:SetPoint("TOPLEFT", x, yOffset + 2)
        b:SetScript("OnClick", function()
            applyFn(opt.value)
            for _, o in ipairs(buttons) do setStepActive(o, o == b) end
        end)
        buttons[#buttons + 1] = b
        x = x + (opt.w or 38) + 2
        if opt.default then applyFn(opt.value); b._default = true end
    end
    for _, b in ipairs(buttons) do
        if b._default then setStepActive(b, true) end
    end
end

rowOfStepBtns(  0, "Move:", {
    { label = "0.1",  value = 0.1,  w = 36 },
    { label = "0.5",  value = 0.5,  w = 36 },
    { label = "1",    value = 1.0,  w = 36, default = true },
    { label = "5",    value = 5.0,  w = 36 },
    { label = "10",   value = 10.0, w = 36 },
}, function(v) active.move = v end)

rowOfStepBtns(-22, "Rot:", {
    { label = "1\194\176",  value = 1,  w = 36 },
    { label = "5\194\176",  value = 5,  w = 36 },
    { label = "15\194\176", value = 15, w = 36, default = true },
    { label = "45\194\176", value = 45, w = 36 },
    { label = "90\194\176", value = 90, w = 36 },
}, function(v) active.rot = v end)

rowOfStepBtns(-44, "Scale:", {
    { label = "0.05", value = 0.05, w = 42 },
    { label = "0.1",  value = 0.1,  w = 42, default = true },
    { label = "0.25", value = 0.25, w = 42 },
    { label = "0.5",  value = 0.5,  w = 42 },
}, function(v) active.scale = v end)

-- ---------------------------------------------------------------------------
-- Nudge row — flat 6 buttons across, no overlapping pad
-- ---------------------------------------------------------------------------
local nudgeFrame = CreateFrame("Frame", nil, F)
nudgeFrame:SetPoint("TOPLEFT", 18, -440)
nudgeFrame:SetPoint("TOPRIGHT", -18, -440)
nudgeFrame:SetHeight(60)

local NUDGE_W, NUDGE_H = 62, 24
local function placeNudge(label, axis, x, y)
    return mkBtnAt(nudgeFrame, label, NUDGE_W, NUDGE_H, x, y, function()
        send("Move", axis, active.move)
    end)
end

-- Row 1: Fwd / Back / Left / Right / Up / Down  (movement)
placeNudge("Fwd",   "f",   0,                    0)
placeNudge("Back",  "b",   1 * (NUDGE_W + 4),    0)
placeNudge("Left",  "l",   2 * (NUDGE_W + 4),    0)
placeNudge("Right", "r",   3 * (NUDGE_W + 4),    0)
placeNudge("Up",    "u",   4 * (NUDGE_W + 4),    0)
placeNudge("Down",  "d",   5 * (NUDGE_W + 4),    0)

-- Row 2: Rot L / Rot R (yaw) + Scale -/+
mkBtnAt(nudgeFrame, "Rot L",   NUDGE_W + 14, NUDGE_H, 0,                    -28,
    function() send("Rotate", "yaw",  active.rot) end)
mkBtnAt(nudgeFrame, "Rot R",   NUDGE_W + 14, NUDGE_H, 1 * (NUDGE_W + 18),   -28,
    function() send("Rotate", "yaw", -active.rot) end)
mkBtnAt(nudgeFrame, "Scale -", NUDGE_W + 14, NUDGE_H, 2 * (NUDGE_W + 18),   -28,
    function() send("Scale",  -active.scale) end)
mkBtnAt(nudgeFrame, "Scale +", NUDGE_W + 14, NUDGE_H, 3 * (NUDGE_W + 18),   -28,
    function() send("Scale",   active.scale) end)

-- ---------------------------------------------------------------------------
-- Action buttons (bottom)
-- ---------------------------------------------------------------------------
local actionFrame = CreateFrame("Frame", nil, F)
actionFrame:SetPoint("TOPLEFT", 18, -516)
actionFrame:SetPoint("TOPRIGHT", -18, -516)
actionFrame:SetHeight(90)

mkBtnAt(actionFrame, "Snap to Ground",   124, 22,   0,   0, function() send("SnapGround")   end)
mkBtnAt(actionFrame, "Snap to Me",       124, 22, 130,   0, function() send("SnapToMe")     end)
mkBtnAt(actionFrame, "Teleport to GO",   124, 22, 260,   0, function() send("TeleportToGO") end)

mkBtnAt(actionFrame, "Save",              90, 22,   0, -28, function() send("Save")         end)
mkBtnAt(actionFrame, "Drop Preview",     115, 22,  94, -28, function() send("DropPreview")  end)
mkBtnAt(actionFrame, "Duplicate",         90, 22, 213, -28, function() send("Duplicate")    end)

local deleteBtn = mkBtnAt(actionFrame, "Delete", 78, 22, 307, -28, function()
    send("DeleteSelected")
end)

mkBtnAt(actionFrame, "Refresh List", 124, 22,   0, -56, function() send("ListNearby") end)
mkBtnAt(actionFrame, "Toggle Debug", 124, 22, 130, -56, function()
    DEBUG = not DEBUG
    toast("Debug " .. (DEBUG and "ON" or "OFF"))
end)

-- ---------------------------------------------------------------------------
-- AIO -> client handlers
-- ---------------------------------------------------------------------------
function Cli.State(player, s)
    dbg("<- State: " .. (s and (s.mode or "?") or "nil"))
    lastState = s
    if not s or s.mode == "none" or not s.entry then
        infoLine1:SetText("|cFFFFD700No active selection.|r")
        infoLine2:SetText("Search and click an entry, or pick from Nearby.")
        infoLine3:SetText("")
        deleteBtn:SetText("Delete")
        return
    end
    local modeTxt = (s.mode == "preview") and "PREVIEW (unsaved)" or "EDIT (saved GO)"
    if s.mode == "edit" and s.editGuidLow then
    