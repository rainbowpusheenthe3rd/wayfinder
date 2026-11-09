-- Wayfinder: a see-through 3D arrow that walks a run of waypoints.
--
-- Runs come from Route.lua (written by `wowmarket wayfinder` from runs/*.json), so a new run needs only a /reload.
-- Progress and fixes are saved per run and per step id, so they survive edits. Talking to a trainer near a step
-- saves where they really stand, and closing their window moves on to the next step.
--
-- Direction comes from world positions (C_Map.GetWorldPosFromMapPos) for the player and the waypoint, so it
-- works across zones on one continent. World x grows north and y grows west; GetPlayerFacing is 0 facing north,
-- growing counter-clockwise, so the bearing relative to where you face is (bearing to target) - (facing), also
-- counter-clockwise. The arrow is a 3D arrow on the ground pre-rendered at FRAMES angles in that same sense
-- (tools/wayfinder_textures.py); the frame nearest the bearing is shown. Each step also sets Blizzard's own map
-- pin, which draws the in-world marker. On another continent there is no direction; the text says where to go.

local ADDON, ns = ...

local ARROW = "Interface\\AddOns\\Wayfinder\\arrow"
local EDGE = "Interface\\AddOns\\Wayfinder\\edge"   -- the 1px rim just outside the arrow, per frame
-- Night elves get a wisp instead (tools/wisp_textures.py: same frames and camera as the arrow): a glowing head
-- leading the way with a comet tail behind, blended as light, breathing, with motes circling it. /wf wisp toggles.
local WISP = "Interface\\AddOns\\Wayfinder\\wisp"
local MOTE = "Interface\\AddOns\\Wayfinder\\mote"
local WISP_ALPHA, MOTES = 0.85, 4
local ALPHA, HOVER_ALPHA = 0.5, 1.0                 -- see the world through it; solid while the mouse is on it
local SIZE = 84
local FRAMES, COLS = 64, 8                         -- the sprite sheets: COLS x COLS frames
local ARRIVE_YARDS = 6
local TRAINER_YARDS = 150                          -- a trainer this close to a step is that step's trainer
local GATHER_YARDS, GATHER_AHEAD = 30, 12          -- gather runs: a spot this close is done; look this far ahead
local TICK = 0.05

local db
local frame, arrow, shadow, title, learn, info, nextButton, runButton, catchButton, who
local motes = {}
local pinned, trainerStep, lastSpot
local Announce, CatchLine  -- defined below, used by Update
local seen = {}  -- run id -> how many of its item you had last tick, to announce each one you gather

-- the game's own peon voice lines (FileDataIDs; Sound/Creature/Peon). "Work, work" and "Work complete" are
-- confirmed by two addons (Skillet, Questie), the rest by one (a WoW streaming theme's credits).
local PEON = {
    chop = { 558147, 558140, 558139, 558136, 558138 },  -- Work work, Okie dokie, Be happy to, I can do that, I'll try
    done = { 558132 }, ready = { 558137 },             -- Work complete; Ready to work
    what = { 558143, 558135 },                         -- What you want? Something need doing?
    pissed = { 558146 },                               -- Me not that kind of orc!
}
-- Warcraft III's peasant (Sound/Creature/Peasant, from wowdev's listfile): yes, yes-attack, ready, what, pissed
local PEASANT = {
    chop = { 558119, 558124, 558125, 558123, 558117, 558126 }, done = { 558118 }, ready = { 558118 },
    what = { 558128, 558127, 558120 }, pissed = { 558122 },
}
-- Every race has its worker: orcs the peon, humans the peasant, the rest their own NPCs' voice (Voices.lua):
-- greetings for "what" and "ready", farewells for "chop" and "done", and the lines for being clicked too often.
-- db.voice overrides it: "peon", "peasant" or nil (your race). The grievance goes to the race's leader.
local WORKER = {
    Orc = { "Peon", "the Warchief", "Zug zug." }, Troll = { "Peon", "the Warchief", "Zug zug." },
    Tauren = { "Peon", "the Warchief", "Zug zug." }, Scourge = { "Peon", "the Warchief", "Zug zug." },
    BloodElf = { "Peon", "the Warchief", "Zug zug." },
    Human = { "Peasant", "the King", "Job's done." }, Dwarf = { "Peasant", "King Magni", "Aye." },
    Gnome = { "Peasant", "High Tinker Mekkatorque", "Have you tried turning it off and on again?" },
    NightElf = { "Wisp", "High Priestess Tyrande", "Elune be with you." },
    Draenei = { "Worker", "Prophet Velen", "The Light guides you." },
}
local function Race() return select(2, UnitRace("player")) or "Orc" end
local function Lines()
    local race = Race()
    local v = db.voice or (race == "Orc" and "peon") or (race == "Human" and "peasant") or nil
    if v == "peon" then return PEON end
    if v == "peasant" then return PEASANT end
    local npc = ns.VOICES and ns.VOICES[race .. (UnitSex("player") or 2)]
    if not npc then return PEON end
    return { chop = npc.go, done = npc.go, ready = npc.what, what = npc.what, pissed = npc.pissed }
end
local function Voice(role)
    local ids = Lines()[role]
    if db.sound ~= false and PlaySoundFile and ids and #ids > 0 then PlaySoundFile(ids[math.random(#ids)], "Master") end
end
local function Worker()
    return unpack(WORKER[Race()] or WORKER.Orc)
end

-- Lae'zel narrates the lumberjacking: empty trees (rarely, never more than one a minute) and milestones
local function Laezel(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffd4a017Lae'zel|r: " .. msg)
end
local EMPTY = {
    "An empty tree. You flew all this way for bark, istik.",
    "The tree is gone. It heard you coming.",
    "You stare at a tree. The tree stares back. Neither of you impresses me.",
    "Even the forest rejects you. Good. Rejection builds character.",
    "Nothing. I have killed for less.",
    "Someone was here first. Find them. Make an example of them.",
}
local MILESTONE = {
    { 0.25, "A quarter. A githyanki hatchling chops faster. With its teeth." },
    { 0.5, "Half. Do not expect praise. Praise is for the finished." },
    { 0.75, "Three quarters. Tsk'va. ...Forget I said that." },
}
-- the worker's grievances, kept across sessions, and how their leader handles them (%1$s worker, %2$s leader, %3$s reply)
local GRIEVANCE = {
    "%1$s has filed a grievance with %2$s.",
    "Grievance escalated. The office of %2$s has acknowledged receipt.",
    "%2$s has reviewed the grievance and responded: \"%3$s\" Case closed.",
}
local trip = {}  -- run id -> this session's spots, empty spots and lumber, for the report card
local quipAt, spotHave = -60, {}
local pokes, pokeAt = 0, -10

-- clicking the arrow pokes the peon, and he has limits
local function Poke()
    local now = GetTime()
    if now - pokeAt > 4 then pokes = 0 end
    pokes, pokeAt = pokes + 1, now
    if pokes >= 6 then
        Voice("pissed")
        db.grievances = (db.grievances or 0) + 1
        local g = db.grievances
        local who, boss, reply = Worker()
        local msg = GRIEVANCE[g] and GRIEVANCE[g]:gsub("%%1%$s", who):gsub("%%2%$s", boss):gsub("%%3%$s", reply)
            or ("%s has filed grievance #%d. %s has stopped opening the mail."):format(who, g, boss:gsub("^%l", string.upper))
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffWayfinder|r: " .. msg:gsub("^%l", string.upper))
        pokes = 0
    elseif pokes >= 3 then
        Voice("chop")
    else
        Voice("what")
    end
end

-- how many of a gather run's item you have: bags, bank, reagent bag and Warband bank
local function Have(run)
    if run.item and C_Item and C_Item.GetItemCount then
        return C_Item.GetItemCount(run.item, true, false, true, true)
    end
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffWayfinder|r: " .. msg)
end

-- Runs ------------------------------------------------------------------------------------------------------

local function Runs()
    local out = {}
    if db.catchup and #db.catchup.steps > 0 then out[1] = db.catchup end
    local me = UnitName("player")
    for _, r in ipairs(ns.RUNS or {}) do
        if not r.char or r.char == me then out[#out + 1] = r end  -- another character's run isn't offered here
    end
    if #db.custom.steps > 0 then out[#out + 1] = db.custom end
    return out
end

local function ActiveRun()
    local runs = Runs()
    for _, r in ipairs(runs) do
        if r.id == db.active then return r end
    end
    db.active = runs[1] and runs[1].id
    return runs[1]
end

-- the run's steps for this character's faction, with saved fixes applied
local function Steps(run)
    local faction = UnitFactionGroup("player")
    local fixes = db.fixes[run.id] or {}
    local out = {}
    for _, s in ipairs(run.steps) do
        if not s.faction or s.faction == faction then
            local f = fixes[s.id]
            out[#out + 1] = f and setmetatable({ map = f.map, x = f.x, y = f.y }, { __index = s }) or s
        end
    end
    return out
end

-- current step, its number, the count; nil step when the run is done
local function Current()
    local run = ActiveRun()
    if not run then return end
    local steps = Steps(run)
    local at = db.at[run.id]
    if at == "done" then return nil, #steps + 1, #steps, run end
    for n, s in ipairs(steps) do
        if s.id == at then return s, n, #steps, run end
    end
    return steps[1], 1, #steps, run
end

local function SetAt(run, step) db.at[run.id] = step and step.id or "done" end

-- Position --------------------------------------------------------------------------------------------------

local function World(mapID, x, y)
    local cont, pos = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
    if cont and pos then return cont, pos.x, pos.y end
end

local function PlayerWorld()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    local p = C_Map.GetPlayerMapPosition(mapID, "player")
    if not p then return end
    local px, py = p:GetXY()
    return World(mapID, px, py)
end

-- yards from you to a step on your continent, with the north and west differences; nil elsewhere
local function Yards(step)
    if not step.x then return end
    local tc, tx, ty = World(step.map, step.x / 100, step.y / 100)
    local pc, px, py = PlayerWorld()
    if tc and pc and tc == pc then
        local dN, dW = tx - px, ty - py
        return math.sqrt(dN * dN + dW * dW), dN, dW
    end
end

local function MapName(mapID)
    local info = C_Map.GetMapInfo(mapID)
    return info and info.name or ("map " .. mapID)
end

-- Blizzard's map pin on the step, so the game draws its own marker in the world
local function Pin(step)
    local key = step and step.x and ("%d:%.2f:%.2f"):format(step.map, step.x, step.y)
    if key == pinned then return end
    pinned = key
    if not key or not (C_Map.SetUserWaypoint and UiMapPoint) then return end
    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(step.map) then return end
    C_SuperTrack.SetSuperTrackedUserWaypoint(false)
    C_Map.ClearUserWaypoint()
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(step.map, step.x / 100, step.y / 100))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
end

local function CharKey() return UnitName("player") .. "-" .. GetRealmName() end

-- "Wayfinder · Zulcalice", the name in your class colour, and "(any character)" for a run nobody owns
local function WhoTag(run)
    local class = select(2, UnitClass("player"))
    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    local name = UnitName("player")
    local tag = ("|cffd4a017Wayfinder|r · %s"):format(cc and cc.colorStr and ("|c%s%s|r"):format(cc.colorStr, name) or name)
    if run and not run.char and run.id ~= "catch-up" and run.id ~= "my-waypoints" then
        tag = tag .. " |cff999999(any character)|r"
    end
    return tag
end

-- Save the names in this character's minimap tracking menu, to read from the saved variables. Guessing a "Lumber"
-- entry there wrongly flagged a character who can chop (players report the Harvesting Hatchet item toggles lumber
-- display instead), so this is a record only, not a check.
local function RecordTracking()
    if not (C_Minimap and C_Minimap.GetNumTrackingTypes) then return end
    local names = {}
    for i = 1, C_Minimap.GetNumTrackingTypes() or 0 do
        local t = C_Minimap.GetTrackingInfo(i)
        if t and t.name then names[#names + 1] = t.name end
    end
    db.chars[CharKey()] = { tracking = names, at = time() }
end

-- Display ---------------------------------------------------------------------------------------------------

-- show the arrow frame nearest a counter-clockwise bearing (0 = straight ahead), or hide it
local function Point(bearing)
    if bearing then
        local i = math.floor((bearing % (2 * math.pi)) / (2 * math.pi) * FRAMES + 0.5) % FRAMES
        local l, t = (i % COLS) / COLS, math.floor(i / COLS) / COLS
        arrow:SetTexCoord(l, l + 1 / COLS, t, t + 1 / COLS)
        shadow:SetTexCoord(l, l + 1 / COLS, t, t + 1 / COLS)
        arrow:Show(); shadow:Show()
    else
        arrow:Hide(); shadow:Hide()
    end
end

-- the wisp is the default for night elves; WayfinderDB.wisp (set by /wf wisp) overrides it either way
local function Wisp()
    if db and db.wisp ~= nil then return db.wisp end
    return select(2, UnitRace("player")) == "NightElf"
end

-- the arrow or the wisp, as chosen; called once the frame exists and whenever /wf wisp switches
local function ApplyLook()
    if not arrow then return end
    local class = select(2, UnitClass("player"))
    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if Wisp() then
        arrow:SetTexture(WISP); arrow:SetBlendMode("ADD"); arrow:SetVertexColor(1, 1, 1, 1)
        shadow:SetTexture(WISP); shadow:SetBlendMode("BLEND"); shadow:SetVertexColor(0, 0, 0, 0.35)
        shadow:SetSize(SIZE * 1.1, SIZE * 1.1)
    else
        arrow:SetTexture(ARROW); arrow:SetBlendMode("BLEND")
        if cc then arrow:SetVertexColor(cc.r, cc.g, cc.b, 1) else arrow:SetVertexColor(1, 0.82, 0.2, 1) end
        shadow:SetTexture(EDGE); shadow:SetBlendMode("BLEND"); shadow:SetVertexColor(0, 0, 0, 1)
        shadow:SetSize(SIZE, SIZE)
        arrow:SetSize(SIZE, SIZE)
        for _, m in ipairs(motes) do m:Hide() end
    end
end

-- the wisp breathes (alpha and size on slow sines) and its motes circle it on a tilted ellipse, as if on the
-- ground around it, each brightening and dimming on its own phase
local function Animate()
    if not (Wisp() and arrow and arrow:IsShown()) then
        for _, m in ipairs(motes) do m:Hide() end
        return
    end
    local t = GetTime()
    arrow:SetAlpha(0.8 + 0.2 * math.sin(t * 2.2))
    local grow = 1 + 0.035 * math.sin(t * 1.7)
    arrow:SetSize(SIZE * grow, SIZE * grow)
    for i, m in ipairs(motes) do
        local a = t * (0.7 + 0.15 * i) + i * math.pi / 2
        local r = 26 + 5 * math.sin(t * 1.3 + i)
        m:ClearAllPoints()
        m:SetPoint("CENTER", arrow, "CENTER", math.cos(a) * r, math.sin(a) * r * 0.45 + 4)
        m:SetAlpha(0.35 + 0.45 * (0.5 + 0.5 * math.sin(t * 2.6 + i * 1.7)))
        m:Show()
    end
end

local function Update()
    frame:SetAlpha(frame:IsMouseOver() and HOVER_ALPHA or (Wisp() and WISP_ALPHA or ALPHA))
    local step, n, total, run = Current()
    if not run then
        Point(); title:SetText("No runs loaded"); learn:SetText(""); info:SetText("")
        return
    end
    runButton:SetText(("%s  %d/%d"):format(run.name, math.min(n, total), total))
    who:SetText(WhoTag(run))
    Pin(step)
    if not step then
        Point(); title:SetText("|cff33ff33Run complete|r"); learn:SetText("")
        info:SetText("Next starts it again"); nextButton:SetText("Restart")
        return
    end
    title:SetText(step.title)
    if run.mode == "gather" then
        -- a gather run: spawn points to sweep. Passing near this spot or any of the next few moves you on past
        -- it, and the end loops back to the start.
        local steps = Steps(run)
        for k = math.min(#steps, n + GATHER_AHEAD), n, -1 do
            local y = steps[k].id ~= lastSpot and Yards(steps[k])
            if y and y <= GATHER_YARDS then
                lastSpot = steps[k].id  -- still standing there next tick mustn't count it again
                SetAt(run, steps[k % #steps + 1])
                -- no lumber since the last spot: it was empty. Now and then, the peon says so.
                local have = Have(run)
                local t = trip[run.id] or { spots = 0, empty = 0 }
                trip[run.id] = t
                t.spots = t.spots + 1
                if have and have == spotHave[run.id] then
                    t.empty = t.empty + 1
                    if GetTime() - quipAt > 60 and math.random() < 0.25 then
                        quipAt = GetTime()
                        Laezel(EMPTY[math.random(#EMPTY)])
                    end
                end
                spotHave[run.id] = have
                return
            end
        end
        local have = Have(run)
        if have and run.need then
            local wood = run.name:gsub("^Lumber: ", "")
            local count = have >= run.need and ("|cff33ff33%s %d/%d, done!|r"):format(wood, have, run.need)
                or ("|cffffd100%s %d/%d|r"):format(wood, have, run.need)
            learn:SetText(("%s   spot %d/%d"):format(count, n, total))
            if seen[run.id] and have > seen[run.id] then
                Print(("+%d %s: %d/%d"):format(have - seen[run.id], wood, have, run.need))
                for _, m in ipairs(MILESTONE) do
                    if seen[run.id] < run.need * m[1] and have >= run.need * m[1] then Laezel(m[2]) end
                end
                if have >= run.need and seen[run.id] < run.need then
                    Voice("done")
                    -- the report card, then a haiku
                    local t = trip[run.id]
                    if t and t.spots > 0 then
                        local trees = t.spots - t.empty
                        Print(("Run report: %d spots visited. %d had a tree. %d were just trees. Efficiency %d%%.")
                            :format(t.spots, trees, t.empty, math.floor(100 * trees / t.spots + 0.5)))
                    end
                    Laezel("It is done. The forest will remember you. Not fondly.")
                    Print("The last log is cut. / The forest did not consent. / Work complete. Zug zug.")
                else
                    Voice("chop")
                end
            elseif seen[run.id] == nil then
                Voice("ready")  -- first look at this run since login or switching to it
            end
            seen[run.id] = have
        else
            learn:SetText(("Spot %d/%d%s"):format(n, total, run.need and (", need " .. run.need) or ""))
        end
        nextButton:SetText("Skip")
        local yards, dN, dW = Yards(step)
        if yards then
            Point(math.atan2(dW, dN) - (GetPlayerFacing() or 0)); info:SetText(("%d yd"):format(yards))
        else
            Point(); info:SetText(("Travel to %s"):format(MapName(step.map)))
        end
        return
    end
    learn:SetText(step.learn and ("|cff33ff33Learn:|r " .. step.learn) or (step.note or ""))
    nextButton:SetText("Next")
    if run.id == "catch-up" and db.parked then
        Point(); title:SetText("|cffffd100Parked for the queue|r"); info:SetText("It picks up here when you're back")
        return
    end
    if not step.x then
        Point(); info:SetText(step.hint or ("Go to %s, then drop a map pin at the trainer"):format(MapName(step.map)))
        return
    end
    local yards, dN, dW = Yards(step)
    if not yards then
        Point(); info:SetText(PlayerWorld() and ("Travel to %s"):format(MapName(step.map)) or "No position here")
    elseif yards <= ARRIVE_YARDS then
        Point(); info:SetText("|cff33ff33Arrived|r")
        nextButton:SetText("|cff33ff33Done|r")
    else
        Point(math.atan2(dW, dN) - (GetPlayerFacing() or 0))
        info:SetText(("%d yd"):format(yards))
    end
end

function Announce()
    local step, n, total, run = Current()
    if not run then return end
    if step and run.mode == "gather" then
        local how = run.item and "Chop the trees with the yellow axe" or "Pick and mine what's there"
        Print(("%s: %d spots, from spot %d. %s; the arrow moves on as you pass.")
            :format(run.name, total, n, how))
    elseif step then
        Print(("%s %d/%d: %s%s%s"):format(run.name, n, total, step.title,
            step.learn and (" - learn " .. step.learn) or "", step.note and (". " .. step.note) or ""))
    else
        Print(run.name .. " complete")
    end
end

-- Actions ---------------------------------------------------------------------------------------------------

local function Next()
    local step, n, _, run = Current()
    if not run then return end
    local steps = Steps(run)
    if step then SetAt(run, steps[n + 1]) else SetAt(run, steps[1]) end
    -- a finished catch-up hands you back to the run it interrupted
    if run.id == "catch-up" and step and not steps[n + 1] and db.returnTo and db.returnTo ~= "catch-up" then
        db.active, db.returnTo = db.returnTo, nil
        local back = ActiveRun()
        Print(("Catch-up done. Back to %s."):format(back and back.name or "your run"))
    end
    Announce()
end

local function Prev()
    local _, n, _, run = Current()
    if not run then return end
    local steps = Steps(run)
    SetAt(run, steps[math.max(1, n - 1)])
    Announce()
end

local function CycleRun()
    local runs = Runs()
    for i, r in ipairs(runs) do
        if r.id == db.active then
            db.active = runs[i % #runs + 1].id
            break
        end
    end
    Announce()
end

-- the run name opens a list of runs to pick from (the game's own menu), each with how far along it is, and a way
-- to start the current one over; without the menu, it steps to the next run
local function PickRun(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return CycleRun() end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Pick a run")
        for _, r in ipairs(Runs()) do
            local steps = Steps(r)
            local at, n = db.at[r.id], 1
            for i, s in ipairs(steps) do if s.id == at then n = i end end
            local label = r.name .. (at == "done" and "  |cff33ff33done|r" or ("  (%d/%d)"):format(n, #steps))
            root:CreateRadio(label, function() return r.id == db.active end, function()
                db.active = r.id
                Announce()
            end)
        end
        local run = ActiveRun()
        if run then
            root:CreateDivider()
            root:CreateButton(("Start %s over"):format(run.name), function()
                db.at[run.id] = nil
                Print(run.name .. " starts over")
                Announce()
            end)
        end
    end)
end

local function Fix(step, run, mapID, x, y)
    db.fixes[run.id] = db.fixes[run.id] or {}
    db.fixes[run.id][step.id] = { map = mapID, x = x, y = y }
end

-- the current step moves to where you're standing, on the step's own map
local function Here(quiet)
    local step, _, _, run = Current()
    if not step then return end
    local p = C_Map.GetPlayerMapPosition(step.map, "player")
    if not p then
        if not quiet then Print("you're not on " .. MapName(step.map)) end
        return
    end
    local x, y = p:GetXY()
    Fix(step, run, step.map, x * 100, y * 100)
    if not quiet then Print(("%s set to %.1f, %.1f"):format(step.title, x * 100, y * 100)) end
end

-- a trainer's window opened: if it's near the step (or the step had no spot yet and you're on its map), this is
-- the step's trainer. Save where they really are; closing the window moves on.
local function TrainerShown()
    local step = Current()
    trainerStep = nil
    if not step then return end
    local yards = Yards(step)
    if (yards and yards <= TRAINER_YARDS) or (not step.x and C_Map.GetPlayerMapPosition(step.map, "player")) then
        Here(true)
        trainerStep = step.id
        if step.learn then Print("learn " .. step.learn .. ", then close the window") end
    end
end

local function TrainerClosed()
    local step = Current()
    if step and trainerStep == step.id then
        Voice("done")
        Next()
    end
    trainerStep = nil
end

-- a map pin you drop (ctrl-click on the world map) fills in a step that has no coordinates
local function AdoptPin()
    local step, _, _, run = Current()
    local pin = C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
    if step and pin and not step.x then
        local x, y = pin.position:GetXY()
        Fix(step, run, pin.uiMapID, x * 100, y * 100)
        Print(("%s set from your map pin"):format(step.title))
    end
end

-- Catch-up --------------------------------------------------------------------------------------------------
-- Gold work piles up while you play: sold auctions, concentration, cooldowns, crafts to make and stock to post.
-- The catch-up line sums it (minutes and gold), and clicking it builds a run from where you stand: mailbox,
-- auction house, crafting, auction house, each step done when you close that window. It speaks up in chat only
-- when something is about to go to waste: concentration nearly full, or a cooldown ready.

local CONC_PER_HOUR = 10   -- about 240 a day (WowCarry's Midnight guide), so an empty pool fills in about 4 days
local CONC_URGENT = 0.9    -- this full, it's about to be wasted
local RUN_YARDS = 7        -- yards a second on foot, for the time estimate
local AH_CUT = 0.95
local SEED = {  -- places known before you've opened them (Dornogal); the rest are learned as you use them
    ah = { { map = 2339, x = 55.8, y = 48.7 } },
    craft = { { map = 2339, x = 49.6, y = 71.0 } },
}
local NAMES = { mail = "Mailbox", ah = "Auction House", craft = "Crafting" }
local LEARN_ON = { MAIL_SHOW = "mail", AUCTION_HOUSE_SHOW = "ah", TRADE_SKILL_SHOW = "craft" }
local DONE_ON = { mail = "MAIL_CLOSED", ah = "AUCTION_HOUSE_CLOSED", craft = "TRADE_SKILL_CLOSE" }
local queue  -- the queue you're in, from Queues below

local function LedgerKey()
    return UnitName("player") .. "-" .. (GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName())
end

local function Gold(copper)
    local g = (copper or 0) / 10000
    return g >= 1000 and ("%.0fk"):format(g / 1000) or ("%dg"):format(g)
end

local function Clock(seconds)
    if not seconds then return "?" end
    seconds = math.max(0, math.floor(seconds + 0.5))
    if seconds >= 3600 then return ("%dh%02d"):format(seconds / 3600, (seconds % 3600) / 60) end
    return ("%d:%02d"):format(seconds / 60, seconds % 60)
end

-- remember where you opened a mailbox, the auction house or your profession: one spot per 30 yards
local function LearnPlace(kind)
    if IsInInstance() then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    local p = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if not p then return end
    local x, y = p:GetXY()
    local spot = { map = mapID, x = x * 100, y = y * 100, t = time() }
    local list = db.places[kind] or {}
    db.places[kind] = list
    for i, q in ipairs(list) do
        local yards = q.map == mapID and Yards(q)
        if yards and yards < 30 then list[i] = spot; return end
    end
    list[#list + 1] = spot
end

-- the nearest known place of a kind on your continent, else the one used last
local function Nearest(kind)
    local best, bestYards, latest
    for _, list in ipairs({ db.places[kind] or {}, SEED[kind] or {} }) do
        for _, q in ipairs(list) do
            local y = Yards(q)
            if y and (not bestYards or y < bestYards) then best, bestYards = q, y end
            if not latest or (q.t or 0) > (latest.t or 0) then latest = q end
        end
    end
    return best or latest, bestYards
end

local function Between(a, b)
    local ac, ax, ay = World(a.map, a.x / 100, a.y / 100)
    local bc, bx, by = World(b.map, b.x / 100, b.y / 100)
    if ac and bc and ac == bc then return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end
end

-- What's piled up: the steps to clear it, gold, concentration, and what's about to go to waste
local function Pot()
    local L, key, now = ProfessionLedgerDB or {}, LedgerKey(), time()
    local pot = { gold = 0, conc = {}, ready = {}, urgent = {}, steps = {} }
    local auctions = L.auctions and L.auctions[key]
    local mail = L.mail and L.mail[key]
    local sold, active = 0, 0
    for _, a in ipairs(auctions and auctions.list or {}) do
        if a.status == 1 then sold = sold + (a.buyout or 0) * AH_CUT elseif a.status == 0 then active = active + 1 end
    end
    -- gold in the mail: what the mailbox last showed if that's newer than the auctions, else what's sold since
    local mailGold = (mail and mail.t >= (auctions and auctions.t or 0)) and mail.money or sold
    local mailWaiting = (HasNewMail and HasNewMail()) or mailGold > 0 or (mail and (mail.ah or 0) > 0)
    for _, c in pairs(L.concentration and L.concentration[key] or {}) do
        local q = math.min(c.max, c.q + (now - c.t) / 3600 * CONC_PER_HOUR)
        local e = { name = c.name or "Concentration", pct = q / c.max, full = now + (c.max - q) / CONC_PER_HOUR * 3600 }
        pot.conc[#pot.conc + 1] = e
        if e.pct >= CONC_URGENT then pot.urgent[#pot.urgent + 1] = ("%s %d%%"):format(e.name, e.pct * 100) end
    end
    table.sort(pot.conc, function(a, b) return a.pct > b.pct end)
    for _, cd in pairs(L.cooldowns and L.cooldowns[key] or {}) do
        if cd.readyAt and cd.readyAt <= now then
            pot.ready[#pot.ready + 1] = cd.name
            pot.urgent[#pot.urgent + 1] = cd.name .. " ready"
        end
    end
    local t = ProfessionQueueAPI and ProfessionQueueAPI.Todo() or {}
    local buy, craft, post = t.buy or 0, (t.craft or 0) > 0 or #pot.ready > 0, t.post or 0
    pot.gold = mailGold + (t.stock or 0) + (t.profit or 0) * 10000
    local function Step(kind, what, note, seconds)
        pot.steps[#pot.steps + 1] = { kind = kind, what = what, note = note, seconds = seconds }
    end
    if mailWaiting then Step("mail", "collect", "Next in ProfessionQueue takes the auction house mail", 20) end
    -- a reagent a vendor sells cheaper than the AH: said up front, since it's a trip of its own
    if t.vendor and #t.vendor > 0 and craft then pot.vendor = table.concat(t.vendor, ", ") end
    if buy > 0 and craft then Step("ah", "buy", ("Next buys what the crafts are short of (%d)"):format(buy), 15 * buy) end
    if craft then
        local what = (t.craft or 0) > 0 and ("%d to make"):format(t.craft) or ""
        if #pot.ready > 0 then what = what .. (what ~= "" and "; " or "") .. table.concat(pot.ready, ", ") end
        Step("craft", "craft", (pot.vendor and ("Fetch " .. pot.vendor .. " first. ") or "") .. "Next crafts, one per click: "
            .. what, 10 + 5 * (t.craft or 0))
    end
    if post > 0 or active > 0 or craft or buy > 0 then
        local bits = {}
        if buy > 0 and not craft then bits[#bits + 1] = ("buy %d"):format(buy) end
        if post > 0 or craft then bits[#bits + 1] = "post" end
        if active > 0 then bits[#bits + 1] = ("check %d listings for undercuts"):format(active) end
        Step("ah", table.concat(bits, ", "), "Next until it says there's nothing left",
            15 * post + 8 * active + (craft and 15 or 0) + (not craft and 15 * buy or 0))
    end
    return pot
end

-- The run for what's piled up. With fit (seconds before a queue pops), only steps in this city that fit.
local function BuildCatchUp(fit)
    local pot = Pot()
    local steps, total, from = {}, 0, nil
    local mapNow = C_Map.GetBestMapForUnit("player")
    for i, s in ipairs(pot.steps) do
        local place, yards = Nearest(s.kind)
        if place and from then yards = Between(from, place) end
        local seconds = s.seconds + (yards and yards / RUN_YARDS or 30)
        if fit and not (place and place.map == mapNow and total + seconds <= fit) then break end
        total = total + seconds
        steps[#steps + 1] = { id = ("c%d-%s"):format(i, s.kind), map = place and place.map or mapNow or 0,
            x = place and place.x, y = place and place.y, title = ("%s: %s"):format(NAMES[s.kind], s.what),
            note = s.note, doneOn = DONE_ON[s.kind], seconds = seconds,
            hint = not place and ("Find a %s; Wayfinder remembers it once you open it"):format(NAMES[s.kind]:lower()) }
        from = place or from
    end
    db.catchup = { id = "catch-up", name = "Catch-up", steps = steps, built = time(), seconds = total }
    db.at["catch-up"] = nil
    db.parked = nil
    if #steps > 0 then
        if db.active ~= "catch-up" then db.returnTo = db.active end -- where a finished catch-up hands you back
        db.active = "catch-up"
    end
    return pot, steps, total
end

-- the line under the run name: what catching up takes and pays, and the fullest concentration
local function Summary(pot)
    local secs = 0
    for _, s in ipairs(pot.steps) do secs = secs + s.seconds end
    local bits = {}
    if #pot.steps > 0 then
        bits[1] = ("Catch-up: %d min"):format(math.max(1, math.floor(secs / 60 + 0.5)))
        if pot.gold > 0 then bits[#bits + 1] = "~" .. Gold(pot.gold) end
    else
        bits[1] = "Caught up"
    end
    local c = pot.conc[1]
    if c then
        local when = c.pct >= 1 and "full now" or c.full - time() < 86400 and ("full in %dh"):format((c.full - time()) / 3600)
            or ("full %s"):format(date("%a", c.full))
        bits[#bits + 1] = ("%s %d%% (%s)"):format(c.name:match("(%S+)$"), c.pct * 100, when)
    end
    return table.concat(bits, " · ")
end

local lineAt = -10
function CatchLine(force)
    if not catchButton or (not force and GetTime() - lineAt < 5) then return end
    lineAt = GetTime()
    local text = Summary(Pot())
    if queue and not queue.popped then
        text = ("|cff66ccffQueue ~%s|r · "):format(Clock(queue.left)) .. text
    end
    catchButton:SetText(text)
end

local function CatchUp()
    local pot, steps, total = BuildCatchUp(queue and not queue.popped and queue.left or nil)
    if #steps == 0 then
        return Print(#pot.steps > 0 and "nothing fits before the queue pops; it'll keep" or "caught up: nothing waiting")
    end
    local names = {}
    for _, s in ipairs(steps) do names[#names + 1] = s.title end
    Print(("Catch-up, about %s: %s"):format(Clock(total), table.concat(names, "; ")))
    if pot.vendor then Print(("Cheaper from a vendor than the AH, so not bought there: %s."):format(pot.vendor)) end
    CatchLine(true)
    Announce()
end

-- in chat only when something would go to waste
local function Nag()
    local pot = Pot()
    if #pot.urgent > 0 then
        Print(("%s. %s; click the catch-up line."):format(Summary(pot), table.concat(pot.urgent, ", ")))
    end
end

-- Queues ----------------------------------------------------------------------------------------------------
-- In a dungeon or PvP queue, the catch-up offers only what's in this city and fits before the pop. Every wait
-- is logged against Blizzard's estimate, so the estimate becomes yours: the median of your last waits for that
-- queue and role. What you collect and list while waiting is tallied, so you see what your queues have paid.
-- A pop parks the run; it picks up where it was when you're back.

local QUEUE_HISTORY, QUEUE_TRUST = 20, 3 -- waits kept per queue; how many before yours replace Blizzard's
local PARK = {
    "The queue calls. Your errands will keep. Your enemies will not.",
    "Leave the gold. Blood first, then the auction house.",
    "Finally. Something worth doing.",
}

local function Median(t)
    local s = {}
    for i, v in ipairs(t) do s[i] = v end
    table.sort(s)
    local n = #s
    return n % 2 == 1 and s[(n + 1) / 2] or (s[n / 2] + s[n / 2 + 1]) / 2
end

local function Mine(key)
    local h = db.queues[key]
    return h and #h >= QUEUE_TRUST and Median(h) or nil
end

-- the queue with the soonest expected pop (key, label, waited, Blizzard's estimate, yours, left), and whether
-- one has popped
local function QueueNow()
    local found, popped
    local function Consider(key, label, waited, est)
        local mine = Mine(key)
        local left = (mine or est) and math.max(0, (mine or est) - waited)
        if not found or (left or math.huge) < (found.left or math.huge) then
            found = { key = key, label = label, waited = waited, est = est, mine = mine, left = left }
        end
    end
    if GetLFGMode then
        local _, tank, healer = GetLFGRoles()
        local role = tank and "tank" or healer and "healer" or "dps"
        for cat = 1, NUM_LE_LFG_CATEGORYS or 7 do
            local mode = GetLFGMode(cat)
            if mode == "proposal" then
                popped = true
            elseif mode == "queued" then
                local s = { GetLFGQueueStats(cat) }
                local name, myWait, queuedTime = s[11], s[16], s[17]
                Consider(("lfg:%s:%s"):format(name or cat, role), name or "the dungeon queue",
                    queuedTime and GetTime() - queuedTime or 0, myWait and myWait > 0 and myWait or nil)
            end
        end
    end
    for i = 1, GetMaxBattlefieldID and GetMaxBattlefieldID() or 0 do
        local status, mapName, _, _, _, _, _, role = GetBattlefieldStatus(i)
        if status == "confirm" then
            popped = true
        elseif status == "queued" then
            local est = GetBattlefieldEstimatedWaitTime(i)
            Consider(("pvp:%s:%s"):format(mapName or i, role or "any"), mapName or "PvP",
                (GetBattlefieldTimeWaited(i) or 0) / 1000, est and est > 0 and est / 1000 or nil)
        end
    end
    return found, popped
end

local function Listed() return ProfessionQueueAPI and ProfessionQueueAPI.listed or 0 end

local function Popped()
    queue.popped = true
    local waited = time() - queue.started
    local h = db.queues[queue.key] or {}
    db.queues[queue.key] = h
    h[#h + 1] = waited
    if #h > QUEUE_HISTORY then table.remove(h, 1) end
    Print(("%s popped after %s. Blizzard said %s%s."):format(queue.label, Clock(waited), Clock(queue.est),
        queue.mine and (", your history said " .. Clock(queue.mine)) or ""))
    local gold, listed = math.max(0, GetMoney() - queue.money), Listed() - queue.listed
    if gold + listed > 0 then
        db.queuePaid = (db.queuePaid or 0) + gold + listed
        Print(("That wait paid %s collected and %s listed. Your queues have paid %s so far."):format(Gold(gold),
            Gold(listed), Gold(db.queuePaid)))
    end
    if db.active == "catch-up" and db.at["catch-up"] ~= "done" and db.catchup and #db.catchup.steps > 0 then
        db.parked = true
        Laezel(PARK[math.random(#PARK)])
    end
end

local function QueueTick()
    local q, popped = QueueNow()
    if queue and popped and not queue.popped then
        Popped()
    elseif q and queue and queue.popped and not popped then
        queue.popped = false  -- the group fell through: back in line
    elseif q and not queue then
        queue = { key = q.key, label = q.label, started = time() - q.waited, est = q.est, mine = q.mine,
                  money = GetMoney(), listed = Listed(), left = q.left }
        local h = db.queues[q.key]
        Print(("Queued for %s. Blizzard says %s%s."):format(q.label, Clock(q.est), q.mine
            and ("; your last %d waits say %s"):format(#h, Clock(q.mine)) or ""))
        CatchUp()
    elseif not q and not popped then
        queue = nil
    end
    if queue and q then queue.left = q.left end
end

-- a catch-up step whose window you just closed is done; finishing before the pop gets the peon's approval
local function WindowClosed(event)
    local step, _, _, run = Current()
    if not (step and step.doneOn == event and run.id == "catch-up") then return end
    Next()
    if db.at["catch-up"] == "done" and queue and not queue.popped then
        Voice("done")
        db.beatPop = (db.beatPop or 0) + 1
        Print(("Caught up with %s to spare before the pop (%d times now)."):format(Clock(queue.left), db.beatPop))
    end
end

-- Frame -----------------------------------------------------------------------------------------------------

-- text gets a 1px outline all round rather than an offset shadow, so it reads even when faint
local function Outline(t)
    if not (t and t.GetFont and t.SetFont) then return end
    local path, size = t:GetFont()
    if path then t:SetFont(path, size, "OUTLINE") end
    if t.SetShadowOffset then t:SetShadowOffset(0, 0) end
end

-- the red panel buttons at half strength (on top of the frame's own ALPHA): there, not shouting
local SOFT = 0.5
local function Button(label, width, onClick)
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(width, 20)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    for _, r in ipairs({ b:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "Texture" then r:SetAlpha(SOFT) end
    end
    Outline(b.GetFontString and b:GetFontString())
    return b
end

local function Build()
    frame = CreateFrame("Frame", "WayfinderFrame", UIParent)
    frame:SetSize(250, SIZE + 114)
    frame:SetPoint(db.point or "TOP", UIParent, db.relPoint or "TOP", db.x or 0, db.y or -120)
    frame:SetAlpha(ALPHA)
    frame:SetMovable(true); frame:EnableMouse(true); frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    local dragged
    frame:SetScript("OnMouseDown", function() dragged = false end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and not dragged then Poke() end
    end)
    frame:SetScript("OnDragStart", function(self) dragged = true; self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
    end)

    -- the shadow is a black 1px rim rather than an offset copy: at 50% a copy underneath would show through
    -- the arrow and darken it, and a rim never overlaps it
    shadow = frame:CreateTexture(nil, "ARTWORK", nil, 0)
    shadow:SetTexture(EDGE); shadow:SetSize(SIZE, SIZE)
    shadow:SetPoint("TOP", frame, "TOP", 0, 0)
    shadow:SetVertexColor(0, 0, 0, 1)
    arrow = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    arrow:SetTexture(ARROW); arrow:SetSize(SIZE, SIZE)
    arrow:SetPoint("TOP", frame, "TOP", 0, 0)
    -- themed to the character: the arrow takes your class colour, and a tag above it says who's playing and
    -- whose run this is
    for i = 1, MOTES do
        local m = frame:CreateTexture(nil, "OVERLAY")
        m:SetTexture(MOTE); m:SetBlendMode("ADD")
        local size = 6 + 2 * (i % 3)
        m:SetSize(size, size)
        m:Hide()
        motes[i] = m
    end
    ApplyLook()

    local function Text(font, anchor, gap)
        local t = frame:CreateFontString(nil, "OVERLAY", font)
        t:SetPoint("TOP", anchor, "BOTTOM", 0, gap)
        t:SetShadowOffset(1, -1); t:SetShadowColor(0, 0, 0, 1)
        Outline(t)
        return t
    end
    title = Text("GameFontNormal", arrow, -2)
    if title.SetAlpha then title:SetAlpha(SOFT) end  -- the gold title, softened like the buttons
    learn = Text("GameFontHighlightSmall", title, -2)
    info = Text("GameFontHighlightSmall", learn, -2)
    who = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    who:SetPoint("BOTTOM", arrow, "TOP", 0, 2)
    who:SetShadowOffset(1, -1); who:SetShadowColor(0, 0, 0, 1)
    Outline(who)
    if who.SetAlpha then who:SetAlpha(SOFT) end

    local back = Button("< Back", 80, Prev)
    nextButton = Button("Next", 80, Next)
    runButton = Button("", 250, function(self) PickRun(self) end)
    back:SetPoint("TOPRIGHT", info, "BOTTOM", -2, -4)
    nextButton:SetPoint("TOPLEFT", info, "BOTTOM", 2, -4)
    runButton:SetPoint("TOP", info, "BOTTOM", 0, -27)
    catchButton = Button("", 250, CatchUp)
    catchButton:SetPoint("TOP", runButton, "BOTTOM", 0, -2)

    local elapsed, queueAt = 0, 0
    frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < TICK then return end
        queueAt = queueAt + elapsed
        elapsed = 0
        if queueAt >= 1 then queueAt = 0; QueueTick() end
        Update()
        Animate()
        CatchLine()
    end)
    if db.hidden then frame:Hide() end
end

-- Slash commands, for the odd thing the buttons don't do ----------------------------------------------------

SLASH_WAYFINDER1 = "/wf"
SlashCmdList.WAYFINDER = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "next" then Next()
    elseif cmd == "prev" or cmd == "back" then Prev()
    elseif cmd == "here" then Here()
    elseif cmd == "run" then CycleRun()
    elseif cmd == "wisp" then
        db.wisp = not Wisp()
        ApplyLook()
        Print(db.wisp and "a wisp will guide you" or "the arrow again")
    elseif cmd == "list" then
        local _, n, _, run = Current()
        if not run then return Print("no runs loaded") end
        for i, s in ipairs(Steps(run)) do
            local where = s.x and ("%s %.1f, %.1f"):format(MapName(s.map), s.x, s.y) or (MapName(s.map) .. ", no coords")
            Print(("%s%d. %s - %s"):format(i == n and "> " or "  ", i, s.title, where))
        end
    elseif cmd == "way" then
        -- /wf way 48.0 35.0 Some title : a waypoint here, added to your own "My waypoints" run and made current
        local x, y, name = rest:match("^([%d%.]+)[,%s]+([%d%.]+)%s*(.*)$")
        local mapID = C_Map.GetBestMapForUnit("player")
        if not (x and mapID) then return Print("usage: /wf way <x> <y> [title]") end
        local steps = db.custom.steps
        local step = { id = "w" .. (#steps + 1) .. "-" .. time(), map = mapID, x = tonumber(x), y = tonumber(y),
                       title = name ~= "" and name or ("%s %s"):format(x, y) }
        steps[#steps + 1] = step
        db.active = db.custom.id
        SetAt(db.custom, step)
        Announce()
    elseif cmd == "restart" then
        local _, _, _, run = Current()
        if run then db.at[run.id], db.fixes[run.id] = nil, nil; Print(run.name .. " restarted, fixes cleared"); Announce() end
    elseif cmd == "sound" then
        db.sound = db.sound == false
        Print("worker sounds " .. (db.sound and "on" or "off"))
    elseif cmd == "voice" then  -- your race's worker, then the peon, then the peasant
        db.voice = (db.voice == nil and "peon") or (db.voice == "peon" and "peasant") or nil
        Print("worker voice: " .. (db.voice or "your race's"))
        Voice("what")
    elseif cmd == "hide" then db.hidden = true; frame:Hide()
    elseif cmd == "show" then db.hidden = false; frame:Show()
    else
        Print("Back, Next, and the run name switches runs. Talk to the trainer and close the window: it moves on.")
        Print("/wf list | here (this step is where I stand) | way <x> <y> [title] | restart | sound | voice | hide | show. Drag to move.")
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("USER_WAYPOINT_UPDATED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("TRAINER_SHOW")
events:RegisterEvent("TRAINER_CLOSED")
for _, e in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "TRADE_SKILL_SHOW",
                     "TRADE_SKILL_CLOSE", "LFG_UPDATE", "LFG_QUEUE_STATUS_UPDATE", "LFG_PROPOSAL_SHOW",
                     "UPDATE_BATTLEFIELD_STATUS" }) do
    events:RegisterEvent(e)
end
local wasInside
events:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" and name == ADDON then
        WayfinderDB = WayfinderDB or {}
        db = WayfinderDB
        if db.route then  -- the first version's layout: one route, no runs
            db.route, db.at = nil, nil
        end
        db.at = db.at or {}
        db.fixes = db.fixes or {}
        db.custom = db.custom or { id = "my-waypoints", name = "My waypoints", steps = {} }
        db.chars = db.chars or {}
        db.places = db.places or {}
        db.queues = db.queues or {}
        if db.active == "lumberjack" and db.started then db.active = db.started end  -- undo the faulty detour
        -- each character keeps its own chosen run (before this, one choice was shared by everyone)
        db.activeBy = db.activeBy or {}
        local me = UnitName("player")
        if db.activeBy[me] then db.active = db.activeBy[me] end
        if ns.START and ns.START ~= db.started then  -- a new run handed over with --start: switch to it once
            for _, r in ipairs(ns.RUNS or {}) do
                if r.id == ns.START and (not r.char or r.char == me) then  -- only on the character it's for
                    db.active, db.started = ns.START, ns.START
                end
            end
        end
        Build()
        Announce()
    elseif not db then
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- out of the way in arenas and battlegrounds, back afterwards (unless you hid it yourself)
        local inside, kind = IsInInstance()
        if kind == "arena" or kind == "pvp" then frame:Hide() elseif not db.hidden then frame:Show() end
        RecordTracking()
        -- at login the saved catch-up is rebuilt from what's piled up now (your auctions included), so it
        -- never walks you to work already done; the run you had chosen stays chosen
        if wasInside == nil and db.catchup and not db.parked then
            local active = db.active
            BuildCatchUp()
            if active ~= "catch-up" then db.active = active end
        end
        -- back from an instance: a parked catch-up picks up again from here; otherwise speak up only if
        -- something is going to waste (also at login)
        if not inside and (wasInside or wasInside == nil) then
            if db.parked then
                db.parked = nil
                Print("Back. The catch-up picks up from here.")
                CatchUp()
            else
                Nag()
            end
        end
        wasInside = inside and true or false
    elseif event == "PLAYER_LOGOUT" then
        db.activeBy[UnitName("player")] = db.active
    elseif event == "USER_WAYPOINT_UPDATED" then
        AdoptPin()
    elseif event == "TRAINER_SHOW" then
        TrainerShown()
    elseif event == "TRAINER_CLOSED" then
        TrainerClosed()
    elseif LEARN_ON[event] then
        LearnPlace(LEARN_ON[event])
    elseif event == "MAIL_CLOSED" or event == "AUCTION_HOUSE_CLOSED" or event == "TRADE_SKILL_CLOSE" then
        WindowClosed(event)
        CatchLine(true)
    else
        QueueTick()
    end
end)

-- Minimap button, in Shan'do's style: half opacity until you point at it, drag to move it round the edge (the
-- angle is kept in the saved variables). The tooltip says which addon and which character.
if Minimap then  -- every client has one; test stubs may not
    local REST, NAME, COLOUR = 0.5, "Wayfinder", "ffd4a017"
    local b = CreateFrame("Button", "WayfinderMinimapButton", Minimap)
    b:SetSize(24, 24)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    b:SetAlpha(REST)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\AddOns\\Wayfinder\\icon")
    local function Saved() WayfinderDB = WayfinderDB or {}; return WayfinderDB end
    local function Place(angle)
        local r = Minimap:GetWidth() / 2 + 6
        b:ClearAllPoints()
        b:SetPoint("CENTER", Minimap, "CENTER", r * math.cos(math.rad(angle)), r * math.sin(math.rad(angle)))
    end
    b:SetScript("OnEnter", function(self)
        self:SetAlpha(1)
        local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[select(2, UnitClass("player"))]
        local who = UnitName("player")
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(("|c%s%s|r · %s"):format(COLOUR, NAME, cc and cc.colorStr and ("|c%s%s|r"):format(cc.colorStr, who) or who))
        GameTooltip:AddLine("Left-click: show or hide the arrow", 1, 1, 1)
        GameTooltip:AddLine("Right-click: pick a run", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this button", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self) self:SetAlpha(REST); GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then PickRun(self)
        else SlashCmdList.WAYFINDER(frame:IsShown() and "hide" or "show") end
    end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            Saved().minimapAngle = math.deg(math.atan2(cy / s - my, cx / s - mx))
            Place(Saved().minimapAngle)
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:RegisterEvent("PLAYER_LOGIN")
    b:SetScript("OnEvent", function() Place(Saved().minimapAngle or 225) end)
end
