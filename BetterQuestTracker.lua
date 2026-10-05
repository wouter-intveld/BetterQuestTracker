local ADDON = ...

local DEFAULTS = {
    point = { "TOPRIGHT", "UIParent", "TOPRIGHT", -80, -220 },
    scale = 1.0,
    width = 260,
    maxHeight = 500,
    locked = true,
    zoneFilter = true,     -- only show quests for the current zone
    sortByDistance = true, -- nearest quest first
    completedLast = false, -- finished quests at the bottom of their zone
    respectWatch = true,   -- hide quests unchecked in the quest log
    skipHighLevel = false, -- don't auto-track newly accepted high-level quests
    showHighLevel = false, -- still list the quests skipHighLevel untracked (the +3 header toggle)
    skipLevelDiff = 3,
    quiet = false,         -- mute automatic chat messages
    showRecipes = true,    -- list recipes tracked in the profession window
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
local slowestRender, slowestReason, lastRender = 0, "none", 0
local titleLines = {}
local UpdateItemButtons, Render, Refresh -- defined below, called from frame scripts set up above them
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

-- Blizzard's localized UI strings, with English fallbacks if a name is missing on this client.
local function L(name, fallback)
    local s = _G[name]
    return type(s) == "string" and s or fallback
end
local TEXT = {
    quests = L("QUESTS_LABEL", "Quests"),
    ready = L("QUEST_WATCH_QUEST_READY", "Ready to turn in"),
    setWaypoint = L("SUPER_TRACK_QUEST", "Set waypoint"),
    removeWaypoint = L("STOP_SUPER_TRACK_QUEST", "Remove waypoint"),
    openQuestLog = L("OBJECTIVES_SHOW_QUEST_MAP", "Open in quest log"),
    stopTracking = L("OBJECTIVES_STOP_TRACKING", "Remove from tracker"),
    share = L("SHARE_QUEST", "Share with party"),
    abandon = L("ABANDON_QUEST_ABBREV", "Abandon quest"),
    recipes = L("PROFESSIONS_TRACKER_HEADER_PROFESSION", "Professions"),
    openRecipe = L("PROFESSIONS_TRACKING_VIEW_RECIPE", "Open recipe"),
}

---------------------------------------------------------------------------
-- Main frame
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "BetterQuestTrackerFrame", UIParent, "BackdropTemplate")
frame:SetSize(DEFAULTS.width, 60)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:SetDontSavePosition(true)
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

local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("BOTTOMLEFT")
title:SetJustifyH("LEFT")

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

local moreText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
moreText:SetPoint("BOTTOMRIGHT", -8, 3)
moreText:SetText("scroll for more")

---------------------------------------------------------------------------
-- Header controls
-- Small atlas icons in their own colours, dimmed until hovered. Right to left
-- in the header: zone filter, +N (high-level quests), lock. The collapse
-- toggle sits just outside the tracker, on its top-right corner.
---------------------------------------------------------------------------
local ICON_SIZE, ICON_GAP, ICON_DIM = 14, 6, 0.6

local function IconButton(parent, atlas)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(ICON_SIZE, ICON_SIZE)
    b.icon = b:CreateTexture(nil, "OVERLAY")
    b.icon:SetAllPoints()
    b.icon:SetAlpha(ICON_DIM)
    if atlas then b.icon:SetAtlas(atlas) end
    return b
end

local collapseButton = IconButton(frame) -- atlas follows db.collapsed, see UpdateHeader
collapseButton:SetPoint("BOTTOMLEFT", frame, "TOPRIGHT")

local modeButton = IconButton(header, "Map-Filter-Button")
modeButton:SetPoint("BOTTOMRIGHT", 0, -1)

local levelButton = IconButton(header, "UI-HUD-UnitFrame-Target-HighLevelTarget_Icon")
levelButton:SetPoint("BOTTOMRIGHT", modeButton, "BOTTOMLEFT", -ICON_GAP, 0)

-- Parented to the frame, not the header, so it stays clickable and undimmed
-- above the move overlay.
local lockButton = IconButton(frame, "communities-icon-lock")
lockButton:SetPoint("BOTTOMRIGHT", levelButton, "BOTTOMLEFT", -ICON_GAP, 0)
lockButton:SetFrameLevel(moveOverlay:GetFrameLevel() + 10)

-- The lock and the +N stay out of sight until the header is hovered: the lock
-- also shows while unlocked, the +N also while it is showing the high-level
-- quests, and only with that option on at all. Alpha rather than Hide keeps the
-- +N's slot, so the lock never shifts. Runs as the mouse enters or leaves the
-- header or any control, because moving onto a control leaves the header.
local function UpdateHeaderHover()
    local hover = header:IsMouseOver()
    lockButton:SetShown(hover or not db.locked)
    lockButton.icon:SetAlpha((not db.locked or lockButton:IsMouseOver()) and 1 or ICON_DIM)
    levelButton:SetAlpha(db.skipHighLevel and (db.showHighLevel or hover) and 1 or 0)
end

-- A control's click toggles a setting and redraws; its tooltip describes the
-- state, so it is rebuilt after the click.
local function SetupControl(button, onClick, tooltip)
    local function OnEnter(self)
        self.icon:SetAlpha(1)
        UpdateHeaderHover()
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        tooltip()
        GameTooltip:Show()
    end
    button:SetScript("OnEnter", OnEnter)
    button:SetScript("OnLeave", function(self)
        self.icon:SetAlpha(ICON_DIM)
        UpdateHeaderHover()
        GameTooltip_Hide()
    end)
    button:SetScript("OnClick", function(self)
        onClick()
        OnEnter(self)
    end)
end

SetupControl(collapseButton, function()
    db.collapsed = not db.collapsed
    Render()
end, function()
    GameTooltip:AddLine(db.collapsed and "Expand" or "Collapse")
end)

SetupControl(modeButton, function()
    db.zoneFilter = not db.zoneFilter
    Render()
end, function()
    GameTooltip:AddLine("Zone filter")
    GameTooltip:AddLine(db.zoneFilter and "Showing quests in your current zone" or "Showing all quests", 1, 1, 1)
    GameTooltip:AddLine("Click: toggle", 0.5, 0.5, 0.5)
end)

SetupControl(levelButton, function()
    db.showHighLevel = not db.showHighLevel
    Render()
end, function()
    GameTooltip:AddLine("High-level quests")
    local minLevel = UnitLevel("player") + db.skipLevelDiff
    GameTooltip:AddLine(("Not tracking quests +%d levels above you (level %d and up)"):format(db.skipLevelDiff, minLevel),
        1, 0.5, 0.25, true)
    if db.showHighLevel then
        GameTooltip:AddLine("Showing them in the tracker anyway", 0.7, 0.7, 0.7, true)
    else
        GameTooltip:AddLine("Hidden from the tracker", 1, 1, 1, true)
    end
    GameTooltip:AddLine("Click: show / hide them", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Turn off or change the threshold in /bqt settings", 0.5, 0.5, 0.5)
end)

SetupControl(lockButton, function()
    db.locked = not db.locked
    Refresh()
end, function()
    GameTooltip:AddLine(db.locked and "Locked" or "Unlocked")
    GameTooltip:AddLine(db.locked and "Click to unlock: move and scale the tracker" or "Click to lock", 1, 1, 1)
end)

header:SetScript("OnEnter", function(self)
    UpdateHeaderHover()
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("BetterQuestTracker")
    GameTooltip:AddLine("Quest left-click: set / remove waypoint", 1, 1, 1)
    GameTooltip:AddLine("Quest right-click: quest options", 1, 1, 1)
    GameTooltip:AddLine("/bqt: open settings", 1, 1, 1)
    GameTooltip:Show()
end)
header:SetScript("OnLeave", function()
    UpdateHeaderHover()
    GameTooltip_Hide()
end)

-- Header state that follows the settings: the quest count and which icons are
-- desaturated, hidden or lit.
local function UpdateHeader(questCount)
    title:SetText(("%s (%d)"):format(TEXT.quests, questCount))
    collapseButton.icon:SetAtlas(db.collapsed and "UI-QuestTrackerButton-Expand-All"
        or "UI-QuestTrackerButton-Collapse-All")
    modeButton.icon:SetDesaturated(not db.zoneFilter)
    levelButton.icon:SetDesaturated(db.showHighLevel)
    -- The +N only works while the option is on; its slot stays either way.
    levelButton:EnableMouse(db.skipHighLevel)
    UpdateHeaderHover()
end

local function MaxScroll()
    return math.max(0, content:GetHeight() - scroll:GetHeight())
end

local function UpdateMoreText()
    moreText:SetShown(scroll:GetVerticalScroll() < MaxScroll() - 1)
end

-- The ready-check texture stands in if this client lacks the tracker's check atlas.
local CHECK_ICON = C_Texture.GetAtlasInfo("ui-questtracker-tracker-check")
    and "|A:ui-questtracker-tracker-check:14:14|a"
    or "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t"

local function AddPartyProgress(questID)
    if GetNumSubgroupMembers() == 0 then return end
    local data = C_TooltipInfo.GetQuestPartyProgress(questID, true, true)
    if not data or not data.lines or #data.lines == 0 then return end
    GameTooltip:AddLine(" ")
    for _, l in ipairs(data.lines) do
        if l.leftText and l.leftText ~= "" then
            local r, g, b = 1, 1, 1
            if l.leftColor then r, g, b = l.leftColor:GetRGB() end
            -- Blizzard greys out a member's finished objectives and leaves open ones
            -- white; match our own objective lines. Other colours (names) stay.
            if r == g and g == b and r < 0.9 then
                GameTooltip:AddLine(CHECK_ICON .. " " .. l.leftText, 0.13, 1, 0.13)
            elseif r == 1 and g == 1 and b == 1 then
                GameTooltip:AddLine("- " .. l.leftText, 1, 1, 1)
            else
                GameTooltip:AddLine(l.leftText, r, g, b)
            end
        end
    end
end

local function ToggleWaypoint(questID)
    local tracked = C_SuperTrack.GetSuperTrackedQuestID() == questID
    C_SuperTrack.SetSuperTrackedQuestID(tracked and 0 or questID)
end

local function ShareQuest(questID)
    C_QuestLog.SetSelectedQuest(questID)
    QuestLogPushQuest()
end

local function ShowQuestMenu(owner, questID)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(C_QuestLog.GetTitleForQuestID(questID) or "?")
        local tracked = C_SuperTrack.GetSuperTrackedQuestID() == questID
        root:CreateButton(tracked and TEXT.removeWaypoint or TEXT.setWaypoint, function() ToggleWaypoint(questID) end)
        root:CreateButton(TEXT.openQuestLog, function() QuestMapFrame_OpenToQuestDetails(questID) end)
        local share = root:CreateButton(TEXT.share, function() ShareQuest(questID) end)
        share:SetEnabled(IsInGroup() and C_QuestLog.IsPushableQuest(questID))
        root:CreateButton(TEXT.stopTracking, function() C_QuestLog.RemoveQuestWatch(questID) end)
        root:CreateDivider()
        -- Blizzard's own quest log flow: localized popup, warns about quest items.
        root:CreateButton("|cffff4040" .. TEXT.abandon .. "|r", function() QuestMapQuestOptions_AbandonQuest(questID) end)
    end)
end

local function ShowRecipeMenu(owner, recipeID, name)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(name)
        root:CreateButton(TEXT.openRecipe, function() C_TradeSkillUI.OpenRecipe(recipeID) end)
        root:CreateButton(TEXT.stopTracking, function() C_TradeSkillUI.SetRecipeTracked(recipeID, false, false) end)
    end)
end

local function ShowRecipeTooltip(line)
    GameTooltip:SetOwner(line, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOPRIGHT", line, "TOPLEFT", -34, 0)
    GameTooltip:AddLine(line.recipeName)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: open recipe", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Shift-click: remove from tracker", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Right-click: recipe options", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function OnRecipeClick(line, button)
    if button == "RightButton" then
        GameTooltip:Hide()
        ShowRecipeMenu(line, line.recipeID, line.recipeName)
    elseif IsShiftKeyDown() then
        C_TradeSkillUI.SetRecipeTracked(line.recipeID, false, false)
    else
        C_TradeSkillUI.OpenRecipe(line.recipeID)
    end
end

local lines = {}
local BULLET_WIDTH = 8

local function GetLine(i)
    local line = lines[i]
    if line then return line end
    line = CreateFrame("Button", nil, content)
    line:SetHeight(14)
    line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.text:SetPoint("BOTTOMRIGHT")
    -- "- " sits in its own column so wrapped objective text lines up under the text.
    line.bullet = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line.bullet:SetPoint("TOPLEFT")
    line.text:SetJustifyH("LEFT")
    line.text:SetWordWrap(true)
    line:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    line:SetScript("OnEnter", function(self)
        if self.recipeID then
            ShowRecipeTooltip(self)
            return
        end
        local questID = self.questID
        if not questID then return end
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        GameTooltip:SetPoint("TOPRIGHT", self, "TOPLEFT", -34, 0)
        GameTooltip:AddLine(C_QuestLog.GetTitleForQuestID(questID) or "?")
        local logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
        if logIndex then
            local _, objectiveText = GetQuestLogQuestText(logIndex)
            if objectiveText and objectiveText ~= "" then
                GameTooltip:AddLine(objectiveText, 1, 1, 1, true)
            end
        end
        GameTooltip:AddLine(" ")
        if C_QuestLog.IsComplete(questID) then
            GameTooltip:AddLine(TEXT.ready, 0.13, 1, 0.13)
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
        GameTooltip:AddLine("Left-click: set / remove waypoint", 0.5, 0.5, 0.5)
        GameTooltip:AddLine("Shift-click: remove from tracker (or link in chat)", 0.5, 0.5, 0.5)
        GameTooltip:AddLine("Ctrl-click: open in quest log", 0.5, 0.5, 0.5)
        GameTooltip:AddLine("Right-click: quest options", 0.5, 0.5, 0.5)
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
        if self.recipeID then
            OnRecipeClick(self, button)
            return
        end
        if not self.questID then return end
        if button == "RightButton" then
            GameTooltip:Hide()
            ShowQuestMenu(self, self.questID)
        elseif IsShiftKeyDown() then
            -- Like Blizzard's tracker: while typing in chat, shift-click links the quest.
            local link = GetQuestLink(self.questID)
            if link and ChatEdit_GetActiveWindow() then
                ChatEdit_InsertLink(link)
            else
                C_QuestLog.RemoveQuestWatch(self.questID)
            end
        elseif IsControlKeyDown() then
            QuestMapFrame_OpenToQuestDetails(self.questID)
        else
            ToggleWaypoint(self.questID)
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
    if not db.locked or not df:IsVisible() then return 0 end
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
    moveOverlay:SetShown(not db.locked)
    UpdateHeaderHover()
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

-- Moving and scaling go through the move overlay, which covers the tracker
-- while it is unlocked; only the lock button sits above it.
local function StartMove()
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
-- Mouse wheel: scales while unlocked (through the overlay), scrolls the list
-- while locked. Render enables the frame's wheel only when the list is taller
-- than maxHeight, so over a short tracker the wheel still reaches the camera.
local function OnMouseWheel(_, delta)
    if not db.locked then
        SetScaleKeepingPosition(math.min(2.5, math.max(0.5, db.scale + delta * 0.05)))
        ApplyLayout()
        return
    end
    local target = scroll:GetVerticalScroll() - delta * SCROLL_STEP
    scroll:SetVerticalScroll(math.min(MaxScroll(), math.max(0, target)))
end
frame:SetScript("OnMouseWheel", OnMouseWheel)

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
-- Reused across renders to keep garbage down.
local zoneNames, questBuf, groupRank = {}, {}, {}

local function ByDistance(a, b)
    if a.bqtDistance ~= b.bqtDistance then return a.bqtDistance < b.bqtDistance end
    return a.bqtIndex < b.bqtIndex
end

local function ByGroup(a, b)
    local ra, rb = groupRank[a.bqtHeader], groupRank[b.bqtHeader]
    if ra ~= rb then return ra < rb end
    if a.bqtDone ~= b.bqtDone then return b.bqtDone end
    return a.bqtIndex < b.bqtIndex
end

local function SortByDistance(quests)
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
---@field bqtDone boolean

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
                    or (db.skipHighLevel and db.showHighLevel and char.autoUntracked[info.questID])
                local inZone = not db.zoneFilter or zoneNames[currentHeader] or C_QuestLog.IsOnMap(info.questID)
                if watched and inZone then
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
        q.bqtDone = db.completedLast and C_QuestLog.IsComplete(q.questID) or false
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
        GameTooltip:SetQuestLogSpecialItem(self.logIndex) -- the quest log's own item tooltip
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    b:Hide()
    itemButtons[i] = b
    return b
end

-- Range has no event, so poll it like Blizzard's item buttons do, but only
-- while an item button is visible and you have a target (without a target
-- there is no range to check), 4 times per second.
local rangeTicker
local itemButtonsShown = 0

local function SetOutOfRange(b, out)
    if b.outOfRange == out then return end
    b.outOfRange = out
    if out then
        b.icon:SetVertexColor(1, 0.3, 0.3)
    else
        b.icon:SetVertexColor(1, 1, 1)
    end
end

local function UpdateItemRanges()
    for _, b in ipairs(itemButtons) do
        if b:IsShown() and b.logIndex then
            -- 0 = out of range, 1 = in range, nil = no range check for this item.
            SetOutOfRange(b, IsQuestLogSpecialItemInRange(b.logIndex) == 0)
        end
    end
end

local function UpdateRangeTicker()
    local wanted = itemButtonsShown > 0 and UnitExists("target")
    if wanted and not rangeTicker then
        rangeTicker = C_Timer.NewTicker(0.25, UpdateItemRanges)
    elseif not wanted and rangeTicker then
        rangeTicker:Cancel()
        rangeTicker = nil
        for _, b in ipairs(itemButtons) do SetOutOfRange(b, false) end
    end
    if wanted then UpdateItemRanges() end
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
    if not db.collapsed and not frame.isMoving and frame:IsVisible() then
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
                if b.lastScale ~= db.scale then
                    b.lastScale = db.scale
                    b:SetScale(db.scale)
                end
                if b.lastLeft ~= left or b.lastTop ~= top then
                    b.lastLeft, b.lastTop = left, top
                    b:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", left - 4, top + 3)
                end
                b:Show()
            end
        end
    end
    for i = used + 1, #itemButtons do itemButtons[i]:Hide() end
    UpdateItemCooldowns()
    itemButtonsShown = used
    UpdateRangeTicker()
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
    if not level then return "|cffffd100" end
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
local recipesTracked = 0 -- recipes shown in the last redraw; bag changes only matter then

function Render(reason)
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
    UpdateHeader(#quests)

    local n, y = 0, 0
    local textWidth = db.width - 16

    local function AddLine(text, questID, indent, zone, recipeID, recipeName)
        if n >= MAX_LINES then return end
        n = n + 1
        local line = GetLine(n)
        local width = textWidth - indent
        line.questID = questID
        line.zone = zone
        line.recipeID, line.recipeName = recipeID, recipeName
        if line.lastText ~= text or line.lastWidth ~= width then
            line.lastText, line.lastWidth = text, width
            local color, rest = text:match("^(|c%x%x%x%x%x%x%x%x)%- (.*)$")
            local inset = color and BULLET_WIDTH or 0
            line.bullet:SetText(color and color .. "-|r" or "")
            line.text:SetPoint("TOPLEFT", inset, 0)
            line:SetWidth(width)
            line.text:SetWidth(width - inset)
            line.text:SetText(color and color .. rest or text)
            line.lastHeight = math.max(14, line.text:GetStringHeight())
            line:SetHeight(line.lastHeight)
        end
        -- A line only ever has this one anchor, so SetPoint replaces it; skip it when nothing moved.
        local x = 8 + indent
        if line.lastX ~= x or line.lastY ~= y then
            line.lastX, line.lastY = x, y
            line:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
        end
        line:Show()
        y = y - line.lastHeight - 2
    end

    if not db.collapsed then
        local trackedID = C_SuperTrack.GetSuperTrackedQuestID()
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
                    AddLine("|cff20ff20- " .. TEXT.ready .. "|r", q.questID, 10)
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

    -- Recipes tracked in the profession window, with reagents in bags / needed.
    local recipes = db.showRecipes and C_TradeSkillUI.GetRecipesTracked(false) or {}
    recipesTracked = #recipes
    if not db.collapsed and #recipes > 0 then
        local key = TEXT.recipes
        if n > 0 then y = y - 4 end
        if db.collapsedZones[key] then
            AddLine(("|cffb0b0ff+ %s (%d)|r"):format(key, #recipes), nil, 0, key)
        else
            AddLine("|cffb0b0ff" .. key .. "|r", nil, 0, key)
            for _, recipeID in ipairs(recipes) do
                local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
                local name = schematic.name or "?"
                AddLine("|cffffd100" .. name .. "|r", nil, 0, nil, recipeID, name)
                for _, slot in ipairs(schematic.reagentSlotSchematics) do
                    local reagent = slot.reagents[1]
                    if slot.reagentType == Enum.CraftingReagentType.Basic and reagent and reagent.itemID then
                        local have = C_Item.GetItemCount(reagent.itemID)
                        local c = have >= slot.quantityRequired and "|cff20ff20" or "|cffffffff"
                        local itemName = C_Item.GetItemNameByID(reagent.itemID) or "..."
                        AddLine(("%s- %s %d/%d|r"):format(c, itemName, have, slot.quantityRequired),
                            nil, 10, nil, recipeID, name)
                    end
                end
                y = y - 4
            end
        end
    end
    for i = n + 1, #lines do lines[i]:Hide() end

    local contentHeight = math.max(1, -y)
    local scrollable = contentHeight > db.maxHeight
    local visible = db.collapsed and 0 or math.min(contentHeight, db.maxHeight)
    content:SetHeight(contentHeight)
    scroll:SetHeight(math.max(1, visible))
    scroll:SetShown(not db.collapsed)
    frame:EnableMouseWheel(scrollable)
    scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), MaxScroll()))

    local height = HEADER_HEIGHT + visible + (scrollable and FOOTER_HEIGHT or 4)
    frame:SetHeight(height)
    frame:SetClampRectInsets(0, 0, 0, height - HEADER_HEIGHT)
    if scrollable then UpdateMoreText() else moreText:Hide() end
    if AvoidOffset() ~= frame.avoidOffset then PlaceFrame() end
    UpdateItemButtons()

    lastRender = debugprofilestop() - startTime
    if lastRender > slowestRender then
        slowestRender, slowestReason = lastRender, reason or "direct"
    end
end

-- Re-placing the frame moves every child, so only do it when the offset changed.
local function OnDurabilityChanged()
    if AvoidOffset() == frame.avoidOffset then return end
    PlaceFrame()
    UpdateItemButtons()
end

-- Visibility can also change without OnShow/OnHide firing on the frame itself
-- (parent container, Edit Mode), so re-check on those signals too, next frame.
local function RecheckDurabilitySoon() C_Timer.After(0, OnDurabilityChanged) end

local durabilityHooked = false
local function HookDurabilityFrame()
    if durabilityHooked then return end
    durabilityHooked = true
    DurabilityFrame:HookScript("OnShow", OnDurabilityChanged)
    DurabilityFrame:HookScript("OnHide", OnDurabilityChanged)
    hooksecurefunc(DurabilityFrame, "SetPoint", OnDurabilityChanged)
    EventRegistry:RegisterCallback("EditMode.Enter", RecheckDurabilitySoon, frame)
    EventRegistry:RegisterCallback("EditMode.Exit", RecheckDurabilitySoon, frame)
end

local function PrintLayout()
    local df = DurabilityFrame
    Print(("tracker scale %.3f rect %s"):format(frame:GetEffectiveScale(),
        strjoin(" ", tostringall(frame:GetRect()))))
    Print(("durability visible %s scale %.3f rect %s"):format(tostring(df:IsVisible()),
        df:GetEffectiveScale(), strjoin(" ", tostringall(df:GetRect()))))
    Print(("avoid offset %.1f (locked %s)"):format(AvoidOffset(), tostring(db.locked)))
end

-- Throttle: quest log events fire in bursts. Holds the reason of the queued redraw, nil when none.
local pendingReason
local function DoPendingRender()
    local reason = pendingReason
    pendingReason = nil
    Render(reason)
end
local function RequestRender(reason)
    if pendingReason then return end
    pendingReason = reason or "settings"
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
    -- Zones are ordered by their nearest quest; within a zone quests run nearest
    -- first, and with completedLast the finished ones start a second run.
    local previous, previousGroupMin, groupMin, lastHeader, lastDone = -1, -1, nil, nil, false
    for i, questID in ipairs(shownOrder) do
        local h = shownHeader[i]
        if not db.collapsedZones[h] then
            local distSq, onContinent = C_QuestLog.GetDistanceSqToQuest(questID)
            local d = (distSq and onContinent) and distSq or math.huge
            local done = db.completedLast and C_QuestLog.IsComplete(questID)
            if h ~= lastHeader then
                if groupMin then
                    if groupMin < previousGroupMin then return true end
                    previousGroupMin = groupMin
                end
                groupMin, lastHeader, lastDone, previous = d, h, false, -1
            else
                if done ~= lastDone then previous = -1 end
                if d < groupMin then groupMin = d end
            end
            if d < previous then return true end
            previous, lastDone = d, done
        end
    end
    return groupMin ~= nil and groupMin < previousGroupMin
end

local function OnSortTick()
    if not db.sortByDistance or db.collapsed or not frame:IsVisible() then return end
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

function Refresh()
    ApplyLayout()
    RequestRender()
end

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
    if InCombatLockdown() then return end
    local tracker = ObjectiveTrackerFrame
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
-- High-level quests
-- With skipHighLevel on, quests skipLevelDiff or more levels above the player
-- are unchecked in the quest log and remembered in char.autoUntracked, so they
-- can be checked again on level-up or when the option goes off.
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

---------------------------------------------------------------------------
-- Settings panel (Options > AddOns)
---------------------------------------------------------------------------
local function RegisterSettings()
    local category = Settings.RegisterVerticalLayoutCategory("|cff33ff99Better|rQuestTracker")

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
    Checkbox("completedLast", "Finished quests last", "Move quests that are ready to turn in to the bottom of their zone.", RequestRender)
    Checkbox("showRecipes", "Show tracked recipes", "List recipes tracked in the profession window below your quests, with the reagents you carry.", RequestRender)
    Slider("scale", "Scale", "Size of the tracker.", 0.5, 2.5, 0.05,
        SetScaleKeepingPosition, "%.2f")
    Slider("width", "Width", "Width of the tracker in pixels.", 150, 600, 10,
        function(value) db.width = value end, "%d")
    Slider("maxHeight", "Maximum height", "Taller lists scroll with the mouse wheel.", 150, 1200, 10,
        function(value) db.maxHeight = value end, "%d")

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_BETTERQUESTTRACKER1 = "/bqt"
SlashCmdList.BETTERQUESTTRACKER = function(msg)
    local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "" or cmd == "config" then
        Settings.OpenToCategory(settingsCategory:GetID())
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
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = type(v) == "table" and CopyTable(v) or v end
        end
        BetterQuestTrackerCharDB = BetterQuestTrackerCharDB or {}
        char = BetterQuestTrackerCharDB
        for k, v in pairs(CHAR_DEFAULTS) do
            if char[k] == nil then char[k] = CopyTable(v) end
        end
        frame:UnregisterEvent("ADDON_LOADED")
        for _, e in ipairs({
            "PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED",
            "QUEST_ACCEPTED", "QUEST_REMOVED",
            "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS",
            "PLAYER_REGEN_ENABLED", "SUPER_TRACKING_CHANGED", "BAG_UPDATE_COOLDOWN",
            "PLAYER_LEVEL_UP", "PLAYER_TARGET_CHANGED", "UPDATE_INVENTORY_ALERTS",
            "TRACKED_RECIPE_UPDATE", "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED",
        }) do
            frame:RegisterEvent(e)
        end
        RegisterSettings()
        -- Distance changes as you walk; only redraw when the nearest-first order breaks.
        C_Timer.NewTicker(2, OnSortTick)
        ApplyLayout()
        frame:Show()
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        UpdateBlizzardTracker()
        if itemsDirty then UpdateItemButtons() end
        return
    end
    if event == "BAG_UPDATE_COOLDOWN" then
        UpdateItemCooldowns()
        return
    end
    if event == "PLAYER_TARGET_CHANGED" then
        UpdateRangeTicker()
        return
    end
    if event == "UPDATE_INVENTORY_ALERTS" then
        RecheckDurabilitySoon()
        return
    end
    -- Reagent counts and names only matter while recipes are on screen.
    if (event == "BAG_UPDATE_DELAYED" or event == "GET_ITEM_INFO_RECEIVED") and recipesTracked == 0 then
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        ApplyLayout()
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
