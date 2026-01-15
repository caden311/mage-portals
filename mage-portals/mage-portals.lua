-- mage-portals.lua
-- WoW Classic (Anniversary realms): auto-invite people who ask "WTB port" in /yell or /1 (channel 1).

MagePortalsDB = MagePortalsDB or {}

local ADDON_NAME = ...

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99%s|r: %s"):format(ADDON_NAME, tostring(msg)))
end

local function Debug(level, msg)
  level = tonumber(level) or 1
  local dbLevel = tonumber(MagePortalsDB and MagePortalsDB.debugLevel) or 0
  if dbLevel < level then return end
  Print(("debug[%d]: %s"):format(level, tostring(msg)))
end

local function EnsureDefaults()
  if MagePortalsDB.enabled == nil then
    MagePortalsDB.enabled = true
  end

  -- debug logging (0=off, 1=basic, 2=verbose)
  if MagePortalsDB.debugLevel == nil then
    MagePortalsDB.debugLevel = 0
  end

  -- listen to /2 (Trade) as well as /1; off by default since we can't verify location pre-invite
  if MagePortalsDB.listenChannel2 == nil then
    MagePortalsDB.listenChannel2 = false
  end

  -- seconds to ignore repeated triggers from the same player
  if MagePortalsDB.inviteThrottleSeconds == nil then
    MagePortalsDB.inviteThrottleSeconds = 60
  end

  -- attempt to open trade automatically when invitee is in trade range
  if MagePortalsDB.autoTrade == nil then
    MagePortalsDB.autoTrade = false
  end

  -- how often we poll to see if the invitee is in trade range
  if MagePortalsDB.tradePollSeconds == nil then
    MagePortalsDB.tradePollSeconds = 0.5
  end

  -- stop watching after N seconds
  if MagePortalsDB.tradeTimeoutSeconds == nil then
    MagePortalsDB.tradeTimeoutSeconds = 180
  end

  -- show a clickable button when the client blocks automatic trade
  if MagePortalsDB.showTradeButton == nil then
    MagePortalsDB.showTradeButton = false
  end

  -- show a clickable portal cast button when trade opens
  if MagePortalsDB.showPortalButton == nil then
    MagePortalsDB.showPortalButton = false
  end
end

local recentInvites = {} ---@type table<string, number>
local recentTradeAttempts = {} ---@type table<string, number>

local pendingTradeName ---@type string|nil
local pendingTradeStartedAt ---@type number|nil
local tradeTicker ---@type any
local tradeButton ---@type Button|nil
local portalButton ---@type Button|nil
local lastInviteAttempt ---@type { name: string|nil, at: number|nil, reason: string|nil }
lastInviteAttempt = { name = nil, at = nil, reason = nil }

-- last known request per player (set when they trigger the invite)
-- key: short player name, value: { spell: string, dest: string, requestedAt: number }
local pendingPortalRequests = {} ---@type table<string, {spell: string, dest: string, requestedAt: number}>

local function NormalizeSender(sender)
  -- Strip realm if present (e.g. "Name-Realm" -> "Name")
  if type(Ambiguate) == "function" then
    return Ambiguate(sender, "short")
  end
  return sender
end

local function MsgHasPortalRequest(msg)
  if type(msg) ~= "string" then return false end
  local s = msg:lower()

  -- Word-boundary matches to avoid "airport" etc.
  -- Trigger words: WTB or LF
  local hasWTB = s:find("%f[%a]wtb%f[%A]") ~= nil
  local hasLF = s:find("%f[%a]lf%f[%A]") ~= nil

  -- Portal words: port/ports OR portal/portals
  local hasPort =
    (s:find("%f[%a]ports?%f[%A]") ~= nil) or
    (s:find("%f[%a]portals?%f[%A]") ~= nil)

  return (hasWTB or hasLF) and hasPort
end

local function GetRequestedPortalFromMsg(msg)
  if type(msg) ~= "string" then return nil end
  local s = msg:lower()

  local function has(pat)
    return s:find(pat) ~= nil
  end

  -- Shattrath (shat/shatt/shattrath)
  if has("%f[%a]shattrath%f[%A]") or has("%f[%a]shatt%f[%A]") or has("%f[%a]shat%f[%A]") then
    return { dest = "Shattrath", spell = "Portal: Shattrath" }
  end

  -- Silvermoon (sm/silvermoon)
  if has("%f[%a]silvermoon%f[%A]") or has("%f[%a]sm%f[%A]") then
    return { dest = "Silvermoon", spell = "Portal: Silvermoon" }
  end

  -- Orgrimmar (org/orgrimmar)
  if has("%f[%a]orgrimmar%f[%A]") or has("%f[%a]org%f[%A]") then
    return { dest = "Orgrimmar", spell = "Portal: Orgrimmar" }
  end

  -- Thunder Bluff (tb/thunderbluff/thunder bluff)
  if has("%f[%a]thunderbluff%f[%A]") or has("%f[%a]tb%f[%A]") or has("thunder%s+bluff") then
    return { dest = "Thunder Bluff", spell = "Portal: Thunder Bluff" }
  end

  -- Undercity (uc/undercity)
  if has("%f[%a]undercity%f[%A]") or has("%f[%a]uc%f[%A]") then
    return { dest = "Undercity", spell = "Portal: Undercity" }
  end

  return nil
end

local function FindGroupUnitByName(shortName)
  if type(shortName) ~= "string" or shortName == "" then return nil end

  -- Party
  for i = 1, 4 do
    local unit = "party" .. i
    if UnitExists(unit) then
      local n = UnitName(unit)
      if n and NormalizeSender(n) == shortName then
        return unit
      end
    end
  end

  -- Raid (just in case)
  for i = 1, 40 do
    local unit = "raid" .. i
    if UnitExists(unit) then
      local n = UnitName(unit)
      if n and NormalizeSender(n) == shortName then
        return unit
      end
    end
  end

  return nil
end

local function AnyTradeFeatureEnabled()
  return MagePortalsDB.autoTrade or MagePortalsDB.showTradeButton or MagePortalsDB.showPortalButton
end

local function CanSendInvite()
  -- In parties/raids, only leader/assist can invite.
  if IsInRaid and IsInRaid() then
    if UnitIsGroupLeader and UnitIsGroupLeader("player") then return true end
    if UnitIsGroupAssistant and UnitIsGroupAssistant("player") then return true end
    return false, "not raid leader/assistant"
  end

  if IsInGroup and IsInGroup() then
    if UnitIsGroupLeader and UnitIsGroupLeader("player") then
      -- Party size limit is 5 (including you)
      if GetNumGroupMembers and GetNumGroupMembers() >= 5 then
        return false, "party full"
      end
      return true
    end
    return false, "not party leader"
  end

  return true
end

local function InTradeRange(unit)
  if not unit or not UnitExists(unit) then return false end
  if type(CheckInteractDistance) ~= "function" then return false end

  -- Classic constants vary by client; try the common “trade” distances.
  return (CheckInteractDistance(unit, 2) == true) or (CheckInteractDistance(unit, 1) == true)
end

local function EnsureTradeButton()
  if tradeButton or type(CreateFrame) ~= "function" then return end
  if not UIParent then return end

  -- SecureActionButton requires a click from the user; it’s a safe fallback when auto-trade is blocked.
  tradeButton = CreateFrame("Button", "MagePortalsTradeButton", UIParent, "SecureActionButtonTemplate,BackdropTemplate")
  tradeButton:SetSize(240, 44)
  tradeButton:SetPoint("CENTER", UIParent, "CENTER", 0, -180)

  if tradeButton.SetBackdrop then
    tradeButton:SetBackdrop({
      bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    tradeButton:SetBackdropColor(0, 0, 0, 0.85)
  end

  local text = tradeButton:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  text:SetPoint("CENTER")
  tradeButton._text = text

  tradeButton:SetAttribute("type", "macro")
  tradeButton:Hide()
end

local function EnsurePortalButton()
  if portalButton or type(CreateFrame) ~= "function" then return end
  if not UIParent then return end

  portalButton = CreateFrame("Button", "MagePortalsPortalButton", UIParent, "SecureActionButtonTemplate,BackdropTemplate")
  portalButton:SetSize(240, 44)
  portalButton:SetPoint("CENTER", UIParent, "CENTER", 0, -230)

  if portalButton.SetBackdrop then
    portalButton:SetBackdrop({
      bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    portalButton:SetBackdropColor(0, 0, 0, 0.85)
  end

  local text = portalButton:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  text:SetPoint("CENTER")
  portalButton._text = text

  portalButton:SetAttribute("type", "macro")
  portalButton:Hide()
end

local function HideTradeButton()
  if tradeButton then tradeButton:Hide() end
end

local function HidePortalButton()
  if portalButton then portalButton:Hide() end
end

local function ShowTradeButtonFor(name)
  if not MagePortalsDB.showTradeButton then return end
  EnsureTradeButton()
  if not tradeButton or not tradeButton._text then return end

  tradeButton._text:SetText(("Click to trade: %s"):format(name))
  tradeButton:SetAttribute("macrotext", ("/targetexact %s\n/trade"):format(name))
  tradeButton:Show()
end

local function ShowPortalButtonFor(spellName, dest)
  if MagePortalsDB.showPortalButton == false then return end
  EnsurePortalButton()
  if not portalButton or not portalButton._text then return end
  portalButton._text:SetText(("Click to cast portal: %s"):format(dest))
  portalButton:SetAttribute("macrotext", ("/cast %s"):format(spellName))
  portalButton:Show()
end

local function StopWatchingTrade()
  pendingTradeName = nil
  pendingTradeStartedAt = nil
  if tradeTicker and tradeTicker.Cancel then
    tradeTicker:Cancel()
  end
  tradeTicker = nil
  HideTradeButton()
  HidePortalButton()
end

local function TryInitiateTrade(shortName, unit)
  if not MagePortalsDB.autoTrade then
    ShowTradeButtonFor(shortName)
    return
  end

  local now = GetTime and GetTime() or 0
  local last = recentTradeAttempts[shortName]
  if last and now - last < 5 then
    return
  end
  recentTradeAttempts[shortName] = now

  if type(InitiateTrade) ~= "function" then
    ShowTradeButtonFor(shortName)
    return
  end

  -- InitiateTrade can be protected/blocked depending on client restrictions; attempt it,
  -- then fall back to a click button if TradeFrame doesn't appear shortly after.
  InitiateTrade(unit)
  if C_Timer and C_Timer.After then
    C_Timer.After(0.15, function()
      if TradeFrame and TradeFrame.IsShown and TradeFrame:IsShown() then
        HideTradeButton()
        StopWatchingTrade()
      else
        ShowTradeButtonFor(shortName)
      end
    end)
  end
end

local function StartWatchingTradeFor(shortName)
  if not shortName or shortName == "" then return end

  pendingTradeName = shortName
  pendingTradeStartedAt = GetTime and GetTime() or 0

  if tradeTicker and tradeTicker.Cancel then
    tradeTicker:Cancel()
  end

  local poll = tonumber(MagePortalsDB.tradePollSeconds) or 0.5
  if poll < 0.1 then poll = 0.1 end

  if not (C_Timer and C_Timer.NewTicker) then
    -- No ticker available; degrade gracefully (no autotrade).
    return
  end

  tradeTicker = C_Timer.NewTicker(poll, function()
    if not MagePortalsDB.enabled then
      StopWatchingTrade()
      return
    end

    if not AnyTradeFeatureEnabled() then
      StopWatchingTrade()
      return
    end

    if not pendingTradeName then
      StopWatchingTrade()
      return
    end

    local now = GetTime and GetTime() or 0
    local timeout = tonumber(MagePortalsDB.tradeTimeoutSeconds) or 180
    if pendingTradeStartedAt and timeout > 0 and now - pendingTradeStartedAt > timeout then
      StopWatchingTrade()
      return
    end

    local unit = FindGroupUnitByName(pendingTradeName)
    if not unit then return end
    if not InTradeRange(unit) then
      HideTradeButton()
      HidePortalButton()
      return
    end

    TryInitiateTrade(pendingTradeName, unit)
  end)
end

local function CanAttemptInvite(sender)
  if not MagePortalsDB.enabled then return false, "addon disabled" end
  if type(sender) ~= "string" or sender == "" then return false, "missing sender" end

  local me = UnitName("player")
  if me and sender:find("^" .. me) then
    return false, "sender is player"
  end

  local short = NormalizeSender(sender)

  -- If they're already with us, skip.
  if UnitInParty(short) or UnitInRaid(short) then
    return false, "already in group"
  end

  local now = GetTime and GetTime() or 0
  local throttle = tonumber(MagePortalsDB.inviteThrottleSeconds) or 60
  local last = recentInvites[short]
  if last and now - last < throttle then
    local remaining = math.max(0, throttle - (now - last))
    return false, ("throttled (%.1fs left)"):format(remaining)
  end

  recentInvites[short] = now
  return true, nil
end

local function TryInvite(sender, reason, portalRequest)
  local short = NormalizeSender(sender)
  local ok, why = CanSendInvite()
  if not ok then
    Debug(1, ("Invite attempt blocked (%s): %s"):format(short, tostring(why)))
    Print(("Can't invite %s (%s)."):format(short, tostring(why)))
    return
  end

  if type(InviteUnit) ~= "function" then
    Debug(1, ("InviteUnit API missing; cannot invite %s"):format(short))
    Print(("Can't invite %s (InviteUnit unavailable)."):format(short))
    return
  end

  if (tonumber(MagePortalsDB.debugLevel) or 0) >= 1 then
    local inGroup = (IsInGroup and IsInGroup()) and "yes" or "no"
    local inRaid = (IsInRaid and IsInRaid()) and "yes" or "no"
    local isLeader = (UnitIsGroupLeader and UnitIsGroupLeader("player")) and "yes" or "no"
    local isAssist = (UnitIsGroupAssistant and UnitIsGroupAssistant("player")) and "yes" or "no"
    local members = (GetNumGroupMembers and GetNumGroupMembers()) or 0
    local inCombat = (InCombatLockdown and InCombatLockdown()) and "yes" or "no"
    Debug(1, ("Invite attempt -> %s (reason=%s) state={group=%s raid=%s leader=%s assist=%s members=%s combatLock=%s}"):format(
      short, tostring(reason), inGroup, inRaid, isLeader, isAssist, tostring(members), inCombat
    ))
  end
  lastInviteAttempt.name = short
  lastInviteAttempt.at = GetTime and GetTime() or 0
  lastInviteAttempt.reason = tostring(reason)

  InviteUnit(short)
  Print(("Invite attempt sent to %s (%s)"):format(short, reason))
  if portalRequest and portalRequest.spell and portalRequest.dest then
    pendingPortalRequests[short] = {
      spell = portalRequest.spell,
      dest = portalRequest.dest,
      requestedAt = GetTime and GetTime() or 0,
    }
  end
  if AnyTradeFeatureEnabled() then
    StartWatchingTradeFor(short)
  end
end

local f = CreateFrame("Frame")

-- forward declare so SetAddonEnabled can call it safely
local ApplyEnabledState

local function SetAddonEnabled(enabled)
  MagePortalsDB.enabled = enabled and true or false

  if MagePortalsDB.enabled then
    ApplyEnabledState()
    if MagePortalsDB.showTradeButton then
      EnsureTradeButton()
    end
    if MagePortalsDB.showPortalButton then
      EnsurePortalButton()
    end
  else
    ApplyEnabledState()
    StopWatchingTrade()
    HideTradeButton()
    HidePortalButton()
  end
end

ApplyEnabledState = function()
  f:UnregisterEvent("CHAT_MSG_YELL")
  f:UnregisterEvent("CHAT_MSG_SAY")
  f:UnregisterEvent("CHAT_MSG_WHISPER")
  f:UnregisterEvent("CHAT_MSG_CHANNEL")
  f:UnregisterEvent("TRADE_SHOW")
  f:UnregisterEvent("TRADE_CLOSED")
  f:UnregisterEvent("CHAT_MSG_SYSTEM")
  f:UnregisterEvent("UI_ERROR_MESSAGE")

  if MagePortalsDB.enabled then
    f:RegisterEvent("CHAT_MSG_YELL")
    f:RegisterEvent("CHAT_MSG_SAY")
    f:RegisterEvent("CHAT_MSG_WHISPER")
    f:RegisterEvent("CHAT_MSG_CHANNEL") -- we'll filter to channel 1 in handler
    -- Always register these; we only print when debug is enabled.
    f:RegisterEvent("CHAT_MSG_SYSTEM")
    f:RegisterEvent("UI_ERROR_MESSAGE")
    if AnyTradeFeatureEnabled() then
      f:RegisterEvent("TRADE_SHOW")
      f:RegisterEvent("TRADE_CLOSED")
    end
  end
end

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")

f:SetScript("OnEvent", function(_, event, ...)
  Debug(2, ("Event: %s"):format(event))
  if event == "ADDON_LOADED" then
    local addonName = ...
    if addonName ~= ADDON_NAME then return end
    EnsureDefaults()
    return
  end

  if event == "PLAYER_LOGIN" then
    EnsureDefaults()
    ApplyEnabledState()
    if MagePortalsDB.showTradeButton then
      EnsureTradeButton()
    end
    if MagePortalsDB.showPortalButton then
      EnsurePortalButton()
    end
    Print(("Loaded (%s). Type /mp help."):format(MagePortalsDB.enabled and "on" or "off"))
    return
  end

  if event == "CHAT_MSG_YELL" then
    local msg, sender = ...
    Debug(2, ("YELL from %s: %q"):format(tostring(sender), tostring(msg)))
    if not MsgHasPortalRequest(msg) then
      Debug(2, "Ignored: missing portal request keywords")
      return
    end
    local ok, why = CanAttemptInvite(sender)
    if not ok then
      Debug(1, ("Invite blocked for %s: %s"):format(NormalizeSender(sender), tostring(why)))
      return
    end
    TryInvite(sender, "yell", GetRequestedPortalFromMsg(msg))
    return
  end

  if event == "CHAT_MSG_SAY" then
    local msg, sender = ...
    Debug(2, ("SAY from %s: %q"):format(tostring(sender), tostring(msg)))
    if not MsgHasPortalRequest(msg) then
      Debug(2, "Ignored: missing portal request keywords")
      return
    end
    local ok, why = CanAttemptInvite(sender)
    if not ok then
      Debug(1, ("Invite blocked for %s: %s"):format(NormalizeSender(sender), tostring(why)))
      return
    end
    TryInvite(sender, "say", GetRequestedPortalFromMsg(msg))
    return
  end

  if event == "CHAT_MSG_WHISPER" then
    local msg, sender = ...
    Debug(2, ("WHISPER from %s: %q"):format(tostring(sender), tostring(msg)))
    if not MsgHasPortalRequest(msg) then
      Debug(2, "Ignored: missing portal request keywords")
      return
    end
    local ok, why = CanAttemptInvite(sender)
    if not ok then
      Debug(1, ("Invite blocked for %s: %s"):format(NormalizeSender(sender), tostring(why)))
      return
    end
    TryInvite(sender, "whisper", GetRequestedPortalFromMsg(msg))
    return
  end

  if event == "CHAT_MSG_CHANNEL" then
    -- CHAT_MSG_CHANNEL args vary slightly across versions; the 8th arg is channel number in Classic.
    local msg, sender, _, channelString, _, _, _, channelNumber = ...
    channelNumber = tonumber(channelNumber)

    -- /1 General always; optionally /2 Trade (opt-in).
    if channelNumber ~= 1 and not (channelNumber == 2 and MagePortalsDB.listenChannel2) then
      Debug(2, ("Ignored channel %s (%s)"):format(tostring(channelNumber), tostring(channelString)))
      return
    end

    Debug(2, ("CHANNEL %s (%s) from %s: %q"):format(tostring(channelNumber), tostring(channelString), tostring(sender), tostring(msg)))
    if not MsgHasPortalRequest(msg) then
      Debug(2, "Ignored: missing portal request keywords")
      return
    end
    local ok, why = CanAttemptInvite(sender)
    if not ok then
      Debug(1, ("Invite blocked for %s: %s"):format(NormalizeSender(sender), tostring(why)))
      return
    end
    TryInvite(sender, ("channel %s"):format(channelString or "1"), GetRequestedPortalFromMsg(msg))
    return
  end

  if event == "UI_ERROR_MESSAGE" then
    -- Args vary slightly; generally (messageType, message)
    local _, message = ...
    if (tonumber(MagePortalsDB.debugLevel) or 0) <= 0 then return end

    local now = GetTime and GetTime() or 0
    if lastInviteAttempt and lastInviteAttempt.at and (now - lastInviteAttempt.at) <= 3 then
      Debug(1, ("UI_ERROR_MESSAGE after inviting %s: %s"):format(tostring(lastInviteAttempt.name), tostring(message)))
    else
      Debug(2, ("UI_ERROR_MESSAGE: %s"):format(tostring(message)))
    end
    return
  end

  if event == "CHAT_MSG_SYSTEM" then
    local sysmsg = ...
    if (tonumber(MagePortalsDB.debugLevel) or 0) <= 0 then return end

    local now = GetTime and GetTime() or 0
    if lastInviteAttempt and lastInviteAttempt.at and (now - lastInviteAttempt.at) <= 5 then
      Debug(1, ("SYSTEM near invite(%s): %s"):format(tostring(lastInviteAttempt.name), tostring(sysmsg)))
    else
      Debug(2, ("SYSTEM: %s"):format(tostring(sysmsg)))
    end
    return
  end

  if event == "TRADE_SHOW" then
    HideTradeButton()
    -- When trade opens, show a click-to-cast portal button if we detected a destination.
    -- (Auto-casting spells is typically blocked; this keeps it reliable.)
    if MagePortalsDB.showPortalButton and pendingTradeName then
      local req = pendingPortalRequests[pendingTradeName]
      if req and req.spell and req.dest then
        ShowPortalButtonFor(req.spell, req.dest)
      else
        HidePortalButton()
      end
    else
      HidePortalButton()
    end
    return
  end

  if event == "TRADE_CLOSED" then
    HideTradeButton()
    StopWatchingTrade()
    return
  end
end)

SLASH_MAGEPORTALS1 = "/mp"
SLASH_MAGEPORTALS2 = "/mageportals"
SlashCmdList["MAGEPORTALS"] = function(input)
  input = (input or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

  if input == "" or input == "help" then
    Print("Commands:")
    Print("/mp on        - enable addon (auto-invite on; trade helpers depend on your settings)")
    Print("/mp off       - disable addon (stops invites + trade helpers)")
    Print("/mp status    - show current status")
    Print("/mp throttle N- ignore repeat triggers from same player for N seconds (default 60)")
    Print("/mp ch2 on|off - also listen in /2 (Trade) (default off)")
    Print("/mp debug off|on|0|1|2 - debug logging (0=off, 1=basic, 2=verbose)")
    Print("/mp testinvite Name - manually attempt an invite (debug helper)")
    Print("/mp autotrade on|off - attempt to auto-open trade when they are in range")
    Print("/mp tradebutton on|off - show a clickable trade button fallback")
    Print("/mp portalbutton on|off - show a clickable portal-cast button when trade opens")
    return
  end

  if input == "on" then
    SetAddonEnabled(true)
    Print("Enabled.")
    return
  end

  if input == "off" then
    SetAddonEnabled(false)
    Print("Disabled.")
    return
  end

  if input == "status" then
    Print(("Status: %s (ch2=%s, debug=%s, throttle=%ss, autotrade=%s, tradebutton=%s, portalbutton=%s)"):format(
      MagePortalsDB.enabled and "on" or "off",
      MagePortalsDB.listenChannel2 and "on" or "off",
      tostring(MagePortalsDB.debugLevel or 0),
      tostring(MagePortalsDB.inviteThrottleSeconds),
      MagePortalsDB.autoTrade and "on" or "off",
      MagePortalsDB.showTradeButton and "on" or "off",
      MagePortalsDB.showPortalButton and "on" or "off"
    ))
    return
  end

  local throttleN = input:match("^throttle%s+(%d+)$")
  if throttleN then
    MagePortalsDB.inviteThrottleSeconds = tonumber(throttleN) or 60
    Print(("Throttle set to %ss."):format(tostring(MagePortalsDB.inviteThrottleSeconds)))
    return
  end

  local autotradeToggle = input:match("^autotrade%s+(on|off)$")
  if autotradeToggle then
    MagePortalsDB.autoTrade = autotradeToggle == "on"
    if MagePortalsDB.enabled then
      ApplyEnabledState()
      if not AnyTradeFeatureEnabled() then
        StopWatchingTrade()
      end
    end
    Print(("Auto-trade %s."):format(MagePortalsDB.autoTrade and "enabled" or "disabled"))
    return
  end

  local ch2Toggle = input:match("^(ch2|channel2)%s+(on|off)$")
  if ch2Toggle then
    local _, onoff = input:match("^(ch2|channel2)%s+(on|off)$")
    MagePortalsDB.listenChannel2 = onoff == "on"
    Print(("/2 (Trade) listening %s."):format(MagePortalsDB.listenChannel2 and "enabled" or "disabled"))
    return
  end

  local debugArg = input:match("^debug%s+(.+)$")
  if debugArg then
    debugArg = debugArg:gsub("^%s+", ""):gsub("%s+$", "")
    if debugArg == "on" then
      MagePortalsDB.debugLevel = 1
    elseif debugArg == "off" then
      MagePortalsDB.debugLevel = 0
    else
      local n = tonumber(debugArg)
      if n == nil then
        Print("Usage: /mp debug off|on|0|1|2")
        return
      end
      if n < 0 then n = 0 end
      if n > 2 then n = 2 end
      MagePortalsDB.debugLevel = n
    end
    Print(("Debug level set to %s."):format(tostring(MagePortalsDB.debugLevel)))
    return
  end

  local testInviteName = input:match("^testinvite%s+(.+)$")
  if testInviteName then
    testInviteName = testInviteName:gsub("^%s+", ""):gsub("%s+$", "")
    if testInviteName == "" then
      Print("Usage: /mp testinvite Name")
      return
    end
    -- Debug helper: attempt invite without keyword matching.
    TryInvite(testInviteName, "manual", nil)
    return
  end

  local tradebuttonToggle = input:match("^tradebutton%s+(on|off)$")
  if tradebuttonToggle then
    MagePortalsDB.showTradeButton = tradebuttonToggle == "on"
    if not MagePortalsDB.showTradeButton then
      HideTradeButton()
      if MagePortalsDB.enabled then
        ApplyEnabledState()
        if not AnyTradeFeatureEnabled() then
          StopWatchingTrade()
        end
      end
    else
      EnsureTradeButton()
      if MagePortalsDB.enabled then
        ApplyEnabledState()
      end
    end
    Print(("Trade button %s."):format(MagePortalsDB.showTradeButton and "enabled" or "disabled"))
    return
  end

  local portalbuttonToggle = input:match("^portalbutton%s+(on|off)$")
  if portalbuttonToggle then
    MagePortalsDB.showPortalButton = portalbuttonToggle == "on"
    if not MagePortalsDB.showPortalButton then
      HidePortalButton()
      if MagePortalsDB.enabled then
        ApplyEnabledState()
        if not AnyTradeFeatureEnabled() then
          StopWatchingTrade()
        end
      end
    else
      EnsurePortalButton()
      if MagePortalsDB.enabled then
        ApplyEnabledState()
      end
    end
    Print(("Portal button %s."):format(MagePortalsDB.showPortalButton and "enabled" or "disabled"))
    return
  end

  Print(("Unknown command: %q (try /mp help)"):format(input))
end


