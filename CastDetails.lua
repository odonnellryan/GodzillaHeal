--
--  CastDetails V1
--  This is a library that provides a more complete SPELLCAST_START event by hooking into
--  all possible ways to iniate a spell cast.
--
--  By Xut@Valkryie-WoW
--  
--  function MyHandler(cast)
--  	cast.Spell
--		cast.Rank
--		cast.Duration
--		cast.Target
--  end
--
--  CastDetails.RegisterHandler(MyHandler)
--



--
--  Collection of tables to determine if spells are helpful/harmful spells
--  I need this only when auto self cast is on. Actually, this part isn't done yet.
--  This library doesn't check these values yet. So it's not working well with self cast.
--

local MaxRanks;

local NoTargetSpells = {
	'Tranquility',
	'Prayer of Healing',
	'Blizzard',
	'Hurricane',
	'Rain of Fire'
}

local SelfCastSpells = {
	'Desperate Prayer',
	'Divine Shield',
	'Nature\'s Grasp',
	'Life Tap',
	'Demon Armor'
}

local HelpfulSpells = {
	-- Priest
	'Flash Heal',
	'Lesser Heal',
	'Renew',
	'Greater Heal',
	'Heal',
	'Abolish Disease',
	'Cure Disease',
	'Divine Spirit',
	'Power Word: Fortitude',
	'Power Word: Shield',
	'Prayer of Spirit',
	'Prayer of Fortitude',
	-- Pally
	'Blessing of Might',
	'Holy Light',
	'Flash of Light',
	'Purify',
	'Cleanse',
	'Blessing of Protection',
	'Lay on Hands',
	'Redemption',
	'Blessing of Wisdom',
	'Divine Protection',
	'Blessing of Freedom',
	'Blessing of Kings',
	'Blessing of Salvation',
	'Blessing of Sacrifice',
	'Divine Intervention',
	'Holy Shock',
	'Greater Blessing of Might',
	'Greater Blessing of Wisdom',
	'Greater Blessing of Salvation',
	'Greater Blessing of Sanctuary',
	'Greater Blessing of Kings',
	-- Druid
	'Healing Touch',
	'Rejuvenation',
	'Mark of the Wild',
	'Regrowth',
	'Cure Poison',
	'Rebirth',
	'Abolish Poison',
	'Gift of the Wild',
	'Thorns',
	-- Warlock
	'Unending Breath',
	'Ritual of Summoning',
	'Detect Lesser Invisibility'
}

local HealsOverTime = {
	'Rejuvenation',
	'Renew'
}

local function ContainsKey(table, element)
 	for _, value in pairs(table) do
		if value == element then
			return true
		end
	end
	return false
end

local function IsNoTargetSpell(spell)
	return ContainsKey(NoTargetSpells, spell)
end

local function IsSelfCastSpell(spell)
	return ContainsKey(SelfCastSpells, spell)
end

local function IsHelpfulSpell(spell)
	return ContainsKey(HelpfulSpells, spell)
end

local function IsHealOverTime(spellName)
	return ContainsKey(HealsOverTime, spellName)
end

local function DebugCast(cast)
	if cast.Rank then
		DEFAULT_CHAT_FRAME:AddMessage("Casting " .. cast.Spell .. " (Rank " .. cast.Rank .. ") on " .. cast.Target)
	else
		DEFAULT_CHAT_FRAME:AddMessage("Casting " .. cast.Spell)
	end
end

local function CallAll(cast)
	if (cast.Spell == nil) then return end
	if CastDetails.Debug then
		DebugCast(cast)
	end
	for _, handler in CastDetails.Handlers do
		handler(cast)
	end
end

local function OnSpellCast()
	-- 
	if CastDetails.Cast ~= nil then end

	local cast = CastDetails.PendingCast
	local duration = arg1
	if duration == nil then duration = 0 end
	cast.Duration = duration
	-- If we have no target at this point, then the spellcast must be the result of a click on a player in the game
	-- At least, I believe this has to be true. Unsure.
	if cast.Target == nil then cast.Target = CastDetails.LastMouseover end

	CastDetails.Cast = CastDetails.PendingCast
	CallAll(cast)
	CastDetails.PendingCast = nil
end

local function ProbeRanks()
	MaxRanks = {}
	for i = 1, 160 do
		spellName, rankText = GetSpellName(i, "spell")
		if rankText ~= nil then
			_, _, rank = string.find(rankText, "Rank (%d)")
			if rank == nil then rank = 1 end
			rank = tonumber(rank)
			local cur = MaxRanks[spellName]
			if cur == nil or rank > cur then
				MaxRanks[spellName] = rank
			end
		end
	end
end

local function OnEvent()
	if event == "SPELLCAST_START" then
		if CastDetails.PendingCast ~= nil then
			OnSpellCast()
		end
	elseif event == "SPELLCAST_STOP" or event == "SPELLCAST_INTERRUPTED" or event == "SPELLCAST_FAILED" then
		-- Always send cancel, even if as the result of a successful cast.
		if CastDetails.Cast ~= nil then
			CastDetails.Cast = nil
		end
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		CastDetails.LastMouseover = UnitName("mouseover")
	elseif event == "PLAYER_LOGIN" then
		ProbeRanks()
	end
end

local function GetMaxRank(spell)
	return MaxRanks[spell]
end

local function IsSelfCastOn()
	return GetCVar("autoSelfCast") == "1"
end

local function ParseCast(spell)
	local _, _, spellName, rankText = string.find(spell, "^([%a%s]+)(%b())$")
	local rank
	if spellName == nil then
		spellName = spell
		rank = GetMaxRank(spellName)
	else
		_, _, rank = string.find(rankText, "Rank (%d)")
	end
	return spellName, rank
end

--
--  Called in every spell cast hook.
--  The idea is that if the hooked function (e.g. UseAction) succeeds,
--  we'll soon after receive a SPELLCAST_START event. This means that for
--  this addon to be accurate, the function that causes the spellcast must
--  be the last one called before the event. I'm pretty sure this isn't guaranteed
--  to be true; it's possible that OnCast will be called once, which causes
--  the spellcast, and then quickly again before the event is raised.
--  This means the cast information may be wrong, e.g. wrong spell or rank.
--  But it seems unlikely to me, esp. because a player is probably spamming
--  the same spell anyway, so it would've been the same regardless. It's hard
--  to find information about any guarantees that do or don't exist in the API,
--  and even if there were I suspect it would also depend on the server.
--
local function OnCast(spellName, rank, targetOverride)
	if rank ~= nil then
		rank = tonumber(rank)
	end

	local target = targetOverride
	if target == nil and UnitExists("target") then
		-- If auto self cast isn't on, then the target is for sure the right choice.
		-- If it is on, then benefical spells may end up targetting the player instead of the
		-- target. It just depends on the type of spell and whether or not the unit can receive
		-- benefical spells. Luckily UnitCanAssist does the second part, 
		if not IsSelfCastOn() then
			target = UnitName("target")
		end
	end
		--UnitIsFriend("player", "target") then  end
	if target == nil and IsSelfCastOn() then target = UnitName("player") end

	local cast = {}
	cast.Spell = spellName
	cast.Rank = rank
	cast.Target = target
	CastDetails.PendingCast = cast
end

local function CastSpellNew(spellId, bookType)
	-- Not supporting this yet (stupid function)
	CastDetails.PendingCast = nil
	CastDetails.CastSpell(spellId, bookType)
end

local function CastSpellByNameNew(spell, self)
	local spellName, rank = ParseCast(spell)
	local target = nil
	if self then target = UnitName("Player") end -- Set target override
	OnCast(spellName, rank, self)
	CastDetails.CastSpellByName(spell)
end

local function UseActionNew(action)
	if GetActionText(action) == nil then -- Test if not macro
		CastDetails.Tooltip:SetAction(action)
		local spellName = CastDetailsTooltipTextLeft1:GetText()
		local rankText = CastDetailsTooltipTextRight1:GetText()
		local rank
		if rankText ~= nil then
			_, _, rank = string.find(rankText, "Rank (%d)")
		end
		OnCast(spellName, rank)
	end
	CastDetails.UseAction(action)
end

--
--  Usually called while spell is waiting targeting.
--
local function SpellTargetUnitNew(unit)
	if CastDetails.PendingCast ~= nil then
		CastDetails.PendingCast.Target = UnitName(unit)
	end
	CastDetails.SpellTargetUnit(unit)
end

local function TargetUnitNew(unit)
	if CastDetails.PendingCast ~= nil then
		CastDetails.PendingCast.Target = UnitName(unit)
	end
	CastDetails.TargetUnit(unit)
end

local function RegisterHandler(handler)
	table.insert(CastDetails.Handlers, handler)
end

local function PlayerHasSpell(cast)
	local spellName, _ = ParseCast(cast)
	return GetMaxRank(spellName) ~= nil;
end

local function Initialize()
	CastDetails.Handlers = {}
	CastDetails.CastSpellByName = CastSpellByName
	CastDetails.UseAction = UseAction
	CastDetails.CastSpell = CastSpell
	CastDetails.SpellTargetUnit = SpellTargetUnit
	CastDetails.TargetUnit = TargetUnit
	CastDetails.RegisterHandler = RegisterHandler
	CastDetails.ParseCast = ParseCast
	CastDetails.IsHealOverTime = IsHealOverTime
	CastDetails.PlayerHasSpell = PlayerHasSpell

	CastDetails.Debug = false

	SLASH_CASTDETAILS1 = "/cddebug"
	SlashCmdList["CASTDETAILS"] = function(msg) 
		CastDetails.Debug = not CastDetails.Debug
		if CastDetails.Debug then
			DEFAULT_CHAT_FRAME:AddMessage("Debugging is on")
		else
			DEFAULT_CHAT_FRAME:AddMessage("Debugging is off")
		end
	end

	local tooltip = CreateFrame("GameTooltip", "CastDetailsTooltip", nil, "GameTooltipTemplate");
	tooltip:SetOwner(WorldFrame, "ANCHOR_NONE");
	CastDetails.Tooltip = tooltip

	UseAction = UseActionNew
	CastSpell = CastSpellNew
	CastSpellByName = CastSpellByNameNew
	SpellTargetUnit = SpellTargetUnitNew
	TargetUnit = TargetUnitNew

	-- Do this last
	local f = CreateFrame("FRAME")
	f:SetScript("OnEvent", OnEvent)
	f:RegisterEvent("SPELLCAST_START")
	f:RegisterEvent("SPELLCAST_STOP")
	f:RegisterEvent("SPELLCAST_INTERRUPTED")
	f:RegisterEvent("SPELLCAST_FAILED")
	f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
	f:RegisterEvent("PLAYER_LOGIN")
end

if not CastDetails then
	CastDetails = {}
	Initialize()
end
