Here is the updated `README.md` reflecting all the massive improvements we just made. 

I have completely removed the outdated references to hardcoding usernames in the config and replaced them with a dedicated section explaining your new, highly secure BeamMP ID authentication system and console commands.

### The Updated README

```markdown
# CareerMP Dynamic AI Traffic 🚗🚦

Welcome to the **CareerMP Dynamic AI Traffic** script! This custom server and client package brings highly stable, dynamically scaling AI traffic to your BeamMP / CareerMP servers. 

To prevent server lag and client framerates, this script actively monitors the player count, scales the amount of traffic per person, and uses Waiting Rooms and queues to ensure cars only spawn when players are fully loaded and ready. It also features a fully dynamic Anti-Explosion "Ghost Mode" to prevent pileups!


## ⚙️ 1. Server Configuration (`main.lua`)
All settings for the server can be found at the very top of the `main.lua` file in the `Config` block. You do not need to edit any of the core code below this block!

### Traffic Limits
* **`aisPerPlayer`** *(Default: 4)*: The maximum number of AI cars allowed *per person* when the server is mostly empty.
* **`maxServerTraffic`** *(Default: 8)*: The absolute hard limit of AI cars allowed on the server at one time. 
*(Example: If Max is 8 and there are 4 players, the script automatically scales it down to 2 cars per player).*
* **`trafficGhosting`** *(Default: true)*: Toggles whether AI are solid objects (`false`) or as pass-through "ghosts" to prevent crashes (`true`).

### ⏱️ Customizing Timers
To adjust the waiting room and queue timers, simply change the values in the `Config` table at the top of the `main.lua` script. All values are calculated in **seconds**. 

* **`timerFirstPlayer`**
  * *Example:* `Config.timerFirstPlayer = 45`
  * *Effect:* Waits 45 seconds after the first player spawns on an empty server before generating the initial traffic.
* **`timerPlayerJoin`**
  * *Example:* `Config.timerPlayerJoin = 90`
  * *Effect:* Waits 90 seconds after a new player joins an already populated server before respawning traffic for everyone.
* **`timerPlayerLeave`**
  * *Example:* `Config.timerPlayerLeave = 20`
  * *Effect:* Waits 20 seconds after a player leaves the server before respawning traffic to match the new player count.
* **`timerAdminRefresh`**
  * *Example:* `Config.timerAdminRefresh = 15`
  * *Effect:* Waits 15 seconds after an admin forces a server refresh before spawning the new batch of traffic.

### 💬 Customizing Chat Messages
Because multiplayer syncing is heavy, the script uses timers to pause traffic generation so players don't lag out while loading in. You can customize the announcements sent to the server for all of these events. 

**Formatting Rules:**
* Use BeamMP color codes like `^c` (Red) or `^f` (White) to style your text.
* Do **NOT** delete the `%s` or `%d` symbols! 
  * `%s` is automatically replaced with a **Player's Name**.
  * `%d` is automatically replaced with a **Number** (like seconds remaining, or the amount of cars spawned).

#### 🚦 Initial Server Startup Messages
* **`msgFirstPlayerWait`** * *Default:* `^l^e[Traffic] ^fFirst player loaded! - Traffic will generate in ^c%d seconds...`
  * *Trigger:* When the first player spawns in, starting the initial waiting room timer.
* **`msgPendingPlayer`** * *Default:* `^l^e[Traffic] ^f%s is downloading/loading! Pausing traffic spawn...`
  * *Trigger:* If another player starts joining, putting the initial traffic spawn on hold.
* **`msgExtendTimer`** * *Default:* `^l^e[Traffic] ^fAnother player is loading in! Delaying traffic generation by ^c%d seconds...`
  * *Trigger:* If the waiting room timer is already active and another player starts joining, extending the delay.
* **`msgFirstPlayer5s`** * *Default:* `^l^e[Traffic] ^fTraffic generating in ^c5 seconds...`
  * *Trigger:* The 5-second warning before the initial traffic spawns.

#### 🔄 Dynamic Scaling & Queue Messages
* **`msgPlayerJoinWait`** * *Default:* `^l^e[Traffic] ^f%s Joined - Traffic has been ^cDeleted ^fwhilst the server ^crecalculates!`
  * *Trigger:* When a new player joins an active server, immediately deleting existing traffic and starting the recalculation timer.
* **`msgPlayerJoinReset`** * *Default:* `^l^e[Traffic] ^f%s Joined! - Traffic Spawning ^cCancelled ^fand ^crecalculating.`
  * *Trigger:* If a new player joins while a spawn countdown is *already* happening, resetting the queue.
* **`msgPlayerLeaveWait`** * *Default:* `^l^e[Traffic] ^fA player left. - Traffic ^cDeleted. ^fRespawning in ^c%d seconds...`
  * *Trigger:* When a player leaves, clearing traffic and starting the respawn countdown for the new limits.
* **`msgQueue1Min`** * *Default:* `^l^e[Traffic] ^fTraffic Recalculated, Respawning in 1 min.`
  * *Trigger:* The 60-second warning during a recalculation queue.
* **`msgQueue5s`** * *Default:* `^l^e[Traffic] ^fRespawning traffic in ^c5 seconds... Find a safe location!`
  * *Trigger:* The 5-second warning before recalculated traffic spawns.
* **`msgTrafficSpawned`** * *Default:* `^l^e[Traffic] ^fTraffic spawned ^c(%d per player).`
  * *Trigger:* Announcement that traffic has successfully spawned, showing the active amount per player.

#### 👑 Admin Messages
* **`msgAdminRefreshWait`** * *Default:* `^l^e[Traffic] ^fAdmin %s forced a traffic refresh. ^cRespawning in %d seconds...`
  * *Trigger:* When an admin forces a refresh or changes a setting, starting the refresh countdown.
* **`msgNoPermission`** * *Default:* `^l^cYou do not have permission to use admin commands.`
  * *Trigger:* Error message sent privately to a player who attempts to use an admin-only command.



## 🛠️ 2. IMPORTANT: Modifying CareerMP Core (`PlayerDriving.lua`)
For this dynamic scaling script to work properly, you **MUST** edit a core file inside the original CareerMP mod. If you skip this step, CareerMP will completely ignore our script and permanently lock your traffic to exactly 2 cars!

**How to fix it:**

1. Open your server's mod folder and extract or open **`CareerMP.zip`**.
2. Navigate to the following file path: 
   `lua\ge\extensions\career\modules\playerDriving.lua`
3. Open `playerDriving.lua` in a text editor (like Notepad++) and scroll down to **Line 57**. It will look like this:
   ```lua
   amount = clamp(amount, 2, 2) -- at least 2 vehicles should get spawned
   ```
4. **Change the numbers inside the parenthesis!** * The first number is the *minimum* AI allowed. Set this to **`1`**.
   * The second number is the *maximum* AI per player. Set this to match whatever you put for `aisPerPlayer` in your server's `main.lua` config (You can set the second number high if you want to this is just the top cap! My example I set to **`8`**).
5. **Your updated Line 57 should look exactly like this:**
   ```lua
   amount = clamp(amount, 1, 8) -- Dynamic limit allowing 1 to 8 cars
   ```
6. Save the file, re-zip `CareerMP.zip`, and put it back in your server!



## 👑 3. Admin Management System
The admin system uses secure, unique BeamMP IDs instead of easily spoofed usernames. Admins are automatically saved to `Resources/Server/CareerMPTraffic/TrafficAdmins.txt` and their usernames will auto-update in the file if they change their name in-game.

### Server Console Commands (Host Only)
These commands are typed directly into the black server console window:

* **`traffic.au <ID> <Name>`**: Add a new admin using their BeamMP ID and Username (e.g., `traffic.au 1234567 UkDrifter`). *Do this first to give yourself access!*
* **`traffic.ru <ID>`**: Remove an admin using their BeamMP ID.
* **`traffic.lookup <Name>`** (or `traffic.lu`): Look up the BeamMP ID of a connected player. Generates a link to their BeamMP forum profile!
* **`traffic.admins`**: List all current admins and their forum profile links.
* **`traffic.status`** (or `traffic.s`): View the current server limits, active vehicle targets, and ghosting status.
* **`traffic.maxaipp <number>`**: Change the `aisPerPlayer` config on the fly. Triggers a server refresh.
* **`traffic.maxtraffic <number>`**: Change the `maxServerTraffic` config on the fly. Triggers a server refresh.
* **`traffic.ghosting <on|off>`** (or `traffic.g`): Toggle AI collisions on or off. Triggers a massive on-screen UI message for all players!
* **`traffic.help`** (or `traffic.h`): Displays the console command list.

## 💬 4. In-Game Chat Commands

### Public Commands (For Everyone)
* **`/mytraffic refresh`**: If a player's local traffic glitches out, gets stuck, or turns invisible, they can type this to instantly delete and respawn *only their personal traffic* without affecting the rest of the server.

### Admin Commands (In-Game)
*(Note: You must be added as an admin via the server console first to use these)*

* **`/traffic status`**: Readout of current limits, server max, active targets, and ghosting state.
* **`/traffic refresh`**: Forces a global wipe of all traffic on the server. Cancels queues, deletes cars, and starts the `timerAdminRefresh` countdown.
* **`/traffic maxaipp <number>`**: Change the max AI allowed per player on the fly. Triggers a server refresh.
* **`/traffic maxtraffic <number>`**: Change the hard cap for total AI on the server. Triggers a server refresh.
* **`/traffic ghosting <on|off>`**: Toggle AI collisions. Triggers a massive on-screen UI message (Red for ON, Green for OFF) for all connected players.
* **`/traffic help`**: Displays a quick list of available in-game traffic commands.
<<<<<<< Updated upstream
```
=======
>>>>>>> Stashed changes
