# vp_chopshop

Chop shop system for FiveM: players use a **hydraulic jack** (`chopshop_jackstand`) to lift any vehicle and dismantle parts in 4 progressive stages, yielding material rewards, tyre sales to a rotating fence NPC, optional ambushes, and a **full license-plate system** (physical theft, fake plates that fool the MDT, persistence, and witness-based dispatch). Built for stacks using **ox_lib**, **ox_target**, **ox_inventory**, and **oxmysql** — frameworks **QBox / QBCore / ESX**.

---

## Security & Compatibility

### Audit — 2026-04-27 (v1.6.7)
- Audited by fivem-audit skill (Claude Code)
- ESX fix: `_ESX.Player()` → `_ESX.GetPlayerFromId()`; `ExtendedPlayers()` → `GetPlayers()` + iteration; `xPlayer.getJob()` → `xPlayer.job.name` (property)
- Framework: **ESX-only** (bridge layer)

### Audit — 2026-04-27 (v1.6.6)
- Audited by fivem-audit skill (Claude Code)
- 1 critical, 4 high, 4 medium, 2 low resolved
- C1: `ServerTyreCounts` promoted to global — `server/main.lua` and `server/fence.lua` share the single source of truth for tyre counter
- H1–H4: race condition in tyre sale (`SellTyresBusy` mutex); trust decay XP floor fixed; dead `_npcBuyCooldown` code removed; alarm dispatch when original player disconnected
- M1–M4: refund AddItem with pcall; tyre contract target gated by feature flag; dispatch uses vehicle coords; XP persist in pcall

### Audit — 2026-04-27 (v1.6.4)
- Audited by fivem-audit skill (Claude Code)
- 0 critical, 2 high, 1 medium resolved
- High: double SQL query per `VPChopHeatCheck` eliminated; ghost `data_file` ytyp removed
- Medium: ESX `getAccount('money')` nil guard added in `BridgeGetCash` / `BridgeRemoveCash`
- Framework: **ESX-only** (bridge layer)
- All oxmysql queries parameterized (`?` placeholders) — no SQL injection

---

## Mandatory Requirements

| Resource | Usage |
|---------|-------|
| `ox_lib` | Menus, progress bars, skillcheck, callbacks |
| `ox_target` | Interaction on lifted vehicle, bench, welder, NPC |
| `ox_inventory` | Items, add/remove materials |
| `oxmysql` | Persistence for benches, welders, progression, fence trust |

Suggested order in `server.cfg`: ox dependencies first, then `ensure vp_chopshop`.

---

## Languages (UI)

In `shared/config.lua`, set **`Config.Locale`** to one of:

| Value | Language |
|-------|----------|
| `en` | English |
| `pt` | Português (default) |
| `es` | Español |
| `fr` | Français |
| `tr` | Türkçe |

Strings are in `shared/locale.lua`. For custom recipes: use `labelKey` (existing key in `locale.lua`) or the legacy `label` field (fixed text, no automatic translation).

Item labels in `ox_inventory` (`installation/ox_items_snippet.txt`) are independent — translate them manually in your `items.lua` if needed.

---

## How it works (Player)

### 1. Hydraulic Jack — Main tool

- Use the **Jack** item (`chopshop_jackstand`) near any vehicle.
- A "Placing jacks..." progress bar lifts the car (~8 s).
- With the car lifted, **dismantle targets** appear on each part via `ox_target`.
- **Lower the car**: use the "Remove jacks" target on the vehicle.

### 2. Dismantle Stages (all require a lifted vehicle)

| Stage | Parts | Extra Tool | Reward |
|-------|-------|-----------|--------|
| **1 — Basic** | Hood, trunk, wheels, doors | — | Materials via `Config.CarPartRewards` |
| **2 — Structural** | Doors / hood / trunk | Saw (`metal_saw`) | `car_parts` per piece |
| **3 — Engine** | Engine | Screwdriver (`screwdriver`) | 5× `car_parts` |
| **4 — Carcass** | Carcass | Welder near vehicle | Recyclable materials (chance) |

> **Stage 3** requires the hood to be removed in Stage 2.
> **Stage 4** requires the engine removed in Stage 3 and a welder placed within `Config.AdvancedChop.WelderRadius`.

### 3. Vehicle Alarm

When the **first part** of a vehicle is dismantled, the server rolls a chance of triggering the alarm proportional to the car's class (Super 80%, Motorcycles 10%…).

**If the alarm triggers:**
- Vehicle alarm sound and lights activate
- Notification: *"The alarm triggered! Disable it before the police arrive."*
- Target `Disable alarm` appears on the vehicle

**To disarm** (within 30 s, configurable):
1. Requires **screwdriver** (`screwdriver`) in inventory
2. Pass a `lib.skillCheck` (easy + medium)
3. On failure: can retry until time expires

**If time expires without disarming:** automatic dispatch to police with vehicle location.

### 4. Vehicle Discard

After removing `Config.Discard.MinPartsToDiscard` parts, the **Discard vehicle** target appears. The player receives cash (`DefaultPayout`). With `CopsBonus.Enable`, the amount is multiplied when enough police officers are online.

### 5. Workbench (`chopshop_bench`)

- Place the **Workbench** item to deploy the crafting station.
- Recipes configured in `Config.BenchRecipes` (inputs/outputs/duration).
- A welder must be nearby (≤ `Config.AdvancedChop.WelderRadius`) for Stage 4 crafting.

### 6. Tyres — Direct sale

- Remove tyres with the jack → a tyre minigame plays per wheel.
- Load tyres into a pickup truck (max `Config.TyreSelling.MaxTyresInTruck`).
- Drive to the buyer NPC → receive cash per tyre.

### 7. Fence NPC — Materials and parts

The fence rotates between up to 4 configurable locations every ~45 minutes. A `fence_referral` item (15% drop from ambush NPCs) is required for first introduction.

**Trust levels (0–4):**

| Level | Name | Access |
|-------|------|--------|
| 1 | Known | Sell materials and tyres |
| 2 | Trusted | Buy bench at the fence |
| 3 | Partner | Receive orders with price bonus (×1.35–1.5) |
| 4 | Associate | Deliver whole stripped cars; maximum bonus |

Trust decays after 7 days of inactivity.

**Price multipliers applied over the base price:**
- Player trust level
- Progression tier (Tier 4 = +10%)
- Vehicle heat (penalty if hot)
- Night bonus (×1.3 between 21h–06h, configurable)

### 8. Progression (Tier 1–4)

XP is earned per successful dismantle action and fence delivery.

| Tier | Name | Total XP | Speed | Materials | Fence Price | Unlocks |
|------|------|----------|-------|-----------|-------------|---------|
| 1 | Rookie | 0 | ×1.0 | ×1.0 | ×1.0 | — |
| 2 | Mechanic | 500 | ×1.10 | ×1.05 | ×1.0 | — |
| 3 | Specialist | 2 000 | ×1.20 | ×1.10 | ×1.0 | VIN scratch + orders |
| 4 | Master | 5 000 | ×1.30 | ×1.15 | ×1.10 | Whole-car delivery |

### 9. Plate theft and fake plates (`Config.Plates`)

A vehicle-identity system tied to heat/MDT — the plate is what links the car to the crime.

- **Steal the physical plate**: with the screwdriver (`screwdriver`), aim at a target vehicle (ox_target "Pry off plate") → skillcheck → receive the `stolen_plate` item (the original plate is kept in the metadata). The car is left with no visible plate. Sellable at the fence or used as a forging input.
  - **Witness-based dispatch**: stealing does not call the police automatically. The chance scales with **nearby NPCs and players** (with a night modifier) — a deserted area in the dead of night almost never calls, a busy area calls more often. Stealing **with witnesses nearby** earns a **risk bonus** (XP/cash, server-capped).
- **Forge a fake plate**: at the bench (trust **tier 2**), consumes a `stolen_plate` + inputs (`plastic` + `aluminum`) → produces the `fake_plate` item (inherits the stolen plate).
- **Apply the fake plate** (use the `fake_plate` item): swaps the vehicle's visible plate and **fools the MDT plate lookup** — anyone running the plate sees the fake "clean" plate, hiding the history.
  - **Heat follows the REAL plate**: the disguise fools the police, but the crime keeps accumulating on the real car. The fake plate **does not launder heat** (that is VIN scratch's job).
  - **Full persistence**: the disguise survives a restart and is re-applied when the car respawns.
  - **Garage-safe**: storing a disguised car **never saves the fake plate** to the database (it is reverted to the real one before saving); the disguise returns on the next spawn. Requires the garage hook (see Installation).
- **Remove the fake plate** (police): jobs in `Config.Plates.PoliceJobs` get an ox_target to break the disguise and restore the real plate.

### 10. Forensic traces / Evidence (`Config.Evidence`)

A **forensic** layer tied to the [`evidences`](https://forum.cfx.re/t/free-evidence-script/5357633) resource — it makes crime genuinely traceable, on top of heat/MDT.

- **Every crime action leaves a trace** linked to the criminal: dismantling a part, VIN scratch, plate theft, forging and applying a fake plate.
- **Types:** **fingerprint** (higher chance) + **DNA** (blood, lower chance — "cut/sweat").
- **Counterplay — gloves:** carrying the **`gloves`** item in your inventory **blocks fingerprints**; but DNA can still drop (you are never 100% safe). A tactical choice: go in clean and prepared, or fast and risky.
- **Scales with heat:** a "hotter" car (super, freshly stolen, many parts removed) leaves **more traces**. Working in a hurry = more risk.
- **The police collect** with the `evidences` kit and the script **identifies the offender** by biometrics — the criminal may flee, but the scene gives them away.
- **Optional & safe:** if the `evidences` resource isn't running, the feature **auto-disables** without affecting chopping (`Config.Evidence.Enable` also toggles it on/off).

### 11. Tyre marks (`Config.TyreMarks`)

A **getaway** lead — it complements forensics, but points at the **vehicle**, not the person.

- After a crime, if the criminal **does a burnout / peels out** within a short window (~45 s), a **mark is left on the ground** tied to the **vehicle MODEL** used to flee.
- The police (configured jobs) spot the mark and **examine** it → "Tyre marks from a **{model}** (**{class}**)". It **never reveals the plate** (a tyre can't tell the plate) — only the type of car.
- **Counterplay:** driving away calmly (no burnout) leaves no mark.
- The mark is **transient** (configurable TTL); the server resolves the model by netId (anti-cheat), and examination is gated by job + proximity.

### 12. Part serial numbers (`Config.PartSerial`)

An **economy + forensic** layer on the `car_parts` item — a parts-market RP for mechanics, criminals, and police.

- Each `car_parts` carries a **serial + state** in its metadata. A chopped part starts **stolen** ("hot" serial + source model, **no plate**; one serial per car).
- **At the bench** (gated by progression tier): **scratch the serial** (mid tier → visibly tampered, obvious) and **forge a new serial** (max tier → the part **looks legal**).
- **Legal source:** export `exports.vp_chopshop:IssueLegalParts(src, amount)` (for mechanic resources to integrate) + an optional vendor. Legit serials are registered in the database.
- **Police** (item `parts_scanner` + a target on the player "Inspect parts"): a normal scan shows **stolen / scratched / registered**; a **forged** part looks registered — only **forensics** (with `forensic_kit`) cross-checks the serial against the registry and flags the **forgery**.
- The serial is a forensic layer: it **does not affect** `car_parts` consumption in recipes/fence sales.

---

## Installation

1. **Database**
   Execute `sql/vp_chopshop.sql` (creates all 8 tables: `vp_chopshop_benches`, `vp_chopshop_welders`, `vp_chop_vin_scratched`, `vp_chop_fence_trust`, `vp_chop_fence_orders`, `vp_chop_progression`, `vp_chop_fake_plates`, `vp_chop_legit_serials`). The tables are also created/migrated automatically on boot (idempotent).

2. **Items (ox_inventory)**
   Copy the blocks from `installation/ox_items_snippet.txt` to `ox_inventory/data/items.lua`.

   | Item | Usage |
   |------|-------|
   | `chopshop_jackstand` | Jack — main tool |
   | `chopshop_bench` | Crafting bench |
   | `chopshop_welder` | Welder (Stage 4) |
   | `metal_saw` | Saw (Stage 2) |
   | `screwdriver` | Screwdriver (Stage 3 + plate theft) |
   | `chopshop_tyre` | Stolen tyre |
   | `stolen_plate` | Stolen physical plate (metadata) |
   | `fake_plate` | Forged fake plate (usable — applies the disguise) |
   | `fence_referral` | First introduction to the fence NPC |
   | `gloves` | Gloves — prevent leaving fingerprints (evidence system) |
   | `parts_scanner` | Parts scanner (police) — inspects the `car_parts` serial |

3. **Server**
   Add `ensure vp_chopshop` after `ox_lib`, `ox_inventory`, `ox_target`, `oxmysql`.

   **Evidence (optional):** for the forensic layer (section 10), install the [`evidences`](https://forum.cfx.re/t/free-evidence-script/5357633) resource and `ensure` it. vp_chopshop only **consumes** its API (`exports.evidences:syncEvidence`) and **auto-disables** if the resource is absent — no hard dependency. Toggle it via `Config.Evidence.Enable`.

   **Garage hook (required for fake plates on owned cars):** so the garage never saves the fake plate, add this at the point where it captures the `props`/plate before saving, BEFORE the save:
   ```lua
   if GetResourceState('vp_chopshop') == 'started' then
       props = exports.vp_chopshop:GetRealPlateForProps(vehicle, props)
   end
   ```
   - **QBox (qbx_garages):** in `server/main.lua`, in the `qbx_garages:server:parkVehicle` callback, before `SaveVehicle` (block tagged `[vp_chopshop F3 garagem]`). ⚠️ Re-apply if qbx_garages is updated.
   - **QBCore (qb-garages):** see the snippet in `installation/qb-garages-hook.md`.

4. **Permissions (ACE)**
   For admin commands (`/choplifts`, `/chopremove`):
   ```
   add_ace group.admin command.choplifts allow
   add_ace group.admin command.chopremove allow
   ```

5. **Framework**
   The bridge in `bridge/server_framework.lua` auto-detects **QBox (`qbx_core`)**, **QBCore (`qb-core`)**, or **ESX (`es_extended`)** by priority order. Used for `ServerPlayerIsReady`, job (police gate for plates), cash, and citizenid. *(The LIVE server is QBox; QBCore is supported for portability but not tested in this environment.)*

---

## Configuration (`shared/config.lua`)

### Distances and models
| Key | Description |
|-----|-------------|
| `Config.InteractDistance` | Max distance to interact (ox_target) |
| `Config.MaxPlaceDistance` | Max distance to place bench/welder |
| `Config.VehicleNearLiftRadius` | Server-side player↔vehicle validation radius |
| `Config.MinBenchSpacing` | Min distance between benches |
| `Config.BenchModel` | Bench prop (`prop_tool_bench02`) |

### Dismantle
| Key | Description |
|-----|-------------|
| `Config.RequireVehicleKeys` | Requires vehicle keys (see `Config.VehicleKeys`) |
| `Config.ChopCooldownSeconds` | Cooldown between dismantles per player (`0` = off) |
| `Config.ChopSkillCheck` | Optional skillcheck before progress bar |
| `Config.ChopProgressMs` | Dismantle progress bar duration (ms) |
| `Config.Tools` | Per-tool: speed multiplier, max uses, dispatch chance |
| `Config.CarPartRewards` | Materials per part in Stage 1 |
| `Config.PartProps` | Visual props loaded when removing a part |

**Dismantle tools:**

| Item | Uses | Dispatch chance | Speed |
|------|------|----------------|-------|
| `saw_cheap` | 2 | 100% | ×1.4 (slower) |
| `saw_pro` | 6 | 25% | ×1.0 |
| `mechanic_drill` | 10 | 0% | ×0.7 (faster) |

### Hydraulic Jack (`Config.Jackstand`)
| Key | Description |
|-----|-------------|
| `Item` | Item that triggers the jack (`chopshop_jackstand`) |
| `TyreItem` | Item generated when stealing a tyre (`chopshop_tyre`) |
| `PropModel` | GTA V jack prop (`imp_prop_axel_stand_01a`) |
| `LiftHeight` | Car lift height (GTA units) |
| `LiftProgressMs` | "Placing jacks…" duration |
| `LowerProgressMs` | "Removing jacks…" duration |
| `MaxCarDistance` | Max radius to trigger the jack |
| `Minigame` | Tyre removal minigame (`skill_circle` / `button_mash`) |

### Advanced Dismantle (`Config.AdvancedChop`)
| Key | Description |
|-----|-------------|
| `Enable` | Toggles Stages 2–4 |
| `SawItem` | Saw item for Stage 2 |
| `ScrewdriverItem` | Screwdriver item for Stage 3 |
| `WelderRadius` | Welder detection radius for Stage 4 |
| `DoorReward` | Reward per part in Stage 2 |
| `EngineReward` | Reward for engine in Stage 3 |
| `CarcassRewards` | `{ item, count, chance }` list for Stage 4 |

### Vehicle Alarm (`Config.Alarm`)
| Key | Description |
|-----|-------------|
| `Enable` | Toggles the alarm system (default: `true`) |
| `ChanceByClass` | `[classId] = chance` table (0.0–1.0) per GTA class |
| `DefaultChance` | Fallback chance for unmapped classes (`0.25`) |
| `DisarmWindowSeconds` | Seconds to disarm before dispatch (`30`) |
| `DisarmDistance` | Max target distance for disarm in metres (`6.0`) |
| `DisarmItem` | Item required to start the minigame (`'screwdriver'`) |
| `DisarmSkillCheck` | `{ difficulties, keys }` for `lib.skillCheck`; `false` = no minigame |

**Default chances by class:**

| GTA Class | Examples | Chance |
|-----------|----------|--------|
| Super (7) | Zentorno, T20 | 80% |
| Military (19) | Insurgent, Rhino | 75% |
| Sports (6) | Elegy, Rapid GT | 55% |
| Emergency (18) | Police, Ambulance | 65% |
| Muscle (4) | Gauntlet, Vigero | 40% |
| SUVs (2) / Coupes (3) | Granger, Buffalo | 35% |
| Off-Road (9) | Sandking, Kamacho | 30% |
| Sedans (1) | Stanier, Emperor | 20% |
| Compacts (0) / Vans (12) | Issi, Rumpo | 15–20% |
| Motorcycles (8) | PCJ, Bati | 10% |
| Others | — | 25% (default) |

### Fence NPC (`Config.Fence`)
| Key | Description |
|-----|-------------|
| `Locations` | List of `{ coords=vector4, blipLabel }` — fence rotates through these |
| `RotationMinutes` | Minutes between location changes |
| `IntroduceItem` | Item required for first introduction (`fence_referral`) |
| `TrustDecayDays` | Days of inactivity before trust level drops |
| `TrustXpPerLevel` | `[1]=100, [2]=300, [3]=600, [4]=1000` — cumulative XP per level |
| `NightBonus` | `{ Enable, StartHour, EndHour, Multiplier }` — night price bonus |
| `ItemPrices` | Base price per item (modified by trust/tier/heat) |
| `WholeCarEnable` | Enables whole-car delivery (requires Trust 4) |
| `WholeCarPayout` | Base cash for a whole stripped car |
| `OrdersEnable` | Enables the orders system (requires Trust 3+) |

### Progression (`Config.Progression`)
| Key | Description |
|-----|-------------|
| `TierXp` | `[1]=0, [2]=500, [3]=2000, [4]=5000` — cumulative XP per tier |
| `SpeedMult` | Progress bar speed multiplier per tier |
| `MaterialMult` | Material quantity multiplier per tier |
| `FencePriceMult` | Fence price multiplier per tier (Tier 4 = +10%) |

**XP per action:**

| Action | XP |
|--------|----|
| Stage 1 part | 8 |
| Stage 2 part | 15 |
| Stage 3 (engine) | 40 |
| Stage 4 (carcass) | 60 |
| Vehicle discard | 25 |
| Tyre sale | 5 |
| Order delivered | 120 |
| Tyre mission | 80 |
| VIN scratch | 30 |
| Material sale | 10 |
| Whole-car delivery | 150 |

### Discard (`Config.Discard`)
| Key | Description |
|-----|-------------|
| `Enable` | Toggles vehicle discard |
| `MinPartsToDiscard` | Min parts removed before discard target appears |
| `DefaultPayout` | Base cash on discard |
| `CopsBonus` | `{ Enable, PoliceJobs, MinCops, Multiplier }` — multiplies payout when police are online |
| `PayoutByModel` | Per-model payout override table |

### NPC (`Config.NPC`)

Optional static NPC with shop and mission targets (disabled by default).

| Key | Description |
|-----|-------------|
| `NPC.Enable` | Toggles the NPC |
| `NPC.Model` | Ped model |
| `NPC.Coords` | `vector4` position + heading |
| `NPC.Scenario` | Idle animation (e.g. `WORLD_HUMAN_CLIPBOARD`) |
| `NPC.Shop.Enable` | Cash item shop (bench, welder) |
| `NPC.Shop.BenchPrice` | Bench price |
| `NPC.Mission.Enable` | Ambush missions via NPC |
| `NPC.Mission.CooldownSeconds` | Cooldown between mission requests |
| `NPC.Mission.AmbushChance` | 0..1 probability of ambush occurring |

### Ambushes (`Config.Ambush`)
| Key | Description |
|-----|-------------|
| `Enable` | Toggles hostile spawns |
| `RandomOnDismantle` | Random chance per dismantle action |
| `Chance` | Probability (0..1) when random |
| `KindWeights` | Weights per type: `pistol`, `dog`, `bat` |
| `CooldownSeconds` | Min seconds between ambushes per player |
| `DespawnMs` | Timeout before peds disappear |

### Tyre Sales (`Config.TyreSelling`)
| Key | Description |
|-----|-------------|
| `Enable` | Toggles tyre sales |
| `PickupTruckModels` | Models accepted for transporting tyres |
| `MaxTyresInTruck` | Max tyres per trip |
| `PricePerTyre` | Cash per sold tyre |
| `NpcCoords` / `NpcModel` | Buyer position and model |

### Tyre Missions (`Config.TyreMission`)
| Key | Description |
|-----|-------------|
| `Enable` | Toggles missions (default: `false`) |
| `MissionCooldown` | Seconds between contracts per player |
| `VehicleModels` | Target vehicle models |
| `TargetLocations` | Target vehicle spawn locations |
| `BonusReward` | Cash bonus per completed mission |
| `MinigameRounds` | Bolts per tyre (skillcheck rounds) |

### Plate theft and fake plates (`Config.Plates`)
| Key | Description |
|-----|-------------|
| `Enable` | Toggles the entire plate feature |
| `MaxDistance` / `ApplyMaxDistance` | Max distance (server-side) to steal / apply |
| `StealCooldownSeconds` | Anti-farm steal cooldown per player |
| `SkillCheck` | Minigame when prying off the plate (`{ difficulties, keys }` for `lib.skillCheck`) |
| `ToolItem` | Item required to steal (default `screwdriver`) |
| `ForgeTier` | Minimum fence trust to forge a fake plate (default 2) |
| `ForgeInputs` | Forge inputs (e.g. `{ plastic = 2, aluminum = 1 }`) |
| `Persist` | Full disguise persistence (re-applies on spawn, survives restart) |
| `BlockOnOwned` | (legacy, inert — now allows any car via the garage hook) |
| `PoliceJobs` | Jobs that can remove the fake plate (e.g. `{ 'police','bcso','sheriff' }`) |
| `Witness` | Witness-based dispatch: `{ Radius, NpcWeight, PlayerWeight, BaseChance, MaxChance, NightModifier, BonusMinScore, BonusXp, BonusCashMax }` |

### Forensic traces / Evidence (`Config.Evidence`)

Optional integration with the `evidences` resource. Auto-disables if it isn't running.

| Key | Description |
|-----|-------------|
| `Enable` | Toggles the forensic layer |
| `GlovesItem` | Item that blocks fingerprints (default `gloves`) |
| `GlovesBlocksDna` | If `true`, gloves also block DNA (default `false` — DNA still drops) |
| `DnaType` | Type of DNA left: `'blood'` or `'saliva'` |
| `HeatScaling` / `HeatFactor` | More heat on the plate → higher trace chance (`chance × (1 + heat/100 × HeatFactor)`) |
| `Actions` | Base chance (0..1) of **fingerprint** and **DNA** per action: `chop_part`, `vin_scratch`, `plate_steal`, `plate_forge`, `plate_apply` |

### Tyre marks (`Config.TyreMarks`)
| Key | Description |
|-----|-------------|
| `Enable` | Toggles tyre marks |
| `ArmWindowSeconds` | Window after the crime during which a burnout leaves a mark (~45) |
| `MarkTTLSeconds` | Mark lifetime before it disappears (~600) |
| `MaxMarksPerCrime` | Max marks per crime window |
| `ExamineDistance` | Distance for the police to examine |
| `Burnout` | Detection thresholds: `{ Ratio, MinWheelSpeed, MaxRealSpeed, CooldownMs }` (calibrate in-game) |
| `PoliceJobs` | Jobs that can examine |
| `ClassNames` | Map of GTA classes (0..22) → display name |

### Part serial numbers (`Config.PartSerial`)
| Key | Description |
|-----|-------------|
| `Enable` | Toggles the serial system on `car_parts` |
| `ScratchTier` / `ForgeTier` | Progression tier to scratch (mid) and to forge (max) |
| `ForgeInputs` | Inputs consumed when forging (e.g. `{ plastic = 2, aluminum = 1 }`) |
| `LegalVendor` | Legal parts vendor: `{ Enable, Coords, Model, Price, Amount }` |
| `PoliceJobs` | Jobs that can inspect parts |
| `ScannerItem` / `ForensicItem` | Items: police scanner (`parts_scanner`) and forensic kit (`forensic_kit`) |

### Discord (`Config.Discord`)
| Key | Description |
|-----|-------------|
| `Webhook` | Webhook URL (empty = off) |
| `LogChopPart` | Log every dismantled part |
| `LogBenchCraft` | Log bench recipes |
| `LogPlaceBench` | Log bench placements |
| `LogPlaceWelder` | Log welder placements |

### Dispatch (`Config.Dispatch`)
| Key | Description |
|-----|-------------|
| `Enable` | Toggles police dispatch alerts |
| `System` | `'ps-dispatch'`, `'cd_dispatch'`, or `'qs-dispatch'` |

---

## Framework Compatibility

The script **does not depend on any framework** for main logic — inventory is strictly **ox_inventory**. The bridge in `bridge/server_framework.lua` auto-detects the framework and uses it for:

- `ServerPlayerIsReady` — checks if the player has fully loaded.
- `BridgeGetJob` / `BridgeIsPolice` — police gate for fake-plate removal.
- `BridgeGetCash` / `BridgeRemoveCash` / `BridgeAddCash` — NPC shop and plate bonuses.

| Framework | Support |
|-----------|---------|
| QBox (`qbx_core`) | Full — direct exports (`GetPlayer`, `AddMoney`, `job.name`) |
| QBCore (`qb-core`) | Supported (portability — `GetCoreObject`/`Functions.GetPlayer`); not tested in this environment |
| ESX Legacy (`es_extended`) | Full — uses `GetPlayerFromId`, `GetPlayers`, `xPlayer.job.name` |
| None | Functional (NPC cash shop and cash bonuses disabled) |

**Vehicle keys:** use `Config.VehicleKeys` to point to your keys resource/export in ESX. To disable the check, set `Config.RequireVehicleKeys = false`.

---

## File Structure

| Path | Function |
|------|----------|
| `bridge/server_framework.lua` | Framework detect; `ServerPlayerIsReady`; `ServerChopPlayerKey`; NPC shop cash |
| `bridge/server_inventory.lua` | ox_inventory wrappers (count/add/remove) |
| `bridge/client_notify.lua` | `lib.notify` notifications |
| `bridge/mdt.lua` | `VPChopEvt` global event bus; pluggable MDT bridge |
| `bridge/evidence.lua` | Forensic link to the `evidences` resource (`VPChopLeaveEvidence`) |
| `shared/config.lua` | Shared global config |
| `shared/locale.lua` | UI texts (en, pt, es, fr, tr) |
| `shared/chop_parts.lua` | Dismantlable parts and menu order |
| `server/db.lua` | oxmysql: benches and welders CRUD |
| `server/validate.lua` | `ValidatePlayerNearPoint`, `ValidatePlayerNearVehicle` |
| `server/cooldown.lua` | Optional cooldown between dismantles |
| `server/chop.lua` | Stage 1: server logic — dismantle part and rewards |
| `server/advanced_chop.lua` | Stages 2–4: door/engine/carcass, rate limiting |
| `server/bench.lua` | Bench recipe logic |
| `server/ambush.lua` | Ambushes (netId-based): `VPChopAmbushMaybe`, `VPChopNpcMissionAccept` |
| `server/fence.lua` | Rotating fence NPC, trust system, orders, tyre sales, jackstand server-side |
| `server/heat.lua` | Heat system (VIN scratch, MDT components + parts) |
| `server/plates.lua` | Plate theft, fake-plate forge/apply/remove, persistence + cache, witness-based dispatch, `GetRealPlateForProps` export |
| `server/tyremarks.lua` | Tyre marks (resolves model, marks with TTL, police examination) |
| `server/partserial.lua` | `car_parts` serial (scratch/forge, legal source, police inspection) |
| `server/progression.lua` | XP and tiers (listens to event bus, persists in `vp_chop_progression`) |
| `server/discord.lua` | Optional Discord webhook |
| `server/main.lua` | Init, placement callbacks, world broadcast |
| `client/placement.lua` | Bench/welder placement mode (raycast + preview) |
| `client/carry.lua` | Carry system for loaded parts (`VPChopCarryingPart`) |
| `client/bench.lua` | Bench and crafting (client) |
| `client/welder.lua` | Welder (client) |
| `client/fence.lua` | Rotating blip, fence NPC targets, tyre carry, truck loading |
| `client/alarm.lua` | Vehicle alarm: trigger, skillcheck, dispatch |
| `client/plates.lua` | Plate theft/removal ox_target, skillcheck, witness scoring, `useFakePlateItem` export, visible-plate sync |
| `client/tyremarks.lua` | Burnout detection (armed after a crime) + police ox_target |
| `client/partserial.lua` | Serial options at the bench, inspection ox_target, legal vendor |
| `client/progression.lua` | XP float text, tier-up notification |
| `client/main.lua` | Jackstand system, Stages 1–4, world sync, discard |

---

## Debugging

- `Config.Debug = true` in `shared/config.lua` enables diagnostic prints.
- If `ox_target` fails to start, the client warns in the F8 console and registers no targets.
- Admin commands (require ACE):
  - `/choplifts` — list active benches and welders on the server.
  - `/chopremove <id> <bench|welder>` — remove a bench or welder by ID.

---

## Version

`1.13.2` — defined in `fxmanifest.lua`. Full history in [`CHANGELOG.md`](CHANGELOG.md).

> ⚠️ **This translated README lags.** Current: **`v1.14.3`** released (`main`), **`v1.16-dev`** in
> QA (Part Registry as the single part-definition authority, discard restart recovery,
> front/rear-aware plate minigame, `vp_gangs` bridge). See [`CHANGELOG.md`](CHANGELOG.md) and
> [`STATUS.md`](STATUS.md) for the authoritative state; [`README.md`](README.md) / [`README_pt.md`](README_pt.md) are the maintained versions.

> **v1.7.0–1.13.2:** audit (cleanup/security/performance), immediate reward + ambush,
> the **full license-plate system** (physical theft → forge → fake plate that fools the MDT,
> persistent and with garage reversion; witness-based dispatch; QBox/QBCore/ESX support),
> the **forensic layer** (fingerprint/DNA traces per action, with gloves and heat scaling,
> via optional integration with the `evidences` resource),
> the **tyre marks** (a getaway lead by vehicle model, no plate),
> and **part serials** (`car_parts` stolen/scratched/forged/legal, with police forensics).
