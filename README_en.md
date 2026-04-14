# vp_chopshop

Chop shop system for FiveM: players use a **hydraulic jack** (`chopshop_jackstand`) to lift any vehicle and dismantle parts in 4 progressive stages, yielding material rewards, tyre sales to an NPC, and optional ambushes. Designed for stacks using **ox_lib**, **ox_target**, **ox_inventory**, and **oxmysql**.

---

## Mandatory Requirements

| Resource | Usage |
|---------|-----|
| `ox_lib` | Menus, progress bars, skillcheck, callbacks |
| `ox_target` | Interaction on the lifted vehicle, bench, welder, and NPC |
| `ox_inventory` | Items, add/remove materials |
| `oxmysql` | Persistence for benches and welders |

Suggested order in `server.cfg`: ox dependencies first, then `ensure vp_chopshop`.

---

## Languages (UI)

In `shared/config.lua`, set **`Config.Locale`** to one of these values:

| Value | Language |
|-------|--------|
| `en` | English |
| `pt` | Português (default) |
| `es` | Español |
| `fr` | Français |
| `tr` | Türkçe |

Strings are located in `shared/locale.lua`. For custom recipes: use `labelKey` (an existing key in `locale.lua`) or the legacy `label` field (fixed text, no automatic translation).

The **item labels** in `ox_inventory` (`installation/ox_items_snippet.txt`) are independent — translate them manually in your `items.lua` if needed.

---

## How it works (Player)

### 1. Hydraulic Jack — Main tool

- Use the **Jack** item (`chopshop_jackstand`) near any vehicle.
- The "Placing jacks..." progress bar lifts the car (~8s).
- With the car lifted, the **dismantle targets** appear via `ox_target`.
- **Lower the car**: use the "Remove jacks" target on the vehicle.

### 2. Dismantle Stages (all require a jack)

| Stage | Parts | Extra Tool | Reward |
|------|-------|-----------------|------------|
| **1 — Basic** | Hood, trunk, wheels, doors | — | Materials via `Config.CarPartRewards` |
| **2 — Structural** | Doors / hood / trunk | Saw (`metal_saw`) | `car_parts` per piece |
| **3 — Engine** | Engine | Screwdriver (`screwdriver`) | 5× `car_parts` |
| **4 — Carcass** | Carcass | Welder near the vehicle | Recyclable materials (chance) |

> **Stage 3** requires the hood to be removed in Stage 2.
> **Stage 4** requires the engine to be removed in Stage 3 and a welder placed within the `Config.AdvancedChop.WelderRadius`.

### 3. Vehicle Discard

After removing `Config.Discard.MinPartsToDiscard` parts, the **Discard vehicle** target appears. The player receives cash (`DefaultPayout`). If `CopsBonus.Enable` is on, the amount is multiplied when there are enough police officers online.

### 4. Workbench (`chopshop_bench`)

- Use the **Workbench** item to place the crafting station.
- Recipes are configured in `Config.BenchRecipes` (inputs/outputs/duration).
- A welder is mandatory near the bench to craft Stage 4 items.

### 5. Tyres — Sale and missions

- **Direct sale**: remove tyres using the jack → load into a pickup truck → go to the buyer NPC → receive cash (`Config.TyreSelling.PricePerTyre`).
- **Contract missions** (`Config.TyreMission`): NPC gives a contract → target vehicle spawns → steal 4 tyres using the bolt minigame → deliver to buyer → receive a bonus.

---

## Installation

1. **Database**
   Execute `sql/vp_chopshop.sql` (creates all 6 tables: `vp_chopshop_benches`, `vp_chopshop_welders`, `vp_chop_vin_scratched`, `vp_chop_fence_trust`, `vp_chop_fence_orders`, `vp_chop_progression`).

2. **Items (ox_inventory)**
   Copy the blocks from `installation/ox_items_snippet.txt` to `ox_inventory/data/items.lua`. Required items:

   | Item | Usage |
   |------|-----|
   | `chopshop_jackstand` | Jack — main tool |
   | `chopshop_bench` | Crafting bench |
   | `chopshop_welder` | Welder (Stage 4) |
   | `metal_saw` | Saw (Stage 2) |
   | `screwdriver` | Screwdriver (Stage 3) |
   | `chopshop_tyre` | Stolen tyre |

3. **Server**
   Add `ensure vp_chopshop` after `ox_lib`, `ox_inventory`, `ox_target`, `oxmysql`.

4. **Permissions (ACE)**
   For admin commands (`/choplifts`, `/chopremove`), add:
   ```
   add_ace group.admin command.choplifts allow
   add_ace group.admin command.chopremove allow
   ```

5. **Framework (optional)**
   QBCore/QBox/ESX are not mandatory. Without them, `ServerPlayerIsReady` returns `true` for everyone. The bridge in `bridge/server_framework.lua` only uses the framework for `ServerPlayerIsReady` and for money checking/adding in the NPC shop.

---

## Configuration (`shared/config.lua`)

### Distances and models
| Key | Description |
|-------|-----------|
| `Config.InteractDistance` | Max distance to interact (ox_target) |
| `Config.MaxPlaceDistance` | Max distance to place bench/welder |
| `Config.VehicleNearLiftRadius` | Validation radius player↔vehicle (server-side) |
| `Config.MinBenchSpacing` | Min distance between benches |
| `Config.BenchModel` | Bench prop (`prop_tool_bench02`) |

### Dismantle

| Key | Description |
|-------|-----------|
| `Config.RequireVehicleKeys` | Requires vehicle keys (`qbx_vehiclekeys` / `qb-vehiclekeys`) |
| `Config.ChopCooldownSeconds` | Wait after each part dismantled (`0` = off) |
| `Config.ChopSkillCheck` | Optional skillcheck before progress bar |
| `Config.ChopProgressMs` | Dismantle progress bar duration (ms) |
| `Config.Tools` | Configures individual tools, their speed, durability, and dispatch alert chance |
| `Config.AlarmOnChop` | Automatically triggers the vehicle alarm if dismantled without keys |
| `Config.Dispatch` | Dispatches suspicious activity to police via ps-dispatch, cd-dispatch, or qs-dispatch |
| `Config.CarPartRewards` | Materials per part in Stage 1 |
| `Config.PartProps` | Visual props loaded when removing a part |

### Hydraulic Jack (`Config.Jackstand`)

| Key | Description |
|-------|-----------|
| `Item` | Item that triggers the jack (`chopshop_jackstand`) |
| `TyreItem` | Item generated when stealing a tyre (`chopshop_tyre`) |
| `PropModel` | GTA V jack prop (`imp_prop_axel_stand_01a`) |
| `LiftHeight` | Car lift height (GTA units) |
| `LiftProgressMs` | "Placing jacks..." duration |
| `LowerProgressMs` | "Removing jacks..." duration |
| `MaxCarDistance` | Max radius to trigger the jack |
| `Minigame` | Tyre removal minigame (`skill_circle` / `button_mash`) |

### Advanced Dismantle (`Config.AdvancedChop`)

| Key | Description |
|-------|-----------|
| `SawItem` | Saw for Stage 2 |
| `ScrewdriverItem` | Screwdriver for Stage 3 |
| `WelderRadius` | Welder detection radius for Stage 4 |
| `DoorReward` | Reward per part in Stage 2 |
| `EngineReward` | Reward for engine in Stage 3 |
| `CarcassRewards` | Rewards with chance in Stage 4 |

### Discard (`Config.Discard`)
| Key | Description |
|-------|-----------|
| `Enable` | Toggles vehicle discard |
| `MinPartsToDiscard` | Min parts removed to discard |
| `DefaultPayout` | Base cash on discard |
| `CopsBonus` | Multiplies payout when police are online |
| `PayoutByModel` | Specific payout per vehicle model |

### NPC (`Config.NPC`) and Fence (`Config.Fence`)

Optional static NPC. Available targets: **How it works**, **shop** (bench and welder only), **Hot job** (ambush mission).

| Key | Description |
|-------|-----------|
| `NPC.Enable` | Toggles the NPC on/off |
| `NPC.Model` | Ped model |
| `NPC.Coords` | `vector4` position + heading |
| `NPC.Scenario` | Idle animation (e.g. `WORLD_HUMAN_CLIPBOARD`) |
| `NPC.Shop.Enable` | Toggles cash item shop |
| `NPC.Shop.BenchPrice` | Bench price |
| `NPC.Mission.Enable` | Toggles ambush missions via NPC |
| `NPC.Mission.CooldownSeconds` | Cooldown between mission requests |
| `NPC.Mission.AmbushChance` | 0..1 probability of an ambush occurring |
| `Fence.NightBonus` | Adds a payment bonus if the sale is made during in-game night time |

### Ambushes (`Config.Ambush`)

| Key | Description |
|-------|-----------|
| `Enable` | Toggles hostile spawns |
| `RandomOnDismantle` | Random chance per dismantle |
| `Chance` | Probability (0..1) when random |
| `KindWeights` | Weights per type: `pistol`, `dog`, `bat` |
| `CooldownSeconds` | Min seconds between ambushes per player |
| `DespawnMs` | Timeout for peds to disappear |

### Discord (`Config.Discord`)

Optional webhook for event logging:

| Key | Description |
|-------|-----------|
| `Webhook` | Webhook URL (empty = off) |
| `LogChopPart` | Log every dismantled part |
| `LogBenchCraft` | Log bench recipes |
| `LogPlaceBench` | Log bench placements |

### Tyre Sales (`Config.TyreSelling`)

| Key | Description |
|-------|-----------|
| `Enable` | Toggles sales |
| `PickupTruckModels` | Accepted models to transport tyres |
| `MaxTyresInTruck` | Max tyres per trip |
| `PricePerTyre` | Cash per sold tyre |
| `NpcCoords` / `NpcModel` | Buyer position and model |

### Tyre Missions (`Config.TyreMission`)

| Key | Description |
|-------|-----------|
| `Enable` | Toggles missions |
| `MissionCooldown` | Seconds between contracts per player |
| `VehicleModels` | Target vehicle models |
| `TargetLocations` | Target vehicle spawn locations |
| `BonusReward` | Cash bonus per completed mission |
| `MinigameRounds` | Bolts per tyre (skillcheck) |

---

## Framework Compatibility

The script **does not depend on any framework** for the main logic — inventory is strictly **ox_inventory**. The bridge in `bridge/server_framework.lua` only uses the framework for:

- `ServerPlayerIsReady` — checks if the player has fully loaded.
- `BridgeGetCash` / `BridgeRemoveCash` / `BridgeAddCash` — NPC shop (if `NPC.Shop.Enable = true`).

| Framework | Support |
|-----------|---------|
| QBox (`qbx_core`) | Full |
| QBCore (`qb-core`) | Full |
| ESX (`es_extended`) | Functional (no `esx_inventory` support) |
| None | Functional (cash NPC shop disabled) |

**Vehicle keys:** explicit integration with `qbx_vehiclekeys` and `qb-vehiclekeys`. With another key system, set `Config.RequireVehicleKeys = false` to disable checking.

---

## File Structure

| Path | Function |
|---------|--------|
| `bridge/server_framework.lua` | Framework detect; `ServerPlayerIsReady`; `ServerChopPlayerKey`; NPC shop cash |
| `bridge/server_inventory.lua` | ox_inventory wrappers (count/add/remove) |
| `bridge/client_notify.lua` | `lib.notify` notifications |
| `shared/config.lua` | Shared global config |
| `shared/locale.lua` | UI Texts (en, pt, es, fr, tr) |
| `shared/chop_parts.lua` | Dismountable parts and menu order |
| `server/db.lua` | oxmysql: benches and welders CRUD |
| `server/validate.lua` | `ValidatePlayerNearPoint`, `ValidatePlayerNearVehicle` |
| `server/cooldown.lua` | Optional cooldown between dismantles |
| `server/chop.lua` | Stage 1: server logic to dismantle part and rewards |
| `server/advanced_chop.lua` | Stages 2-4: door/engine/carcass, rate limiting |
| `server/bench.lua` | Bench recipe logic |
| `server/npc.lua` | Foreman ped (spawn, shop, mission) |
| `server/ambush.lua` | Ambushes (netId-based): `VPChopAmbushMaybe`, `VPChopNpcMissionAccept` |
| `server/tyres.lua` | Tyre sales and missions (server) |
| `server/discord.lua` | Optional Discord webhook |
| `server/main.lua` | Init, placement callbacks, world broadcast |
| `client/placement.lua` | Bench/welder placement mode (raycast + preview) |
| `client/lifts.lua` | Carried parts utilities (`VPChopCarryingPart`) |
| `client/bench.lua` | Bench and crafting (client) |
| `client/welder.lua` | Welder (client) |
| `client/npc.lua` | Blip + ox_target on the foreman NPC |
| `client/tyres.lua` | Tyre sales and missions (client) |
| `client/main.lua` | Jackstand system, Stages 1-4, world sync, discard |

---

## Version

`1.3.7` — defined in `fxmanifest.lua`.
