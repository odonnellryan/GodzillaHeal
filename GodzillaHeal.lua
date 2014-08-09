local HealComm = AceLibrary("HealComm-1.0")
local GH_VERSION = "1.7"
local GodzillaHeal = {}

--
-- Consts
--
local CANCEL_DELAY = 300
local RED     = "|cffff0000";
local GREEN   = "|cff00ff00";
local BLUE    = "|cff0000ff";
local MAGENTA = "|cffff00ff";
local YELLOW  = "|cffffff00";
local CYAN    = "|cff00ffff";
local WHITE   = "|cffffffff";

--
-- Enum
--
local CancelMode_Immediate = 1
local CancelMode_Delayed = 2

--
--  State Machine
--
local State_Idle = 1 			-- Not casting
local State_Precast = 2 		-- Between when /gh initiated a cast and the SPELLCAST event comes
local State_Casting = 3 		-- Casting not as a result of /gh
local State_Canceling = 4 		-- Between a successful /gh cancel and SPELLCAST_SPOT or INTERRUPT
local State_GodzillaCasting = 5 -- Casting as a result of /gh

--
-- Runtime
--
GodzillaHeal.State = State_Idle
GodzillaHeal.Enabled = false
GodzillaHeal.CastTime = -1
GodzillaHeal.Blacklist = {}
GodzillaHeal.HealthTable = {}
GodzillaHeal.HealActionSlot = nil
GodzillaHeal.DelayAfterCancel = 0 -- 200 ms.
GodzillaHeal.BlackListTimeout = 5 -- 5 sec timeout

--
-- Settings
--
local GodzillaHeal_DefaultSettings = { 
	Threshold = 250,
	Mode = 1,
	CancelThreshold = 300,
	Randomize = 0,
	Watch = {},
	AutoDownRank = false,
	IncludeExpression = "*",
	ExcludeExpression = ""
}

--
--  Modes
--  To add a new mode, add to this list. Nothing else is required.
--
local Modes = {}
table.insert(Modes, {
		GetMetric = function(unit) return UnitHealth(unit) / UnitHealthMax(unit) end,
		Ascending = true,
		Name = "LowestPercent",
	})

table.insert(Modes, {
		GetMetric = function(unit) return UnitHealthMax(unit) - UnitHealth(unit) end,
		Ascending = false, -- Descending
		Name = "HighestMissingHp",
	})

table.insert(Modes, {
	GetMetric = function(unit) return UnitHealthMax(unit) - UnitHealth(unit) + HealComm:getHeal(UnitName(unit)) end,
	Ascending = false,
	Name = "HighestMissingHpHealComm"
	})

--
--  Names of spells that are heals and are 40 yard range. We will scan the player's action bars for a spell of this name.
--
local healNames = {
	'Flash Heal',
	'Lesser Heal',
	'Renew',
	'Heal',
	'Greater Heal',
	'Regrowth',
	'Rejuvenation',
	'Healing Touch',
	'Holy Light',
	'Flash of Light',
	'Healing Wave',
	'Healing Way',
	'Lesser Healing Wave',
	'Chain Heal'
}

local function ghprint(msg)
	if msg == nil then
		msg = "[nil]"
	end
	DEFAULT_CHAT_FRAME:AddMessage(YELLOW.."GodzillaHeal: "..WHITE..msg)
end

local function ghdebug(msg)
	if GodzillaHeal.Debug then
		ghprint(msg)
	end
end

local function TargetInHealRange()
	return IsActionInRange(GodzillaHeal.HealActionSlot) == 1
end

local function IsHealerClass()
	_, playerClass = UnitClass("player")
	return (playerClass == "DRUID" or playerClass == "PRIEST" or playerClass == "PALADIN" or playerClass == "SHAMAN")
end

local function ParseFlags(flags)
	flags = string.sub(flags, 1, string.len(flags) - 2)
end

--
--  Health Table
--
local function GetPartyRosterInfo(index)

	local unitId = "party"..index
	local name = UnitName(unitId)
	
	local rank = 0
	if (index == GetPartyLeaderIndex()) then rank = 1 end
	
	local level = UnitLevel(unitId)
	local classLocale, class = UnitClass(unitId)
	local isDead = UnitIsDeadOrGhost(unitId)

	return name, rank, level, classLocale, class, isDead
end

local function GetUnitInfo(groupType, index)
	local unitId, group, unitClass, online, isDead, _

	if groupType == "raid" then
		unitId = groupType..index
		_, _, group, _, _, unitClass, _, online, isDead = GetRaidRosterInfo(index)
	elseif groupType == "party" then
		unitId = groupType..index
		online = UnitIsConnected(unitId)
		_, _, _, _, unitClass, isDead = GetPartyRosterInfo(index)
	elseif groupType == "player" or groupType == "pet" then
		unitId = groupType
		online = UnitIsConnected("player")
		_, unitClass = UnitClass("player")
		isDead = UnitIsDeadOrGhost(unitId)
	elseif groupType == "partypet" then
		unitId = groupType..index
		online = UnitIsConnected("party"..index)
		_, unitClass = UnitClass("party"..index)
		isDead = UnitIsDeadOrGhost(unitId)
	elseif groupType == "raidpet" then
		unitId = groupType..index
		online = UnitIsConnected("raid"..index)
		_, unitClass = UnitClass("raid"..index)
		isDead = UnitIsDeadOrGhost(unitId)
	end
	
	local unitHealth, unitHealthMax = UnitHealth(unitId), UnitHealthMax(unitId)

	local unitInfo = {
		name = UnitName(unitId),
		hp = unitHealth, 
		hpMax = unitHealthMax, 
		unitId = unitId, 
		isDead = isDead or unitHealth == 0 or unitHealth == 1, -- When ghost your health is 1
		online = online,
		metric = GodzillaHeal.Mode.GetMetric(unitId)
	}

	return (unitInfo)
end

local function AddUnit(tbl, groupType, index)
	local unitInfo = GetUnitInfo(groupType, index)

	if UnitIsVisible(unitInfo.unitId) 
		and UnitExists(unitInfo.unitId) 
		and not unitInfo.isDead 
		and unitInfo.online 
		and UnitIsFriend("player", unitInfo.unitId)
	then
		local updated = false	
		-- Find correct position
		for j = 1, table.getn(tbl) do
			if GodzillaHeal.Mode.Ascending then
				if (unitInfo.metric < tbl[j].metric) then
					table.insert(tbl, j, unitInfo)
					updated = true
					break
				end
			else
				if (unitInfo.metric > tbl[j].metric) then
					table.insert(tbl, j, unitInfo)
					updated = true
					break
				end
			end
		end

		if (not updated) then
			table.insert(tbl, unitInfo)
		end
	end
end

local function DoesUnitMatchExpression(index, match)
	if match == nil or match == "" then return false end
	if match == "*" then return true end
	local name, _, group = GetRaidRosterInfo(index);
	name = string.lower(name)

	for s in GHUtil.strsplit2(" ", match) do
		s = GHUtil.trim1(s)
		s = string.lower(s)
		if s == name then return true end
		if s == ("g"..group) then return true end
		if s == ("grp"..group) then return true end
		if s == ("group"..group) then return true end
	end

	return (false)
end

local function RefreshTable(request)
	local include = request.IncludeExpression
	local exclude = request.ExcludeExpression

	local healthTable = {}
	GodzillaHeal.Mode = Modes[request.Mode]
	
	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers() do
			if DoesUnitMatchExpression(i, include) and not DoesUnitMatchExpression(i, exclude) then
				AddUnit(healthTable, "raid", i)
			end
		end
	elseif GetNumPartyMembers() > 0 then
		for i = 1, GetNumPartyMembers() do
			AddUnit(healthTable, "party", i)
		end
	end

	AddUnit(healthTable, "player")
	GodzillaHeal.HealthTable = healthTable
end

local function BlacklistLastTarget()
	if GodzillaHeal.LastTarget then
		GodzillaHeal.Blacklist[GodzillaHeal.LastTarget] = 0
	end
	GodzillaHeal.LastTarget = nil
end

local function FindUnitFromName(name)
	if UnitName("player") == name then
		return "player"
	end

	if GetNumRaidMembers() > 0 then
		for i = 1, 40 do
			local unit = "raid"..i
			local unitName = UnitName(unit)
			if (name == unitName) then
				return unit
			end
		end
	elseif GetNumPartyMembers() > 0 then
		for i = 1, 4 do
			local unit = "party"..i
			local unitName = UnitName(unit)
			if (name == unitName) then
				return unit
			end
		end
	end

	return nil
end

--
--  Cancel
--
local function ShouldTryCancel()
	local shouldCancel = false
	shouldCancel = shouldCancel or (GodzillaHeal.CancelMode == CancelMode_Immediate)
	shouldCancel = shouldCancel or (GodzillaHeal.CancelMode == CancelMode_Delayed and GodzillaHeal.CastTime < GodzillaHeal_Settings.CancelThreshold)
	return shouldCancel
end

local function TryCancelCore()
	local unit = FindUnitFromName(GodzillaHeal.LastTarget)
	if not unit then return end

	local missingHealth = UnitHealthMax(unit) - UnitHealth(unit)
	if missingHealth < GodzillaHeal_Settings.Threshold then
		GodzillaHeal.State = State_Canceling
		GodzillaHeal.DelayAfterCancel = CANCEL_DELAY
		SpellStopCasting()
	end
end

local function TryCancel()
	if GodzillaHeal.State == State_GodzillaCasting and ShouldTryCancel() then
		TryCancelCore()
	end
end

--
--  Core
--
local function SelectUnit(threshold)
	for i = 1, table.getn(GodzillaHeal.HealthTable) do
		local unitInfo = GodzillaHeal.HealthTable[i]
		local unitId = unitInfo.unitId
		local missingHp = unitInfo.hpMax - unitInfo.hp
		if not GodzillaHeal.Blacklist[UnitName(unitId)] and missingHp >= threshold then
			TargetUnit(unitId)
			if TargetInHealRange() then
				return unitId
			else
				ghdebug("Unit not in range; trying again.")
			end
		end
	end
	return nil
end

local function SelectRandomUnitFromList(tbl, threshold)
	tbl = GHUtil.copyTable(tbl) -- Don't need to copy here, but just do it to prevent bugs in the future
	while table.getn(tbl) > 0 do
		local i = math.random(table.getn(tbl))
		local unitInfo = tbl[i]
		local unitId = unitInfo.unitId
		local missingHp = unitInfo.hpMax - unitInfo.hp
		if not GodzillaHeal.Blacklist[UnitName(unitId)] and missingHp >= threshold then
			TargetUnit(unitId)
			if TargetInHealRange() then
				return unitId
			else
				ghdebug("Unit not in range; trying next.")
			end
		end
		table.remove(tbl, i)
	end
	return nil
end

local function Percent_Difference(a, b)
	if a > b then
		return (a - b) / a
	else
		return (b - a) / b
	end
end

-- Some complexity here. The idea is to create a table containing the person with the lowest health
-- and anyone who is within 10% of that percentage. Unfortunately I have to deal with the situation
-- where nobody in that list is within range. The technique is create this list, remove them from the original
-- table, see if anyone in the list is within range, and then otherwise call recursively to that smaller list.
local function SelectUnitRandomCore(tbl, threshold, randomize)
	if table.getn(tbl) == 0 then return nil end

	local unitInfo = tbl[1]
	local topMetric = unitInfo.metric

	local possibleUnits = {}

	for i = 1, table.getn(tbl) do
		unitInfo = tbl[i]
		local missingHp = unitInfo.hpMax - unitInfo.hp
		if missingHp >= threshold then
			local percentDiff = Percent_Difference(unitInfo.metric, topMetric)
			if (percentDiff < randomize) then
				table.insert(possibleUnits, unitInfo)
			else
				break
			end
		end
	end

	if table.getn(possibleUnits) == 0 then return nill end

	for i = 1, table.getn(possibleUnits) do
		table.remove(tbl, i)
	end

	ghdebug("Randomize: " .. table.getn(possibleUnits) .. " possible candidate(s).")

	local selectedUnit = SelectRandomUnitFromList(possibleUnits, threshold)
	if selectedUnit then return selectedUnit end
	return SelectUnitRandomCore(tbl, threshold, randomize)
end

local function SelectUnitRandom(threshold, randomize)
	local copy = GHUtil.copyTable(GodzillaHeal.HealthTable)
	return SelectUnitRandomCore(copy, threshold, randomize)
end

local function ChooseSpell(unit, spell)
	local spellName, rank = CastDetails.ParseCast(spell)
	local missingHp = UnitHealthMax(unit) - UnitHealth(unit)
	for i = rank, 1, -1 do
		if i == 1 then
			rank = 1
			break
		end

		local spellInfo = TheoryCraft_GetSpellDataByName(spellName, i - 1)
		local healAmount = spellInfo.averagehealnocrit

		ghdebug("Checking " ..spellName .. "(Rank "..i.."): Heal Amount = " .. healAmount .. ", Missing Hp = " .. missingHp)

		if (healAmount < missingHp) then
			rank = i
			break
		end
	end
	local spell = spellName .. "(Rank " .. rank .. ")"
	return spell
end

local function GodzillaHeal_HealCore(spellName, selectedUnit, cancelMode)
	if not GodzillaHeal.Enabled or (GodzillaHeal.State ~= State_Idle) then return end
	if GodzillaHeal.DelayAfterCancel > 0 then return end

	if selectedUnit then
		GodzillaHeal.State = State_Precast
		GodzillaHeal.CancelMode = cancelMode
		GodzillaHeal.LastTarget = UnitName(selectedUnit)
		TargetUnit(selectedUnit)
		CastSpellByName(spellName)
	else
		ClearTarget()
	end
end

local function ParseHealRequest(cmd)
	local _, _, params, spell = string.find(cmd, "^%[(.*)%]%s(.*)$")

	if spell == nil then
		spell = cmd
	end

	local request = {}
	request.SpellName = spell

	-- Defaults
	request.Randomize = GodzillaHeal_Settings.Randomize
	request.Threshold = GodzillaHeal_Settings.Threshold
	request.AutoDownRank = GodzillaHeal_Settings.AutoDownRank
	request.IncludeExpression = GodzillaHeal_Settings.IncludeExpression
	request.ExcludeExpression = GodzillaHeal_Settings.ExcludeExpression
	request.Mode = GodzillaHeal_Settings.Mode

	if params ~= nil then
		for s in GHUtil.strsplit2(",", params) do
			local key, value = GHUtil.strsplit("=", s)
			if key ~= nil then
				key = GHUtil.trim1(key)
				if value == nil then value = "" end
				value = GHUtil.trim1(value)
				if key == "i" then request.IncludeExpression = value
				elseif key == "inc" then request.IncludeExpression = value
				elseif key == "include" then request.IncludeExpression = value
				elseif key == "e" then request.ExcludeExpression = value
				elseif key == "ex" then request.ExcludeExpression = value
				elseif key == "exclude" then request.ExcludeExpression = value
				elseif key == "threshold" then request.Threshold = tonumber(value)
				elseif key == "mode" then request.Mode = tonumber(value)
				else
					ghprint("Notice: unknown parameter '" .. key .. "'.")
				end
			end
		end
	end
	return (request)
end

local function GodzillaHeal_Heal(commandString)
	if not GodzillaHeal.Enabled or (GodzillaHeal.State ~= State_Idle) then return end

	local healRequest = ParseHealRequest(commandString)

	RefreshTable(healRequest)

	local selectedUnit = nil
	if healRequest.Randomize == 0 then
		selectedUnit = SelectUnit(healRequest.Threshold)
	else
		selectedUnit = SelectUnitRandom(healRequest.Threshold, healRequest.Randomize)
	end

	if selectedUnit == nil then
		ghdebug("No eligible units.")
		ClearTarget(); 
		return
	end

	if healRequest.AutoDownRank then
		healRequest.SpellName = ChooseSpell(selectedUnit, healRequest.SpellName)
	end

	ghdebug("Healing: Unit=" .. selectedUnit .. ", SpellName=" .. healRequest.SpellName .. ", Mode=" .. GodzillaHeal.Mode.Name .. ", Threshold=" ..healRequest.Threshold .. ", Randomize=" .. healRequest.Randomize .. ", IncludeExpression=" .. healRequest.IncludeExpression .. ", ExcludeExpression=" .. healRequest.ExcludeExpression)

	GodzillaHeal_HealCore(healRequest.SpellName, selectedUnit, CancelMode_Immediate)
end

local function GodzillaHeal_TankHeal(spellName)
	GodzillaHeal_HealCore(spellName, "Target", CancelMode_Delayed)
end

--
--  Enable
--
function LocateHealSpell()
	for i = 1, 120 do
		if HasAction(i) and GetActionText(i) == nil then
		    GodzillaHeal_ScanningTooltip:SetAction(i);
		    local slotName
		    slotName = GodzillaHeal_ScanningTooltipTextLeft1:GetText();
		    if (GHUtil.containsValue(healNames, slotName)) then
				return (i)
			end
		end
	end
	return 0
end

local function TryEnable()
	GodzillaHeal.HealActionSlot = LocateHealSpell()
	if GodzillaHeal.HealActionSlot > 0 and not GodzillaHeal.Enabled then
		GodzillaHeal.Enabled = true
	elseif GodzillaHeal.HealActionSlot == 0 then
		GodzillaHeal.Enabled = false
	end
end

local function AddWatch(spell, dest, txt)
	GodzillaHeal_Settings.Watch[spell] = { Dest = dest, Text = txt }
end

--
--  Commands
--
local function PrintHelp()
	DEFAULT_CHAT_FRAME:AddMessage(YELLOW.."GodzillaHeal -- Commands:")
	DEFAULT_CHAT_FRAME:AddMessage(CYAN.."/gh"..WHITE.." Spell Name(Rank x)")
	DEFAULT_CHAT_FRAME:AddMessage("e.g.: /gh Flash Heal(Rank 4). It must be formatted like it would be in a /cast macro.")
	DEFAULT_CHAT_FRAME:AddMessage(CYAN.."/gh set "..WHITE.."key value (/gh set for more information)")
	DEFAULT_CHAT_FRAME:AddMessage(CYAN.."/gh cancel. "..WHITE.."Cancel a cast initiated by GodzillaHeal if the target's heal has moved above the threshold.")
	DEFAULT_CHAT_FRAME:AddMessage(" -- See Readme for more details (sorry!).")
end

local function BoolToEnabledString(boolValue)
	if boolValue then return "enabled" else return "disabled" end
end

--
--  Clearly needs cleanup, too lazy
--
local function SetConfiguration(key, value)
	key = string.lower(key)
	if value then value = string.lower(value) end
	if key == "mode" then
		if not value then
			ghprint("Current mode is "..GodzillaHeal.Mode.Name..".")
		else
			value = tonumber(value)
			if Modes[value] == nil then
				ghprint("Unknown value '"..value.."'.")
				return
			end
			GodzillaHeal_Settings.Mode = value
			GodzillaHeal.Mode = Modes[value]
			ghprint("Mode is now " .. GodzillaHeal.Mode.Name .. ".")
		end
		GodzillaHeal.Mode = Modes[GodzillaHeal_Settings.Mode]
	elseif key == "threshold" then
		if not value then
			ghprint("Current health threshold is "..GodzillaHeal_Settings.Threshold.."hp.")
		else
			GodzillaHeal_Settings.Threshold = tonumber(value)
			ghprint("Threshold health is now "..GodzillaHeal_Settings.Threshold.."hp.")
		end
	elseif key == "cancel" then
		if not value then
			ghprint("Current cancel threshold is " .. GodzillaHeal_Settings.CancelThreshold .. "ms.")
		else
			GodzillaHeal_Settings.CancelThreshold = tonumber(value)
			ghprint("Cancel threshold is now "..GodzillaHeal_Settings.CancelThreshold.."ms.")
		end
	elseif key == "randomize" then
		value = tonumber(value)
		if not value then
			ghprint("Current randomize threshold is " .. GodzillaHeal_Settings.Randomize * 100 .. "%.")
		else
			if value > 1 then
				value = value / 100
			end
			if value < 0 or value > 100 then
				ghprint("Invalid value. The randomize threshold must be between [0, 100] (as a percentage) or [0, 1].")
				return
			end
			GodzillaHeal_Settings.Randomize = value
			ghprint("Randomize threshold is now " .. GodzillaHeal_Settings.Randomize * 100 .. "%.")
		end
	elseif key == "autodownrank" then
		if not value then
			ghprint("Auto down rank is " .. BoolToEnabledString(GodzillaHeal_Settings.AutoDownRank) .. ".")
		else
			value = (value == "1" or value == "true")
			GodzillaHeal_Settings.AutoDownRank = value
			ghprint("Auto down rank is now " .. BoolToEnabledString(GodzillaHeal_Settings.AutoDownRank) .. ".")
		end
	else
		ghprint("Unknown key.")
	end
end

local function PrintSetHelp()
	DEFAULT_CHAT_FRAME:AddMessage(YELLOW.."GodzillaHeal -- Settings:")
	local modeString = ""
	for index, mode in Modes do
		if modeString ~= "" then
			modeString = modeString .. " | "
		end
		modeString = modeString .. index .. " [" .. mode.Name .. "]"
	end
	DEFAULT_CHAT_FRAME:AddMessage(CYAN.."/gh set "..WHITE.."mode " .. modeString)
	DEFAULT_CHAT_FRAME:AddMessage(CYAN.."/gh set "..WHITE.. "randomize <number>. Sets the randomize threshold. Set to zero to disable.")
	DEFAULT_CHAT_FRAME:AddMessage(CYAN.."/gh set "..WHITE.. "threshold <number>. Set the amount of hp that must be mssing before /gh cancel will cancel a cast (either casted from /gh ot /ght).")
	DEFAULT_CHAT_FRAME:AddMessage(CYAN.."/gh set "..WHITE.. "cancel <number>. Sets the amount of time remaining in a cast before a cast started with /ght can be canceled via /gh cancel.")
	DEFAULT_CHAT_FRAME:AddMessage(CYAN.."/gh set "..WHITE.. "autodownrank <bool> (1|true|0|false). Sets whether or not to auto down rank heals based on missing hp.")
end

local function GH_CommandHandler(msg)
	msg = GHUtil.trim1(msg)
	local a, b, c = GHUtil.strsplit(" ", msg)
	if (not msg or msg == "") then
		PrintHelp()
	elseif (a == "cancel") then
		TryCancel()
	elseif (a == "set") then
		if b then
			SetConfiguration(b, c)
		else
			PrintSetHelp()
		end
	elseif (a == "watch") then
		local value = string.sub(msg, 7)
		local spell, dest, action 
		if value ~= nil then spell, dest, action = GHUtil.strsplit(",", value) end
		if not value or not spell or not action or not dest then
			ghprint("Invalid syntax. /gh watch <Spell Name>, <Dest [SAY|YELL|RAID]>, <Message>. %t can be used for target.")
		else
			spell = GHUtil.trim1(spell)
			dest = GHUtil.trim1(dest)
			action = GHUtil.trim1(action)
			AddWatch(string.lower(spell), dest, action)
			ghprint("Added watch for spell `" .. spell .. "`")
		end
	elseif (a == "debug") then
		GodzillaHeal.Debug = not GodzillaHeal.Debug
		ghprint("Debugging is now " .. BoolToEnabledString(GodzillaHeal.Debug) .. ".")
	else
		GodzillaHeal_Heal(msg)
	end
end

local function GHT_CommandHandler(msg)
	GodzillaHeal_TankHeal(msg)
end

--
--  Event Handlers
--
function GodzillaHeal_OnUpdate(arg1)
	if not GodzillaHeal.Enabled then return end

	if GodzillaHeal.DelayAfterCancel >= 0 then
		GodzillaHeal.DelayAfterCancel = GodzillaHeal.DelayAfterCancel - arg1 * 1000 -- Convert to ms
	end

	if (GodzillaHeal.CastTime > 0) then
		GodzillaHeal.CastTime = GodzillaHeal.CastTime - arg1 * 1000
	end

	for name, timelapse in GodzillaHeal.Blacklist do
		local current_timelapse = timelapse + arg1
		if(current_timelapse > GodzillaHeal.BlackListTimeout) then
			GodzillaHeal.Blacklist[name] = nil
		else
			GodzillaHeal.Blacklist[name] = current_timelapse
		end
	end
end

function GodzillaHeal_OnLoad()
	if not IsHealerClass() then return end

	ghprint("v"..GH_VERSION.." :: "..YELLOW.."/gh"..WHITE.." :: "..YELLOW.."/godzillaheal")

	SLASH_GODZILLAHEAL1 = "/GodzillaHeal"
	SLASH_GODZILLAHEAL2 = "/gh"
	SLASH_GODZILLATANK1 = "/ght"

	SlashCmdList["GODZILLAHEAL"] = GH_CommandHandler
	SlashCmdList["GODZILLATANK"] = GHT_CommandHandler

	this:RegisterEvent("UNIT_HEALTH")
	this:RegisterEvent("UNIT_MAXHEALTH")
	this:RegisterEvent("SPELLCAST_FAILED")
	this:RegisterEvent("SPELLCAST_START")
	this:RegisterEvent("SPELLCAST_STOP")
	this:RegisterEvent("SPELLCAST_INTERRUPTED")
	this:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
	this:RegisterEvent("UI_ERROR_MESSAGE")
	this:RegisterEvent("PLAYER_LOGIN")
	this:RegisterEvent("VARIABLES_LOADED")
end

local function LoadMissingVariables()
	if not GodzillaHeal_Settings then
		GodzillaHeal_Settings = {}
	end
	for key, value in GodzillaHeal_DefaultSettings
	do
		if not GodzillaHeal_Settings[key] then
			GodzillaHeal_Settings[key] = value
		end
	end
end

local function CastDetailsHandler(cast)
	local spell = string.lower(cast.Spell)
	local watch = GodzillaHeal_Settings.Watch[spell]
	if watch == nil then return end
	local msg = string.gsub(watch.Text, "%%t", cast.Target)
	SendChatMessage(msg, string.upper(watch.Dest))
end

local function RegisterWatchSpells()
	CastDetails.RegisterHandler(CastDetailsHandler)
end

local GodzillaHeal_Events = {}
local GodzillaHeal_EnabledOnlyEvents = {}

function GodzillaHeal_Events.VARIABLES_LOADED()
	LoadMissingVariables()
	GodzillaHeal.Mode = Modes[GodzillaHeal_Settings.Mode]
	RegisterWatchSpells()
end

function GodzillaHeal_Events.ACTIONBAR_SLOT_CHANGED()
	TryEnable()
end

function GodzillaHeal_Events.PLAYER_LOGIN()
	TryEnable()
end

function GodzillaHeal_EnabledOnlyEvents.SPELLCAST_START()
	if GodzillaHeal.State == State_Precast then
		GodzillaHeal.State = State_GodzillaCasting
	else
		GodzillaHeal.State = State_Casting
	end
	GodzillaHeal.CastTime = tonumber(arg2)
end

local function OnCastStop()
	GodzillaHeal.LastTarget = nil
	GodzillaHeal.State = State_Idle
end

function GodzillaHeal_EnabledOnlyEvents.SPELLCAST_STOP()
	OnCastStop()
end

function GodzillaHeal_EnabledOnlyEvents.SPELLCAST_INTERRUPTED()
	OnCastStop()
end

function GodzillaHeal_EnabledOnlyEvents.SPELLCAST_FAILED()
	OnCastStop()
end

function GodzillaHeal_EnabledOnlyEvents.UI_ERROR_MESSAGE()
	if arg1 == "Target not in line of sight" then
		if GodzillaHeal.State == State_Precast or GodzillaHeal.State == State_GodzillaCasting then
			BlacklistLastTarget()
		end
	end
end

function GodzillaHeal_OnEvent(event)
	local handler = GodzillaHeal_Events[event]
	if handler ~= nil then
		 handler()
	end

	if not GodzillaHeal.Enabled then return end

	handler = GodzillaHeal_EnabledOnlyEvents[event]
	if handler ~= nil then
		handler()
	end

end


