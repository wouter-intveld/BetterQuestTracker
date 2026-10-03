local ADDON = ...

local DEFAULTS = {
    point = { "TOPRIGHT", "UIParent", "TOPRIGHT", -80, -220 },
    scale = 1.0,
    width = 260,
    maxHeight = 500,
    locked = true,
    zoneFilter = true,     -- only show quests for the current zone
    sortByDistance = true, -- nearest quest first
    respectWatch = true,   -- hide quests unchecked in the quest log
    skipHighLevel = true,  -- don't auto-track newly accepted high-level quests
    skipLevelDiff = 3,
    quiet = false,         -- mute automatic chat messages
    collapsed = false,
    collapsedZones = {},
}

-- Per character: these refer to one character's quest log.
local CHAR_DEFAULTS = {
    autoUntracked = {},    -- questIDs we unchecked, so we can re-check them
    collapsedQuests = {},
}

local db, char
local settingsCategory
local shownOrder = {}
local shownHeader = {}
local renderCount = 0
local renderReason, slowestRender, slowestReason, lastRender = "load", 0, "none", 0
local titleLines = {}
local UpdateItemButtons
local Render
local MAX_LINES = 150
local HEADER_HEIGHT = 32
local FOOTER_HEIGHT = 14
local SCROLL_STEP = 40

local function Print(msg)
    print("|cff33ff99BetterQuestTracker|r: " .. msg)
end

local function Notify(msg)
    if not db.quiet then Print(msg) end
end

---------------------------------------------------------------------------
-- Main frame
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "BetterQuestTrackerFrame", UIParent, "BackdropTemplate")
frame:SetSize(DEFAULTS.width, 60)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
frame:SetFrameStrata("MEDIUM")
frame:Hide()

frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})

local header = CreateFrame("Button", nil, frame)
header:SetPoint("TOPLEFT", 6, -4)
header:SetPoint("TOPRIGHT", -6, -4)
header:SetHeight(20)

local divider = frame:CreateTexture(nil, "ARTWORK")
divider:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
divider:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -4)
divider:SetHeight(1)
divider:SetColorTexture(1, 0.82, 0, 0.35)
header:RegisterForDrag("LeftButton")

local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("BOTTOMLEFT")
title:SetJustifyH("LEFT")

local modeText = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
modeText:SetPoint("BOTTOMRIGHT", -22, 1)

-- Drawn from two thin bars so it matches the flat header text instead of a bulky stock button.
local collapseButton = CreateFrame("Button", nil, header)
collapseButton:SetSize(16, 16)
collapseButton:SetPoint("RIGHT", 0, -1)
collapseButton.h = collapseButton:CreateTexture(nil, "ARTWORK")
collapseButton.h:SetSize(7, 2)
collapseButton.h:SetPoint("CENTER")
collapseButton.v = collapseButton:CreateTexture(nil, "ARTWORK")
collapseButton.v:SetSize(2, 7)
collapseButton.v:SetPoint("CENTER")
local function SetCollapseColor(c)
    collapseButton.h:SetColorTexture(c, c, c, 1)
    collapseButton.v:SetColorTexture(c, c, c, 1)
end
SetCollapseColor(0.5)
collapseButton:SetScript("OnClick", function(self)
    db.collapsed = not db.collapsed
    Render()
    self:GetScript("OnEnter")(self)
end)
collapseButton:SetScript("OnEnter", function(self)
    SetCollapseColor(1)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(db.collapsed and "Expand" or "Collapse")
    GameTooltip:Show()
end)
collapseButton:SetScript("OnLeave", function()
    SetCollapseColor(0.5)
    GameTooltip_Hide()
end)

local modeButton = CreateFrame("Button", nil, header)
modeButton:SetAllPoints(modeText)
modeButton:SetScript("OnClick", function(self)
    db.zoneFilter = not db.zoneFilter
    Render()
    self:GetScript("OnEnter")(self)
end)
modeButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Zone filter")
    GameTooltip:AddLine(db.zoneFilter and "Showing quests in your current zone" or "Showing all quests", 1, 1, 1)
    GameTooltip:AddLine("Click: toggle", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end)
modeButton:SetScript("OnLeave", GameTooltip_Hide)

local levelButton = CreateFrame("Button", nil, header)
levelButton:SetSize(16, 12)
levelButton:SetPoint("BOTTOMRIGHT", modeText, "BOTTOMLEFT", -8, 0)
levelButton.text = levelButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
levelButton.text:SetPoint("BOTTOMRIGHT")

local scroll = CreateFrame("ScrollFrame", nil, frame)
scroll:SetPoint("TOPLEFT", 0, -HEADER_HEIGHT)
scroll:SetPoint("RIGHT")

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(DEFAULTS.width, 1)
scroll:SetScrollChild(content)

-- Covers the tracker while unlocked, so clicks move/scale instead of hitting quests.
local moveOverlay = CreateFrame("Frame", nil, frame)
moveOverlay:SetAllPoints()
moveOverlay:SetFrameLevel(frame:GetFrameLevel() + 20)
moveOverlay:EnableMouse(true)
moveOverlay:EnableMouseWheel(true)
moveOverlay:RegisterForDrag("LeftButton")
moveOverlay:Hide()
moveOverlay.bg = moveOverlay:CreateTexture(nil, "BACKGROUND")
moveOverlay.bg:SetAllPoints()
moveOverlay.bg:SetColorTexture(0, 0, 0, 0.4)
moveOverlay.text = moveOverlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
moveOverlay.text:SetPoint("TOP", 0, -HEADER_HEIGHT - 6)
moveOverlay.text:SetJustifyH("CENTER")

-- Parented to the frame, not the header, so it stays clickable and undimmed above the move overlay.
local lockButton = CreateFrame("Button", nil, frame)
lockButton:SetSize(16, 12)
lockButton:SetPoint("BOTTOMRIGHT", levelButton, "BOTTOMLEFT", -8, 0)
lockButton:SetFrameLevel(moveOverlay:GetFrameLevel() + 10)
lockButton.text = lockButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
lockButton.text:SetPoint("BOTTOMRIGHT")

-- "move" (locked) only shows while hovering the header; "lock" (unlocked) always shows.
local function UpdateLockLabel(hover)
    lockButton.text:SetText(db.locked and "move" or "lock")
    if hover then
        lockButton.text:SetTextColor(1, 1, 1)
    elseif db.locked then
        lockButton.text:SetTextColor(0.5, 0.5, 0.5)
    else
        lockButton.text:SetTextColor(1, 0.82, 0)
    end
    lockButton:SetSize(lockButton.text:GetStringWidth(), lockButton.text:GetStringHeight())
    lockButton:SetShown(not db.locked or header:IsMouseOver())
end

local moreText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
moreText:SetPoint("BOTTOMRIGHT", -8, 3)
moreText:SetText("scroll for more")

local function MaxScroll()
    return math.max(0, content:GetHeight() - scroll:GetHeight())
end

local function UpdateMoreText()
    moreText:SetShown(scroll:GetVerticalScroll() < MaxScroll() - 1)
end
scroll:SetScript("OnVerticalScroll", UpdateMoreText)

local CHECK_ICON = (C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("ui-questtracker-tracker-check"))
    and "|A:ui-questtracker-tracker-check:14:14|a"
    or "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t"

local function AddPartyProgress(questID)
    local members = GetNumSubgroupMembers()
    if members == 0 then return end
    GameTooltip:AddLine(" ")

    if C_TooltipInfo and C_TooltipInfo.GetQuestPartyProgress then
        local ok, data = pcall(C_TooltipInfo.GetQuestPartyProgress, questID, true, true)
        if ok and data and data.lines and #data.lines > 0 then
            for _, l in ipairs(data.lines) do
                if l.leftText and l.leftText ~= "" then
                    local r, g, b = 1, 1, 1
                    if l.leftColor then r, g, b = l.leftColor:GetRGB() end
                    GameTooltip:AddLine(l.leftText, r, g, b)
                end
            end
            return
        end
    end

    for i = 1, members do
        local unit = "party" .. i
        local name = UnitName(unit) or unit
        if C_QuestLog.IsUnitOnQuest(unit, questID) then
            GameTooltip:AddLine(name .. ": on quest", 1, 1, 1)
        else
            GameTooltip:AddLine(name .. ": not on quest", 0.5, 0.5, 0.5)
        end
    end
end

local lines = {}
local function GetLine(i)
    local line = lines[i]
    if line then return line end
    line = CreateFrame("Button", nil, content)
    line:SetHeight(14)
    line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.text:SetAllPoints()
    line.text:SetJustifyH("LEFT")
    line.text:SetWordWrap(true)
    line:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    line:SetScript("OnEnter", function(self)
        local questID = self.questID
        if not questID then return end
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:SetPoint("TOPRIGHT", self, "TOPLEFT", -34, 0)
        GameTooltip:AddLine(C_QuestLog.GetTitleForQuestID(questID) or "?")
        local logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
        if logIndex and GetQuestLogQuestText then
            local _, objectiveText = GetQuestLogQuestText(logIndex)
            if objectiveText and objectiveText ~= "" then
                GameTooltip:AddLine(objectiveText, 1, 1, 1, true)
            end
        end
        GameTooltip:AddLine(" ")
        if C_QuestLog.IsComplete(questID) then
            GameTooltip:AddLine("Ready to turn in", 0.13, 1, 0.13)
        else
            for _, obj in ipairs(C_QuestLog.GetQuestObjectives(questID) or {}) do
                if obj.text and obj.text ~= "" then
                    if obj.finished then
                        GameTooltip:AddLine(CHECK_ICON .. " " .. obj.text, 0.13, 1, 0.13)
                    else
                        GameTooltip:AddLine("- " .. obj.text, 1, 1, 1)
                    end
                end
            end
        end
        AddPartyProgress(questID)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: track / untrack", 0.5, 0.5, 0.5)
        GameTooltip:AddLine("Right-click: open in quest log", 0.5, 0.5, 0.5)
        GameTooltip:AddLine("Middle-click: collapse / expand objectives", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    line:SetScript("OnLeave", GameTooltip_Hide)
    line:SetScript("OnClick", function(self, button)
        if button == "MiddleButton" then
            if self.zone then
                db.collapsedZones[self.zone] = not db.collapsedZones[self.zone] or nil
            elseif self.questID then
                char.collapsedQuests[self.questID] = not char.collapsedQuests[self.questID] or nil
            end
            Render()
            return
        end
        if not self.questID then return end
        if button == "LeftButton" and C_SuperTrack then
            local tracked = C_SuperTrack.GetSuperTrackedQuestID() == self.questID
            C_SuperTrack.SetSuperTrackedQuestID(tracked and 0 or self.questID)
        elseif QuestMapFrame_OpenToQuestDetails then
            QuestMapFrame_OpenToQuestDetails(self.questID)
        elseif ToggleQuestLog then
            ToggleQuestLog()
        end
    end)
    lines[i] = line
    return line
end

local function SavePosition()
    db.point = { "TOPRIGHT", "UIParent", "BOTTOMLEFT", frame:GetRight(), frame:GetTop() }
end

-- Blizzard re-stacks DurabilityFrame under the minimap and moves its own tracker
-- out of the way. We aren't part of that stack, so we drop below it ourselves
-- while it overlaps us. The saved position (db.point) never includes this offset.
local function AvoidOffset()
    local df = DurabilityFrame
    if not db.locked or not df or not df:IsVisible() then return 0 end
    local dfLeft, dfBottom, dfWidth, dfHeight = df:GetRect()
    if not dfLeft then return 0 end
    local ds, fs = df:GetEffectiveScale(), frame:GetEffectiveScale()
    dfLeft, dfBottom = dfLeft * ds, dfBottom * ds
    local dfRight, dfTop = dfLeft + dfWidth * ds, dfBottom + dfHeight * ds
    local right, top = db.point[4] * fs, db.point[5] * fs
    local left, bottom = right - frame:GetWidth() * fs, top - frame:GetHeight() * fs
    if dfRight <= left or dfLeft >= right or dfBottom >= top or dfTop <= bottom then return 0 end
    return (top - dfBottom + 4) / fs
end

local function PlaceFrame()
    frame.avoidOffset = AvoidOffset()
    frame:ClearAllPoints()
    frame:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", db.point[4], db.point[5] - frame.avoidOffset)
end

local function SetScaleKeepingPosition(scale)
    local right, top = db.point[4], db.point[5]
    if right and top then
        local ratio = frame:GetScale() / scale
        db.point = { "TOPRIGHT", "UIParent", "BOTTOMLEFT", right * ratio, top * ratio }
    end
    db.scale = scale
end

local function ApplyLayout()
    frame:SetScale(db.scale)
    frame:SetWidth(db.width)
    content:SetWidth(db.width)
    local p = db.point
    if p[1] ~= "TOPRIGHT" or p[3] ~= "BOTTOMLEFT" then
        frame:ClearAllPoints()
        frame:SetPoint(p[1], UIParent, p[3], p[4], p[5])
        SavePosition()
    end
    PlaceFrame()
    frame:EnableMouse(not db.locked)
    moveOverlay:SetShown(not db.locked)
    UpdateLockLabel(lockButton:IsVisible() and lockButton:IsMouseOver())
    scroll:SetAlpha(db.locked and 1 or 0.25)
    header:SetAlpha(db.locked and 1 or 0.25)
    moveOverlay.text:SetText(("Scale %d%%\n|cffaaaaaaDrag: move   Wheel: scale\nRight-click: reset scale|r"):format(db.scale * 100 + 0.5))
    if db.locked then
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(0, 0, 0, 0)
    else
        frame:SetBackdropColor(0, 0.3, 0.6, 0.35)
        frame:SetBackdropBorderColor(0.2, 0.6, 1, 0.9)
    end
    UpdateItemButtons()
end

-- Dragging works from the header always and from the whole frame when unlocked.
local function StartMove()
    if db.locked then return end
    frame.isMoving = true
    UpdateItemButtons()
    frame:StartMoving()
end
local function StopMove()
    frame:StopMovingOrSizing()
    frame.isMoving = false
    frame:SetUserPlaced(false)
    SavePosition()
    PlaceFrame()
    UpdateItemButtons()
end
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", StartMove)
frame:SetScript("OnDragStop", StopMove)
header:SetScript("OnDragStart", StartMove)
header:SetScript("OnDragStop", StopMove)

-- Mouse wheel: scales while unlocked, scrolls the list while locked.
local function OnMouseWheel(_, delta)
    if not db.locked then
        SetScaleKeepingPosition(math.min(2.5, math.max(0.5, db.scale + delta * 0.05)))
        ApplyLayout()
        return
    end
    local target = scroll:GetVerticalScroll() - delta * SCROLL_STEP
    scroll:SetVerticalScroll(math.min(MaxScroll(), math.max(0, target)))
end
frame:EnableMouseWheel(true)
frame:SetScript("OnMouseWheel", OnMouseWheel)
scroll:SetScript("OnMouseWheel", OnMouseWheel)

moveOverlay:SetScript("OnDragStart", StartMove)
moveOverlay:SetScript("OnDragStop", StopMove)
moveOverlay:SetScript("OnMouseWheel", OnMouseWheel)
moveOverlay:SetScript("OnMouseUp", function(_, button)
    if button ~= "RightButton" then return end
    SetScaleKeepingPosition(DEFAULTS.scale)
    ApplyLayout()
end)

---------------------------------------------------------------------------
-- Quest collection
---------------------------------------------------------------------------
local function IsQuestInCurrentZone(questID, headerTitle, zoneNames)
    if headerTitle and zoneNames[headerTitle] then return true end
    if C_QuestLog.IsOnMap then
        local onMap = C_QuestLog.IsOnMap(questID)
        if onMap then return true end
    end
    return false
end

-- Reused across renders to keep garbage down.
local zoneNames, questBuf, groupRank = {}, {}, {}

local function ByDistance(a, b)
    if a.bqtDistance ~= b.bqtDistance then return a.bqtDistance < b.bqtDistance end
    return a.bqtIndex < b.bqtIndex
end

local function ByGroup(a, b)
    local ra, rb = groupRank[a.bqtHeader], groupRank[b.bqtHeader]
    if ra ~= rb then return ra < rb end
    return a.bqtIndex < b.bqtIndex
end

local function SortByDistance(quests)
    if not C_QuestLog.GetDistanceSqToQuest then return end
    for i, q in ipairs(quests) do
        local distSq, onContinent = C_QuestLog.GetDistanceSqToQuest(q.questID)
        q.bqtDistance = (distSq and onContinent) and distSq or math.huge
        q.bqtIndex = i
    end
    table.sort(quests, ByDistance)
end

local function AddZoneName(z)
    if z and z ~= "" then zoneNames[z] = true end
end

---@class BQTQuestInfo: QuestInfo
---@field bqtLogIndex number
---@field bqtHeader string
---@field bqtDistance number
---@field bqtIndex number

local function CollectQuests()
    wipe(zoneNames)
    AddZoneName(GetRealZoneText())
    AddZoneName(GetZoneText())
    AddZoneName(GetSubZoneText())

    wipe(questBuf)
    local quests, currentHeader = questBuf, nil
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i) --[[@as BQTQuestInfo?]]
        if info then
            if info.isHeader then
                currentHeader = info.title
            elseif not info.isHidden and info.questID and info.questID > 0 then
                local watched = not db.respectWatch or C_QuestLog.GetQuestWatchType(info.questID) ~= nil
                if watched and (not db.zoneFilter or IsQuestInCurrentZone(info.questID, currentHeader, zoneNames)) then
                    info.bqtLogIndex = i
                    info.bqtHeader = currentHeader or "Other"
                    quests[#quests + 1] = info
                end
            end
        end
    end
    if db.sortByDistance then SortByDistance(quests) end

    -- Group by zone header; groups keep the order of their first (nearest) quest.
    wipe(groupRank)
    local rank = 0
    for i, q in ipairs(quests) do
        q.bqtIndex = i
        if not groupRank[q.bqtHeader] then
            rank = rank + 1
            groupRank[q.bqtHeader] = rank
        end
    end
    table.sort(quests, ByGroup)
    return quests
end

---------------------------------------------------------------------------
-- Quest item buttons
-- Using items needs secure buttons, which cannot be moved, shown or hidden
-- in combat. They are parented to UIParent (not anchored to our frames, so
-- the tracker stays free to change in combat) and re-aligned after combat.
---------------------------------------------------------------------------
local itemButtons = {}
local itemsDirty = false

local function GetItemButton(i)
    local b = itemButtons[i]
    if b then return b end
    b = CreateFrame("Button", "BetterQuestTrackerItem" .. i, UIParent, "SecureActionButtonTemplate")
    b:SetSize(22, 22)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(frame:GetFrameLevel() + 10)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("type", "item")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.count:SetPoint("BOTTOMRIGHT", -1, 1)
    b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cooldown:SetAllPoints()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(self.link)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    b:Hide()
    itemButtons[i] = b
    return b
end

local function UpdateItemCooldowns()
    for _, b in ipairs(itemButtons) do
        if b:IsShown() and b.logIndex then
            local start, duration, enable = GetQuestLogSpecialItemCooldown(b.logIndex)
            if start then CooldownFrame_Set(b.cooldown, start, duration, enable) end
        end
    end
end

function UpdateItemButtons()
    if InCombatLockdown() then
        itemsDirty = true
        return
    end
    itemsDirty = false
    local used = 0
    if GetQuestLogSpecialItemInfo and db and not db.collapsed and not frame.isMoving and frame:IsVisible() then
        local viewTop, viewBottom, left = scroll:GetTop(), scroll:GetBottom(), frame:GetLeft()
        for _, line in ipairs(titleLines) do
            local link, texture, charges, showWhenComplete = GetQuestLogSpecialItemInfo(line.logIndex)
            local top = line:GetTop()
            local itemID = link and link:match("item:(%d+)")
            if itemID and top and viewTop and top <= viewTop + 1 and top - 22 >= viewBottom - 1
                and (showWhenComplete or not C_QuestLog.IsComplete(line.questID)) then
                used = used + 1
                local b = GetItemButton(used)
                if b.link ~= link then
                    b.link = link
                    b:SetAttribute("item", "item:" .. itemID)
                    b.icon:SetTexture(texture)
                end
                b.logIndex = line.logIndex
                if b.charges ~= charges then
                    b.charges = charges
                    b.count:SetText((charges and charges > 1) and tostring(charges) or "")
                end
                b:SetScale(db.scale)
                b:ClearAllPoints()
                b:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", left - 4, top + 3)
                b:Show()
            end
        end
    end
    for i = used + 1, #itemButtons do itemButtons[i]:Hide() end
    UpdateItemCooldowns()
end

scroll:SetScript("OnVerticalScroll", function()
    UpdateMoreText()
    UpdateItemButtons()
end)

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
local levelColorCache, levelColorFor = {}, nil
local function LevelColor(level)
    if not level or not GetQuestDifficultyColor then return "|cffffd100" end
    local playerLevel = UnitLevel("player")
    if levelColorFor ~= playerLevel then
        wipe(levelColorCache)
        levelColorFor = playerLevel
    end
    local color = levelColorCache[level]
    if not color then
        local c = GetQuestDifficultyColor(level)
        color = ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
        levelColorCache[level] = color
    end
    return color
end

local zoneCounts = {}

function Render()
    if not db then return end
    local startTime = debugprofilestop()
    renderCount = renderCount + 1
    local quests = CollectQuests()
    wipe(shownOrder)
    wipe(shownHeader)
    wipe(titleLines)
    for i, q in ipairs(quests) do
        shownOrder[i] = q.questID
        shownHeader[i] = q.bqtHeader
    end
    title:SetText(("Quests (%d)"):format(#quests))
    levelButton.text:SetText(("%s+%d|r"):format(db.skipHighLevel and "|cffff8040" or "|cff808080", db.skipLevelDiff))
    levelButton:SetSize(levelButton.text:GetStringWidth(), levelButton.text:GetStringHeight())
    modeText:SetText(db.zoneFilter and "zone" or "all")
    collapseButton.v:SetShown(db.collapsed)

    local n, y = 0, 0
    local textWidth = db.width - 16

    local function AddLine(text, questID, indent, zone)
        if n >= MAX_LINES then return end
        n = n + 1
        local line = GetLine(n)
        local width = textWidth - indent
        line.questID = questID
        line.zone = zone
        if line.lastText ~= text or line.lastWidth ~= width then
            line.lastText, line.lastWidth = text, width
            line:SetWidth(width)
            line.text:SetWidth(width)
            line.text:SetText(text)
            line.lastHeight = math.max(14, line.text:GetStringHeight())
            line:SetHeight(line.lastHeight)
        end
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", content, "TOPLEFT", 8 + indent, y)
        line:Show()
        y = y - line.lastHeight - 2
    end

    if not db.collapsed then
        local trackedID = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID()
        wipe(zoneCounts)
        for _, q in ipairs(quests) do
            zoneCounts[q.bqtHeader] = (zoneCounts[q.bqtHeader] or 0) + 1
        end
        local lastHeader
        for _, q in ipairs(quests) do
            local zoneCollapsed = db.collapsedZones[q.bqtHeader]
            if q.bqtHeader ~= lastHeader then
                lastHeader = q.bqtHeader
                if n > 0 then y = y - 4 end
                if zoneCollapsed then
                    AddLine(("|cffb0b0ff+ %s (%d)|r"):format(lastHeader, zoneCounts[lastHeader]), nil, 0, lastHeader)
                else
                    AddLine("|cffb0b0ff" .. lastHeader .. "|r", nil, 0, lastHeader)
                end
            end
            if not zoneCollapsed then
            local questCollapsed = char.collapsedQuests[q.questID]
            local complete = C_QuestLog.IsComplete(q.questID)
            local color = complete and "|cff20ff20" or "|cffffd100"
            if q.questID == trackedID then color = "|cff66ccff" end
            local titleIndex = n + 1
            local collapsedMark = questCollapsed and " |cff808080+|r" or ""
            AddLine(("%s[%d]|r %s%s|r%s"):format(LevelColor(q.level), q.level or 0, color, q.title or "?", collapsedMark), q.questID, 0)
            if n == titleIndex then
                lines[n].logIndex = q.bqtLogIndex
                titleLines[#titleLines + 1] = lines[n]
            end
            if complete and not questCollapsed then
                AddLine("|cff20ff20- Ready to turn in|r", q.questID, 10)
            elseif not questCollapsed then
                for _, obj in ipairs(C_QuestLog.GetQuestObjectives(q.questID) or {}) do
                    if obj.text and obj.text ~= "" then
                        local c = obj.finished and "|cff20ff20" or "|cffffffff"
                        AddLine(c .. "- " .. obj.text .. "|r", q.questID, 10)
                    end
                end
            end
            y = y - 4
            end
        end
        if #quests == 0 then
            AddLine("|cff808080No quests for this zone|r", nil, 0)
        end
    end
    for i = n + 1, #lines do lines[i]:Hide() end

    local contentHeight = math.max(1, -y)
    local scrollable = contentHeight > db.maxHeight
    local visible = db.collapsed and 0 or math.min(contentHeight, db.maxHeight)
    content:SetHeight(contentHeight)
    scroll:SetHeight(math.max(1, visible))
    scroll:SetShown(not db.collapsed)
    scroll:EnableMouseWheel(scrollable or not db.locked)
    scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), MaxScroll()))

    local height = HEADER_HEIGHT + visible + (scrollable and FOOTER_HEIGHT or 4)
    frame:SetHeight(height)
    frame:SetClampRectInsets(0, 0, 0, height - HEADER_HEIGHT)
    if scrollable then UpdateMoreText() else moreText:Hide() end
    if frame.avoidOffset ~= 0 or (DurabilityFrame and DurabilityFrame:IsVisible()) then PlaceFrame() end
    UpdateItemButtons()

    lastRender = debugprofilestop() - startTime
    if lastRender > slowestRender then
        slowestRender, slowestReason = lastRender, renderReason
    end
    renderReason = "direct"
end

local durabilityHooked = false
local function HookDurabilityFrame()
    if durabilityHooked or not DurabilityFrame then return end
    durabilityHooked = true
    local function OnDurabilityChanged()
        PlaceFrame()
        UpdateItemButtons()
    end
    DurabilityFrame:HookScript("OnShow", OnDurabilityChanged)
    DurabilityFrame:HookScript("OnHide", OnDurabilityChanged)
    hooksecurefunc(DurabilityFrame, "SetPoint", OnDurabilityChanged)
    -- Visibility can also change without OnShow/OnHide firing on the frame itself
    -- (parent container, Edit Mode), so re-check on those signals too, next frame.
    local function RecheckSoon() C_Timer.After(0, OnDurabilityChanged) end
    frame:RegisterEvent("UPDATE_INVENTORY_ALERTS")
    frame.recheckDurability = RecheckSoon
    if EventRegistry then
        EventRegistry:RegisterCallback("EditMode.Enter", RecheckSoon, frame)
        EventRegistry:RegisterCallback("EditMode.Exit", RecheckSoon, frame)
    end
end

local function PrintLayout()
    local df = DurabilityFrame
    Print(("tracker scale %.3f rect %s"):format(frame:GetEffectiveScale(),
        strjoin(" ", tostringall(frame:GetRect()))))
    if df then
        Print(("durability visible %s scale %.3f rect %s"):format(tostring(df:IsVisible()),
            df:GetEffectiveScale(), strjoin(" ", tostringall(df:GetRect()))))
    else
        Print("durability frame not found")
    end
    Print(("avoid offset %.1f (locked %s)"):format(AvoidOffset(), tostring(db.locked)))
end

-- Throttle: quest log events fire in bursts.
local pending = false
local function DoPendingRender()
    pending = false
    Render()
end
local function RequestRender(reason)
    if pending then return end
    pending = true
    renderReason = reason or "settings"
    C_Timer.After(0.25, DoPendingRender)
end

-- Zone events also fire for indoor/outdoor transitions where the names don't
-- change; the zone filter only depends on these names, so skip those redraws.
local lastZoneKey
local function ZoneNamesChanged()
    local key = (GetRealZoneText() or "") .. "|" .. (GetZoneText() or "") .. "|" .. (GetSubZoneText() or "")
    if key == lastZoneKey then return false end
    lastZoneKey = key
    return true
end

local function ShownOrderIsStale()
    local previous, previousGroupFirst, lastHeader = -1, -1, nil
    for i, questID in ipairs(shownOrder) do
        local h = shownHeader[i]
        if not db.collapsedZones[h] then
            local distSq, onContinent = C_QuestLog.GetDistanceSqToQuest(questID)
            local d = (distSq and onContinent) and distSq or math.huge
            if h ~= lastHeader then
                if d < previousGroupFirst then return true end
                previousGroupFirst = d
                lastHeader = h
            elseif d < previous then
                return true
            end
            previous = d
        end
    end
    return false
end

local function OnSortTick()
    if not db.sortByDistance or db.collapsed or not frame:IsVisible() then return end
    if not C_QuestLog.GetDistanceSqToQuest then return end
    if ShownOrderIsStale() then RequestRender("distance sort") end
end

local function PrintPerf()
    UpdateAddOnMemoryUsage()
    Print(("memory %.1f KB, %d lines pooled, %d redraws this session"):format(
        GetAddOnMemoryUsage(ADDON), #lines, renderCount))
    Print(("redraw: last %.2f ms, slowest %.2f ms (%s)"):format(lastRender, slowestRender, slowestReason))
    if C_AddOnProfiler and C_AddOnProfiler.IsEnabled and C_AddOnProfiler.IsEnabled()
        and Enum.AddOnProfilerMetric then
        local metric = Enum.AddOnProfilerMetric
        Print(("cpu recent avg %.3f ms/frame, peak %.3f ms"):format(
            C_AddOnProfiler.GetAddOnMetric(ADDON, metric.RecentAverageTime),
            C_AddOnProfiler.GetAddOnMetric(ADDON, metric.PeakTime)))
    elseif GetCVarBool("scriptProfile") then
        UpdateAddOnCPUUsage()
        Print(("cpu %.1f ms total this session"):format(GetAddOnCPUUsage(ADDON)))
    else
        Print("cpu: no profiler; /console scriptProfile 1 then /reload (turn off afterwards)")
    end
end

local function Refresh()
    ApplyLayout()
    RequestRender()
end

lockButton:SetScript("OnClick", function(self)
    db.locked = not db.locked
    Refresh()
    self:GetScript("OnEnter")(self)
end)
lockButton:SetScript("OnEnter", function(self)
    UpdateLockLabel(true)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(db.locked and "Locked" or "Unlocked")
    GameTooltip:AddLine(db.locked and "Click to unlock: move and scale the tracker" or "Click to lock", 1, 1, 1)
    GameTooltip:Show()
end)
lockButton:SetScript("OnLeave", function()
    UpdateLockLabel(false)
    GameTooltip_Hide()
end)

header:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("BetterQuestTracker")
    GameTooltip:AddLine("Quest left-click: track / untrack", 1, 1, 1)
    GameTooltip:AddLine("Quest right-click: open in quest log", 1, 1, 1)
    GameTooltip:AddLine("/bqt: open settings", 1, 1, 1)
    GameTooltip:Show()
end)
header:SetScript("OnLeave", GameTooltip_Hide)

---------------------------------------------------------------------------
-- Blizzard tracker
---------------------------------------------------------------------------
-- Hiding the tracker with Hide() is blocked in combat (it holds secure item
-- buttons), and Blizzard re-shows it e.g. when the quest log opens. Parenting it
-- to a hidden frame keeps it invisible even when it shows itself in combat.
local blizzardHider = CreateFrame("Frame")
blizzardHider:Hide()
local blizzardHooked = false
local function UpdateBlizzardTracker()
    local tracker = ObjectiveTrackerFrame or QuestWatchFrame
    if not tracker or InCombatLockdown() then return end
    if not blizzardHooked then
        blizzardHooked = true
        hooksecurefunc(tracker, "SetParent", function(self, parent)
            if parent ~= blizzardHider and not InCombatLockdown() then
                self:SetParent(blizzardHider)
            end
        end)
    end
    if tracker:GetParent() ~= blizzardHider then
        tracker:SetParent(blizzardHider)
    end
end

---------------------------------------------------------------------------
-- Settings panel (Options > AddOns)
---------------------------------------------------------------------------
local function UntrackIfTooHigh(questID)
    local logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
    local info = logIndex and C_QuestLog.GetInfo(logIndex)
    if not info or not info.level then return end
    if info.level - UnitLevel("player") < db.skipLevelDiff then return end
    if C_QuestLog.GetQuestWatchType(questID) == nil then return end
    C_QuestLog.RemoveQuestWatch(questID)
    char.autoUntracked[questID] = true
    Notify(("not tracking [%d] %s (%d+ levels above you)"):format(info.level, info.title or "?", db.skipLevelDiff))
end

local function RetrackAllowed(newLevel)
    local playerLevel = newLevel or UnitLevel("player")
    for questID in pairs(char.autoUntracked) do
        local logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
        local info = logIndex and C_QuestLog.GetInfo(logIndex)
        if not info then
            char.autoUntracked[questID] = nil
        elseif not db.skipHighLevel or (info.level or 0) - playerLevel < db.skipLevelDiff then
            char.autoUntracked[questID] = nil
            C_QuestLog.AddQuestWatch(questID)
            Notify(("tracking [%d] %s again"):format(info.level or 0, info.title or "?"))
        end
    end
end

local function UntrackHighLevelInLog()
    if not db.skipHighLevel then return end
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID and info.questID > 0 then
            UntrackIfTooHigh(info.questID)
        end
    end
end

levelButton:SetScript("OnClick", function(self)
    db.skipHighLevel = not db.skipHighLevel
    RetrackAllowed()
    UntrackHighLevelInLog()
    Render()
    self:GetScript("OnEnter")(self)
end)
levelButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("High-level quests")
    local minLevel = UnitLevel("player") + db.skipLevelDiff
    if db.skipHighLevel then
        GameTooltip:AddLine(("Not tracking quests +%d levels above you (level %d and up)"):format(db.skipLevelDiff, minLevel), 1, 0.5, 0.25, true)
    else
        GameTooltip:AddLine(("Off: tracking all quests (threshold +%d, level %d and up)"):format(db.skipLevelDiff, minLevel), 0.7, 0.7, 0.7, true)
    end
    GameTooltip:AddLine("Click: toggle", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Change threshold in /bqt settings", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end)
levelButton:SetScript("OnLeave", GameTooltip_Hide)

-- Show/hide the "move" label as the mouse enters or leaves the header area,
-- including when it leaves via one of the header's own buttons.
-- Must run after every SetScript on these frames, which would drop the hooks.
local function OnHeaderHoverChanged()
    if db then UpdateLockLabel(lockButton:IsVisible() and lockButton:IsMouseOver()) end
end
for _, f in ipairs({ header, levelButton, modeButton, collapseButton }) do
    f:HookScript("OnEnter", OnHeaderHoverChanged)
    f:HookScript("OnLeave", OnHeaderHoverChanged)
end

local function RegisterSettings()
    local category = Settings.RegisterVerticalLayoutCategory("BetterQuestTracker")

    local function Proxy(key, varType, name, setter)
        return Settings.RegisterProxySetting(category, "BQT_" .. key, varType, name, DEFAULTS[key],
            function() return db[key] end, setter)
    end

    local function Checkbox(key, name, tooltip, onChange)
        local setting = Proxy(key, Settings.VarType.Boolean, name, function(value)
            db[key] = value
            onChange()
        end)
        Settings.CreateCheckbox(category, setting, tooltip)
    end

    local function Slider(key, name, tooltip, min, max, step, setter, format)
        local setting = Proxy(key, Settings.VarType.Number, name, function(value)
            setter(value)
            Refresh()
        end)
        local options = Settings.CreateSliderOptions(min, max, step)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
            return format:format(value)
        end)
        Settings.CreateSlider(category, setting, options, tooltip)
    end

    Checkbox("locked", "Lock position", "Unlock to drag the tracker and scale it with the mouse wheel.", Refresh)
    Checkbox("zoneFilter", "Only quests in current zone", "Hide quests that are not in your current zone.", RequestRender)
    Checkbox("respectWatch", "Only quests checked in quest log", "Quests you uncheck in the quest log are hidden from the tracker.", RequestRender)
    Checkbox("skipHighLevel", "Don't track high-level quests", "Quests this many levels above you are unchecked in the quest log, on accept and when this option changes.", function()
        RetrackAllowed()
        UntrackHighLevelInLog()
        RequestRender()
    end)
    Slider("skipLevelDiff", "High-level threshold", "Levels above your own that count as high-level.", 1, 10, 1,
        function(value)
            db.skipLevelDiff = value
            RetrackAllowed()
            UntrackHighLevelInLog()
        end, "+%d")
    Checkbox("quiet", "Mute chat messages", "Don't print automatic messages, like quests being (un)tracked.", function() end)
    Checkbox("sortByDistance", "Sort by distance", "Show the nearest quest first.", RequestRender)
    Slider("scale", "Scale", "Size of the tracker.", 0.5, 2.5, 0.05,
        SetScaleKeepingPosition, "%.2f")
    Slider("width", "Width", "Width of the tracker in pixels.", 150, 600, 10,
        function(value) db.width = value end, "%d")
    Slider("maxHeight", "Maximum height", "Taller lists scroll with the mouse wheel.", 150, 1200, 10,
        function(value) db.maxHeight = value end, "%d")

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

local function OpenSettings()
    if settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    else
        Print("settings panel unavailable on this client, use /bqt help")
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_BETTERQUESTTRACKER1 = "/bqt"
SlashCmdList.BETTERQUESTTRACKER = function(msg)
    local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "" or cmd == "config" then
        OpenSettings()
        return
    elseif cmd == "move" or cmd == "unlock" or cmd == "lock" then
        if cmd == "move" then db.locked = not db.locked else db.locked = (cmd == "lock") end
        Print(db.locked and "locked" or "unlocked: drag to move, mouse wheel to scale")
    elseif cmd == "scale" then
        local s = tonumber(arg)
        if s and s >= 0.5 and s <= 2.5 then
            SetScaleKeepingPosition(s)
        else
            Print("usage: /bqt scale 0.5-2.5 (current " .. db.scale .. ")")
            return
        end
    elseif cmd == "width" then
        local w = tonumber(arg)
        if w and w >= 150 and w <= 600 then db.width = w else Print("usage: /bqt width 150-600") return end
    elseif cmd == "height" then
        local h = tonumber(arg)
        if h and h >= 150 and h <= 1200 then db.maxHeight = h else Print("usage: /bqt height 150-1200") return end
    elseif cmd == "zone" then
        db.zoneFilter = not db.zoneFilter
        Print("zone filter " .. (db.zoneFilter and "on" or "off"))
    elseif cmd == "quiet" then
        db.quiet = not db.quiet
        Print("chat messages " .. (db.quiet and "muted" or "on"))
    elseif cmd == "watch" then
        db.respectWatch = not db.respectWatch
        Print("follow quest log checkboxes " .. (db.respectWatch and "on" or "off"))
    elseif cmd == "sort" then
        db.sortByDistance = not db.sortByDistance
        Print("sort by distance " .. (db.sortByDistance and "on" or "off"))
    elseif cmd == "perf" then
        PrintPerf()
        return
    elseif cmd == "layout" then
        PrintLayout()
        return
    elseif cmd == "reset" then
        db.point = CopyTable(DEFAULTS.point)
        db.scale = DEFAULTS.scale
        db.width = DEFAULTS.width
        db.maxHeight = DEFAULTS.maxHeight
        Print("position, scale, width and height reset")
    else
        Print("commands:")
        print("  /bqt - open settings")
        print("  /bqt move - toggle move mode (drag + mouse wheel scale)")
        print("  /bqt scale <0.5-2.5>")
        print("  /bqt width <150-600>")
        print("  /bqt height <150-1200> - max height before scrolling")
        print("  /bqt zone - toggle zone filter")
        print("  /bqt sort - toggle sort by distance")
        print("  /bqt watch - toggle following quest log checkboxes")
        print("  /bqt quiet - mute automatic chat messages")
        print("  /bqt reset - reset position, scale, width, height")
        print("  /bqt perf - show memory and cpu usage")
        print("  /bqt layout - show tracker and durability positions")
        return
    end
    Refresh()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        BetterQuestTrackerDB = BetterQuestTrackerDB or {}
        db = BetterQuestTrackerDB
        db.hideBlizzard = nil
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = type(v) == "table" and CopyTable(v) or v end
        end
        BetterQuestTrackerCharDB = BetterQuestTrackerCharDB or {}
        char = BetterQuestTrackerCharDB
        -- One-time move of lists that used to be saved account-wide.
        for k in pairs(CHAR_DEFAULTS) do
            if char[k] == nil and db[k] then char[k] = db[k] end
            db[k] = nil
            if char[k] == nil then char[k] = {} end
        end
        frame:UnregisterEvent("ADDON_LOADED")
        for _, e in ipairs({
            "PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED",
            "QUEST_ACCEPTED", "QUEST_REMOVED",
            "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS",
            "PLAYER_REGEN_ENABLED", "SUPER_TRACKING_CHANGED", "BAG_UPDATE_COOLDOWN",
            "PLAYER_LEVEL_UP",
        }) do
            pcall(frame.RegisterEvent, frame, e) -- skip events this client lacks
        end
        local ok, err = pcall(RegisterSettings)
        if not ok then Print("could not create settings panel: " .. tostring(err)) end
        -- Distance changes as you walk; only redraw when the nearest-first order breaks.
        C_Timer.NewTicker(2, OnSortTick)
        ApplyLayout()
        frame:Show()
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then ApplyLayout() end
    if event == "PLAYER_REGEN_ENABLED" then
        UpdateBlizzardTracker()
        if itemsDirty then UpdateItemButtons() end
        return
    end
    if event == "BAG_UPDATE_COOLDOWN" then
        UpdateItemCooldowns()
        return
    end
    if event == "UPDATE_INVENTORY_ALERTS" then
        if frame.recheckDurability then frame.recheckDurability() end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        UpdateBlizzardTracker()
        HookDurabilityFrame()
    end
    if event == "PLAYER_LEVEL_UP" then
        -- UnitLevel can still report the old level here; use the event's new level.
        RetrackAllowed(arg1)
    end
    if event == "QUEST_REMOVED" and arg1 then
        char.collapsedQuests[arg1] = nil
        char.autoUntracked[arg1] = nil
    end
    if event == "QUEST_WATCH_LIST_CHANGED" and arg1 and arg2 then
        char.autoUntracked[arg1] = nil
    end
    if (event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED_NEW_AREA")
        and not ZoneNamesChanged() then
        return
    end
    if event == "QUEST_ACCEPTED" and db.skipHighLevel then
        -- Older clients pass (logIndex, questID), Retail passes (questID).
        -- Blizzard auto-watches after this event, so untrack slightly later.
        local questID = arg2 or arg1
        C_Timer.After(0.5, function() UntrackIfTooHigh(questID) end)
    end
    RequestRender(event)
end)
