-- CareerMP Dynamic AI Traffic - Server/Client Module
-- Author: DeadEndReece
-- Description: State-driven multiplayer traffic manager built on BeamMP events and
-- BeamNG's gameplay_traffic API 

local Config = {
  aisPerPlayer = 1,
  maxServerTraffic = 8,
  trafficGhosting = true,
  trafficSpawnWarnings = true,
  missionExitHideDuration = 10,

  tickRate = 1000,

  timerFirstPlayer = 30,
  timerPlayerJoin = 120,
  timerPlayerLeave = 60,
  timerAdminRefresh = 30,
  timerPendingTimeout = 300,

  timerWarningLong = 60,
  timerWarningShort = 10,

  msgFirstPlayerWait = "^l^e[Traffic] ^fFirst player loaded! - Traffic will generate in ^c%d seconds...",
  msgPendingPlayer = "^l^e[Traffic] ^f%s is downloading/loading! Pausing traffic spawn...",
  msgExtendTimer = "^l^e[Traffic] ^fAnother player is loading in! Delaying traffic generation by ^c%d seconds...",
  msgFirstPlayerWarn = "^l^e[Traffic] ^fTraffic generating in ^c%d seconds...",

  msgPlayerJoinReset = "^l^e[Traffic] ^f%s Joined! - Traffic Spawning ^cCancelled ^fand ^crecalculating.",
  msgPlayerJoinWait = "^l^e[Traffic] ^f%s Joined - Traffic has been ^cDeleted ^fwhilst the server ^crecalculates!",

  msgPlayerLeaveWait = "^l^e[Traffic] ^fA player left. - Traffic ^cDeleted. ^fRespawning in ^c%d seconds...",

  msgQueueLongWarn = "^l^e[Traffic] ^fTraffic Recalculated, Respawning in %d seconds.",
  msgQueueShortWarn = "^l^e[Traffic] ^fRespawning traffic in ^c%d seconds... Find a safe location!",

  msgTrafficSpawned = "^l^e[Traffic] ^fTraffic spawned ^c(%d per player).",

  msgAdminRefreshWait = "^l^e[Traffic] ^fAdmin %s forced a traffic refresh. ^cRespawning in %d seconds...",
  msgNoPermission = "^l^cYou do not have permission to use admin commands."
}

local SPAWN_COUNTDOWN_START = 5

local settingsPath = "Resources/Server/CareerMPTraffic/settings.txt"
local TRAFFIC_ADMINS = {}

local pendingPlayers = {}
local fullyJoinedPlayers = {}
local playerIdsToNames = {}
local missionTrafficSuppressedPlayers = {}
local missionExitHiddenUntil = {}

local firstPlayerSpawning = false
local firstPlayerTimer = 0
local serverHasTraffic = false
local firstPlayer5sWarning = false
local firstPlayerCountdownValue = nil

local trafficPaused = false
local isCountingDown = false
local respawnTimer = 0
local oneMinuteWarningSent = false
local join5sWarning = false
local joinCountdownValue = nil

local recalcSpawning = false
local recalcTimer = 0
local recalcAmount = 0
local recalc5sWarning = false
local recalcCountdownValue = nil

local replicatedTrafficState = {
  enabled = false,
  amount = 0,
  ghosting = Config.trafficGhosting
}

local function logInfo(msg)
  print("[CareerMPTraffic] " .. tostring(msg))
end

local function toBoolean(value, defaultValue)
  local valueType = type(value)
  if valueType == "boolean" then return value end
  if valueType == "number" then return value ~= 0 end
  if valueType == "string" then
    local lowered = value:lower()
    if lowered == "1" or lowered == "true" or lowered == "on" or lowered == "yes" then
      return true
    end
    if lowered == "0" or lowered == "false" or lowered == "off" or lowered == "no" then
      return false
    end
  end
  return defaultValue
end

local function getPlayerKey(playerId)
  if playerId == nil then return nil end
  return tostring(playerId)
end

local function shallowCopy(source)
  local out = {}
  for key, value in pairs(source or {}) do
    out[key] = value
  end
  return out
end

local function forEachConnectedPlayer(callback)
  if not (MP and MP.GetPlayers and callback) then return end

  local ok, players = pcall(MP.GetPlayers)
  if not ok or type(players) ~= "table" then return end

  for playerId in pairs(players) do
    callback(playerId)
  end
end

local function encodePayload(payload)
  if Util and Util.JsonEncode then
    local ok, encoded = pcall(Util.JsonEncode, payload)
    if ok and type(encoded) == "string" then
      return encoded
    end
  end

  return "{}"
end

local function sendClientPayload(targetId, eventName, payload)
  if MP and MP.TriggerClientEventJson then
    MP.TriggerClientEventJson(targetId, eventName, payload)
  else
    MP.TriggerClientEvent(targetId, eventName, encodePayload(payload))
  end
end

local function sendTrafficWarningChat(targetId, message)
  if not Config.trafficSpawnWarnings then return end
  if not (MP and MP.SendChatMessage) then return end
  MP.SendChatMessage(targetId, message)
end

local function broadcastTrafficSpawnCountdown(seconds)
  if not Config.trafficSpawnWarnings then return end
  if not (MP and MP.TriggerClientEvent) then return end
  if not seconds or seconds < 1 then return end
  MP.TriggerClientEvent(-1, "showTrafficSpawnCountdown", tostring(seconds))
end

local function isMissionHiddenOwner(playerId)
  local playerKey = getPlayerKey(playerId)
  if playerKey == nil then
    return false
  end

  if missionTrafficSuppressedPlayers[playerKey] == true then
    return true
  end

  local hiddenUntil = tonumber(missionExitHiddenUntil[playerKey]) or 0
  return hiddenUntil > os.time()
end

local function isMissionSuppressed(playerId)
  local playerKey = getPlayerKey(playerId)
  return playerKey ~= nil and missionTrafficSuppressedPlayers[playerKey] == true
end

local function setMissionHiddenOwner(playerId, isHidden)
  local playerKey = getPlayerKey(playerId)
  if not playerKey then
    return false
  end

  local wasHidden = missionTrafficSuppressedPlayers[playerKey] == true
  if isHidden then
    missionTrafficSuppressedPlayers[playerKey] = true
  else
    missionTrafficSuppressedPlayers[playerKey] = nil
  end

  return wasHidden ~= isHidden
end

local function setMissionExitHiddenUntil(playerId, hiddenUntil)
  local playerKey = getPlayerKey(playerId)
  if not playerKey then
    return false
  end

  local previousHiddenUntil = tonumber(missionExitHiddenUntil[playerKey]) or 0

  if hiddenUntil and hiddenUntil > os.time() then
    missionExitHiddenUntil[playerKey] = hiddenUntil
  else
    missionExitHiddenUntil[playerKey] = nil
  end

  local nextHiddenUntil = tonumber(missionExitHiddenUntil[playerKey]) or 0
  return previousHiddenUntil ~= nextHiddenUntil
end

local function buildHiddenTrafficOwners()
  local owners = {}
  local currentTime = os.time()

  for playerKey, isHidden in pairs(missionTrafficSuppressedPlayers) do
    if isHidden then
      owners[playerKey] = true
    end
  end

  for playerKey, hiddenUntil in pairs(missionExitHiddenUntil) do
    if tonumber(hiddenUntil) and hiddenUntil > currentTime then
      owners[playerKey] = true
    end
  end

  return owners
end

local function buildTrafficStatePayload(overrides)
  local payload = shallowCopy(replicatedTrafficState)
  payload.forceRespawn = false

  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      payload[key] = value
    end
  end

  return payload
end

local function sendTrafficState(targetId, overrides)
  sendClientPayload(targetId, "traffic_applyState", buildTrafficStatePayload(overrides))
end

local function sendHiddenTrafficOwners(targetId)
  sendClientPayload(targetId, "traffic_setHiddenOwners", {
    owners = buildHiddenTrafficOwners()
  })
end

local function broadcastHiddenTrafficOwners()
  sendHiddenTrafficOwners(-1)
end

local function broadcastTrafficState(overrides)
  forEachConnectedPlayer(function(playerId)
    sendTrafficState(playerId, overrides)
  end)
end

local function setReplicatedTrafficAmount(amount, enabled)
  local numericAmount = math.max(0, math.floor(tonumber(amount) or 0))
  replicatedTrafficState.amount = numericAmount
  replicatedTrafficState.enabled = enabled
  replicatedTrafficState.ghosting = Config.trafficGhosting
end

local function extractServerVehicleId(data)
  if type(data) ~= "string" or data == "" then return nil end
  return data:match("^([^|]+)|")
end

local function clearTrafficForClients()
  setReplicatedTrafficAmount(0, false)
  broadcastTrafficState({forceRespawn = true})
end

local function spawnTrafficForClients(amount)
  setReplicatedTrafficAmount(amount, true)
  broadcastTrafficState({forceRespawn = true})
end

local function syncTrafficGhosting(targetId)
  replicatedTrafficState.ghosting = Config.trafficGhosting
  if targetId then
    sendTrafficState(targetId)
  else
    broadcastTrafficState()
  end
end

function LoadSettings()
  TRAFFIC_ADMINS = {}
  local file = io.open(settingsPath, "r")
  if file then
    local adminCount = 0
    for line in file:lines() do
      if not line:match("^%[") and line:match("=") then
        local key, value = line:match("([^=]+)=(.+)")
        if key and value then
          key = key:match("^%s*(.-)%s*$")
          value = value:match("^%s*(.-)%s*$")

          if key == "aisPerPlayer" then
            Config.aisPerPlayer = tonumber(value) or Config.aisPerPlayer
          elseif key == "maxServerTraffic" then
            Config.maxServerTraffic = tonumber(value) or Config.maxServerTraffic
          elseif key == "trafficGhosting" then
            Config.trafficGhosting = (value == "true")
          elseif key == "trafficSpawnWarnings" then
            Config.trafficSpawnWarnings = (value == "true")
          else
            TRAFFIC_ADMINS[key] = value
            adminCount = adminCount + 1
          end
        end
      end
    end
    file:close()
    logInfo("Loaded config overrides and " .. adminCount .. " admins from settings.txt")
  else
    logInfo("No settings.txt found. Creating a new one with default values...")
    SaveSettings()
  end

  replicatedTrafficState.ghosting = Config.trafficGhosting
end

function SaveSettings()
  local file = io.open(settingsPath, "w")
  if file then
    file:write("[Config]\n")
    file:write("aisPerPlayer=" .. Config.aisPerPlayer .. "\n")
    file:write("maxServerTraffic=" .. Config.maxServerTraffic .. "\n")
    file:write("trafficGhosting=" .. tostring(Config.trafficGhosting) .. "\n")
    file:write("trafficSpawnWarnings=" .. tostring(Config.trafficSpawnWarnings) .. "\n")
    file:write("\n")

    file:write("[Admins]\n")
    for id, name in pairs(TRAFFIC_ADMINS) do
      file:write(id .. "=" .. name .. "\n")
    end
    file:close()
  end
end

local function getPlayerCount(isDisconnecting)
  local count = 0

  if MP and MP.GetPlayers then
    local ok, players = pcall(MP.GetPlayers)
    if ok and type(players) == "table" then
      for _ in pairs(players) do
        count = count + 1
      end
    end
  end

  if isDisconnecting then
    count = count - 1
  end

  if count < 0 then
    count = 0
  end

  return count
end

local function getScaledTrafficAmount(isDisconnecting)
  local players = getPlayerCount(isDisconnecting)
  if players < 1 then
    players = 1
  end

  local amount = math.floor(Config.maxServerTraffic / players)
  if amount > Config.aisPerPlayer then
    amount = Config.aisPerPlayer
  end
  if amount < 1 then
    amount = 1
  end

  return amount
end

function onPlayerAuth(playerName, playerRole, isGuest, ip)
  if not playerName then return end

  pendingPlayers[playerName] = os.time()
  fullyJoinedPlayers[playerName] = nil
  logInfo("Player authenticating (pending): " .. tostring(playerName))

  if not serverHasTraffic and firstPlayerSpawning then
    firstPlayerTimer = os.time() + Config.timerFirstPlayer
    firstPlayer5sWarning = false
    firstPlayerCountdownValue = nil
    sendTrafficWarningChat(-1, string.format(Config.msgPendingPlayer, playerName))
  end
end
MP.RegisterEvent("onPlayerAuth", "onPlayerAuth")

function onPlayerJoin(playerId)
  local playerName = MP.GetPlayerName(playerId)
  if playerName then
    playerIdsToNames[playerId] = playerName
    setMissionHiddenOwner(playerId, false)
    setMissionExitHiddenUntil(playerId, nil)
    logInfo("Player connecting/downloading: " .. playerName .. " (Not synced yet, ignoring traffic locks)")
  end
end
MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")

function onVehicleSpawn(playerId, vehicleId, data)
  local playerName = MP.GetPlayerName(playerId)
  if not playerName then return end

  if type(data) == "string" and not data:find("simple_traffic", 1, true) then
    if not fullyJoinedPlayers[playerName] then
      fullyJoinedPlayers[playerName] = true

      if pendingPlayers[playerName] then
        pendingPlayers[playerName] = nil
      end

      sendTrafficState(playerId)
      sendHiddenTrafficOwners(playerId)
      logInfo(playerName .. " has fully synced and spawned their first vehicle.")

      if not serverHasTraffic then
        if not firstPlayerSpawning then
          firstPlayerSpawning = true
          firstPlayerTimer = os.time() + Config.timerFirstPlayer
          firstPlayer5sWarning = false
          firstPlayerCountdownValue = nil
          logInfo("First player spawned. Waiting for NavGraph...")
          sendTrafficWarningChat(-1, string.format(Config.msgFirstPlayerWait, Config.timerFirstPlayer))
        else
          firstPlayerTimer = os.time() + Config.timerFirstPlayer
          firstPlayer5sWarning = false
          firstPlayerCountdownValue = nil
          sendTrafficWarningChat(-1, string.format(Config.msgExtendTimer, Config.timerFirstPlayer))
        end
      else
        recalcSpawning = false
        recalcCountdownValue = nil
        trafficPaused = true
        clearTrafficForClients()

        if isCountingDown then
          respawnTimer = os.time() + Config.timerPlayerJoin
          oneMinuteWarningSent = false
          join5sWarning = false
          joinCountdownValue = nil
          sendTrafficWarningChat(-1, string.format(Config.msgPlayerJoinReset, playerName))
        else
          isCountingDown = true
          respawnTimer = os.time() + Config.timerPlayerJoin
          oneMinuteWarningSent = false
          join5sWarning = false
          joinCountdownValue = nil
          sendTrafficWarningChat(-1, string.format(Config.msgPlayerJoinWait, playerName))
        end
      end
    end
  end
end
MP.RegisterEvent("onVehicleSpawn", "onVehicleSpawn")

function onPlayerDisconnect(playerId)
  local playerName = playerIdsToNames[playerId]
  local wasFullyJoined = false

  local wasMissionHidden = isMissionHiddenOwner(playerId)
  setMissionHiddenOwner(playerId, false)
  setMissionExitHiddenUntil(playerId, nil)

  if playerName then
    if pendingPlayers[playerName] then
      pendingPlayers[playerName] = nil
    end
    wasFullyJoined = fullyJoinedPlayers[playerName] == true
    fullyJoinedPlayers[playerName] = nil
    playerIdsToNames[playerId] = nil
  end

  if getPlayerCount(true) <= 0 then
    serverHasTraffic = false
    firstPlayerSpawning = false
    trafficPaused = false
    isCountingDown = false
    recalcSpawning = false
    setReplicatedTrafficAmount(0, false)
    logInfo("Server empty. Traffic locks reset.")
  else
    if wasFullyJoined and not trafficPaused and not firstPlayerSpawning then
      recalcSpawning = true
      recalcTimer = os.time() + Config.timerPlayerLeave
      recalcAmount = getScaledTrafficAmount(true)
      recalc5sWarning = false
      recalcCountdownValue = nil

      clearTrafficForClients()
      sendTrafficWarningChat(-1, string.format(Config.msgPlayerLeaveWait, Config.timerPlayerLeave))
    elseif not wasFullyJoined then
      logInfo("A pending player disconnected before syncing. Ignoring traffic recalculation.")
    end
  end

  if wasMissionHidden then
    broadcastHiddenTrafficOwners()
  end
end
MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")

function onTrafficMissionStateChanged(playerId, data)
  local isSuppressed = toBoolean(data, false)
  local wasSuppressed = isMissionSuppressed(playerId)
  local wasHidden = isMissionHiddenOwner(playerId)

  if isSuppressed == wasSuppressed then
    return 0
  end

  local playerName = MP.GetPlayerName(playerId) or playerIdsToNames[playerId] or tostring(playerId)
  if isSuppressed then
    setMissionHiddenOwner(playerId, true)
    setMissionExitHiddenUntil(playerId, nil)
  else
    setMissionHiddenOwner(playerId, false)
    setMissionExitHiddenUntil(playerId, os.time() + Config.missionExitHideDuration)
  end

  local isHiddenNow = isMissionHiddenOwner(playerId)
  if isHiddenNow ~= wasHidden then
    broadcastHiddenTrafficOwners()
  end

  if isSuppressed then
    logInfo(playerName .. " entered a mission. Their synced AI traffic meshes are now hidden for everyone.")
  elseif isHiddenNow then
    logInfo(playerName .. " left a mission. Their synced AI traffic meshes will stay hidden for " .. Config.missionExitHideDuration .. " seconds while traffic disperses.")
  else
    logInfo(playerName .. " left a mission. Their synced AI traffic meshes are visible again.")
  end

  return 0
end
MP.RegisterEvent("traffic_setMissionState", "onTrafficMissionStateChanged")

function onTrafficForceTeleportRequest(playerId, data)
  if not isMissionHiddenOwner(playerId) then
    return 0
  end

  local serverVehicleID = extractServerVehicleId(data)
  if not serverVehicleID then
    return 0
  end

  local ownerId = serverVehicleID:match("^([^-]+)%-.+$")
  if not ownerId then
    return 0
  end

  MP.TriggerClientEvent(tonumber(ownerId) or ownerId, "traffic_forceTeleportVehicle", tostring(data))
  return 0
end
MP.RegisterEvent("traffic_requestForceTeleport", "onTrafficForceTeleportRequest")

function trafficManagerTick()
  local currentTime = os.time()
  local expiredMissionExitOwners = false

  for playerKey, hiddenUntil in pairs(missionExitHiddenUntil) do
    if tonumber(hiddenUntil) and hiddenUntil <= currentTime then
      missionExitHiddenUntil[playerKey] = nil
      expiredMissionExitOwners = true

      if missionTrafficSuppressedPlayers[playerKey] ~= true then
        local playerId = tonumber(playerKey) or playerKey
        local playerName = playerIdsToNames[playerId] or tostring(playerKey)
        logInfo(playerName .. " left mission exit cooldown. Their synced AI traffic meshes are visible again.")
      end
    end
  end

  if expiredMissionExitOwners then
    broadcastHiddenTrafficOwners()
  end

  if firstPlayerSpawning then
    local pendingCount = 0
    for name, authTime in pairs(pendingPlayers) do
      if (currentTime - authTime) < Config.timerPendingTimeout then
        pendingCount = pendingCount + 1
      else
        pendingPlayers[name] = nil
      end
    end

    if pendingCount > 0 then
      firstPlayerTimer = currentTime + Config.timerFirstPlayer
      firstPlayer5sWarning = false
      firstPlayerCountdownValue = nil
    else
      local timeLeft = firstPlayerTimer - currentTime

      if timeLeft <= Config.timerWarningShort and not firstPlayer5sWarning then
        firstPlayer5sWarning = true
        sendTrafficWarningChat(-1, string.format(Config.msgFirstPlayerWarn, Config.timerWarningShort))
      end

      if timeLeft <= SPAWN_COUNTDOWN_START and timeLeft > 0 and firstPlayerCountdownValue ~= timeLeft then
        firstPlayerCountdownValue = timeLeft
        broadcastTrafficSpawnCountdown(timeLeft)
      end

      if timeLeft <= 0 then
        firstPlayerSpawning = false
        firstPlayerCountdownValue = nil
        serverHasTraffic = true

        local amount = getScaledTrafficAmount(false)
        spawnTrafficForClients(amount)
        sendTrafficWarningChat(-1, string.format(Config.msgTrafficSpawned, amount))
      end
    end
  end

  if recalcSpawning then
    local timeLeft = recalcTimer - currentTime

    if timeLeft <= Config.timerWarningShort and not recalc5sWarning then
      recalc5sWarning = true
      sendTrafficWarningChat(-1, string.format(Config.msgQueueShortWarn, Config.timerWarningShort))
    end

    if timeLeft <= SPAWN_COUNTDOWN_START and timeLeft > 0 and recalcCountdownValue ~= timeLeft then
      recalcCountdownValue = timeLeft
      broadcastTrafficSpawnCountdown(timeLeft)
    end

    if timeLeft <= 0 then
      recalcSpawning = false
      recalcCountdownValue = nil
      spawnTrafficForClients(recalcAmount)
      sendTrafficWarningChat(-1, string.format(Config.msgTrafficSpawned, recalcAmount))
    end
  end

  if isCountingDown and trafficPaused then
    local timeLeft = respawnTimer - currentTime

    if timeLeft <= Config.timerWarningLong and not oneMinuteWarningSent then
      oneMinuteWarningSent = true
      sendTrafficWarningChat(-1, string.format(Config.msgQueueLongWarn, Config.timerWarningLong))
    end

    if timeLeft <= Config.timerWarningShort and not join5sWarning then
      join5sWarning = true
      sendTrafficWarningChat(-1, string.format(Config.msgQueueShortWarn, Config.timerWarningShort))
    end

    if timeLeft <= SPAWN_COUNTDOWN_START and timeLeft > 0 and joinCountdownValue ~= timeLeft then
      joinCountdownValue = timeLeft
      broadcastTrafficSpawnCountdown(timeLeft)
    end

    if timeLeft <= 0 then
      isCountingDown = false
      trafficPaused = false
      joinCountdownValue = nil

      local amount = getScaledTrafficAmount(false)
      spawnTrafficForClients(amount)
      sendTrafficWarningChat(-1, string.format(Config.msgTrafficSpawned, amount))
    end
  end
end
MP.RegisterEvent("TrafficManagerTick", "trafficManagerTick")
MP.CreateEventTimer("TrafficManagerTick", Config.tickRate)

function onChatMessage(senderId, senderName, message)
  local msg = tostring(message or "")
  local args = {}
  for word in msg:gmatch("%S+") do
    table.insert(args, word)
  end
  if #args == 0 then return 0 end

  local cmd = args[1]:lower()

  local identifiers = MP.GetPlayerIdentifiers(senderId)
  local beammpId = identifiers and tostring(identifiers.beammp) or nil

  if beammpId and TRAFFIC_ADMINS[beammpId] and TRAFFIC_ADMINS[beammpId] ~= senderName then
    TRAFFIC_ADMINS[beammpId] = senderName
    SaveSettings()
  end

  local isAdmin = beammpId and TRAFFIC_ADMINS[beammpId] ~= nil

  if cmd == "/traffic" then
    if not isAdmin then
      MP.SendChatMessage(senderId, Config.msgNoPermission)
      return 1
    end

    local action = args[2] and args[2]:lower() or ""

    if action == "refresh" then
      local amount = getScaledTrafficAmount(false)
      firstPlayerSpawning = false
      isCountingDown = false
      trafficPaused = false
      serverHasTraffic = true

      recalcSpawning = true
      recalcTimer = os.time() + Config.timerAdminRefresh
      recalcAmount = amount
      recalc5sWarning = false
      recalcCountdownValue = nil

      clearTrafficForClients()
      sendTrafficWarningChat(-1, string.format(Config.msgAdminRefreshWait, senderName, Config.timerAdminRefresh))
      return 1

    elseif action == "status" then
      MP.SendChatMessage(senderId, "--- ^cTraffic Status ^f---")
      MP.SendChatMessage(senderId, "^fMax AI per player: ^c" .. Config.aisPerPlayer)
      MP.SendChatMessage(senderId, "^fMax server traffic: ^c" .. Config.maxServerTraffic)
      MP.SendChatMessage(senderId, "^fGhosting (No Collision): ^c" .. (Config.trafficGhosting and "ON" or "OFF"))
      MP.SendChatMessage(senderId, "^fSpawn warnings: ^c" .. (Config.trafficSpawnWarnings and "ON" or "OFF"))
      MP.SendChatMessage(senderId, "^fCurrent Active Target: ^c" .. getScaledTrafficAmount(false) .. " per player")
      return 1

    elseif action == "help" then
      MP.SendChatMessage(senderId, "--- ^cTraffic Admin Commands ^f---")
      MP.SendChatMessage(senderId, "^c/traffic status ^f- View current traffic settings")
      MP.SendChatMessage(senderId, "^c/traffic refresh ^f- Force refresh AI traffic")
      MP.SendChatMessage(senderId, "^c/traffic maxaipp ^f(^cnum^f) - Set max AI per player")
      MP.SendChatMessage(senderId, "^c/traffic maxtraffic ^f(^cnum^f) - Set max total server AI")
      MP.SendChatMessage(senderId, "^c/traffic ghosting ^f(^con^f|^coff^f) - Toggle traffic collisions")
      MP.SendChatMessage(senderId, "^c/traffic warnings ^f(^con^f|^coff^f) - Toggle traffic spawn warnings")
      MP.SendChatMessage(senderId, "^f(^cAdmin management and player lookups are console-only^f)")
      return 1

    elseif action == "maxaipp" then
      if args[3] then
        local num = tonumber(args[3])
        if num and num >= 1 then
          Config.aisPerPlayer = math.floor(num)
          SaveSettings()
          MP.SendChatMessage(senderId, "^l^cMax AI per player updated to: " .. Config.aisPerPlayer .. ". Use ^b/traffic refresh ^cwhen ready.")
          logInfo(senderName .. " changed maxaipp to " .. Config.aisPerPlayer)
        else
          MP.SendChatMessage(senderId, "^l^cUsage: /traffic maxaipp <number> (Must be 1 or higher)")
        end
      else
        MP.SendChatMessage(senderId, "^l^cCurrent Max AI per player: " .. Config.aisPerPlayer)
      end
      return 1

    elseif action == "maxtraffic" then
      if args[3] then
        local num = tonumber(args[3])
        if num and num >= 1 then
          Config.maxServerTraffic = math.floor(num)
          SaveSettings()
          MP.SendChatMessage(senderId, "^l^cMax total server traffic updated to: " .. Config.maxServerTraffic .. ". Use ^b/traffic refresh ^cwhen ready.")
          logInfo(senderName .. " changed maxtraffic to " .. Config.maxServerTraffic)
        else
          MP.SendChatMessage(senderId, "^l^cUsage: /traffic maxtraffic <number> (Must be 1 or higher)")
        end
      else
        MP.SendChatMessage(senderId, "^l^cCurrent Max Server Traffic: " .. Config.maxServerTraffic)
      end
      return 1

    elseif action == "ghosting" then
      if args[3] then
        local state = args[3]:lower()
        if state == "on" or state == "1" or state == "true" then
          Config.trafficGhosting = true
          SaveSettings()
          syncTrafficGhosting()
          MP.TriggerClientEvent(-1, "showGhostingMessage", "1")
          MP.SendChatMessage(senderId, "^l^cTraffic ghosting ENABLED. Cars will pass through players.")
          logInfo(senderName .. " ENABLED traffic ghosting via chat.")
        elseif state == "off" or state == "0" or state == "false" then
          Config.trafficGhosting = false
          SaveSettings()
          syncTrafficGhosting()
          MP.TriggerClientEvent(-1, "showGhostingMessage", "0")
          MP.SendChatMessage(senderId, "^l^cTraffic ghosting DISABLED. Cars are now solid.")
          logInfo(senderName .. " DISABLED traffic ghosting via chat.")
        else
          MP.SendChatMessage(senderId, "^l^cUsage: /traffic ghosting <on|off>")
        end
      else
        MP.SendChatMessage(senderId, "^l^cGhosting is currently: " .. (Config.trafficGhosting and "ON" or "OFF"))
        MP.SendChatMessage(senderId, "^l^cUsage: /traffic ghosting <on|off>")
      end
      return 1

    elseif action == "warnings" then
      if args[3] then
        local state = args[3]:lower()
        if state == "on" or state == "1" or state == "true" then
          Config.trafficSpawnWarnings = true
          SaveSettings()
          MP.SendChatMessage(senderId, "^l^cTraffic spawn warnings ENABLED.")
          logInfo(senderName .. " ENABLED traffic spawn warnings via chat.")
        elseif state == "off" or state == "0" or state == "false" then
          Config.trafficSpawnWarnings = false
          SaveSettings()
          MP.SendChatMessage(senderId, "^l^cTraffic spawn warnings DISABLED.")
          logInfo(senderName .. " DISABLED traffic spawn warnings via chat.")
        else
          MP.SendChatMessage(senderId, "^l^cUsage: /traffic warnings <on|off>")
        end
      else
        MP.SendChatMessage(senderId, "^l^cTraffic spawn warnings are currently: " .. (Config.trafficSpawnWarnings and "ON" or "OFF"))
        MP.SendChatMessage(senderId, "^l^cUsage: /traffic warnings <on|off>")
      end
      return 1

    else
      MP.SendChatMessage(senderId, "^l^cUnknown traffic command. Type ^b/traffic help ^cfor options.")
      return 1
    end
  end

  if msg == "/mytraffic refresh" then
    sendTrafficState(senderId, {forceRespawn = true})
    MP.SendChatMessage(senderId, "^l^cYour local traffic has been refreshed.")
    return 1
  end

  return 0
end
MP.RegisterEvent("onChatMessage", "onChatMessage")

function onConsoleTrafficInput(cmd)
  local rawInput = cmd:match("^%s*(.-)%s*$")
  local args = {}
  for word in rawInput:gmatch("%S+") do
    table.insert(args, word)
  end
  if #args == 0 then return end

  local command = args[1]:lower()

  if command == "traffic.help" or command == "traffic.h" then
    logInfo("--- Traffic Console Commands ---")
    logInfo("traffic.help (traffic.h)      - Show this help menu")
    logInfo("traffic.status (traffic.s)    - View current traffic settings")
    logInfo("traffic.au <ID> <Name>        - Add an Admin")
    logInfo("traffic.ru <ID>               - Remove an Admin")
    logInfo("traffic.admins                - List current Admins")
    logInfo("traffic.lookup <Name>         - Find online player's ID & link")
    logInfo("traffic.ghosting <on|off>     - Toggle traffic collisions")
    logInfo("traffic.warnings <on|off>     - Toggle traffic spawn warnings")
    logInfo("traffic.maxaipp <number>      - Set max AI cars per player")
    logInfo("traffic.maxtraffic <number>   - Set max total AI cars on server")
    return ""

  elseif command == "traffic.status" or command == "traffic.s" then
    logInfo("--- Traffic Status ---")
    logInfo("Max AI per player: " .. Config.aisPerPlayer)
    logInfo("Max server traffic: " .. Config.maxServerTraffic)
    logInfo("Ghosting (No Collision): " .. (Config.trafficGhosting and "ON" or "OFF"))
    logInfo("Spawn warnings: " .. (Config.trafficSpawnWarnings and "ON" or "OFF"))
    logInfo("Current Active Target: " .. getScaledTrafficAmount(false) .. " per player")
    return ""

  elseif command == "traffic.au" or command == "traffic.addadmin" then
    if #args >= 3 then
      local id = args[2]
      local name = table.concat(args, " ", 3)
      TRAFFIC_ADMINS[id] = name
      SaveSettings()
      logInfo("Added Admin: ID '" .. id .. "' | Name: '" .. name .. "'")
    else
      logInfo("Usage: traffic.au <ID> <Name>")
    end
    return ""

  elseif command == "traffic.ru" or command == "traffic.remadmin" then
    if #args >= 2 then
      local id = args[2]
      if TRAFFIC_ADMINS[id] then
        local removedName = TRAFFIC_ADMINS[id]
        TRAFFIC_ADMINS[id] = nil
        SaveSettings()
        logInfo("Removed Admin: ID '" .. id .. "' | Name: '" .. tostring(removedName) .. "'")
      else
        logInfo("Error: Could not find an admin with ID '" .. id .. "'")
      end
    else
      logInfo("Usage: traffic.ru <ID>")
    end
    return ""

  elseif command == "traffic.admins" then
    logInfo("--- Current Traffic Admins ---")
    local count = 0
    for id, name in pairs(TRAFFIC_ADMINS) do
      local safeName = tostring(name):gsub(" ", "_")
      logInfo("ID: " .. id .. " | Name: " .. tostring(name) .. " | URL: https://forum.beammp.com/u/" .. safeName)
      count = count + 1
    end
    if count == 0 then
      logInfo("(None)")
    end
    return ""

  elseif command == "traffic.lookup" or command == "traffic.lu" then
    if #args > 1 then
      local targetName = table.concat(args, " ", 2)
      local targetNameLower = targetName:lower()
      local found = false
      local players = MP.GetPlayers()

      for pid, name in pairs(players) do
        if name:lower() == targetNameLower then
          local targetIdentifiers = MP.GetPlayerIdentifiers(pid)
          local targetId = targetIdentifiers and tostring(targetIdentifiers.beammp) or "Unknown"
          local safeName = name:gsub(" ", "_")
          local url = "https://forum.beammp.com/u/" .. safeName

          logInfo("Found User: " .. name .. " | ID: " .. targetId)
          logInfo("Profile URL: " .. url)
          found = true
          break
        end
      end

      if not found then
        local safeName = targetName:gsub(" ", "_")
        logInfo("Player '" .. targetName .. "' is not currently online to fetch their ID.")
        logInfo("However, their profile URL would be: https://forum.beammp.com/u/" .. safeName)
      end
    else
      logInfo("Usage: traffic.lookup <username>")
    end
    return ""

  elseif command == "traffic.ghosting" or command == "traffic.g" then
    if #args >= 2 then
      local state = args[2]:lower()
      if state == "on" or state == "1" or state == "true" then
        Config.trafficGhosting = true
        SaveSettings()
        syncTrafficGhosting()
        MP.TriggerClientEvent(-1, "showGhostingMessage", "1")
        logInfo("Traffic ghosting ENABLED. Cars will pass through players.")
      elseif state == "off" or state == "0" or state == "false" then
        Config.trafficGhosting = false
        SaveSettings()
        syncTrafficGhosting()
        MP.TriggerClientEvent(-1, "showGhostingMessage", "0")
        logInfo("Traffic ghosting DISABLED. Cars are now solid.")
      else
        logInfo("Usage: traffic.ghosting <on|off>")
      end
    else
      logInfo("Ghosting is currently: " .. (Config.trafficGhosting and "ON" or "OFF"))
      logInfo("Usage: traffic.ghosting <on|off>")
    end
    return ""

  elseif command == "traffic.warnings" or command == "traffic.w" then
    if #args >= 2 then
      local state = args[2]:lower()
      if state == "on" or state == "1" or state == "true" then
        Config.trafficSpawnWarnings = true
        SaveSettings()
        logInfo("Traffic spawn warnings ENABLED.")
      elseif state == "off" or state == "0" or state == "false" then
        Config.trafficSpawnWarnings = false
        SaveSettings()
        logInfo("Traffic spawn warnings DISABLED.")
      else
        logInfo("Usage: traffic.warnings <on|off>")
      end
    else
      logInfo("Traffic spawn warnings are currently: " .. (Config.trafficSpawnWarnings and "ON" or "OFF"))
      logInfo("Usage: traffic.warnings <on|off>")
    end
    return ""

  elseif command == "traffic.maxaipp" then
    if #args >= 2 then
      local num = tonumber(args[2])
      if num and num >= 1 then
        Config.aisPerPlayer = math.floor(num)
        SaveSettings()
        logInfo("Max AI per player updated to: " .. Config.aisPerPlayer .. ". (Use /traffic refresh in-game to apply)")
      else
        logInfo("Usage: traffic.maxaipp <number> (Must be 1 or higher)")
      end
    else
      logInfo("Current Max AI per player: " .. Config.aisPerPlayer)
      logInfo("Usage: traffic.maxaipp <number>")
    end
    return ""

  elseif command == "traffic.maxtraffic" then
    if #args >= 2 then
      local num = tonumber(args[2])
      if num and num >= 1 then
        Config.maxServerTraffic = math.floor(num)
        SaveSettings()
        logInfo("Max total server traffic updated to: " .. Config.maxServerTraffic .. ". (Use /traffic refresh in-game to apply)")
      else
        logInfo("Usage: traffic.maxtraffic <number> (Must be 1 or higher)")
      end
    else
      logInfo("Current Max Server Traffic: " .. Config.maxServerTraffic)
      logInfo("Usage: traffic.maxtraffic <number>")
    end
    return ""
  end
end
MP.RegisterEvent("onConsoleInput", "onConsoleTrafficInput")

local function initExistingPlayers()
  LoadSettings()

  if MP and MP.GetPlayers then
    local ok, players = pcall(MP.GetPlayers)
    if ok and type(players) == "table" then
      for id, name in pairs(players) do
        playerIdsToNames[id] = name
        fullyJoinedPlayers[name] = true
        serverHasTraffic = true
      end
    end
  end

  if serverHasTraffic then
    setReplicatedTrafficAmount(getScaledTrafficAmount(false), true)
  else
    setReplicatedTrafficAmount(0, false)
  end

  logInfo("Server module loaded successfully. Existing players grandfathered in.")
end

initExistingPlayers()
