local M = {}

local DEFAULT_SPAWN_OPTIONS = {
  simpleVehs = true,
  autoLoadFromFile = true
}

local trafficTuning = {
  missionProtectionRadius = 50,
  missionTeleportRadius = 75,
  missionTeleportMinDist = 200,
  missionTeleportMaxDist = 350,
  missionTeleportTargetDist = 270,
  missionTeleportCooldown = 2,
  missionTeleportBatchLimit = 2,
  missionExitGhostDuration = 10,
  trafficVisualUpdateInterval = 0.25,
  trafficSpawnGhostDuration = 3,
  trafficSeparationRadius = 10
}

local trafficState = {
  enabled = false,
  amount = 0,
  ghosting = false
}

local appliedState = {
  enabled = nil,
  amount = nil
}

local stateDirty = true
local pendingForceRespawn = false
local lastStateApplyAt = 0

local ghostingEnabled = false
local lastGhostCheckAt = 0
local trackedTrafficVisualState = {}

local missionTrafficSuppressed = false
local lastMissionCheckAt = 0
local lastMissionReportedState = nil
local missionExitGhostUntil = 0
local hiddenTrafficOwners = {}
local recentTrafficTeleportRequests = {}
local queueTrafficApply

local function toInteger(value, defaultValue)
  local n = tonumber(value)
  if not n then return defaultValue end
  return math.max(0, math.floor(n))
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

local function decodePayload(data)
  if type(data) == "table" then return data end
  if type(data) ~= "string" or data == "" then return nil end
  if not jsonDecode then return nil end

  local ok, decoded = pcall(jsonDecode, data)
  if ok and type(decoded) == "table" then
    return decoded
  end

  return nil
end

local function isMissionActive()
  if not gameplay_missions_missionManager or not gameplay_missions_missionManager.getForegroundMissionId then
    return false
  end

  local ok, missionId = pcall(gameplay_missions_missionManager.getForegroundMissionId)
  return ok and missionId ~= nil
end

local function reportMissionState(forceReport)
  if not TriggerServerEvent then return end

  if forceReport or lastMissionReportedState ~= missionTrafficSuppressed then
    lastMissionReportedState = missionTrafficSuppressed
    TriggerServerEvent("traffic_setMissionState", missionTrafficSuppressed and "1" or "0")
  end
end

local function refreshMissionTrafficSuppression(forceReport)
  local shouldSuppress = isMissionActive()
  if missionTrafficSuppressed ~= shouldSuppress then
    if missionTrafficSuppressed and not shouldSuppress then
      missionExitGhostUntil = os.clock() + trafficTuning.missionExitGhostDuration
    elseif shouldSuppress then
      missionExitGhostUntil = 0
    end

    missionTrafficSuppressed = shouldSuppress
    lastGhostCheckAt = 0
    reportMissionState(true)
    return
  end

  if forceReport then
    reportMissionState(true)
  end
end

local function ensureTrafficExtension()
  if gameplay_traffic then return true end
  if extensions and extensions.load then
    pcall(extensions.load, "gameplay_traffic")
  end
  return gameplay_traffic ~= nil
end

local function hasTrafficVehicles()
  if not gameplay_traffic or not gameplay_traffic.getTrafficList then return false end

  local ok, trafficList = pcall(gameplay_traffic.getTrafficList, true)
  if not ok or type(trafficList) ~= "table" then return false end

  return next(trafficList) ~= nil
end

local function applyGhostingEnabled(newState)
  ghostingEnabled = newState
end

local function normalizeOwnerKey(vehicleKey, vehicleData)
  if type(vehicleData) == "table" and vehicleData.ownerID ~= nil then
    return tostring(vehicleData.ownerID)
  end

  local serverVehicleId = tostring(vehicleKey or "")
  local ownerKey = serverVehicleId:match("^([^-]+)%-.+$")
  if ownerKey then
    return ownerKey
  end

  return nil
end

local function getObjectPosition(objVeh)
  if not objVeh or not objVeh.getPosition then return nil end
  local position = objVeh:getPosition()
  if not position or position.x == nil or position.y == nil or position.z == nil then
    return nil
  end

  return position
end

local function getObjectDirection(objVeh)
  if not objVeh or not objVeh.getDirectionVector then return nil end
  local direction = objVeh:getDirectionVector()
  if not direction or direction.x == nil or direction.y == nil or direction.z == nil then
    return nil
  end

  return direction
end

local function getSquaredDistance(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  local dz = a.z - b.z
  return (dx * dx) + (dy * dy) + (dz * dz)
end

local function isWithinRadius(position, comparePositions, radius)
  if not position or #comparePositions == 0 then
    return false
  end

  local radiusSq = radius * radius
  for _, comparePosition in ipairs(comparePositions) do
    if getSquaredDistance(position, comparePosition) <= radiusSq then
      return true
    end
  end

  return false
end

local function getMissionReferenceTransform()
  local playerVeh = getPlayerVehicle and getPlayerVehicle(0) or nil
  local position = getObjectPosition(playerVeh)
  local direction = getObjectDirection(playerVeh)
  if position and direction then
    return position, direction
  end

  if core_camera and core_camera.getPosition and core_camera.getForward then
    local cameraPosition = core_camera.getPosition()
    local cameraDirection = core_camera.getForward()
    if cameraPosition and cameraDirection and cameraPosition.x ~= nil and cameraDirection.x ~= nil then
      return cameraPosition, cameraDirection
    end
  end

  return nil, nil
end

local function requestTrafficTeleport(serverVehicleID, position, direction)
  if not TriggerServerEvent or type(serverVehicleID) ~= "string" or serverVehicleID == "" then
    return false
  end
  if not position or not direction then return false end

  local now = os.clock()
  local lastRequestAt = recentTrafficTeleportRequests[serverVehicleID] or 0
  if (now - lastRequestAt) < trafficTuning.missionTeleportCooldown then
    return false
  end

  recentTrafficTeleportRequests[serverVehicleID] = now

  local payload = string.format(
    "%s|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f",
    serverVehicleID,
    position.x, position.y, position.z,
    direction.x, direction.y, direction.z,
    trafficTuning.missionTeleportMinDist,
    trafficTuning.missionTeleportMaxDist,
    trafficTuning.missionTeleportTargetDist
  )

  TriggerServerEvent("traffic_requestForceTeleport", payload)
  return true
end

local function parseForceTeleportPayload(data)
  if type(data) ~= "string" or data == "" then return nil end

  local parts = {}
  for part in string.gmatch(data, "[^|]+") do
    table.insert(parts, part)
  end

  if #parts ~= 10 then return nil end

  local px = tonumber(parts[2])
  local py = tonumber(parts[3])
  local pz = tonumber(parts[4])
  local dx = tonumber(parts[5])
  local dy = tonumber(parts[6])
  local dz = tonumber(parts[7])
  local minDist = tonumber(parts[8])
  local maxDist = tonumber(parts[9])
  local targetDist = tonumber(parts[10])

  if not (px and py and pz and dx and dy and dz and minDist and maxDist and targetDist) then
    return nil
  end

  return {
    serverVehicleID = parts[1],
    position = vec3(px, py, pz),
    direction = vec3(dx, dy, dz),
    minDist = minDist,
    maxDist = maxDist,
    targetDist = targetDist
  }
end

local function forceTeleportOwnedTraffic(data)
  local payload = parseForceTeleportPayload(data)
  if not payload then return end
  if not ensureTrafficExtension() then return end
  if not MPVehicleGE then return end

  local vehicleData = MPVehicleGE.getVehicleByServerID and MPVehicleGE.getVehicleByServerID(payload.serverVehicleID) or nil
  local gameVehicleID = tonumber(vehicleData and vehicleData.gameVehicleID or nil)
  if (not gameVehicleID or gameVehicleID < 0) and MPVehicleGE.getGameVehicleID then
    gameVehicleID = tonumber(MPVehicleGE.getGameVehicleID(payload.serverVehicleID))
  end

  if not gameVehicleID or gameVehicleID < 0 then return end
  if vehicleData and tostring(vehicleData.jbeam or "") ~= "simple_traffic" then return end
  if gameplay_traffic and gameplay_traffic.forceTeleport then
    pcall(gameplay_traffic.forceTeleport, gameVehicleID, payload.position, payload.direction, payload.minDist, payload.maxDist, payload.targetDist)
  end
end

local function setVehicleGhostEnabled(objVeh, isEnabled)
  if not objVeh then return end
  objVeh:queueLuaCommand("if obj and obj.setGhostEnabled then obj:setGhostEnabled(" .. tostring(isEnabled) .. ") end")
end

local function restoreTrafficVisualState(id)
  local objVeh = getObjectByID(id)
  if objVeh then
    setVehicleGhostEnabled(objVeh, false)
    if objVeh.setMeshAlpha then
      objVeh:setMeshAlpha(1.0, "", false)
    end
  end

  trackedTrafficVisualState[id] = nil
end

local function applyTrafficVisualState(id, shouldGhost, targetAlpha)
  local objVeh = getObjectByID(id)
  if not objVeh then return end

  local currentState = trackedTrafficVisualState[id] or {}

  if shouldGhost or currentState.ghosted ~= shouldGhost then
    setVehicleGhostEnabled(objVeh, shouldGhost)
    currentState.ghosted = shouldGhost
  end

  if currentState.alpha == nil or math.abs(currentState.alpha - targetAlpha) > 0.02 then
    if objVeh.setMeshAlpha then
      objVeh:setMeshAlpha(targetAlpha, "", false)
    end
    currentState.alpha = targetAlpha
  end

  trackedTrafficVisualState[id] = currentState
end

local function isTrafficSpawnGhostActive(id, serverVehicleID, now)
  local currentState = trackedTrafficVisualState[id] or {}

  if currentState.serverVehicleID ~= serverVehicleID or currentState.spawnGhostUntil == nil then
    currentState.serverVehicleID = serverVehicleID
    currentState.spawnGhostUntil = now + trafficTuning.trafficSpawnGhostDuration
    trackedTrafficVisualState[id] = currentState
  end

  return (currentState.spawnGhostUntil or 0) > now
end

local function getNearbyTrafficGhostIds(trafficVehicles, radius)
  local nearbyIds = {}
  local radiusSq = radius * radius

  for i = 1, #trafficVehicles do
    local trafficVehicle = trafficVehicles[i]
    if trafficVehicle.position then
      for j = i + 1, #trafficVehicles do
        local otherTrafficVehicle = trafficVehicles[j]
        if otherTrafficVehicle.position and getSquaredDistance(trafficVehicle.position, otherTrafficVehicle.position) <= radiusSq then
          nearbyIds[trafficVehicle.id] = true
          nearbyIds[otherTrafficVehicle.id] = true
        end
      end
    end
  end

  return nearbyIds
end

local function setHiddenTrafficOwners(data)
  local decoded = decodePayload(data)
  if type(decoded) ~= "table" then return end

  local nextOwners = {}
  local owners = decoded.owners

  if type(owners) == "table" then
    for key, value in pairs(owners) do
      if type(key) == "number" then
        nextOwners[tostring(value)] = true
      elseif value then
        nextOwners[tostring(key)] = true
      end
    end
  end

  hiddenTrafficOwners = nextOwners
  lastGhostCheckAt = 0
end

local function deleteTrafficVehicles()
  if not ensureTrafficExtension() then return true end

  if gameplay_traffic.deleteVehicles then
    gameplay_traffic.deleteVehicles()
    return true
  end

  if gameplay_traffic.removeTraffic and gameplay_traffic.getTrafficList then
    local ok, trafficList = pcall(gameplay_traffic.getTrafficList, true)
    if ok and type(trafficList) == "table" then
      for _, id in pairs(trafficList) do
        gameplay_traffic.removeTraffic(id, true)
      end
    end
    return true
  end

  return false
end

local function tryApplyTrafficState(forceRespawn)
  local enabled = toBoolean(trafficState.enabled, false)
  local amount = toInteger(trafficState.amount, 0)

  applyGhostingEnabled(toBoolean(trafficState.ghosting, false))

  if not enabled or amount <= 0 then
    deleteTrafficVehicles()
    appliedState.enabled = enabled
    appliedState.amount = amount
    stateDirty = false
    pendingForceRespawn = false
    return true
  end

  if not ensureTrafficExtension() then
    return false
  end

  local shouldRespawn = forceRespawn or appliedState.enabled ~= enabled or appliedState.amount ~= amount

  if shouldRespawn and hasTrafficVehicles() then
    deleteTrafficVehicles()
  end

  local trafficStateName = gameplay_traffic.getState and gameplay_traffic.getState() or "off"
  if shouldRespawn or trafficStateName == "off" or not hasTrafficVehicles() then
    if gameplay_traffic.setupTraffic then
      local ok, spawned = pcall(gameplay_traffic.setupTraffic, amount, 0, DEFAULT_SPAWN_OPTIONS)
      if not ok or spawned == false then
        return false
      end
    else
      return false
    end
  end

  if gameplay_traffic.setTrafficVars then
    gameplay_traffic.setTrafficVars({
      enableRandomEvents = false,
      activeAmount = amount
    })
  end

  if gameplay_traffic.setActiveAmount then
    gameplay_traffic.setActiveAmount(amount)
  end

  appliedState.enabled = enabled
  appliedState.amount = amount
  stateDirty = false
  pendingForceRespawn = false
  return true
end

queueTrafficApply = function(forceRespawn)
  stateDirty = true
  pendingForceRespawn = pendingForceRespawn or forceRespawn == true
end

local function applyStructuredTrafficState(data)
  local decoded = decodePayload(data)
  if type(decoded) ~= "table" then return end

  if decoded.enabled ~= nil then
    trafficState.enabled = toBoolean(decoded.enabled, trafficState.enabled)
  end

  if decoded.amount ~= nil then
    trafficState.amount = toInteger(decoded.amount, trafficState.amount)
  end

  if decoded.ghosting ~= nil then
    trafficState.ghosting = toBoolean(decoded.ghosting, trafficState.ghosting)
  end

  queueTrafficApply(toBoolean(decoded.forceRespawn, false))
end

local function spawnTraffic(amountArg)
  trafficState.amount = toInteger(amountArg, trafficState.amount)
  if trafficState.amount > 0 then
    trafficState.enabled = true
  end
  queueTrafficApply(true)
end

local function deleteTraffic()
  trafficState.enabled = false
  trafficState.amount = 0
  queueTrafficApply(true)
end

local function setTrafficAmount(value)
  trafficState.amount = toInteger(value, trafficState.amount)
  queueTrafficApply(false)
end

local function setTrafficEnabled(value)
  trafficState.enabled = toBoolean(value, trafficState.enabled)
  if not trafficState.enabled then
    trafficState.amount = 0
  end
  queueTrafficApply(true)
end

local function setTrafficGhosting(value)
  trafficState.ghosting = toBoolean(value, trafficState.ghosting)
  applyGhostingEnabled(trafficState.ghosting)
end

local function showGhostingMessage(value)
  local isEnabled = toBoolean(value, false)
  local msg

  if isEnabled then
    msg = "<span style='font-size: 30px; color: #48ff00;'>Traffic Ghost Mode ON(AI Collisions Disabled)</span><br><span style='font-size: 5px; color: #ffffff;'>(AI Collisions Disabled)</span>"
  else
    msg = "<span style='font-size: 30px; color: #ff0000;'>Traffic Ghost Mode OFF(AI Collisions Enabled)</span><br><span style='font-size: 5px; color: #ffffff;'>(AI Collisions Enabled)</span>"
  end

  if guihooks then
    guihooks.trigger("ScenarioFlashMessage", {{msg, 5, "", true}})
  end
end

local function showTrafficSpawnCountdown(value)
  local seconds = toInteger(value, 0)
  if seconds <= 0 then return end

  local suffix = seconds == 1 and "Second" or "Seconds"
  local msg = string.format(
    "<span style='font-size: 60px; color: #ff0000;'>Traffic Spawning In %d %s!</span>",
    seconds,
    suffix
  )

  if guihooks then
    guihooks.trigger("ScenarioFlashMessage", {{msg, 1, "", false}})
  end
end

local function onUpdate(_dtReal, _dtSim, _dtRaw)
  local now = os.clock()

  if (now - lastMissionCheckAt) >= 0.25 then
    lastMissionCheckAt = now
    refreshMissionTrafficSuppression(false)
  end

  if stateDirty and (now - lastStateApplyAt) >= 0.5 then
    lastStateApplyAt = now
    tryApplyTrafficState(pendingForceRespawn)
  end

  if (now - lastGhostCheckAt) < trafficTuning.trafficVisualUpdateInterval then return end

  lastGhostCheckAt = now

  if not MPVehicleGE or not MPVehicleGE.getVehicles then return end

  local seenVisualStateIds = {}
  local missionPlayerPositions = {}
  local trafficVehicles = {}
  local missionReferencePosition, missionReferenceDirection = nil, nil
  local teleportRequestsSent = 0
  local missionExitGhostActive = (not missionTrafficSuppressed) and missionExitGhostUntil > now

  if missionTrafficSuppressed then
    missionReferencePosition, missionReferenceDirection = getMissionReferenceTransform()
  end

  for vehicleKey, vehicleData in pairs(MPVehicleGE.getVehicles() or {}) do
    if vehicleData and vehicleData.gameVehicleID then
      local id = tonumber(vehicleData.gameVehicleID)
      if id then
        local ownerKey = normalizeOwnerKey(vehicleKey, vehicleData)
        local isSimpleTraffic = tostring(vehicleData.jbeam or "") == "simple_traffic"
        local isMissionOwner = ownerKey ~= nil and hiddenTrafficOwners[ownerKey] == true

        if isSimpleTraffic then
          table.insert(trafficVehicles, {
            id = id,
            serverVehicleID = tostring(vehicleKey or ""),
            isMissionOwner = isMissionOwner
          })
        elseif isMissionOwner then
          local missionPlayerObj = getObjectByID(id)
          local missionPlayerPosition = getObjectPosition(missionPlayerObj)
          if missionPlayerPosition then
            table.insert(missionPlayerPositions, missionPlayerPosition)
          end
        end
      end
    end
  end

  for _, trafficVehicle in ipairs(trafficVehicles) do
    local objVeh = getObjectByID(trafficVehicle.id)
    if objVeh then
      trafficVehicle.objVeh = objVeh
      trafficVehicle.position = getObjectPosition(objVeh)
    end
  end

  local nearbyTrafficGhostIds = getNearbyTrafficGhostIds(trafficVehicles, trafficTuning.trafficSeparationRadius)

  for _, trafficVehicle in ipairs(trafficVehicles) do
    local id = trafficVehicle.id
    local objVeh = trafficVehicle.objVeh
    if objVeh then
      local trafficPosition = trafficVehicle.position
      local spawnGhostActive = isTrafficSpawnGhostActive(id, trafficVehicle.serverVehicleID, now)
      local shouldHide = missionTrafficSuppressed or trafficVehicle.isMissionOwner or missionExitGhostActive
      local targetAlpha = shouldHide and 0.0 or 1.0
      local nearMissionPlayer = not shouldHide and isWithinRadius(trafficPosition, missionPlayerPositions, trafficTuning.missionProtectionRadius)
      local nearTrafficVehicle = nearbyTrafficGhostIds[id] == true
      local shouldGhost = ghostingEnabled or shouldHide or nearMissionPlayer or missionExitGhostActive or spawnGhostActive or nearTrafficVehicle

      applyTrafficVisualState(id, shouldGhost, targetAlpha)
      seenVisualStateIds[id] = true

      if missionTrafficSuppressed
        and missionReferencePosition
        and missionReferenceDirection
        and teleportRequestsSent < trafficTuning.missionTeleportBatchLimit
        and not trafficVehicle.isMissionOwner
        and trafficPosition
        and getSquaredDistance(trafficPosition, missionReferencePosition) <= (trafficTuning.missionTeleportRadius * trafficTuning.missionTeleportRadius)
      then
        if requestTrafficTeleport(trafficVehicle.serverVehicleID, missionReferencePosition, missionReferenceDirection) then
          teleportRequestsSent = teleportRequestsSent + 1
        end
      end
    end
  end

  local trafficIdsToRestore = {}
  for id in pairs(trackedTrafficVisualState) do
    if not seenVisualStateIds[id] then
      table.insert(trafficIdsToRestore, id)
    end
  end

  for _, id in ipairs(trafficIdsToRestore) do
    restoreTrafficVisualState(id)
  end
end

local function onExtensionLoaded()
  AddEventHandler("traffic_applyState", applyStructuredTrafficState)
  AddEventHandler("traffic_setHiddenOwners", setHiddenTrafficOwners)
  AddEventHandler("traffic_forceTeleportVehicle", forceTeleportOwnedTraffic)

  AddEventHandler("spawnTraffic", spawnTraffic)
  AddEventHandler("deleteTraffic", deleteTraffic)
  AddEventHandler("setTrafficAmount", setTrafficAmount)
  AddEventHandler("setTrafficEnabled", setTrafficEnabled)
  AddEventHandler("setTrafficGhosting", setTrafficGhosting)
  AddEventHandler("showGhostingMessage", showGhostingMessage)
  AddEventHandler("showTrafficSpawnCountdown", showTrafficSpawnCountdown)

  AddEventHandler("setTrafficAggression", function() end)
  AddEventHandler("setTrafficNametagsVisible", function() end)
  AddEventHandler("setTrafficRadius", function() end)
  AddEventHandler("setTrafficPoolPercent", function() end)
  AddEventHandler("setTrafficRefillInterval", function() end)
  AddEventHandler("setTrafficSpread", function() end)

  refreshMissionTrafficSuppression(true)
  queueTrafficApply(false)
end

local function onClientStartMission()
  refreshMissionTrafficSuppression(true)
end

M.onExtensionLoaded = onExtensionLoaded
M.onClientStartMission = onClientStartMission
M.onUpdate = onUpdate

return M
