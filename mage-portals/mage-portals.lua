-- mage-portals.lua
-- WoW Classic (Anniversary realms): auto-invite people who ask "WTB port" in /yell or /1 (channel 1).

MagePortalsDB = MagePortalsDB or {}

local ADDON_NAME = ...

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99%s|r: %s"):format(ADDON_NAME, tostring(msg)))
end

local function EnsureDefaults()
  if MagePortalsDB.enabled == nil then
    MagePortalsDB.enabled = true
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

local function MsgHasWTBPort(msg)
  if type(msg) ~= "string" then return false end
  local s = msg:lower()

  -- Word-boundary matches to avoid "airport" etc.
  local hasWTB = s:find("%f[%a]wtb%f[%A]") ~= nil
  local hasPort = s:find("%f[%a]port%f[%A]") ~= nil
  return hasWTB and hasPort
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
  if not MagePortalsDB.enabled then return false end
  if type(sender) ~= "string" or sender == "" then return false end

  local me = UnitName("player")
  if me and sender:find("^" .. me) then
    return false
  end

  local short = NormalizeSender(sender)

  -- If they're already with us, skip.
  if UnitInParty(short) or UnitInRaid(short) then
    return false
  end

  local now = GetTime and GetTime() or 0
  local throttle = tonumber(MagePortalsDB.inviteThrottleSeconds) or 60
  local last = recentInvites[short]
  if last and now - last < throttle then
    return false
  end

  recentInvites[short] = now
  return true
end

local function TryInvite(sender, reason, portalRequest)
  local short = NormalizeSender(sender)
  InviteUnit(short)
  Print(("Invited %s (%s)"):format(short, reason))
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

local function ApplyEnabledState()
  f:UnregisterEvent("CHAT_MSG_YELL")
  f:UnregisterEvent("CHAT_MSG_CHANNEL")
  f:UnregisterEvent("TRADE_SHOW")
  f:UnregisterEvent("TRADE_CLOSED")

  if MagePortalsDB.enabled then
    f:RegisterEvent("CHAT_MSG_YELL")
    f:RegisterEvent("CHAT_MSG_CHANNEL") -- we'll filter to channel 1 in handler
    if AnyTradeFeatureEnabled() then
      f:RegisterEvent("TRADE_SHOW")
      f:RegisterEvent("TRADE_CLOSED")
    end
  end
end

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")

f:SetScript("OnEvent", function(_, event, ...)
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
    if not MsgHasWTBPort(msg) then return end
    if not CanAttemptInvite(sender) then return end
    TryInvite(sender, "yell", GetRequestedPortalFromMsg(msg))
    return
  end

  if event == "CHAT_MSG_CHANNEL" then
    -- CHAT_MSG_CHANNEL args vary slightly across versions; the 8th arg is channel number in Classic.
    local msg, sender, _, channelString, _, _, _, channelNumber = ...
    channelNumber = tonumber(channelNumber)

    -- Only /1 (usually General)
    if channelNumber ~= 1 then return end

    if not MsgHasWTBPort(msg) then return end
    if not CanAttemptInvite(sender) then return end
    TryInvite(sender, ("channel %s"):format(channelString or "1"), GetRequestedPortalFromMsg(msg))
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
    Print(("Status: %s (throttle=%ss, autotrade=%s, tradebutton=%s, portalbutton=%s)"):format(
      MagePortalsDB.enabled and "on" or "off",
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


