# 🚦 BeamMP Dynamic AI Traffic Module

A dynamic server and client module for BeamMP that intelligently manages AI traffic spawning based on active player counts. 

This script features a "waiting room" mechanism to prevent traffic from generating before players have fully loaded into the server. This drastically reduces lag spikes and synchronization crashes caused by AI spawning prematurely.


## ✨ Features
* **Dynamic Scaling:** Automatically divides the server's maximum traffic limit by the number of active players.
* **Waiting Room Logic:** Pauses AI generation while players are downloading mods or syncing.
* **Traffic Ghosting:** Optional anti-grief/anti-crash protection that disables collisions for AI vehicles.
* **Persistent Settings:** Saves authorized traffic amounts and admins to a local `settings.txt` file so they survive server restarts.


## 💾 Installation

1. Download the `Latest` Release.
2. Place the zip in your BeamMP Server directory.
3. Extract and it will create the directory: `Resources/Server/BeamMPTraffic/main.lua` & `Resources/Client/BeamMPTraffic.zip`
4. Start your server. The script will automatically generate the `settings.txt` file on the first run.
5. Edit the amount of AI in the `Settings.txt` file or by using the commands listed below!
6. Use the server console to add your first admin (see Commands below).

## ⚙️ Configuration & Timers

All **Default** settings and messages are located in the `Config` table at the top of `main.lua`. (Only edit the messages and timers here as we now use `settings.txt` for AI amounts ect)

### General Settings
| Variable | Default | Description |
| :--- | :---: | :--- |
| `aisPerPlayer` | `1` | Max AI vehicles spawned per player. *(e.g., set to 2 with 3 players = 6 AI total).* |
| `maxServerTraffic` | `8` | The absolute hard cap on AI vehicles, regardless of player count. |
| `trafficGhosting` | `true` | Toggles collisions for AI. `true` = cars pass through players. |

### Core Timers (in Seconds)
> **Note:** `tickRate` is the only timer in milliseconds (Default: `1000` / 1 second).

* **`timerFirstPlayer` (30s):** Time to wait after the *first* player fully loads before spawning initial traffic. Ensures they are fully synced.
* **`timerPlayerJoin` (120s):** Time to wait after a *new* player joins an already populated server. Traffic is paused while they download mods.
* **`timerPlayerLeave` (60s):** Time to wait to recalculate and respawn traffic after someone disconnects.
* **`timerAdminRefresh` (30s):** Countdown triggered when an admin forces a manual refresh.
* **`timerPendingTimeout` (300s):** The max time a player can be stuck on the loading screen before the script ignores them and resumes traffic.

### Warning Timers (in Seconds)
* **`timerWarningLong` (60s):** Triggers a chat warning 60 seconds before traffic spawns.
* **`timerWarningShort` (10s):** Triggers a final *"Find a safe location!"* chat warning 10 seconds before traffic drops.


## 💻 Commands

### In-Game Chat Commands
*Note: Admin commands require the user to be added via the server console first.*

| Command | Permission | Description |
| :--- | :---: | :--- |
| `/mytraffic refresh` | **All Players** | Deletes and respawns the player's local traffic pool if it gets bugged. |
| `/traffic status` | Admin | Shows current max AI, player cap, and ghosting status. |
| `/traffic refresh` | Admin | Deletes current traffic and starts a fresh 30-second recalculation timer. |
| `/traffic maxaipp <num>` | Admin | Changes the maximum AI allowed per player. |
| `/traffic maxtraffic <num>`| Admin | Changes the absolute global AI cap for the server. |
| `/traffic ghosting <on/off>`| Admin | Dynamically toggles AI collisions on or off for all players. |

### Server Console Commands
Admin management and player lookups are handled securely via the server console.

| Command | Description
| :--- | :---:
|  `traffic.help (traffic.h)` | Show the help menu.
|  `traffic.status (traffic.s)`| View current traffic settings.
|  `traffic.au <ID> <Name>` | Adds a new Admin using their BeamMP ID (e.g., traffic.au 12345 Reece).
|  `traffic.ru <ID>` | Removes an Admin.
|  `traffic.admins` | Lists all current admins and automatically generates their forum profile links.
|  `traffic.lookup <Name>` | Find online player's ID & link.
|  `traffic.ghosting <on/off>` | Toggle traffic collisions.
|  `traffic.maxaipp <number>` | Set max AI cars per player.
|  `traffic.maxtraffic <number>` |Set max total AI cars on server.


## 🔧 Under the Hood (Core Functions)

For developers looking to modify the script, here is a brief overview of the core logic:

* **`getScaledTrafficAmount()`**: The mathematical core. Divides `maxServerTraffic` by the active player count to assign AI per player without exceeding global limits.
* **`onPlayerAuth()` & `onPlayerJoin()`**: Catches players as they connect and puts them in a "pending" state, pausing traffic generation.
* **`onVehicleSpawn()`**: Acts as the confirmation trigger. When a player spawns their car, the script assumes they have finished loading and begins the traffic countdown timers.
* **`trafficManagerTick()`**: The heartbeat loop of the script. It checks the system time against active timers and triggers chat warnings or client-side spawn events when clocks hit zero.


