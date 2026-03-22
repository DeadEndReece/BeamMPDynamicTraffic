-- CareerMP Dynamic AI Traffic - Server/Client Module
-- Author: DeadEndReece
-- Description: This script manages dynamic traffic spawning based on player count, with a waiting room mechanism to ensure the first player has fully loaded before traffic spawns. 
-- Version: 0.1 - Github.com/DeadEndReece | Forum.beammp.com/u/DeadEndReece
-- ==========================================
-- CONFIGURATION
-- ==========================================
local Config = {
  aisPerPlayer = 1, -- Maximum AI vehicles per player (e.g., 4 means 4 AI per player, so 2 players = 8 AI)
  maxServerTraffic = 8, -- Absolute cap on total AI vehicles regardless of player count (e.g., 8 means no more than 8 AI on the server at once)
  trafficGhosting     = true, -- Toggle for anti-explosion protection (False = cars are solid, True = cars will pass through players)

  -- Timers (in seconds)
  timerFirstPlayer  = 30, -- Time to wait after the first player spawns before generating traffic (if no one else is loading)
  timerPlayerJoin   = 120, -- Time to wait after a new player joins before respawning traffic (if server is already populated)
  timerPlayerLeave  = 30, -- Time to wait after a player leaves before respawning traffic with the new player count
  timerAdminRefresh = 30,  -- Time to wait after an admin forces a refresh

  -- Chat Messages (Use %s for names, %d for numbers)
  msgFirstPlayerWait  = "^l^e[Traffic] ^fFirst player loaded! - Traffic will generate in ^c%d seconds...",
  msgPendingPlayer    = "^l^e[Traffic] ^f%s is downloading/loading! Pausing traffic spawn...", 
  msgExtendTimer      = "^l^e[Traffic] ^fAnother player is loading in! Delaying traffic generation by ^c%d seconds...",
  msgFirstPlayer5s    = "^l^e[Traffic] ^fTraffic generating in ^c5 seconds...",
  
  msgPlayerJoinReset  = "^l^e[Traffic] ^f%s Joined! - Traffic Spawning ^cCancelled ^fand ^crecalculating.",
  msgPlayerJoinWait   = "^l^e[Traffic] ^f%s Joined - Traffic has been ^cDeleted ^fwhilst the server ^crecalculates!",
  
  msgPlayerLeaveWait  = "^l^e[Traffic] ^fA player left. - Traffic ^cDeleted. ^fRespawning in ^c%d seconds...",
  
  msgQueue1Min        = "^l^e[Traffic] ^fTraffic Recalculated, Respawning in 1 min.",
  msgQueue5s          = "^l^e[Traffic] ^fRespawning traffic in ^c5 seconds... Find a safe location!",
  
  msgTrafficSpawned   = "^l^e[Traffic] ^fTraffic spawned ^c(%d per player).",
  
  msgAdminRefreshWait = "^l^e[Traffic] ^fAdmin %s forced a traffic refresh. ^cRespawning in %d seconds...",
  msgNoPermission     = "^l^cYou do not have permission to use admin commands.",
}

-- ================================
-- INTERNAL STATES & DATA DONT TOUCH UNLESS YOU KNOW WHAT YOU ARE DOING!
-- ================================
local dataPath = "Resources/Server/CareerMPTraffic/TrafficAdmins.txt"
local TRAFFIC_ADMINS = {}

local pendingPlayers = {} 
local fullyJoinedPlayers = {} 
local playerIdsToNames = {} 

local firstPlayerSpawning = false 
local firstPlayerTimer = 0
local serverHasTraffic = false 
local firstPlayer5sWarning = false

local trafficPaused = false 
local isCountingDown = false
local respawnTimer = 0
local oneMinuteWarningSent = false 
local join5sWarning = false

local recalcSpawning = false
local recalcTimer = 0
local recalcAmount = 0
local recalc5sWarning = false

local function logInfo(msg)
  print("[CareerMPTraffic] " .. tostring(msg))
end

-- ==========================================
-- ADMIN PERSISTENCE
-- ==========================================
function LoadTrafficAdmins()
    TRAFFIC_ADMINS = {}
    local file = io.open(dataPath, "r")
    if file then
        local count = 0
        for line in file:lines() do
            local id, name = line:match("([^=]+)=(.+)")
            if id and name then
                TRAFFIC_ADMINS[id] = name
                count = count + 1 
            end
        end
        file:close()
        logInfo("Loaded " .. count .. " admins from data file.")
    else
        logInfo("No admins file found. Use the server console command 'traffic.au <ID> <Name>' to add your first admin!")
    end
end

function SaveTrafficAdmins()
    local file = io.open(dataPath, "w")
    if file then
        for id, name in pairs(TRAFFIC_ADMINS) do
            file:write(id .. "=" .. name .. "\n")
        end
        file:close()
    end
end

-- ==========================================
-- CORE TRAFFIC LOGIC
-- ==========================================
local function getPlayerCount(isDisconnecting)
  local n = 0
  if MP and MP.GetPlayers then
    local ok, players = pcall(MP.GetPlayers)
    if ok and type(players) == "table" then
      for _ in pairs(players) do n = n + 1 end
    end
  end
  
  if isDisconnecting then n = n - 1 end
  if n < 0 then n = 0 end 
  
  return n
end

local function getScaledTrafficAmount(isDisconnecting)
  local players = getPlayerCount(isDisconnecting)
  if players < 1 then players = 1 end 
  
  local amount = math.floor(Config.maxServerTraffic / players)
  if amount > Config.aisPerPlayer then amount = Config.aisPerPlayer end
  if amount < 1 then amount = 1 end
  return amount
end

-- --- The Waiting Room ---
function onPlayerAuth(playerName, playerRole, isGuest, ip)
  if playerName then
    pendingPlayers[playerName] = os.time()
    fullyJoinedPlayers[playerName] = nil 
    logInfo("Player authenticating (pending): " .. tostring(playerName))

    if not serverHasTraffic and firstPlayerSpawning then
      firstPlayerTimer = os.time() + Config.timerFirstPlayer
      firstPlayer5sWarning = false
      MP.SendChatMessage(-1, string.format(Config.msgPendingPlayer, playerName))
    end
  end
end
MP.RegisterEvent("onPlayerAuth", "onPlayerAuth")

function onPlayerJoin(playerId)
  local playerName = MP.GetPlayerName(playerId)
  if playerName then
    playerIdsToNames[playerId] = playerName
    logInfo("Player connecting/downloading: " .. playerName .. " (Not synced yet, ignoring traffic locks)")
  end
end
MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")

function onVehicleSpawn(playerId, vehicleId, data)
  local playerName = MP.GetPlayerName(playerId)
  if not playerName then return end

  if type(data) == "string" and not data:find("simple_traffic") then
    if not fullyJoinedPlayers[playerName] then
      fullyJoinedPlayers[playerName] = true
      
      -- Send current ghosting state to the newly joined player
      MP.TriggerClientEvent(playerId, "setTrafficGhosting", Config.trafficGhosting and "1" or "0")
      
      if pendingPlayers[playerName] then
        pendingPlayers[playerName] = nil
      end
      
      logInfo(playerName .. " has fully synced and spawned their first vehicle.")

      if not serverHasTraffic then
        if not firstPlayerSpawning then
          firstPlayerSpawning = true
          firstPlayerTimer = os.time() + Config.timerFirstPlayer 
          firstPlayer5sWarning = false
          logInfo("First player spawned. Waiting for NavGraph...")
          MP.SendChatMessage(-1, string.format(Config.msgFirstPlayerWait, Config.timerFirstPlayer))
        else
          firstPlayerTimer = os.time() + Config.timerFirstPlayer 
          firstPlayer5sWarning = false
          MP.SendChatMessage(-1, string.format(Config.msgExtendTimer, Config.timerFirstPlayer))
        end
      else
        recalcSpawning = false 
        trafficPaused = true 
        MP.TriggerClientEvent(-1, "setTrafficAmount", "0") 
        MP.TriggerClientEvent(-1, "deleteTraffic", "") 

        if isCountingDown then
          respawnTimer = os.time() + Config.timerPlayerJoin
          oneMinuteWarningSent = false
          join5sWarning = false
          MP.SendChatMessage(-1, string.format(Config.msgPlayerJoinReset, playerName))
        else
          isCountingDown = true
          respawnTimer = os.time() + Config.timerPlayerJoin
          oneMinuteWarningSent = false
          join5sWarning = false
          MP.SendChatMessage(-1, string.format(Config.msgPlayerJoinWait, playerName))
        end
      end
    end
  end
end
MP.RegisterEvent("onVehicleSpawn", "onVehicleSpawn")

function onPlayerDisconnect(playerId)
  local playerName = playerIdsToNames[playerId]
  local wasFullyJoined = false

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
    logInfo("Server empty. Traffic locks reset.")
  else
    if wasFullyJoined and not trafficPaused and not firstPlayerSpawning then
      local amount = getScaledTrafficAmount(true) 
      
      recalcSpawning = true
      recalcTimer = os.time() + Config.timerPlayerLeave 
      recalcAmount = amount
      recalc5sWarning = false
      
      MP.TriggerClientEvent(-1, "setTrafficAmount", "0")
      MP.TriggerClientEvent(-1, "deleteTraffic", "")
      MP.SendChatMessage(-1, string.format(Config.msgPlayerLeaveWait, Config.timerPlayerLeave))
    elseif not wasFullyJoined then
      logInfo("A pending player disconnected before syncing. Ignoring traffic recalculation.")
    end
  end
end
MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")

function trafficManagerTick()
  local currentTime = os.time()

  if firstPlayerSpawning then
    local pendingCount = 0
    for name, authTime in pairs(pendingPlayers) do
      if (currentTime - authTime) < 300 then 
        pendingCount = pendingCount + 1
      else
        pendingPlayers[name] = nil
      end
    end

    if pendingCount > 0 then
      firstPlayerTimer = currentTime + Config.timerFirstPlayer
      firstPlayer5sWarning = false
    else
      local timeLeft = firstPlayerTimer - currentTime
      
      if timeLeft <= 5 and not firstPlayer5sWarning then
         firstPlayer5sWarning = true
         MP.SendChatMessage(-1, Config.msgFirstPlayer5s)
      end

      if timeLeft <= 0 then
        firstPlayerSpawning = false
        serverHasTraffic = true 
        local amount = getScaledTrafficAmount(false)
        
        MP.TriggerClientEvent(-1, "setTrafficAmount", tostring(amount))
        MP.TriggerClientEvent(-1, "spawnTraffic", tostring(amount))
        MP.SendChatMessage(-1, string.format(Config.msgTrafficSpawned, amount))
      end
    end
  end

  if recalcSpawning then
    local timeLeft = recalcTimer - currentTime
    
    if timeLeft <= 5 and not recalc5sWarning then
       recalc5sWarning = true
       MP.SendChatMessage(-1, Config.msgQueue5s)
    end

    if timeLeft <= 0 then
      recalcSpawning = false
      MP.TriggerClientEvent(-1, "setTrafficAmount", tostring(recalcAmount))
      MP.TriggerClientEvent(-1, "spawnTraffic", tostring(recalcAmount))
      MP.SendChatMessage(-1, string.format(Config.msgTrafficSpawned, recalcAmount))
    end
  end

  if isCountingDown and trafficPaused then
    local timeLeft = respawnTimer - currentTime

    if timeLeft <= 60 and not oneMinuteWarningSent then
       oneMinuteWarningSent = true
       MP.SendChatMessage(-1, Config.msgQueue1Min)
    end

    if timeLeft <= 5 and not join5sWarning then
       join5sWarning = true
       MP.SendChatMessage(-1, Config.msgQueue5s)
    end

    if timeLeft <= 0 then
      isCountingDown = false
      trafficPaused = false
      local amount = getScaledTrafficAmount(false)
      
      MP.TriggerClientEvent(-1, "setTrafficAmount", tostring(amount))
      MP.TriggerClientEvent(-1, "spawnTraffic", tostring(amount))
      MP.SendChatMessage(-1, string.format(Config.msgTrafficSpawned, amount))
    end
  end
end
MP.RegisterEvent("TrafficManagerTick", "trafficManagerTick")
MP.CreateEventTimer("TrafficManagerTick", 1000)

-- ==========================================
-- CHAT COMMANDS
-- ==========================================
function onChatMessage(senderId, senderName, message)
  local msg = tostring(message or "")
  local args = {}
  for word in msg:gmatch("%S+") do table.insert(args, word) end
  if #args == 0 then return 0 end
  
  local cmd = args[1]:lower()

  -- Identity Verification for the few in-game commands left
  local identifiers = MP.GetPlayerIdentifiers(senderId)
  local beammp_id = identifiers and tostring(identifiers.beammp) or nil

  -- Auto-Update Admin Usernames!
  if beammp_id and TRAFFIC_ADMINS[beammp_id] then
      if TRAFFIC_ADMINS[beammp_id] ~= senderName then
          TRAFFIC_ADMINS[beammp_id] = senderName
          SaveTrafficAdmins()
      end
  end
  
  local isAdmin = (beammp_id and TRAFFIC_ADMINS[beammp_id] ~= nil)

  -- Process In-Game Traffic Admin Commands
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

          MP.TriggerClientEvent(-1, "setTrafficAmount", "0")
          MP.TriggerClientEvent(-1, "deleteTraffic", "")
          MP.SendChatMessage(-1, string.format(Config.msgAdminRefreshWait, senderName, Config.timerAdminRefresh))
          return 1
          
      elseif action == "status" then
          MP.SendChatMessage(senderId, "--- ^cTraffic Status ^f---")
          MP.SendChatMessage(senderId, "^fMax AI per player: ^c" .. Config.aisPerPlayer)
          MP.SendChatMessage(senderId, "^fMax server traffic: ^c" .. Config.maxServerTraffic)
          MP.SendChatMessage(senderId, "^fGhosting (No Collision): ^c" .. (Config.trafficGhosting and "ON" or "OFF"))
          MP.SendChatMessage(senderId, "^fCurrent Active Target: ^c" .. getScaledTrafficAmount(false) .. " per player")
          return 1

      elseif action == "help" then
          MP.SendChatMessage(senderId, "--- ^cTraffic Admin Commands ^f---")
          MP.SendChatMessage(senderId, "^c/traffic status ^f- View current traffic settings")
          MP.SendChatMessage(senderId, "^c/traffic refresh ^f- Force refresh AI traffic")
          MP.SendChatMessage(senderId, "^c/traffic maxaipp ^f(^cnum^f) - Set max AI per player")
          MP.SendChatMessage(senderId, "^c/traffic maxtraffic ^f(^cnum^f) - Set max total server AI")
          MP.SendChatMessage(senderId, "^c/traffic ghosting ^f(^con^f|^coff^f) - Toggle traffic collisions")
          MP.SendChatMessage(senderId, "^f(^cAdmin management and player lookups are console-only^f)")
          return 1
          
      elseif action == "maxaipp" then
          if args[3] then
              local num = tonumber(args[3])
              if num and num >= 1 then
                  Config.aisPerPlayer = math.floor(num)
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
                  MP.TriggerClientEvent(-1, "setTrafficGhosting", "1")
                  MP.TriggerClientEvent(-1, "showGhostingMessage", "1")
                  MP.SendChatMessage(senderId, "^l^cTraffic ghosting ENABLED. Cars will pass through players.")
                  logInfo(senderName .. " ENABLED traffic ghosting via chat.")
              elseif state == "off" or state == "0" or state == "false" then
                  Config.trafficGhosting = false
                  MP.TriggerClientEvent(-1, "setTrafficGhosting", "0")
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
      else
          MP.SendChatMessage(senderId, "^l^cUnknown traffic command. Type ^b/traffic help ^cfor options.")
          return 1
      end
  end

  -- Global Player Commands
  if msg == "/mytraffic refresh" then
    local amount = getScaledTrafficAmount(false)
    MP.TriggerClientEvent(senderId, "setTrafficAmount", tostring(amount))
    MP.TriggerClientEvent(senderId, "deleteTraffic", "")
    MP.TriggerClientEvent(senderId, "spawnTraffic", tostring(amount))
    MP.SendChatMessage(senderId, "^l^cYour local traffic has been refreshed.")
    return 1
  end
  
  return 0
end
MP.RegisterEvent("onChatMessage", "onChatMessage")

-- ==========================================
-- SERVER CONSOLE COMMANDS
-- ==========================================
-- Admin management and lookups are securely handled here!
function onConsoleTrafficInput(cmd)
    local rawInput = cmd:match("^%s*(.-)%s*$")
    local args = {}
    for word in rawInput:gmatch("%S+") do table.insert(args, word) end
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
        logInfo("traffic.maxaipp <number>      - Set max AI cars per player")
        logInfo("traffic.maxtraffic <number>   - Set max total AI cars on server")
        return ""
        
    elseif command == "traffic.status" or command == "traffic.s" then
        logInfo("--- Traffic Status ---")
        logInfo("Max AI per player: " .. Config.aisPerPlayer)
        logInfo("Max server traffic: " .. Config.maxServerTraffic)
        logInfo("Ghosting (No Collision): " .. (Config.trafficGhosting and "ON" or "OFF"))
        logInfo("Current Active Target: " .. getScaledTrafficAmount(false) .. " per player")
        return ""
        
    elseif command == "traffic.au" or command == "traffic.addadmin" then
        if #args >= 3 then
            local id = args[2]
            local name = table.concat(args, " ", 3)
            TRAFFIC_ADMINS[id] = name
            SaveTrafficAdmins()
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
                SaveTrafficAdmins()
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
        for k, v in pairs(TRAFFIC_ADMINS) do
            local safeName = tostring(v):gsub(" ", "_")
            logInfo("ID: " .. k .. " | Name: " .. tostring(v) .. " | URL: https://forum.beammp.com/u/" .. safeName)
            count = count + 1
        end
        if count == 0 then logInfo("(None)") end
        return ""
        
    elseif command == "traffic.lookup" or command == "traffic.lu" then
        if #args > 1 then
            local targetName = table.concat(args, " ", 2)
            local targetNameLower = targetName:lower()
            local found = false
            local players = MP.GetPlayers() 
            
            for pid, name in pairs(players) do
                if name:lower() == targetNameLower then
                    local target_identifiers = MP.GetPlayerIdentifiers(pid)
                    local target_id = target_identifiers and tostring(target_identifiers.beammp) or "Unknown"
                    local safeName = name:gsub(" ", "_")
                    local url = "https://forum.beammp.com/u/" .. safeName
                    
                    logInfo("Found User: " .. name .. " | ID: " .. target_id)
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
                MP.TriggerClientEvent(-1, "setTrafficGhosting", "1")
                MP.TriggerClientEvent(-1, "showGhostingMessage", "1")
                logInfo("Traffic ghosting ENABLED. Cars will pass through players.")
            elseif state == "off" or state == "0" or state == "false" then
                Config.trafficGhosting = false
                MP.TriggerClientEvent(-1, "setTrafficGhosting", "0")
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
        
    elseif command == "traffic.maxaipp" then
        if #args >= 2 then
            local num = tonumber(args[2])
            if num and num >= 1 then
                Config.aisPerPlayer = math.floor(num)
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

-- ==========================================
-- SCRIPT INITIALIZATION (The No Vehicle Fix)
-- ==========================================
local function initExistingPlayers()
  LoadTrafficAdmins()
  
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
  logInfo("Server module loaded successfully. Existing players grandfathered in.")
end
initExistingPlayers()