-- Group XP: an experience bar for every member of your group.
-- Members share their XP over addon messages. The message format matches Naowh Forever's
-- Group XP, so players running either addon see each other.

local ADDON = ...
local PREFIX = "NaowhGroupXP"
local ASK = "R"
local MSG_FORMAT = "2 %s %d %d %d"
local MSG_PATTERN = "^2 (%S+) (%d+) (%d+) (%d+)$"
local GUID_PATTERN = "^Player%-%d+%-%x+$"
local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }
local MAX_SANE_LEVEL, MAX_SANE_XP = 1000, 2 ^ 31
local SEND_DELAY = 2

local ROW_H, NAME_W, GAP = 18, 90, 2
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local BAR_COLOR = { r = 0.0, g = 0.57, b = 0.93 }
local WHITE = { r = 1, g = 1, b = 1 }
local DEFAULT_POS = { point = "LEFT", relPoint = "LEFT", x = 40, y = 120 }

local DEFAULTS = { showSelf = true, locked = true, width = 260, scale = 1, bgAlpha = 0.8 }

local SAMPLE = {
    { name = "Tank", class = "WARRIOR", data = { level = 24, xp = 11000, max = 12200 } },
    { name = "Healer", class = "PRIEST", data = { level = 25, xp = 3100, max = 13100 } },
    { name = "Rogue", class = "ROGUE", level = 23 },
}

local db
local frame, mover
local rows = {}
local others = {} -- guid -> { level, xp, max }
local sendQueued, askQueued, sendAfterCombat, testMode

local Num = BreakUpLargeNumbers or tostring

local function Print(msg)
    print("|cff0091edGroup XP|r: " .. msg)
end

local function Debug(msg)
    if db and db.debug then Print("|cff9ca3af" .. msg .. "|r") end
end

local function Secret(v)
    return issecretvalue and issecretvalue(v)
end

local function MaxLevel()
    if GetMaxLevelForPlayerExpansion then return GetMaxLevelForPlayerExpansion() end
    return MAX_PLAYER_LEVEL or 60
end

local function Channel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
end

local function Own()
    return { level = UnitLevel("player"), xp = UnitXP("player"), max = UnitXPMax("player") }
end

-- Sending -------------------------------------------------------------------

local function Send()
    local channel = Channel()
    if not channel then
        askQueued = false
        return
    end
    -- Addon messages can be blocked in combat, so hold the update until it ends.
    if InCombatLockdown() then
        sendAfterCombat = true
        return
    end
    if askQueued then
        askQueued = false
        local result = C_ChatInfo.SendAddonMessage(PREFIX, ASK, channel)
        Debug("sent ask on " .. channel .. ", result " .. tostring(result))
    end
    local own = Own()
    local msg = MSG_FORMAT:format(UnitGUID("player"), own.level, own.xp, own.max)
    local result = C_ChatInfo.SendAddonMessage(PREFIX, msg, channel)
    Debug("sent \"" .. msg .. "\" on " .. channel .. ", result " .. tostring(result))
end

-- Batches bursts of events (a kill and a level-up together) into one message.
local function SendSoon(ask)
    if ask then askQueued = true end
    if sendQueued then return end
    sendQueued = true
    C_Timer.After(SEND_DELAY, function()
        sendQueued = false
        Send()
    end)
end

-- Group roster --------------------------------------------------------------

local function Units()
    local units = { "player" }
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            local isMe = UnitIsUnit(unit, "player")
            if not Secret(isMe) and not isMe then units[#units + 1] = unit end
        end
    else
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end
    return units
end

local function Roster()
    local roster = {}
    for _, unit in ipairs(Units()) do
        local name, guid = UnitName(unit), UnitGUID(unit)
        local _, class = UnitClass(unit)
        if name and guid and not (Secret(name) or Secret(guid) or Secret(class)) then
            roster[#roster + 1] = { unit = unit, name = name, class = class, guid = guid }
        end
    end
    return roster
end

-- Only trust a message whose sender is the group member owning that GUID.
-- The sender can arrive as "Name", "Name-Realm" or "Name Realm", so compare only the name part.
local function SenderOwns(sender, guid)
    local short = sender:match("^([^%-%s]+)")
    for _, m in ipairs(Roster()) do
        if m.guid == guid then
            if m.name == short or m.name == sender then return true end
            Debug("sender \"" .. sender .. "\" does not match " .. m.name)
            return false
        end
    end
    Debug("GUID " .. guid .. " from \"" .. sender .. "\" is not in your group")
    return false
end

local function Prune()
    local inGroup = {}
    for _, m in ipairs(Roster()) do inGroup[m.guid] = true end
    for guid in pairs(others) do
        if not inGroup[guid] then others[guid] = nil end
    end
end

-- Display -------------------------------------------------------------------

local function ShowTooltip(row)
    local e = row.entry
    if not e then return end
    local color = e.class and RAID_CLASS_COLORS[e.class] or WHITE
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(e.name, color.r, color.g, color.b)
    local d = e.data
    if not d then
        GameTooltip:AddLine("Not sharing XP (needs Group XP or Naowh Forever).", 0.6, 0.6, 0.6, true)
    elseif d.level >= MaxLevel() or d.max <= 0 then
        GameTooltip:AddDoubleLine("Level", d.level .. " (max)", 1, 1, 1, 1, 1, 1)
    else
        GameTooltip:AddDoubleLine("Level", d.level, 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("XP", Num(d.xp) .. " / " .. Num(d.max), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("To level", Num(d.max - d.xp), 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:Show()
end

local function NewRow()
    local row = CreateFrame("Frame", nil, frame)
    row:SetHeight(ROW_H)
    row:EnableMouse(true)
    row:SetScript("OnEnter", ShowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT")
    row.name:SetWidth(NAME_W - 4)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.border = row:CreateTexture(nil, "BACKGROUND")
    row.border:SetPoint("TOPLEFT", NAME_W, 0)
    row.border:SetPoint("BOTTOMRIGHT")
    row.border:SetColorTexture(0, 0, 0, 1)

    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetPoint("TOPLEFT", NAME_W + 1, -1)
    row.bar:SetPoint("BOTTOMRIGHT", -1, 1)
    row.bar:SetStatusBarTexture(BAR_TEXTURE)
    row.bar:SetStatusBarColor(BAR_COLOR.r, BAR_COLOR.g, BAR_COLOR.b)
    row.bar:SetMinMaxValues(0, 1)

    row.bg = row.bar:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()

    row.text = row.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("CENTER")
    return row
end

local function Paint(row, e)
    row.entry = e
    local color = e.class and RAID_CLASS_COLORS[e.class] or WHITE
    row.name:SetText(e.name)
    row.name:SetTextColor(color.r, color.g, color.b)
    row.bg:SetColorTexture(0.08, 0.08, 0.08, db.bgAlpha)
    local d = e.data
    if not d then
        local lv = e.level and e.level > 0 and ("Lv " .. e.level) or "Lv ?"
        row.bar:SetValue(0)
        row.text:SetText(lv .. "  |cff9ca3afno addon|r")
    elseif d.level >= MaxLevel() or d.max <= 0 then
        row.bar:SetValue(1)
        row.text:SetText("Lv " .. d.level .. "  Max")
    else
        local pct = d.xp / d.max
        row.bar:SetValue(pct)
        row.text:SetText(("Lv %d  %.1f%%"):format(d.level, pct * 100))
    end
    row:Show()
end

local function Entries()
    local list = {}
    if testMode or not db.locked then
        if db.showSelf then
            local _, class = UnitClass("player")
            list[#list + 1] = { name = UnitName("player"), class = class, data = Own() }
        end
        for _, s in ipairs(SAMPLE) do list[#list + 1] = s end
    elseif IsInGroup() then
        for _, m in ipairs(Roster()) do
            local isPlayer = m.unit == "player"
            if not isPlayer or db.showSelf then
                local level = UnitLevel(m.unit)
                if Secret(level) then level = nil end
                list[#list + 1] = {
                    name = m.name, class = m.class, level = level,
                    data = isPlayer and Own() or others[m.guid],
                }
            end
        end
    end
    return list
end

local function Refresh()
    if not frame then return end
    local list = Entries()
    if #list == 0 then
        frame:Hide()
        return
    end
    local step = ROW_H + GAP
    frame:SetSize(db.width, #list * step - GAP)
    for i, e in ipairs(list) do
        local row = rows[i] or NewRow()
        rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(i - 1) * step)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * step)
        Paint(row, e)
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    frame:Show()
end

local function Place()
    local pos = db.pos or DEFAULT_POS
    frame:ClearAllPoints()
    frame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    frame:SetScale(db.scale)
end

local function Build()
    frame = CreateFrame("Frame", "GroupXPFrame", UIParent)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)

    -- An overlay that catches the drag while unlocked, so rows keep their tooltips otherwise.
    mover = CreateFrame("Frame", nil, frame)
    mover:SetAllPoints()
    mover:SetFrameLevel(frame:GetFrameLevel() + 10)
    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")
    mover.tex = mover:CreateTexture(nil, "OVERLAY")
    mover.tex:SetAllPoints()
    mover.tex:SetColorTexture(BAR_COLOR.r, BAR_COLOR.g, BAR_COLOR.b, 0.3)
    mover.label = mover:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mover.label:SetPoint("BOTTOM", mover, "TOP", 0, 4)
    mover.label:SetText("Group XP - drag to move, /gxp lock when done")
    mover:SetScript("OnDragStart", function() frame:StartMoving() end)
    mover:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint()
        db.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    mover:Hide()
end

local function Apply()
    Place()
    mover:SetShown(not db.locked)
    Refresh()
end

-- Events --------------------------------------------------------------------

local function OnAddonMessage(prefix, msg, channel, sender)
    if Secret(prefix) or Secret(msg) or Secret(channel) or Secret(sender) then return end
    if prefix ~= PREFIX then return end
    Debug("got \"" .. msg .. "\" from \"" .. sender .. "\" on " .. channel)
    if not GROUP_CHANNELS[channel] then return end
    if msg == ASK then
        SendSoon()
        return
    end
    local guid, level, xp, max = msg:match(MSG_PATTERN)
    if not guid or not guid:find(GUID_PATTERN) or guid == UnitGUID("player") then return end
    level, xp, max = tonumber(level), tonumber(xp), tonumber(max)
    if level > MAX_SANE_LEVEL or xp > MAX_SANE_XP or max > MAX_SANE_XP then return end
    if not SenderOwns(sender, guid) then return end
    others[guid] = { level = level, xp = xp, max = max }
    Refresh()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        GroupXpBarDB = GroupXpBarDB or {}
        db = GroupXpBarDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        for _, e in ipairs({ "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD",
            "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "UNIT_LEVEL", "PLAYER_REGEN_ENABLED" }) do
            self:RegisterEvent(e)
        end
        Build()
        Apply()
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        Prune()
        -- Ask everyone for their numbers when we arrive; otherwise just share ours.
        SendSoon(event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE")
        Refresh()
    elseif event == "PLAYER_XP_UPDATE" or event == "PLAYER_LEVEL_UP" then
        SendSoon()
        Refresh()
    elseif event == "UNIT_LEVEL" then
        Refresh()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if sendAfterCombat then
            sendAfterCombat = false
            Send()
        end
    end
end)

-- Slash commands ------------------------------------------------------------

local HELP = {
    "/gxp unlock - show the bars with samples and let you drag them",
    "/gxp lock - lock the bars in place",
    "/gxp self - show or hide your own bar",
    "/gxp width <160-500> - bar width",
    "/gxp scale <0.5-2> - overall size",
    "/gxp alpha <0-1> - background opacity",
    "/gxp test - preview with sample members",
    "/gxp reset - restore default settings and position",
    "/gxp debug - print what is sent and received (for troubleshooting)",
}

SLASH_GROUPXP1 = "/gxp"
SLASH_GROUPXP2 = "/groupxp"
SlashCmdList.GROUPXP = function(input)
    local cmd, arg = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    local n = tonumber(arg)
    if cmd == "unlock" then
        db.locked = false
        Print("Unlocked. Drag the bars, then type /gxp lock.")
    elseif cmd == "lock" then
        db.locked = true
        Print("Locked.")
    elseif cmd == "self" then
        db.showSelf = not db.showSelf
        Print("Your own bar is now " .. (db.showSelf and "shown." or "hidden."))
    elseif cmd == "width" and n then
        db.width = math.min(500, math.max(160, n))
    elseif cmd == "scale" and n then
        db.scale = math.min(2, math.max(0.5, n))
    elseif cmd == "alpha" and n then
        db.bgAlpha = math.min(1, math.max(0, n))
    elseif cmd == "debug" then
        db.debug = not db.debug
        Print("Debug messages " .. (db.debug and "on." or "off."))
        if db.debug then
            Print("In group: " .. tostring(IsInGroup()) .. ", channel: " .. tostring(Channel())
                .. ", prefix registered: " .. tostring(C_ChatInfo.IsAddonMessagePrefixRegistered(PREFIX)))
            SendSoon(true)
        end
        return
    elseif cmd == "test" then
        testMode = not testMode
        Print("Test mode " .. (testMode and "on." or "off."))
    elseif cmd == "reset" then
        wipe(db)
        for k, v in pairs(DEFAULTS) do db[k] = v end
        Print("Settings reset.")
    else
        for _, line in ipairs(HELP) do Print(line) end
        return
    end
    Apply()
end
