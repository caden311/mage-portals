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

  -- whisper the invitee a confirmation / destination message
  if MagePortalsDB.whisperOnInvite == nil then
    MagePortalsDB.whisperOnInvite = false
  end

  -- Channel listening toggles
  if MagePortalsDB.listenSay == nil then
    MagePortalsDB.listenSay = true
  end
  if MagePortalsDB.listenYell == nil then
    MagePortalsDB.listenYell = true
  end
  if MagePortalsDB.listenChannel1 == nil then
    MagePortalsDB.listenChannel1 = true
  end
  -- listen to /2 (Trade) as well as /1; off by default since we can't verify location pre-invite
  if MagePortalsDB.listenChannel2 == nil then
    MagePortalsDB.listenChannel2 = false
  end
  -- listen to whispers
  if MagePortalsDB.listenWhisper == nil then
    MagePortalsDB.listenWhisper = true
  end

  -- invite people who ask for mage water (LF/WTB water in public; any "water" in whispers); off by default
  if MagePortalsDB.inviteOnWater == nil then
    MagePortalsDB.inviteOnWater = false
  end

  -- seconds to ignore repeated triggers from the same player
  if MagePortalsDB.inviteThrottleSeconds == nil then
    MagePortalsDB.inviteThrottleSeconds = 60
  end

  -- minimap button settings
  if MagePortalsDB.minimap == nil then
    MagePortalsDB.minimap = { hide = false, angle = 225, x = -70, y = 70, version = 4 }
  end
  if MagePortalsDB.minimap.hide == nil then
    MagePortalsDB.minimap.hide = false
  end
  if MagePortalsDB.minimap.angle == nil then
    MagePortalsDB.minimap.angle = 225
  end
  if MagePortalsDB.minimap.x == nil then
    MagePortalsDB.minimap.x = -70
  end
  if MagePortalsDB.minimap.y == nil then
    MagePortalsDB.minimap.y = 70
  end
  if MagePortalsDB.minimap.version == nil then
    -- Migration: older versions could accidentally save a hidden icon while layout was broken.
    -- Make sure it shows once after upgrade; users can still hide it again intentionally.
    MagePortalsDB.minimap.hide = false
    MagePortalsDB.minimap.version = 4
  elseif MagePortalsDB.minimap.version < 4 then
    -- v4 migration: keep the icon shown after upgrades and ensure angle exists.
    MagePortalsDB.minimap.hide = false
    MagePortalsDB.minimap.angle = MagePortalsDB.minimap.angle or 225
    MagePortalsDB.minimap.version = 4
  end
end

local recentInvites = {} ---@type table<string, number>
local lastInviteAttempt ---@type { name: string|nil, at: number|nil, reason: string|nil }
lastInviteAttempt = { name = nil, at = nil, reason = nil }

local minimapButton ---@type Button|nil
local function UpdateMinimapButtonVisual() end -- forward declare
local function LayoutMinimapButton() end -- forward declare

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

local function MsgHasWaterRequest(msg, requireWTBLF)
  if type(msg) ~= "string" then return false end
  local s = msg:lower()

  -- Word-boundary matches to avoid "waterlord" etc.
  local hasWater =
    (s:find("%f[%a]water%f[%A]") ~= nil) or
    (s:find("%f[%a]waters%f[%A]") ~= nil)
  if not hasWater then return false end

  local hasWTB = s:find("%f[%a]wtb%f[%A]") ~= nil
  local hasLF = s:find("%f[%a]lf%f[%A]") ~= nil

  if requireWTBLF then
    return (hasWTB or hasLF)
  end

  -- In whispers, allow plain "water" without requiring WTB/LF.
  return true
end

-- When listening in /2 (Trade), be stricter to reduce false invites.
-- Only invite if:
-- - they ask for a port (WTB/LF + port/portal), AND
-- - they did NOT specify a "from <city>", OR they specified "from org".
-- If they ever specify a from-city and it's not Orgrimmar, ignore it (e.g. "from tb to uc").
local function MsgHasPortalRequest_Channel2(msg)
  if type(msg) ~= "string" then return false end
  local s = msg:lower()

  -- Require WTB or LF in /2.
  local hasWTB = s:find("%f[%a]wtb%f[%A]") ~= nil
  local hasLF = s:find("%f[%a]lf%f[%A]") ~= nil
  if not (hasWTB or hasLF) then return false end

  -- Require the port/portal word.
  local hasPort =
    (s:find("%f[%a]ports?%f[%A]") ~= nil) or
    (s:find("%f[%a]portals?%f[%A]") ~= nil)
  if not hasPort then return false end

  -- Don't invite people going *to* Orgrimmar in /2.
  local toOrg =
    (s:find("%f[%a]to%f[%A]%s+%f[%a]org%f[%A]") ~= nil) or
    (s:find("%f[%a]to%f[%A]%s+%f[%a]orgrimmar%f[%A]") ~= nil)
  if toOrg then return false end

  -- If they specify "from <city>", only allow if it's Orgrimmar.
  local function fromHas(pat)
    return s:find("from%s+" .. pat) ~= nil
  end

  -- If they specify "<city> to <city>" (without the word "from"), treat the first city as a source city.
  -- Example we want to reject: "wtb port tb to uc"
  local function srcBeforeToHas(pat)
    return s:find(pat .. "%s+%f[%a]to%f[%A]") ~= nil
  end

  local fromOrg = fromHas("%f[%a]org%f[%A]") or fromHas("%f[%a]orgrimmar%f[%A]")
  local fromOtherCity =
    fromHas("%f[%a]uc%f[%A]") or fromHas("%f[%a]undercity%f[%A]") or
    fromHas("%f[%a]tb%f[%A]") or fromHas("%f[%a]thunderbluff%f[%A]") or fromHas("thunder%s+bluff") or
    fromHas("%f[%a]shat%f[%A]") or fromHas("%f[%a]shatt%f[%A]") or fromHas("%f[%a]shattrath%f[%A]") or
    fromHas("%f[%a]sm%f[%A]") or fromHas("%f[%a]silvermoon%f[%A]") or
    fromHas("%f[%a]stonard%f[%A]")

  if fromOtherCity and not fromOrg then
    return false
  end

  -- Also reject implicit sources like "tb to uc" (any non-org city immediately before the word "to").
  local srcOtherCityTo =
    srcBeforeToHas("%f[%a]uc%f[%A]") or srcBeforeToHas("%f[%a]undercity%f[%A]") or
    srcBeforeToHas("%f[%a]tb%f[%A]") or srcBeforeToHas("%f[%a]thunderbluff%f[%A]") or srcBeforeToHas("thunder%s+bluff") or
    srcBeforeToHas("%f[%a]shat%f[%A]") or srcBeforeToHas("%f[%a]shatt%f[%A]") or srcBeforeToHas("%f[%a]shattrath%f[%A]") or
    srcBeforeToHas("%f[%a]sm%f[%A]") or srcBeforeToHas("%f[%a]silvermoon%f[%A]") or
    srcBeforeToHas("%f[%a]stonard%f[%A]")

  if srcOtherCityTo then
    return false
  end

  return true
end

local function MsgHasPortWord(msg)
  if type(msg) ~= "string" then return false end
  local s = msg:lower()
  return (s:find("%f[%a]ports?%f[%A]") ~= nil) or (s:find("%f[%a]portals?%f[%A]") ~= nil)
end

local function GetRequestedPortalFromMsg(msg)
  if type(msg) ~= "string" then return nil end
  local s = msg:lower()

  local function has(pat)
    return s:find(pat) ~= nil
  end

  -- Prefer explicit "to <city>" destination if present (e.g. "org to uc", "from org to tb").
  local function toHas(pat)
    return s:find("to%s+" .. pat) ~= nil
  end

  -- Shattrath (shat/shatt/shattrath)
  if toHas("%f[%a]shattrath%f[%A]") or toHas("%f[%a]shatt%f[%A]") or toHas("%f[%a]shat%f[%A]") then
    return { dest = "Shattrath", spell = "Portal: Shattrath" }
  end

  -- Silvermoon (sm/silvermoon)
  if toHas("%f[%a]silvermoon%f[%A]") or toHas("%f[%a]sm%f[%A]") then
    return { dest = "Silvermoon", spell = "Portal: Silvermoon" }
  end

  -- Stonard (stonard)
  if toHas("%f[%a]stonard%f[%A]") then
    return { dest = "Stonard", spell = "Portal: Stonard" }
  end

  -- Orgrimmar (org/orgrimmar)
  if toHas("%f[%a]orgrimmar%f[%A]") or toHas("%f[%a]org%f[%A]") then
    return { dest = "Orgrimmar", spell = "Portal: Orgrimmar" }
  end

  -- Thunder Bluff (tb/thunderbluff/thunder bluff)
  if toHas("%f[%a]thunderbluff%f[%A]") or toHas("%f[%a]tb%f[%A]") or s:find("to%s+thunder%s+bluff") then
    return { dest = "Thunder Bluff", spell = "Portal: Thunder Bluff" }
  end

  -- Undercity (uc/undercity)
  if toHas("%f[%a]undercity%f[%A]") or toHas("%f[%a]uc%f[%A]") then
    return { dest = "Undercity", spell = "Portal: Undercity" }
  end

  -- Shattrath (shat/shatt/shattrath)
  if has("%f[%a]shattrath%f[%A]") or has("%f[%a]shatt%f[%A]") or has("%f[%a]shat%f[%A]") then
    return { dest = "Shattrath", spell = "Portal: Shattrath" }
  end

  -- Silvermoon (sm/silvermoon)
  if has("%f[%a]silvermoon%f[%A]") or has("%f[%a]sm%f[%A]") then
    return { dest = "Silvermoon", spell = "Portal: Silvermoon" }
  end

  -- Stonard (stonard)
  if has("%f[%a]stonard%f[%A]") then
    return { dest = "Stonard", spell = "Portal: Stonard" }
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

local function SendInviteByName(name)
  -- Some clients expose global InviteUnit; others only expose C_PartyInfo.InviteUnit.
  if type(InviteUnit) == "function" then
    InviteUnit(name)
    return true, "InviteUnit"
  end
  if C_PartyInfo and type(C_PartyInfo.InviteUnit) == "function" then
    C_PartyInfo.InviteUnit(name)
    return true, "C_PartyInfo.InviteUnit"
  end
  return false, "no invite API (InviteUnit/C_PartyInfo.InviteUnit missing)"
end

local function WhisperInvitee(shortName, portalRequest, whisperOverride)
  if not MagePortalsDB.whisperOnInvite then return end
  if type(shortName) ~= "string" or shortName == "" then return end
  if type(SendChatMessage) ~= "function" then
    Debug(1, "SendChatMessage unavailable; can't whisper invitee")
    return
  end

  local msg
  if type(whisperOverride) == "string" and whisperOverride ~= "" then
    msg = whisperOverride
  elseif portalRequest and portalRequest.dest then
    msg = ("Let's get you to %s."):format(portalRequest.dest)
  else
    msg = "Where are you headed (org / tb / uc / shat / sm / stonard)?"
  end

  SendChatMessage(msg, "WHISPER", nil, shortName)
  Debug(2, ("Whispered %s: %q"):format(shortName, msg))
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

local function TryInvite(sender, reason, portalRequest, whisperOverride)
  local short = NormalizeSender(sender)
  local ok, why = CanSendInvite()
  if not ok then
    Debug(1, ("Invite attempt blocked (%s): %s"):format(short, tostring(why)))
    Print(("Can't invite %s (%s)."):format(short, tostring(why)))
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

  local sent, api = SendInviteByName(short)
  if not sent then
    Debug(1, ("Invite API unavailable (%s): %s"):format(short, tostring(api)))
    Print(("Can't invite %s (%s)"):format(short, tostring(api)))
    return
  end

  Debug(1, ("Invite call dispatched via %s -> %s"):format(tostring(api), short))
  Print(("Invite attempt sent to %s (%s)"):format(short, reason))
  WhisperInvitee(short, portalRequest, whisperOverride)
end

local f = CreateFrame("Frame")

-- forward declare so SetAddonEnabled can call it safely
local SetAddonEnabled
local ApplyEnabledState

LayoutMinimapButton = function()
  if not minimapButton then return end
  if not Minimap then return end

  -- "Glued to minimap": place the button on a ring around the minimap using a saved angle.
  minimapButton:ClearAllPoints()
  local angle = (MagePortalsDB.minimap and tonumber(MagePortalsDB.minimap.angle)) or 225
  angle = angle % 360
  local rad = angle * math.pi / 180
  local mmw = (Minimap.GetWidth and Minimap:GetWidth()) or 140
  local mmh = (Minimap.GetHeight and Minimap:GetHeight()) or 140
  local base = math.min(mmw, mmh) / 2
  -- Slightly outside the minimap edge so it looks like other addon buttons.
  local radius = base + 10
  local x = math.cos(rad) * radius
  local y = math.sin(rad) * radius
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
  local buttonSize = 31
  minimapButton:SetSize(buttonSize, buttonSize)

  if minimapButton._bg then
    minimapButton._bg:ClearAllPoints()
    minimapButton._bg:SetSize(25, 25)
    -- Offset slightly to center inside the gold tracking ring
    minimapButton._bg:SetPoint("CENTER", minimapButton, "CENTER", -1, -1)
  end

  if minimapButton._icon then
    minimapButton._icon:ClearAllPoints()
    minimapButton._icon:SetSize(20, 20)
    -- Offset slightly to center inside the gold tracking ring
    minimapButton._icon:SetPoint("CENTER", minimapButton, "CENTER", -1, 1)
  end

  if minimapButton._border then
    minimapButton._border:ClearAllPoints()
    local borderSize = 54
    minimapButton._border:SetSize(borderSize, borderSize)
    -- Use CENTER for the border to keep it centered on the button frame
    minimapButton._border:SetPoint("CENTER", minimapButton, "CENTER", 12, -10)
  end

  if minimapButton._highlight then
    minimapButton._highlight:ClearAllPoints()
    -- Offset highlight to match icon/bg
    minimapButton._highlight:SetSize(31, 31)
    minimapButton._highlight:SetPoint("CENTER", minimapButton, "CENTER", 1, -1)
  end
end

local function EnsureMinimapButton()
  if type(CreateFrame) ~= "function" then return end
  if not Minimap then return end

  if not minimapButton then
    minimapButton = CreateFrame("Button", "MagePortalsMinimapButton", Minimap)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:SetMovable(true)
    minimapButton:EnableMouse(true)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetClampedToScreen(true)

    -- Background fill (Blizzard minimap buttons use this to ensure proper centering/scale)
    local bg = minimapButton:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    minimapButton._bg = bg

    -- Icon (centered)
    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\ICONS\\Spell_Arcane_PortalOrgrimmar")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if icon.SetMaskTexture then
      icon:SetMaskTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    end
    minimapButton._icon = icon

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    minimapButton._border = border

    local highlight = minimapButton:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD")
    minimapButton._highlight = highlight
  end

  minimapButton:SetScript("OnDragStart", function(self)
    self._dragging = true
    self:SetScript("OnUpdate", function()
      if not (Minimap and Minimap.GetCenter) then return end
      local mx, my = Minimap:GetCenter()
      if not mx or not my then return end

      local scale = (Minimap.GetEffectiveScale and Minimap:GetEffectiveScale()) or 1
      local cx, cy = GetCursorPosition()
      cx, cy = cx / scale, cy / scale
      local dx, dy = cx - mx, cy - my

      local atan2 = (math.atan2 or atan2)
      if type(atan2) ~= "function" then return end

      local rad = atan2(dy, dx)
      local deg = (rad * 180 / math.pi) % 360
      if not MagePortalsDB.minimap then MagePortalsDB.minimap = {} end
      MagePortalsDB.minimap.angle = deg
      LayoutMinimapButton()
    end)
  end)

  minimapButton:SetScript("OnDragStop", function(self)
    self._dragging = false
    self:SetScript("OnUpdate", nil)
    LayoutMinimapButton()
  end)

  minimapButton:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      MagePortalsDB.minimap.hide = true
      minimapButton:Hide()
      Print("Minimap icon hidden. Use: /mp minimap on")
      return
    end

    SetAddonEnabled(not MagePortalsDB.enabled)
    Print(MagePortalsDB.enabled and "Enabled." or "Disabled.")
  end)

  minimapButton:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(ADDON_NAME)
    GameTooltip:AddLine(("Status: %s"):format(MagePortalsDB.enabled and "ON" or "OFF"), 1, 1, 1)
    GameTooltip:AddLine("Left-click: Toggle", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: Hide", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: Move", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)

  minimapButton:SetScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
  end)

  UpdateMinimapButtonVisual = function()
    if not minimapButton or not minimapButton._icon then return end
    if MagePortalsDB.enabled then
      minimapButton._icon:SetDesaturated(false)
      minimapButton._icon:SetVertexColor(1, 1, 1)
    else
      minimapButton._icon:SetDesaturated(true)
      minimapButton._icon:SetVertexColor(0.7, 0.7, 0.7)
    end
  end

  -- Apply layout every time (prevents stale anchor points from older versions).
  LayoutMinimapButton()
  UpdateMinimapButtonVisual()
end

SetAddonEnabled = function(enabled)
  MagePortalsDB.enabled = enabled and true or false

  if MagePortalsDB.enabled then
    ApplyEnabledState()
  else
    ApplyEnabledState()
  end
  if UpdateMinimapButtonVisual then UpdateMinimapButtonVisual() end
end

ApplyEnabledState = function()
  f:UnregisterEvent("CHAT_MSG_YELL")
  f:UnregisterEvent("CHAT_MSG_SAY")
  f:UnregisterEvent("CHAT_MSG_WHISPER")
  f:UnregisterEvent("CHAT_MSG_CHANNEL")
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
    EnsureMinimapButton()
    if minimapButton then
      if MagePortalsDB.minimap and MagePortalsDB.minimap.hide then
        minimapButton:Hide()
      else
        minimapButton:Show()
      end
    end
    Print(("Loaded (%s). Type /mp help."):format(MagePortalsDB.enabled and "on" or "off"))
    return
  end

  if event == "CHAT_MSG_YELL" then
    if not MagePortalsDB.listenYell then
      Debug(2, "Ignored YELL: channel disabled")
      return
    end
    local msg, sender = ...
    Debug(2, ("YELL from %s: %q"):format(tostring(sender), tostring(msg)))
    local isPortal = MsgHasPortalRequest(msg)
    local isWater = MagePortalsDB.inviteOnWater and MsgHasWaterRequest(msg, true)
    if not (isPortal or isWater) then
      Debug(2, "Ignored: missing portal/water request keywords")
      return
    end
    local ok, why = CanAttemptInvite(sender)
    if not ok then
      Debug(1, ("Invite blocked for %s: %s"):format(NormalizeSender(sender), tostring(why)))
      return
    end
    if isWater then
      TryInvite(sender, "yell (water)", nil, "Inviting you for mage water.")
    else
      TryInvite(sender, "yell", GetRequestedPortalFromMsg(msg))
    end
    return
  end

  if event == "CHAT_MSG_SAY" then
    if not MagePortalsDB.listenSay then
      Debug(2, "Ignored SAY: channel disabled")
      return
    end
    local msg, sender = ...
    Debug(2, ("SAY from %s: %q"):format(tostring(sender), tostring(msg)))
    local isPortal = MsgHasPortalRequest(msg)
    local isWater = MagePortalsDB.inviteOnWater and MsgHasWaterRequest(msg, true)
    if not (isPortal or isWater) then
      Debug(2, "Ignored: missing portal/water request keywords")
      return
    end
    local ok, why = CanAttemptInvite(sender)
    if not ok then
      Debug(1, ("Invite blocked for %s: %s"):format(NormalizeSender(sender), tostring(why)))
      return
    end
    if isWater then
      TryInvite(sender, "say (water)", nil, "Inviting you for mage water.")
    else
      TryInvite(sender, "say", GetRequestedPortalFromMsg(msg))
    end
    return
  end

  if event == "CHAT_MSG_WHISPER" then
    if not MagePortalsDB.listenWhisper then
      Debug(2, "Ignored WHISPER: channel disabled")
      return
    end
    local msg, sender = ...
    Debug(2, ("WHISPER from %s: %q"):format(tostring(sender), tostring(msg)))
    -- For whispers, allow plain "port/portal" without requiring "WTB"/"LF".
    -- People typically DM "org port?" / "stonard port?" directly.
    local portalRequest = GetRequestedPortalFromMsg(msg)
    local isPortal = MsgHasPortalRequest(msg) or MsgHasPortWord(msg)
    local isWater = MagePortalsDB.inviteOnWater and MsgHasWaterRequest(msg, false)
    if not (isPortal or isWater) then
      Debug(2, "Ignored: missing portal/water request keywords")
      return
    end
    local ok, why = CanAttemptInvite(sender)
    if not ok then
      Debug(1, ("Invite blocked for %s: %s"):format(NormalizeSender(sender), tostring(why)))
      return
    end
    if isWater then
      TryInvite(sender, "whisper (water)", nil, "Inviting you for mage water.")
    else
      TryInvite(sender, "whisper", portalRequest)
    end
    return
  end

  if event == "CHAT_MSG_CHANNEL" then
    -- CHAT_MSG_CHANNEL args vary slightly across versions; the 8th arg is channel number in Classic.
    local msg, sender, _, channelString, _, _, _, channelNumber = ...
    channelNumber = tonumber(channelNumber)

    -- Check channel-specific toggles
    local listenToChannel = false
    if channelNumber == 1 and MagePortalsDB.listenChannel1 then
      listenToChannel = true
    elseif channelNumber == 2 and MagePortalsDB.listenChannel2 then
      listenToChannel = true
    end

    if not listenToChannel then
      Debug(2, ("Ignored channel %s (%s)"):format(tostring(channelNumber), tostring(channelString)))
      return
    end

    Debug(2, ("CHANNEL %s (%s) from %s: %q"):format(tostring(channelNumber), tostring(channelString), tostring(sender), tostring(msg)))
    local isPortalMatch
    if channelNumber == 2 then
      isPortalMatch = MsgHasPortalRequest_Channel2(msg)
    else
      isPortalMatch = MsgHasPortalRequest(msg)
    end

    local isWaterMatch = MagePortalsDB.inviteOnWater and MsgHasWaterRequest(msg, true)

    if not (isPortalMatch or isWaterMatch) then
      Debug(2, channelNumber == 2 and "Ignored: /2 requires 'WTB/LF' + 'port' (water requires 'WTB/LF' + 'water')" or "Ignored: missing portal/water request keywords")
      return
    end
    local ok, why = CanAttemptInvite(sender)
    if not ok then
      Debug(1, ("Invite blocked for %s: %s"):format(NormalizeSender(sender), tostring(why)))
      return
    end
    if isWaterMatch then
      TryInvite(sender, ("channel %s (water)"):format(channelString or "1"), nil, "Inviting you for mage water.")
    else
      TryInvite(sender, ("channel %s"):format(channelString or "1"), GetRequestedPortalFromMsg(msg))
    end
    return
  end

  if event == "UI_ERROR_MESSAGE" then
    -- Args vary slightly; generally (messageType, message)
    local _, message = ...
    local now = GetTime and GetTime() or 0

    if (tonumber(MagePortalsDB.debugLevel) or 0) <= 0 then return end
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

end)

SLASH_MAGEPORTALS1 = "/mp"
SLASH_MAGEPORTALS2 = "/mageportals"
SlashCmdList["MAGEPORTALS"] = function(input)
  local raw = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local lower = raw:lower()

  if lower == "" or lower == "help" then
    Print("Commands:")
    Print("/mp on        - enable addon (auto-invite on)")
    Print("/mp off       - disable addon (stops invites)")
    Print("/mp status    - show current status")
    Print("/mp throttle N- ignore repeat triggers from same player for N seconds (default 60)")
    Print("/mp ch2 on|off - also listen in /2 (Trade) (default off)")
    Print("/mp water on|off - also invite people asking for mage water (default off)")
    Print("/mp minimap on|off - show/hide the minimap icon (right-click icon to hide)")
    Print("/mp debug off|on|0|1|2 - debug logging (0=off, 1=basic, 2=verbose)")
    Print("/mp whisper on|off - whisper the invitee a confirmation / destination message")
    Print("/mp testinvite Name - manually attempt an invite (debug helper)")
    return
  end

  local cmdLower, restLower = lower:match("^(%S+)%s*(.*)$")
  cmdLower = cmdLower or ""
  restLower = (restLower or ""):gsub("^%s+", ""):gsub("%s+$", "")

  local _, restOrig = raw:match("^(%S+)%s*(.*)$")
  restOrig = (restOrig or ""):gsub("^%s+", ""):gsub("%s+$", "")

  if cmdLower == "on" and restLower == "" then
    SetAddonEnabled(true)
    Print("Enabled.")
    return
  end

  if cmdLower == "off" and restLower == "" then
    SetAddonEnabled(false)
    Print("Disabled.")
    return
  end

  if cmdLower == "status" and restLower == "" then
    Print(("Status: %s"):format(MagePortalsDB.enabled and "ON" or "OFF"))
    Print(("  Channels: /s=%s, /y=%s, /w=%s, /1=%s, /2=%s"):format(
      MagePortalsDB.listenSay and "on" or "off",
      MagePortalsDB.listenYell and "on" or "off",
      MagePortalsDB.listenWhisper and "on" or "off",
      MagePortalsDB.listenChannel1 and "on" or "off",
      MagePortalsDB.listenChannel2 and "on" or "off"
    ))
    Print(("  Options: water=%s, whisper=%s, debug=%s, throttle=%ss"):format(
      MagePortalsDB.inviteOnWater and "on" or "off",
      MagePortalsDB.whisperOnInvite and "on" or "off",
      tostring(MagePortalsDB.debugLevel or 0),
      tostring(MagePortalsDB.inviteThrottleSeconds)
    ))
    return
  end

  if cmdLower == "throttle" then
    local n = tonumber(restLower)
    if not n then
      Print("Usage: /mp throttle N")
      return
    end
    MagePortalsDB.inviteThrottleSeconds = n
    Print(("Throttle set to %ss."):format(tostring(MagePortalsDB.inviteThrottleSeconds)))
    return
  end

  if cmdLower == "ch2" or cmdLower == "channel2" then
    if restLower ~= "on" and restLower ~= "off" then
      Print("Usage: /mp ch2 on|off")
      return
    end
    MagePortalsDB.listenChannel2 = restLower == "on"
    Print(("/2 (Trade) listening %s."):format(MagePortalsDB.listenChannel2 and "enabled" or "disabled"))
    return
  end

  if cmdLower == "water" then
    if restLower ~= "on" and restLower ~= "off" then
      Print("Usage: /mp water on|off")
      return
    end
    MagePortalsDB.inviteOnWater = restLower == "on"
    Print(("Water invites %s."):format(MagePortalsDB.inviteOnWater and "enabled" or "disabled"))
    return
  end

  if cmdLower == "minimap" then
    if restLower ~= "on" and restLower ~= "off" then
      Print("Usage: /mp minimap on|off")
      return
    end
    MagePortalsDB.minimap.hide = restLower == "off"
    EnsureMinimapButton()
    if minimapButton then
      if MagePortalsDB.minimap.hide then minimapButton:Hide() else minimapButton:Show() end
    end
    Print(("Minimap icon %s."):format(MagePortalsDB.minimap.hide and "hidden" or "shown"))
    return
  end

  if cmdLower == "whisper" then
    if restLower ~= "on" and restLower ~= "off" then
      Print("Usage: /mp whisper on|off")
      return
    end
    MagePortalsDB.whisperOnInvite = restLower == "on"
    Print(("Whisper on invite %s."):format(MagePortalsDB.whisperOnInvite and "enabled" or "disabled"))
    return
  end

  if cmdLower == "debug" then
    if restLower == "" then
      Print("Usage: /mp debug off|on|0|1|2")
      return
    end
    if restLower == "on" then
      MagePortalsDB.debugLevel = 1
    elseif restLower == "off" then
      MagePortalsDB.debugLevel = 0
    else
      local n = tonumber(restLower)
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

  if cmdLower == "testinvite" then
    if restOrig == "" then
      Print("Usage: /mp testinvite Name")
      return
    end
    -- Debug helper: attempt invite without keyword matching.
    TryInvite(restOrig, "manual", nil)
    return
  end

  if cmdLower == "settings" or cmdLower == "config" or cmdLower == "options" then
    MagePortals_ToggleSettingsFrame()
    return
  end

  Print(("Unknown command: %q (try /mp help)"):format(raw))
end

--------------------------------------------------------------------------------
-- Settings UI Frame
--------------------------------------------------------------------------------
local settingsFrame = nil

local function CreateCheckbox(parent, label, x, y, getter, setter)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  cb:SetSize(26, 26)

  local text = cb:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  text:SetText(label)
  cb._label = text

  cb:SetScript("OnClick", function(self)
    local checked = self:GetChecked()
    setter(checked)
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
  end)

  cb._getter = getter
  cb._setter = setter

  cb:SetChecked(getter())
  return cb
end

local function CreateSettingsFrame()
  if settingsFrame then return settingsFrame end

  -- Main frame
  local frame = CreateFrame("Frame", "MagePortalsSettingsFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(340, 380)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 50)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetFrameStrata("DIALOG")
  frame:SetClampedToScreen(true)
  frame:Hide()

  -- Title
  frame.TitleText:SetText("Mage Portals Settings")

  -- Enable/Disable toggle button
  local toggleBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  toggleBtn:SetSize(140, 28)
  toggleBtn:SetPoint("TOP", frame, "TOP", 0, -35)
  toggleBtn._updateText = function(self)
    if MagePortalsDB.enabled then
      self:SetText("|cff00ff00ADDON ON|r - Click to Disable")
    else
      self:SetText("|cffff0000ADDON OFF|r - Click to Enable")
    end
  end
  toggleBtn:SetScript("OnClick", function(self)
    SetAddonEnabled(not MagePortalsDB.enabled)
    self:_updateText()
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION or 857)
  end)
  toggleBtn:SetSize(200, 28)
  frame._toggleBtn = toggleBtn

  -- Divider line
  local divider1 = frame:CreateTexture(nil, "ARTWORK")
  divider1:SetColorTexture(0.4, 0.4, 0.4, 0.8)
  divider1:SetSize(300, 1)
  divider1:SetPoint("TOP", frame, "TOP", 0, -72)

  -- Section: Channels
  local channelHeader = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  channelHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -82)
  channelHeader:SetText("|cffffcc00Listen to Channels|r")

  local checkboxes = {}

  -- Channel checkboxes
  checkboxes.say = CreateCheckbox(frame, "/s (Say)", 20, -105,
    function() return MagePortalsDB.listenSay end,
    function(v) MagePortalsDB.listenSay = v end
  )

  checkboxes.yell = CreateCheckbox(frame, "/y (Yell)", 160, -105,
    function() return MagePortalsDB.listenYell end,
    function(v) MagePortalsDB.listenYell = v end
  )

  checkboxes.whisper = CreateCheckbox(frame, "/w (Whisper)", 20, -130,
    function() return MagePortalsDB.listenWhisper end,
    function(v) MagePortalsDB.listenWhisper = v end
  )

  checkboxes.ch1 = CreateCheckbox(frame, "/1 (General)", 160, -130,
    function() return MagePortalsDB.listenChannel1 end,
    function(v) MagePortalsDB.listenChannel1 = v end
  )

  checkboxes.ch2 = CreateCheckbox(frame, "/2 (Trade)", 20, -155,
    function() return MagePortalsDB.listenChannel2 end,
    function(v) MagePortalsDB.listenChannel2 = v end
  )

  -- Divider line
  local divider2 = frame:CreateTexture(nil, "ARTWORK")
  divider2:SetColorTexture(0.4, 0.4, 0.4, 0.8)
  divider2:SetSize(300, 1)
  divider2:SetPoint("TOP", frame, "TOP", 0, -188)

  -- Section: Options
  local optionsHeader = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  optionsHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -198)
  optionsHeader:SetText("|cffffcc00Options|r")

  checkboxes.water = CreateCheckbox(frame, "Invite on Water requests", 20, -220,
    function() return MagePortalsDB.inviteOnWater end,
    function(v) MagePortalsDB.inviteOnWater = v end
  )

  checkboxes.whisperInvite = CreateCheckbox(frame, "Whisper invitee on invite", 20, -245,
    function() return MagePortalsDB.whisperOnInvite end,
    function(v) MagePortalsDB.whisperOnInvite = v end
  )

  checkboxes.minimap = CreateCheckbox(frame, "Show Minimap Icon", 20, -270,
    function() return not MagePortalsDB.minimap.hide end,
    function(v)
      MagePortalsDB.minimap.hide = not v
      if minimapButton then
        if v then minimapButton:Show() else minimapButton:Hide() end
      end
    end
  )

  -- Divider line
  local divider3 = frame:CreateTexture(nil, "ARTWORK")
  divider3:SetColorTexture(0.4, 0.4, 0.4, 0.8)
  divider3:SetSize(300, 1)
  divider3:SetPoint("TOP", frame, "TOP", 0, -303)

  -- Debug dropdown
  local debugHeader = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  debugHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -313)
  debugHeader:SetText("|cffffcc00Debug Level|r")

  local debugBtns = {}
  local debugLevels = { { label = "Off", val = 0 }, { label = "Basic", val = 1 }, { label = "Verbose", val = 2 } }
  for i, dbg in ipairs(debugLevels) do
    local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetSize(80, 22)
    btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 20 + (i - 1) * 90, -333)
    btn:SetText(dbg.label)
    btn._val = dbg.val
    btn:SetScript("OnClick", function()
      MagePortalsDB.debugLevel = dbg.val
      for _, b in ipairs(debugBtns) do
        if b._val == MagePortalsDB.debugLevel then
          b:SetButtonState("PUSHED", true)
        else
          b:SetButtonState("NORMAL")
        end
      end
      PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end)
    table.insert(debugBtns, btn)
  end
  frame._debugBtns = debugBtns

  -- Store references for refresh
  frame._checkboxes = checkboxes

  -- Refresh function
  frame._refresh = function()
    for _, cb in pairs(checkboxes) do
      if cb._getter then
        cb:SetChecked(cb._getter())
      end
    end
    toggleBtn:_updateText()
    for _, b in ipairs(debugBtns) do
      if b._val == (MagePortalsDB.debugLevel or 0) then
        b:SetButtonState("PUSHED", true)
      else
        b:SetButtonState("NORMAL")
      end
    end
  end

  frame:SetScript("OnShow", function(self)
    self._refresh()
  end)

  settingsFrame = frame
  return frame
end

function MagePortals_ToggleSettingsFrame()
  local frame = CreateSettingsFrame()
  if frame:IsShown() then
    frame:Hide()
  else
    frame:Show()
    frame._refresh()
  end
end

-- Also make settings accessible via minimap button shift-click