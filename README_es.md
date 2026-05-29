# vp_chopshop

Sistema de **desguace** (chop shop) para FiveM: el jugador usa un **gato hidráulico** (`chopshop_jackstand`) para levantar cualquier vehículo y desmontar piezas en 4 fases progresivas, obteniendo recompensas en materiales, venta de neumáticos a un NPC y emboscadas opcionales. Diseñado para usarse con **ox_lib**, **ox_target**, **ox_inventory** y **oxmysql**.

---

## Requisitos obligatorios

| Recurso | Uso |
|---------|-----|
| `ox_lib` | Menús, progress bars, skillchecks, callbacks |
| `ox_target` | Interacción en el vehículo levantado, mesa de trabajo, soldadora y NPC |
| `ox_inventory` | Objetos, añadir/quitar materiales |
| `oxmysql` | Persistencia para mesas de trabajo y soldadoras |

Orden sugerido en `server.cfg`: dependencias de ox primero, luego `ensure vp_chopshop`.

---

## Idiomas (UI)

En `shared/config.lua`, define **`Config.Locale`** con uno de estos valores:

| Valor | Idioma |
|-------|--------|
| `en` | English |
| `pt` | Português (predeterminado) |
| `es` | Español |
| `fr` | Français |
| `tr` | Türkçe |

Los textos se encuentran en `shared/locale.lua`. Para recetas personalizadas: usa `labelKey` (una clave existente en `locale.lua`) o el campo heredado `label` (texto fijo sin traducción automática).

Las **etiquetas de los ítems** en `ox_inventory` (`installation/ox_items_snippet.txt`) son independientes — tradúcelas manualmente en tu `items.lua` si es necesario.

---

## Cómo funciona (Jugador)

### 1. Gato hidráulico — Herramienta principal

- Usa el ítem **Gato** (`chopshop_jackstand`) cerca de cualquier vehículo.
- La barra de progreso "Colocando gatos..." levanta el coche (~8 s).
- Con el coche levantado, aparecen los **objetivos de desguace** a través de `ox_target`.
- **Bajar el coche**: usa el objetivo "Quitar gatos" en el vehículo.

### 2. Fases de desguace (todas requieren gato)

| Fase | Piezas | Herramienta extra | Recompensa |
|------|-------|-----------------|------------|
| **1 — Básico** | Capó, maletero, ruedas, puertas | — | Materiales vía `Config.CarPartRewards` |
| **2 — Estructural** | Puertas / capó / maletero | Sierra (`metal_saw`) | `car_parts` por pieza |
| **3 — Motor** | Motor | Destornillador (`screwdriver`) | 5× `car_parts` |
| **4 — Carrocería** | Carrocería | Soldadora cerca del vehículo | Materiales reciclables (posibilidad) |

> La **Fase 3** requiere que el capó sea quitado en la Fase 2.
> La **Fase 4** requiere que el motor sea quitado en la Fase 3 y una soldadora colocada dentro de `Config.AdvancedChop.WelderRadius`.

### 3. Descarte del vehículo

Después de quitar `Config.Discard.MinPartsToDiscard` piezas, aparece el objetivo **Descartar vehículo**. El jugador recibe dinero base (`DefaultPayout`). Si `CopsBonus.Enable` está activado, la cantidad se multiplica cuando hay suficientes policías conectados.

### 4. Mesa de trabajo (`chopshop_bench`)

- Usa el ítem **Banco de trabajo** para colocar la estación de crafteo.
- Las recetas se configuran en `Config.BenchRecipes` (ingredientes/resultados/duración).
- Se requiere una soldadora cerca del banco de trabajo para fabricar objetos de la Fase 4.

### 5. Neumáticos — Venta y misiones

- **Venta directa**: quita neumáticos con el gato → cárgalos en una camioneta (pickup) → llévalos al NPC comprador → recibe dinero en efectivo (`Config.TyreSelling.PricePerTyre`).
- **Misiones de contrato** (`Config.TyreMission`): el NPC entrega un contrato → el vehículo objetivo spawnea → roba 4 neumáticos con el minijuego de tornillos → entrégalos al comprador → recibe un bono.

---

## Instalación

1. **Base de datos**
   Ejecuta `sql/vp_chopshop.sql` (crea las 6 tablas: `vp_chopshop_benches`, `vp_chopshop_welders`, `vp_chop_vin_scratched`, `vp_chop_fence_trust`, `vp_chop_fence_orders`, `vp_chop_progression`).

2. **Ítems (ox_inventory)**
   Copia los bloques de `installation/ox_items_snippet.txt` en `ox_inventory/data/items.lua`. Ítems necesarios:

   | Ítem | Uso |
   |------|-----|
   | `chopshop_jackstand` | Gato — herramienta principal |
   | `chopshop_bench` | Mesa de trabajo para crafteo |
   | `chopshop_welder` | Soldadora (Fase 4) |
   | `metal_saw` | Sierra (Fase 2) |
   | `screwdriver` | Destornillador (Fase 3) |
   | `chopshop_tyre` | Neumático robado |

3. **Servidor**
   Añade `ensure vp_chopshop` después de `ox_lib`, `ox_inventory`, `ox_target`, `oxmysql`.

4. **Permisos (ACE)**
   Para los comandos de administrador (`/choplifts`, `/chopremove`), añade:
   ```
   add_ace group.admin command.choplifts allow
   add_ace group.admin command.chopremove allow
   ```

5. **Framework**
   Requiere **ESX** (`es_extended`). El bridge en `bridge/server_framework.lua` usa ESX para `ServerPlayerIsReady` y para transacciones de dinero en la tienda del NPC.

---

## Configuración (`shared/config.lua`)

### Distancias y modelos
| Clave | Descripción |
|-------|-----------|
| `Config.InteractDistance` | Distancia máxima para interactuar (ox_target) |
| `Config.MaxPlaceDistance` | Distancia máxima para colocar mesa/soldadora |
| `Config.VehicleNearLiftRadius` | Radio de validación jugador↔vehículo (server-side) |
| `Config.MinBenchSpacing` | Distancia mínima entre bancos de trabajo |
| `Config.BenchModel` | Prop del banco (`prop_tool_bench02`) |

### Desguace

| Clave | Descripción |
|-------|-----------|
| `Config.RequireVehicleKeys` | Exige llaves del vehículo (ver `Config.VehicleKeys`) |
| `Config.ChopCooldownSeconds` | Tiempo de espera tras desmontar cada pieza (`0` = apagado) |
| `Config.ChopSkillCheck` | Skillcheck opcional antes de la barra de progreso |
| `Config.ChopProgressMs` | Duración de la barra de desguace (ms) |
| `Config.Tools` | Configura herramientas individuales, su velocidad, durabilidad y probabilidad de avisar a la policía |
| `Config.AlarmOnChop` | Activa automáticamente la alarma del vehículo al desmontar sin llaves |
| `Config.Dispatch` | Despacha informes al departamento de policía vía ps-dispatch, cd-dispatch, o qs-dispatch |
| `Config.CarPartRewards` | Materiales por pieza en la Fase 1 |
| `Config.PartProps` | Props visuales devueltos al quitar una pieza |

### Gato Hidráulico (`Config.Jackstand`)

| Clave | Descripción |
|-------|-----------|
| `Item` | Ítem que acciona el gato (`chopshop_jackstand`) |
| `TyreItem` | Ítem generado al robar un neumático (`chopshop_tyre`) |
| `PropModel` | Prop del gato de GTA V (`imp_prop_axel_stand_01a`) |
| `LiftHeight` | Altura de elevación del coche (unidades de GTA) |
| `LiftProgressMs` | Duración de "Colocando gatos..." |
| `LowerProgressMs` | Duración de "Quitando gatos..." |
| `MaxCarDistance` | Radio máximo para accionar el gato |
| `Minigame` | Minijuego de remoción de neumáticos (`skill_circle` / `button_mash`) |

### Desguace Avanzado (`Config.AdvancedChop`)

| Clave | Descripción |
|-------|-----------|
| `SawItem` | Sierra para Fase 2 |
| `ScrewdriverItem` | Destornillador para Fase 3 |
| `WelderRadius` | Radio de detección de la soldadora para Fase 4 |
| `DoorReward` | Recompensa por pieza en la Fase 2 |
| `EngineReward` | Recompensa por el motor en la Fase 3 |
| `CarcassRewards` | Probabilidad de recompensas en la Fase 4 |

### Descarte (`Config.Discard`)
| Clave | Descripción |
|-------|-----------|
| `Enable` | Activa/desactiva el descarte de vehículo |
| `MinPartsToDiscard` | Mínimo de piezas extraídas para descartar |
| `DefaultPayout` | Efectivo base al descartar |
| `CopsBonus` | Multiplica las ganancias si hay policías en línea |
| `PayoutByModel` | Pago específico por modelo de vehículo |

### NPC (`Config.NPC`) y Fence (`Config.Fence`)

NPC fijo opcional. Objetivos disponibles: **Cómo funciona**, **tienda** (sólo mesa y soldadora), **Trabajo caliente** (misión con emboscada).

| Clave | Descripción |
|-------|-----------|
| `NPC.Enable` | Activa/desactiva el NPC |
| `NPC.Model` | Modelo del ped |
| `NPC.Coords` | Coordenadas `vector4` + heading |
| `NPC.Scenario` | Animación de inactividad (ej.: `WORLD_HUMAN_CLIPBOARD`) |
| `NPC.Shop.Enable` | Activa la tienda de ítems con dinero en efectivo |
| `NPC.Shop.BenchPrice` | Precio de la mesa de trabajo |
| `NPC.Mission.Enable` | Activa las misiones de emboscada vía NPC |
| `NPC.Mission.CooldownSeconds` | Enfriamiento (cooldown) entre misiones |
| `NPC.Mission.AmbushChance` | Probabilidad (0..1) de que ocurra una emboscada |
| `Fence.NightBonus` | Añade un bono de pago si la venta se realiza durante horario nocturno en el juego |

### Emboscadas (`Config.Ambush`)

| Clave | Descripción |
|-------|-----------|
| `Enable` | Activa/desactiva spawns de enemigos |
| `RandomOnDismantle` | Posibilidad aleatoria en cada desguace |
| `Chance` | Probabilidad (0..1) si es aleatoria |
| `KindWeights` | Pesos por tipo: `pistol`, `dog`, `bat` |
| `CooldownSeconds` | Segundos mínimos entre emboscadas por jugador |
| `DespawnMs` | Tiempo límite hasta que desaparezcan los peds |

### Discord (`Config.Discord`)

Webhook opcional para registro de eventos (logs):

| Clave | Descripción |
|-------|-----------|
| `Webhook` | URL del webhook (vacío = apagado) |
| `LogChopPart` | Log de cada pieza desmontada |
| `LogBenchCraft` | Log de recetas crafteadas |
| `LogPlaceBench` | Log de colocaciones de la mesa de trabajo |

### Venta de Neumáticos (`Config.TyreSelling`)

| Clave | Descripción |
|-------|-----------|
| `Enable` | Activa/desactiva la venta manual |
| `PickupTruckModels` | Modelos aceptados para transportar los neumáticos |
| `MaxTyresInTruck` | Neumáticos máximos por viaje |
| `PricePerTyre` | Efectivo recibido por neumático |
| `NpcCoords` / `NpcModel` | Posición y modelo de quien compra |

### Misiones de Neumáticos (`Config.TyreMission`)

| Clave | Descripción |
|-------|-----------|
| `Enable` | Activa/desactiva las misiones |
| `MissionCooldown` | Segundos entre contratos por jugador |
| `VehicleModels` | Modelos de vehículos objetivo |
| `TargetLocations` | Lugares de spawn del vehículo |
| `BonusReward` | Bono de efectivo al completar un contrato |
| `MinigameRounds` | Tornillos por neumático (skillcheck) |

---

## Compatibilidad con frameworks

Este script **no requiere un framework** para la lógica principal; el inventario usado es solo **ox_inventory**. El archivo de carga en `bridge/server_framework.lua` solo utiliza el framework para:

- `ServerPlayerIsReady` — saber si el jugador ya está cargado.
- `BridgeGetCash` / `BridgeRemoveCash` / `BridgeAddCash` — tienda NPC (si `NPC.Shop.Enable = true`).

| Framework | Soporte |
|-----------|---------|
| ESX (`es_extended`) | Completo |
| ESX (`es_extended`) | Funcional (sin soporte para `esx_inventory`) |
| Ninguno | Funcional (la tienda con dinero estará desactivada) |

**Llaves de vehículos:** usa `Config.VehicleKeys` para apuntar tu resource/export de llaves en ESX. Si prefieres desactivar la verificación, define `Config.RequireVehicleKeys = false`.

---

## Estructura de archivos

| Ruta | Función |
|---------|--------|
| `bridge/server_framework.lua` | Detección fw; `ServerPlayerIsReady`; `ServerChopPlayerKey`; dinero NPC |
| `bridge/server_inventory.lua` | Wrappers de ox_inventory (count/add/remove) |
| `bridge/client_notify.lua` | Notificaciones `lib.notify` |
| `shared/config.lua` | Config general global |
| `shared/locale.lua` | Textos UI (en, pt, es, fr, tr) |
| `shared/chop_parts.lua` | Piezas desmontables y su orden |
| `server/db.lua` | oxmysql: CRUD mesas y soldadoras |
| `server/validate.lua` | `ValidatePlayerNearPoint`, `ValidatePlayerNearVehicle` |
| `server/cooldown.lua` | Enfriamiento opcional entre desguaces |
| `server/chop.lua` | Fase 1: lógica de servidor e inventario |
| `server/advanced_chop.lua` | Fases 2-4: puerta/motor/chasis, limitadores |
| `server/bench.lua` | Lógica de recetas en la mesa |
| `server/ambush.lua` | Emboscadas (netId-based): `VPChopAmbushMaybe`, `VPChopNpcMissionAccept` |
| `server/fence.lua` | Fence NPC rotativo, confianza, pedidos, venta de neumáticos |
| `server/heat.lua` | Sistema de calor (VIN scratch, componentes MDT) |
| `server/progression.lua` | XP y tiers (persiste en `vp_chop_progression`) |
| `server/discord.lua` | Webhook Discord opcional |
| `server/main.lua` | Init, colocaciones, sync de mundo |
| `client/placement.lua` | Vista de modo colocación (raycast + preestreno) |
| `client/carry.lua` | Sistema de carga de piezas (`VPChopCarryingPart`) |
| `client/bench.lua` | Mesa y crafteo (client) |
| `client/welder.lua` | Soldadora (client) |
| `client/fence.lua` | Blip rotativo, targets NPC fence, carga de neumáticos |
| `client/alarm.lua` | Alarma vehicular: activación, skillcheck, dispatch |
| `client/progression.lua` | Texto flotante XP, notificación de tier |
| `client/main.lua` | Sistema gato hidr., Fases 1-4, sync, descarte |

---

## Versión

`1.6.7` — definida en `fxmanifest.lua`.
