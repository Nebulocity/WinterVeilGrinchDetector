-- WinterVeilGrinchDetector.lua
-- WoW Classic / Anniversary
-- Tracks COMPLETED trade partners and warns on repeat completed traders.

local ADDON_NAME = ...
local f = CreateFrame("Frame")

WinterVeilGrinchDetectorDB = WinterVeilGrinchDetectorDB or {}

-- ------------------------------------------------------------
-- DB / utility
-- ------------------------------------------------------------
local function EnsureDB()
  if WinterVeilGrinchDetectorDB.enabled == nil then WinterVeilGrinchDetectorDB.enabled = true end
  if type(WinterVeilGrinchDetectorDB) ~= "table" then WinterVeilGrinchDetectorDB = {} end
  if type(WinterVeilGrinchDetectorDB.completedByName) ~= "table" then WinterVeilGrinchDetectorDB.completedByName = {} end -- [nameShort] = timestamp
  if type(WinterVeilGrinchDetectorDB.completedByGuid) ~= "table" then WinterVeilGrinchDetectorDB.completedByGuid = {} end -- [guid] = nameShort
  if type(WinterVeilGrinchDetectorDB.lastDuplicateMsg) ~= "string" then WinterVeilGrinchDetectorDB.lastDuplicateMsg = "" end
  if type(WinterVeilGrinchDetectorDB.announceChannel) ~= "string" then WinterVeilGrinchDetectorDB.announceChannel = "SAY" end
  if WinterVeilGrinchDetectorDB.screen == nil then WinterVeilGrinchDetectorDB.screen = true end
  if WinterVeilGrinchDetectorDB.debug == nil then WinterVeilGrinchDetectorDB.debug = false end
end

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff00ffccWinterVeilGrinchDetector:|r " .. tostring(msg))
end

local function Debug(msg)
  if WinterVeilGrinchDetectorDB.debug then
    Print("|cffaaaaaaDEBUG:|r " .. tostring(msg))
  end
end

local function PlayAlertSound()
    if PlaySound then
    pcall(function()
      PlaySound(SOUNDKIT.RAID_WARNING, "Master")
    end)
  end
end

local function ScreenAlert(text)
  if not WinterVeilGrinchDetectorDB.screen then return end
  if RaidWarningFrame and RaidNotice_AddMessage then
    RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
  end
  if UIErrorsFrame and UIErrorsFrame.AddMessage then
    UIErrorsFrame:AddMessage(text, 1, 0.1, 0.1, 1.0)
  end
end

local function ShortName(name)
  if not name or name == "" then return nil end
  return Ambiguate(name, "short")
end

local function SortedKeys(t)
  local list = {}
  for k in pairs(t) do list[#list + 1] = k end
  table.sort(list)
  return list
end

local function IsEnabled()
  EnsureDB()
  return WinterVeilGrinchDetectorDB.enabled == true
end


--------------------------------------------------------------
-- Trade partner resolution (Classic trade frame quirks)
-- ------------------------------------------------------------
local function GetTradePartnerNameAndGuid()
  -- TradeFrame label often populates early.
  if TradeFrameRecipientNameText and TradeFrameRecipientNameText.GetText then
    local txt = TradeFrameRecipientNameText:GetText()
    if txt and txt ~= "" then
      local nameShort = ShortName(txt)
      -- Try to grab GUID too (may be nil depending on client behavior)
      local guid = UnitExists("npc") and UnitGUID("npc") or nil
      return nameShort, guid
    end
  end

  -- Common Classic behavior: trade partner exposed as "npc" while Trade UI is open.
  if UnitExists("npc") then
    local n = UnitName("npc")
    return ShortName(n), UnitGUID("npc")
  end

  return nil, nil
end

-- ------------------------------------------------------------
-- Completed tracking + duplicate logic
-- ------------------------------------------------------------
local function IsCompletedBefore(nameShort, guid)
  EnsureDB()
  if guid and WinterVeilGrinchDetectorDB.completedByGuid[guid] then return true end
  if nameShort and WinterVeilGrinchDetectorDB.completedByName[nameShort] then return true end
  return false
end

local function RecordCompleted(nameShort, guid)
  EnsureDB()

  -- If name missing but guid already mapped, recover it
  if (not nameShort or nameShort == "") and guid then
    nameShort = WinterVeilGrinchDetectorDB.completedByGuid[guid]
  end

  if not nameShort and not guid then
    Debug("RecordCompleted skipped (no name/guid)")
    return false
  end

  local now = time()
  if nameShort then
    WinterVeilGrinchDetectorDB.completedByName[nameShort] = now
  end
  if guid then
    WinterVeilGrinchDetectorDB.completedByGuid[guid] = nameShort or WinterVeilGrinchDetectorDB.completedByGuid[guid] or "UNKNOWN"
  end

  Debug(("Recorded COMPLETED: %s guid=%s"):format(tostring(nameShort), tostring(guid)))
  return true
end

local function MakeDuplicateMessage(nameShort, guid)
  EnsureDB()
  local who = nameShort
  if (not who or who == "") and guid then
    who = WinterVeilGrinchDetectorDB.completedByGuid[guid]
  end
  who = who or "UNKNOWN"
  return "DUPLICATE TRADER DETECTED " .. who
end

local function LocalWarnDuplicate(nameShort, guid)
  local msg = MakeDuplicateMessage(nameShort, guid)
  WinterVeilGrinchDetectorDB.lastDuplicateMsg = msg
  ScreenAlert(msg)
  PlayAlertSound()
  Print(msg)
  Print("WoW blocks addons from auto /say or /yell. Use /wvgd announce if you want to broadcast.")
end


local function AnnounceLastDuplicate()
  EnsureDB()
  local msg = WinterVeilGrinchDetectorDB.lastDuplicateMsg
  if not msg or msg == "" then
    Print("Nothing to announce yet.")
    return
  end

  local ch = (WinterVeilGrinchDetectorDB.announceChannel or "SAY"):upper()
  local ok = { SAY=true, YELL=true, PARTY=true, RAID=true, GUILD=true, INSTANCE_CHAT=true }
  if not ok[ch] then ch = "SAY" end

  -- This is user-initiated (slash command), so it won't trigger the protected-action block.
  SendChatMessage(msg, ch)
end

-- ------------------------------------------------------------
-- Trade session state (the stuff that was flaking before)
-- ------------------------------------------------------------
local tradeId = 0
local currentName, currentGuid = nil, nil
local checkedDuplicateThisTrade = false

local acceptedByBoth = false
local tradeCompleteSeen = false
local recordedCompletedThisTrade = false

-- Cache partner identity at/after close in case the "trade complete" message arrives late.
local lastClosed = nil

local function ResolvePartnerNow()
  local n, g = GetTradePartnerNameAndGuid()
  if n then currentName = n end
  if g then currentGuid = g end
  return currentName, currentGuid
end

local function MaybeCheckDuplicateNow()
  if checkedDuplicateThisTrade then return end
  ResolvePartnerNow()
  if currentName or currentGuid then
    checkedDuplicateThisTrade = true
    Debug(("Partner resolved: %s guid=%s"):format(tostring(currentName), tostring(currentGuid)))
    if IsCompletedBefore(currentName, currentGuid) then
      LocalWarnDuplicate(currentName, currentGuid)
    end
  end
end

local function ResolvePartnerWithRetries(maxTries, delay)
  maxTries = maxTries or 12
  delay = delay or 0.08
  local tries = 0
  local myTradeId = tradeId

  local function attempt()
    -- If a new trade started, stop retrying for the old one.
    if myTradeId ~= tradeId then return end

    tries = tries + 1
    ResolvePartnerNow()
    if currentName or currentGuid then
      MaybeCheckDuplicateNow()
      return
    end
    if tries < maxTries then
      C_Timer.After(delay, attempt)
    else
      Debug("Partner still nil after retries.")
    end
  end

  attempt()
end

local function IsTruthyAccepted(v)
  return (v == 1) or (v == true)
end

local function IsTradeCompleteMessage(msg)
  if not msg then return false end
  if ERR_TRADE_COMPLETE and msg:find(ERR_TRADE_COMPLETE, 1, true) then return true end
  -- Fallback for odd cases (usually ERR_TRADE_COMPLETE is present)
  if msg:find("Trade complete", 1, true) then return true end
  return false
end

local function TryRecordCompleted(reason)
  if recordedCompletedThisTrade then
    Debug("Already recorded completed this trade; reason=" .. tostring(reason))
    return
  end

  ResolvePartnerNow()
  if RecordCompleted(currentName, currentGuid) then
    recordedCompletedThisTrade = true
    Debug("Recorded completed via " .. tostring(reason))
  else
    Debug("Could not record completed (no partner) via " .. tostring(reason))
  end
end

local function TryRecordFromLateCompleteMessage()
  -- If the "trade complete" message arrives after TRADE_CLOSED,
  -- use cached lastClosed partner info (if still fresh).
  if not lastClosed then return end
  if lastClosed.recorded then return end
  if time() > (lastClosed.expiresAt or 0) then return end

  local n, g = lastClosed.name, lastClosed.guid
  if RecordCompleted(n, g) then
    lastClosed.recorded = true
    Debug("Recorded completed from late complete-message using lastClosed cache")
  end
end

-- ------------------------------------------------------------
-- Slash commands
-- ------------------------------------------------------------
SLASH_WINTERVEILGRINCHDETECTOR1 = "/wvgd"
SLASH_WINTERVEILGRINCHDETECTOR2 = "/grinchdetector"
SlashCmdList["WINTERVEILGRINCHDETECTOR"] = function(msg)
  EnsureDB()
  msg = (msg or ""):lower()

  if msg == "debug on" then
    WinterVeilGrinchDetectorDB.debug = true
    Print("Debug: ON")
    return
  end
  if msg == "debug off" then
    WinterVeilGrinchDetectorDB.debug = false
    Print("Debug: OFF")
    return
  end

  if msg == "reset" or msg == "clear" then
    WinterVeilGrinchDetectorDB.completedByName = {}
    WinterVeilGrinchDetectorDB.completedByGuid = {}
    WinterVeilGrinchDetectorDB.lastDuplicateMsg = ""
    Print("Reset complete (completed list cleared).")
    return
  end

  if msg == "list" then
    local names = SortedKeys(WinterVeilGrinchDetectorDB.completedByName)
    Print("Completed traders: " .. #names)
    for _, n in ipairs(names) do
      Print(" - " .. n)
    end
    return
  end

  if msg == "announce" then
    AnnounceLastDuplicate()
    return
  end

  local channel = msg:match("^channel%s+(%S+)$")
  if channel then
    channel = channel:upper()
    local ok = { SAY=true, YELL=true, PARTY=true, RAID=true, GUILD=true, INSTANCE_CHAT=true }
    if not ok[channel] then
      Print("Invalid channel. Use: say, yell, party, raid, guild, instance_chat")
      return
    end
    WinterVeilGrinchDetectorDB.announceChannel = channel
    Print("Announce channel set to: " .. channel)
    return
  end

  if msg == "on" then
	  WinterVeilGrinchDetectorDB.enabled = true
	  Print("Enabled: ON")
	  return
	end

	if msg == "off" then
	  WinterVeilGrinchDetectorDB.enabled = false
	  Print("Enabled: OFF")
	  return
	end

	if msg == "toggle" then
	  WinterVeilGrinchDetectorDB.enabled = not WinterVeilGrinchDetectorDB.enabled
	  Print("Enabled: " .. (WinterVeilGrinchDetectorDB.enabled and "ON" or "OFF"))
	  return
	end

	if msg == "status" then
	  Print("Enabled: " .. (IsEnabled() and "ON" or "OFF"))
	  return
end

  Print("Commands:")
  Print("/wvgd list")
  Print("/wvgd reset")
  Print("/wvgd announce  (broadcast last duplicate msg)")
  Print("/wvgd channel say|yell|party|raid|guild|instance_chat")
  Print("/wvgd debug on|off")
end

-- ------------------------------------------------------------
-- Events
-- ------------------------------------------------------------
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("TRADE_SHOW")
f:RegisterEvent("TRADE_ACCEPT_UPDATE")
f:RegisterEvent("TRADE_CLOSED")
f:RegisterEvent("TRADE_REQUEST_CANCEL")
f:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
f:RegisterEvent("TRADE_TARGET_ITEM_CHANGED")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:RegisterEvent("UI_INFO_MESSAGE")

f:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local loadedName = ...
    if loadedName ~= ADDON_NAME then return end
    EnsureDB()
    Print("Loaded. (/wvgd for commands)")
    return
  end
  
  -- If disabled, ignore all trade-related events.
	if not IsEnabled() then
	  -- Still allow slash commands (they aren't events here), and we already handled ADDON_LOADED above.
	  if event ~= "ADDON_LOADED" then
		return
	  end
	end


  if event == "TRADE_SHOW" then
    EnsureDB()
    tradeId = tradeId + 1

    currentName, currentGuid = nil, nil
    checkedDuplicateThisTrade = false
    acceptedByBoth = false
    tradeCompleteSeen = false
    recordedCompletedThisTrade = false
    lastClosed = nil

    Debug("TRADE_SHOW")
    -- Try immediately, plus retries for the name/guid race.
    MaybeCheckDuplicateNow()
    ResolvePartnerWithRetries(12, 0.08)
    return
  end

  if event == "TRADE_PLAYER_ITEM_CHANGED" or event == "TRADE_TARGET_ITEM_CHANGED" then
    -- These often happen after recipient info becomes reliable.
    Debug(event)
    MaybeCheckDuplicateNow()
    return
  end

  if event == "TRADE_ACCEPT_UPDATE" then
    local playerAccepted, targetAccepted = ...
    local p = IsTruthyAccepted(playerAccepted)
    local t = IsTruthyAccepted(targetAccepted)

    Debug(("TRADE_ACCEPT_UPDATE p=%s t=%s (raw %s/%s)"):format(
      tostring(p), tostring(t), tostring(playerAccepted), tostring(targetAccepted)
    ))

    MaybeCheckDuplicateNow()
    ResolvePartnerNow()

    if p and t then
      -- Most reliable: record COMPLETED immediately when both accept.
      if not acceptedByBoth then Debug("Both accepted -> recording completed immediately") end
      acceptedByBoth = true
      TryRecordCompleted("TRADE_ACCEPT_UPDATE(1/1)")
    end

    return
  end

  if event == "CHAT_MSG_SYSTEM" then
    local msg = ...
    if IsTradeCompleteMessage(msg) then
      tradeCompleteSeen = true
      Debug("CHAT_MSG_SYSTEM saw trade complete")
      -- If close already happened and we didn't record, try from cache.
      TryRecordFromLateCompleteMessage()
      -- If trade is still open and we didn't record yet, record now.
      if not recordedCompletedThisTrade then
        TryRecordCompleted("CHAT_MSG_SYSTEM(trade complete)")
      end
    end
    return
  end

  if event == "UI_INFO_MESSAGE" then
    local _, msg = ...
    if IsTradeCompleteMessage(msg) then
      tradeCompleteSeen = true
      Debug("UI_INFO_MESSAGE saw trade complete")
      TryRecordFromLateCompleteMessage()
      if not recordedCompletedThisTrade then
        TryRecordCompleted("UI_INFO_MESSAGE(trade complete)")
      end
    end
    return
  end

  if event == "TRADE_REQUEST_CANCEL" then
    Debug("TRADE_REQUEST_CANCEL (canceled/failed)")
    acceptedByBoth = false
    tradeCompleteSeen = false
    return
  end

  if event == "TRADE_CLOSED" then
    Debug(("TRADE_CLOSED acceptedByBoth=%s tradeCompleteSeen=%s recorded=%s"):format(
      tostring(acceptedByBoth), tostring(tradeCompleteSeen), tostring(recordedCompletedThisTrade)
    ))

    -- Cache partner at close for late-arriving "trade complete" message.
    ResolvePartnerNow()
    lastClosed = {
      id = tradeId,
      name = currentName,
      guid = currentGuid,
      expiresAt = time() + 8,
      recorded = recordedCompletedThisTrade,
    }

    -- Fallback: if we *already* know it completed but didn't record yet.
    if (acceptedByBoth or tradeCompleteSeen) and not recordedCompletedThisTrade then
      TryRecordCompleted("TRADE_CLOSED fallback")
      if lastClosed then lastClosed.recorded = recordedCompletedThisTrade end
    end

    currentName, currentGuid = nil, nil
    checkedDuplicateThisTrade = false
    acceptedByBoth = false
    tradeCompleteSeen = false
    recordedCompletedThisTrade = false
    return
  end
end)
