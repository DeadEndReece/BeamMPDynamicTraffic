local M = {}

local trafficAmount = 0 
local trafficEnabled = true
local requestedJoinSync = false

local function ensureTrafficExtension()
  if gameplay_traffic then return true end
  if extensions and extensions.load then
    pcall(extensions.load, "gameplay_traffic")
  end
  return gameplay_traffic ~= nil
end

local function executeSpawn()
  if not trafficEnabled then return end
  if not ensureTrafficExtension() then return end

  local amount = math.floor(trafficAmount)
  if amount <= 0 then return end

  local spawnOptions = {
    simpleVehs = true, 
    autoLoadFromFile = true 
  }

  if gameplay_traffic.setupTraffic then

    gameplay_traffic.setupTraffic(amount, 0, spawnOptions)
    
    gameplay_traffic.setTrafficVars({enableRandomEvents = false})
    
    gameplay_traffic.setActiveAmount(amount)
  end
end

local function spawnTraffic(amountArg)
  local amount = tonumber(amountArg)
  if amount then trafficAmount = math.floor(amount) end
  if trafficEnabled then executeSpawn() end
end

local function deleteTraffic()
  if not ensureTrafficExtension() then return end
  if gameplay_traffic.deleteVehicles then
    gameplay_traffic.deleteVehicles()
  elseif gameplay_traffic.removeTraffic then
    gameplay_traffic.removeTraffic()
  end
end

local function setTrafficAmount(value)
  local n = tonumber(value)
  if n then trafficAmount = math.floor(n) end
end

local function setTrafficEnabled(value)
  local v = tostring(value or ""):lower()
  trafficEnabled = (v == "1" or v == "true" or v == "on")
  if not trafficEnabled then deleteTraffic() end
end

local function connectionFinished()
  if TriggerServerEvent then
    TriggerServerEvent("connectionFinished", "")
    requestedJoinSync = true
  end
end

-- ==========================================================
-- MULTIPLAYER ANTI-EXPLOSION PROTECTION
-- ==========================================================
local ghostingEnabled = false
local lastGhostCheckAt = 0
local ghostedTraffic = {} 

local function setTrafficGhosting(value)
  local v = tostring(value or ""):lower()
  local newState = (v == "1" or v == "true" or v == "on")

  -- Un-ghost immediately if toggled off
  if not newState and ghostingEnabled then
    if MPVehicleGE and MPVehicleGE.getVehicles then
      for id, _ in pairs(ghostedTraffic) do
        local objVeh = getObjectByID(id)
        if objVeh then
          objVeh:queueLuaCommand("if obj and obj.setGhostEnabled then obj:setGhostEnabled(false) end")
          if objVeh.setMeshAlpha then objVeh:setMeshAlpha(1.0, "", false) end
        end
      end
    end
    ghostedTraffic = {}
  end

  ghostingEnabled = newState
end

-- Dedicated UI Message triggered by Server Console Command
local function showGhostingMessage(value)
  local v = tostring(value or ""):lower()
  local isEnabled = (v == "1" or v == "true" or v == "on")
  
  if isEnabled then
    local msg = "<span style='font-size: 30px; color: #48ff00;'>Traffic Ghost Mode ON(AI Collisions Disabled)</span><br><span style='font-size: 5px; color: #ffffff;'>(AI Collisions Disabled)</span>"
    if guihooks then guihooks.trigger('ScenarioFlashMessage', {{msg, 5, "", true}}) end
  else
    local msg = "<span style='font-size: 30px; color: #ff0000;'>Traffic Ghost Mode OFF(AI Collisions Enabled)</span><br><span style='font-size: 5px; color: #ffffff;'>(AI Collisions Enabled)</span>"
    if guihooks then guihooks.trigger('ScenarioFlashMessage', {{msg, 5, "", true}}) end
  end
end

local function onUpdate(_dtReal, _dtSim, _dtRaw)
  if not ghostingEnabled then return end

  local t = os.clock()
  if (t - lastGhostCheckAt) < 0.7 then return end 
  lastGhostCheckAt = t
  
  if not MPVehicleGE or not MPVehicleGE.getVehicles then return end
  for _, v in pairs(MPVehicleGE.getVehicles() or {}) do
    if v and v.gameVehicleID and tostring(v.jbeam or "") == "simple_traffic" then
      local id = tonumber(v.gameVehicleID)
      local objVeh = getObjectByID(id)
      if objVeh and not ghostedTraffic[id] then
        objVeh:queueLuaCommand("if obj and obj.setGhostEnabled then obj:setGhostEnabled(true) end")
        if objVeh.setMeshAlpha then objVeh:setMeshAlpha(1.0, "", false) end
        ghostedTraffic[id] = true
      end
    end
  end
end

local function onExtensionLoaded()
  AddEventHandler("spawnTraffic", spawnTraffic)
  AddEventHandler("deleteTraffic", deleteTraffic)
  AddEventHandler("setTrafficAmount", setTrafficAmount)
  AddEventHandler("setTrafficEnabled", setTrafficEnabled)
  AddEventHandler("setTrafficGhosting", setTrafficGhosting)
  AddEventHandler("showGhostingMessage", showGhostingMessage) -- Hooked up to server!
  
  AddEventHandler("setTrafficAggression", function() end)
  AddEventHandler("setTrafficNametagsVisible", function() end)
  AddEventHandler("setTrafficRadius", function() end)
  AddEventHandler("setTrafficPoolPercent", function() end)
  AddEventHandler("setTrafficRefillInterval", function() end)
  AddEventHandler("setTrafficSpread", function() end)

  if not requestedJoinSync then connectionFinished() end
end

local function onGameStateUpdate(data)
  if type(data) ~= "table" then return end
  if type(data.state) ~= "string" then return end
  local state = string.lower(data.state)
  if not state:find("multiplayer", 1, true) then return end
  if not requestedJoinSync then connectionFinished() end
end

M.onExtensionLoaded = onExtensionLoaded
M.onGameStateUpdate = onGameStateUpdate
M.onUpdate = onUpdate

return M