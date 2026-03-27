# CareerMP Dynamic AI Traffic Module

A server/client BeamMP traffic module for CareerMP that scales AI traffic by player count, waits for players to finish loading before spawning traffic, and adds extra multiplayer safety around missions, spawn timing, and overlapping AI vehicles.

## Features

- Dynamic traffic scaling based on active player count.
- Waiting room logic that pauses traffic while players are still syncing or downloading.
- Optional traffic ghosting toggle for anti-grief and anti-crash protection.
- Mission-aware traffic hiding so synced simple traffic does not interfere with mission gameplay.
- Mission exit cooldown that keeps traffic hidden briefly while it disperses.
- Spawn overlap protection with a short ghost window for freshly spawned simple traffic.
- Simple traffic separation logic that keeps nearby AI non-collidable until they move apart.
- In-game 5 to 1 countdown flash before traffic spawns, alongside the existing 10 second chat warning.
- Persistent server settings and admin list saved to `settings.txt`.

## Installation

1. Download the latest release.
2. Place the zip in your BeamMP server directory.
3. Extract it so it creates:
   - `Resources/Server/CareerMPTraffic/main.lua`
   - `Resources/Client/CareerMPTraffic.zip`
4. Start the server. The script creates `settings.txt` on first launch.
5. Adjust server traffic values in `settings.txt` or with the supported admin commands.
6. Use the server console to add your first admin.

## CareerMP Setup Note

To use this properly with CareerMP, edit `playerdriving.lua` inside Client\CareerMP.zip\lua\ge\extensions\career\modules\playerDriving.lua `Line 57` <img width="649" height="22" alt="image" src="https://github.com/user-attachments/assets/dcca5fb7-ba6d-4c76-97b8-1181c554887d" />
 so the traffic clamp allows the amount you want. For example, change the hard clamp from a fixed value to the maximum number you want a player to be able to spawn.

If fewer cars are spawning than expected, also check the in-game Gameplay traffic settings on the client.

## Configuration

Server-side settings are stored in `Resources/Server/CareerMPTraffic/settings.txt`.

### Main Server Settings

| Variable | Default | Description |
| :--- | :---: | :--- |
| `aisPerPlayer` | `1` | Maximum AI vehicles allowed per player. |
| `maxServerTraffic` | `8` | Absolute hard cap for total server traffic. |
| `trafficGhosting` | `true` | Global collision toggle for AI traffic. |

### Core Timers

`tickRate` is in milliseconds. All other timers are in seconds.

- `timerFirstPlayer` = `30`: Delay after the first fully loaded player before initial traffic spawn.
- `timerPlayerJoin` = `120`: Delay after a new player joins an active server.
- `timerPlayerLeave` = `60`: Delay before traffic recalculates after a player leaves.
- `timerAdminRefresh` = `30`: Delay used when an admin forces a refresh.
- `timerPendingTimeout` = `300`: Maximum time a player can remain pending before being ignored.
- `timerWarningLong` = `60`: Long warning chat message before traffic spawns.
- `timerWarningShort` = `10`: Final short chat warning before traffic spawns.

### Client-Side Traffic Safety Values

These are locked client-side in `Resources/Client/lua/ge/extensions/AITrafficSpawner.lua`.

| Variable | Default | Description |
| :--- | :---: | :--- |
| `missionProtectionRadius` | `50` | Protects mission players from nearby synced simple traffic. |
| `missionTeleportRadius` | `75` | Radius used when checking if nearby traffic should be teleported away during missions. |
| `missionTeleportMinDist` | `200` | Minimum teleport distance for mission traffic relocation. |
| `missionTeleportMaxDist` | `350` | Maximum teleport distance for mission traffic relocation. |
| `missionTeleportTargetDist` | `270` | Preferred teleport distance for moved traffic. |
| `missionTeleportCooldown` | `2` | Cooldown between teleport requests for the same traffic vehicle. |
| `missionTeleportBatchLimit` | `2` | Maximum teleport requests sent per update cycle during missions. |
| `missionExitGhostDuration` | `10` | Time traffic remains hidden/ghosted after leaving a mission. |
| `trafficVisualUpdateInterval` | `0.25` | Update rate for client traffic collision/visibility checks. |
| `trafficSpawnGhostDuration` | `3` | Temporary no-collision window for newly spawned simple traffic. |
| `trafficSeparationRadius` | `10` | Nearby simple traffic stays non-collidable until it separates beyond this distance. |

## Spawn Warnings

Traffic spawning now uses two warning layers:

- The existing 10 second warning is still sent in chat.
- At 5, 4, 3, 2, and 1 seconds, players get an in-game flash countdown saying `Traffic Spawning In X Seconds!`

This countdown is used for:

- First traffic spawn after the first player loads.
- Recalculation after a player leaves.
- Recalculation after a player joins.
- Admin-triggered traffic refreshes.

## Commands

### In-Game Chat Commands

Admin commands require the player to be added through the server console first.

| Command | Permission | Description |
| :--- | :---: | :--- |
| `/mytraffic refresh` | All Players | Refreshes the player's local traffic pool if it becomes bugged. |
| `/traffic status` | Admin | Shows current max AI, server cap, and ghosting status. |
| `/traffic refresh` | Admin | Deletes current traffic and starts a fresh recalculation timer. |
| `/traffic maxaipp <num>` | Admin | Changes the maximum AI allowed per player. |
| `/traffic maxtraffic <num>` | Admin | Changes the absolute global AI cap. |
| `/traffic ghosting <on/off>` | Admin | Toggles AI collisions for all players. |

### Server Console Commands

| Command | Description |
| :--- | :--- |
| `traffic.help` or `traffic.h` | Show the help menu. |
| `traffic.status` or `traffic.s` | View current traffic settings. |
| `traffic.au <ID> <Name>` | Add an admin using their BeamMP ID. |
| `traffic.ru <ID>` | Remove an admin. |
| `traffic.admins` | List current admins. |
| `traffic.lookup <Name>` | Look up an online player's BeamMP ID. |
| `traffic.ghosting <on/off>` | Toggle traffic collisions. |
| `traffic.maxaipp <number>` | Set max AI cars per player. |
| `traffic.maxtraffic <number>` | Set max total AI cars on the server. |

## Mission Behaviour

When a player enters a mission:

- Their synced simple traffic is hidden for everyone.
- Nearby traffic can be teleported away from the mission area.
- Mission players are protected from nearby synced traffic meshes.

When a player exits a mission:

- Their synced simple traffic stays hidden briefly while it clears the area.
- Traffic remains ghosted during the exit cooldown to reduce immediate collisions.

## How It Works

- `getScaledTrafficAmount()` calculates per-player traffic while respecting the server cap.
- `onPlayerAuth()` and `onPlayerJoin()` mark players as pending and pause unsafe traffic spawns.
- `onVehicleSpawn()` confirms a player is fully loaded and starts the appropriate traffic timer.
- `trafficManagerTick()` handles waiting-room timing, spawn countdowns, warnings, and respawns.
- `AITrafficSpawner.lua` manages local simple traffic spawning, ghosting, hiding, mission protection, and anti-overlap behaviour.
