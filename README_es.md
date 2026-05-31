# vp_chopshop

Sistema de **desguace** (chop shop) para FiveM: el jugador usa un **gato hidráulico** (`chopshop_jackstand`) para levantar cualquier vehículo y desmontar piezas en 4 fases progresivas, obteniendo recompensas en materiales, venta de neumáticos a un NPC comprador rotativo, emboscadas opcionales, un **sistema completo de placas** (robo físico, placa falsa que engaña al MDT, persistencia y despacho por testigos) y una **capa forense** (rastros de huella/ADN que la policía recoge). Diseñado para usarse con **ox_lib**, **ox_target**, **ox_inventory** y **oxmysql** — frameworks **QBox / QBCore / ESX**.

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

### 6. Robo de placas y placas falsas (`Config.Plates`)

Sistema de identidad vehicular ligado al heat/MDT — la placa es lo que conecta el coche con el crimen.

- **Robar la placa física**: con el destornillador (`screwdriver`), apunta a un vehículo objetivo (ox_target "Arrancar placa") → skillcheck → recibes el ítem `stolen_plate` (la placa original queda en la metadata). El coche queda sin placa visible. Vendible en el fence o como insumo para forjar.
  - **Despacho por testigos**: robar no avisa a la policía automáticamente. La probabilidad es proporcional a los **NPCs y jugadores cercanos** (con modificador nocturno) — una zona desierta de madrugada casi nunca avisa, una zona concurrida avisa más. Robar **con testigos cerca** otorga un **bono de riesgo** (XP/dinero, limitado en el servidor).
- **Forjar placa falsa**: en la mesa de trabajo (confianza **tier 2**), consume una `stolen_plate` + insumos (`plastic` + `aluminum`) → genera el ítem `fake_plate` (hereda la placa de la robada).
- **Aplicar placa falsa** (usar el ítem `fake_plate`): cambia la placa visible del vehículo y **engaña la consulta de placa del MDT** — quien consulta ve la placa falsa "limpia", ocultando el historial.
  - **El heat sigue la placa REAL**: el disfraz engaña a la policía, pero el crimen sigue acumulándose en el coche verdadero. La placa falsa **no lava heat** (eso es papel del VIN scratch).
  - **Persistencia total**: el disfraz sobrevive a un reinicio y se re-aplica cuando el coche reaparece.
  - **Garaje seguro**: guardar un coche disfrazado **nunca graba la placa falsa** en la base de datos (se revierte a la real antes de guardar); el disfraz vuelve en el próximo spawn. Requiere el hook de garaje (ver Instalación).
- **Quitar placa falsa** (policía): los jobs en `Config.Plates.PoliceJobs` tienen un ox_target para descubrir el disfraz y restaurar la placa real.

### 7. Rastros forenses / Evidencias (`Config.Evidence`)

Capa **forense** ligada al resource [`evidences`](https://forum.cfx.re/t/free-evidence-script/5357633) — hace que el crimen sea rastreable de verdad, por encima del heat/MDT.

- **Toda acción criminal deja un rastro** vinculado al criminal: desguazar una pieza, VIN scratch, robo de placa, forjar y aplicar placa falsa.
- **Tipos:** **huella** (fingerprint, mayor probabilidad) + **ADN** (sangre, menor probabilidad — "corte/sudor").
- **Counterplay — guantes:** tener el ítem **`gloves`** en el inventario **bloquea las huellas**; pero el ADN aún puede caer (nunca estás 100% seguro). Decisión táctica: ir limpio y preparado, o rápido y arriesgado.
- **Escala con el heat:** un coche más "caliente" (super, recién robado, muchas piezas removidas) deja **más rastros**. Trabajar con prisas = más riesgo.
- **La policía recoge** con el kit de `evidences` y el script **identifica al autor** por la biometría — el criminal puede huir, pero la escena lo entrega.
- **Opcional y seguro:** si el resource `evidences` no está corriendo, la función **se auto-desactiva** sin afectar el desguace (`Config.Evidence.Enable` también la activa/desactiva).

---

## Instalación

1. **Base de datos**
   Ejecuta `sql/vp_chopshop.sql` (crea las 7 tablas: `vp_chopshop_benches`, `vp_chopshop_welders`, `vp_chop_vin_scratched`, `vp_chop_fence_trust`, `vp_chop_fence_orders`, `vp_chop_progression`, `vp_chop_fake_plates`). Las tablas también se crean/migran automáticamente al iniciar (idempotente).

2. **Ítems (ox_inventory)**
   Copia los bloques de `installation/ox_items_snippet.txt` en `ox_inventory/data/items.lua`. Ítems necesarios:

   | Ítem | Uso |
   |------|-----|
   | `chopshop_jackstand` | Gato — herramienta principal |
   | `chopshop_bench` | Mesa de trabajo para crafteo |
   | `chopshop_welder` | Soldadora (Fase 4) |
   | `metal_saw` | Sierra (Fase 2) |
   | `screwdriver` | Destornillador (Fase 3 + robo de placa) |
   | `chopshop_tyre` | Neumático robado |
   | `stolen_plate` | Placa física robada (metadata) |
   | `fake_plate` | Placa falsa forjada (usable — aplica el disfraz) |
   | `gloves` | Guantes — evitan dejar huellas (sistema de evidencias) |

3. **Servidor**
   Añade `ensure vp_chopshop` después de `ox_lib`, `ox_inventory`, `ox_target`, `oxmysql`.

   **Evidencias (opcional):** para la capa forense (sección 7), instala el resource [`evidences`](https://forum.cfx.re/t/free-evidence-script/5357633) y asegúrate de hacerle `ensure`. vp_chopshop solo **consume** su API (`exports.evidences:syncEvidence`) y **se auto-desactiva** si el resource no está presente — sin dependencia rígida. Se activa/desactiva en `Config.Evidence.Enable`.

   **Hook de garaje (necesario para la placa falsa en coche propio):** para que el garaje nunca guarde la placa falsa, añade en el punto donde captura los `props`/placa antes de guardar, ANTES del save:
   ```lua
   if GetResourceState('vp_chopshop') == 'started' then
       props = exports.vp_chopshop:GetRealPlateForProps(vehicle, props)
   end
   ```
   - **QBox (qbx_garages):** en `server/main.lua`, en el callback `qbx_garages:server:parkVehicle`, antes del `SaveVehicle` (bloque etiquetado `[vp_chopshop F3 garagem]`). ⚠️ Reaplícalo si actualizas qbx_garages.
   - **QBCore (qb-garages):** ver snippet en `installation/qb-garages-hook.md`.

4. **Permisos (ACE)**
   Para los comandos de administrador (`/choplifts`, `/chopremove`), añade:
   ```
   add_ace group.admin command.choplifts allow
   add_ace group.admin command.chopremove allow
   ```

5. **Framework**
   El bridge en `bridge/server_framework.lua` detecta automáticamente **QBox (`qbx_core`)**, **QBCore (`qb-core`)** o **ESX (`es_extended`)** por orden de prioridad. Se usa para `ServerPlayerIsReady`, job (gate policial de las placas), dinero y citizenid. *(El servidor LIVE es QBox; QBCore está soportado para portabilidad pero no probado en este entorno.)*

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
| `Config.Tools` | Configura herramientas individuales, su velocidad, durabilidad y probabilidad de avisar a la policía (`dispatchChance`) |
| `Config.Alarm` | Sistema de alarma vehicular — ver tabla abajo |
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

### Robo de placas y placas falsas (`Config.Plates`)

| Clave | Descripción |
|-------|-----------|
| `Enable` | Activa/desactiva toda la feature de placas |
| `MaxDistance` / `ApplyMaxDistance` | Distancia máx. (server-side) para robar / aplicar |
| `StealCooldownSeconds` | Cooldown anti-farm de robo por jugador |
| `SkillCheck` | Minijuego al arrancar la placa (`{ difficulties, keys }` de `lib.skillCheck`) |
| `ToolItem` | Ítem requerido para robar (por defecto `screwdriver`) |
| `ForgeTier` | Confianza mínima en el fence para forjar placa falsa (por defecto 2) |
| `ForgeInputs` | Insumos de la forja (ej.: `{ plastic = 2, aluminum = 1 }`) |
| `Persist` | Persistencia total del disfraz (se re-aplica en el spawn, sobrevive a un reinicio) |
| `BlockOnOwned` | (heredado, inerte — ahora permite cualquier coche vía hook de garaje) |
| `PoliceJobs` | Jobs que pueden quitar la placa falsa (ej.: `{ 'police','bcso','sheriff' }`) |
| `Witness` | Despacho por testigos: `{ Radius, NpcWeight, PlayerWeight, BaseChance, MaxChance, NightModifier, BonusMinScore, BonusXp, BonusCashMax }` |

### Rastros forenses / Evidencias (`Config.Evidence`)

Integración opcional con el resource `evidences`. Se auto-desactiva si no está corriendo.

| Clave | Descripción |
|-------|-----------|
| `Enable` | Activa/desactiva la capa forense |
| `GlovesItem` | Ítem que bloquea las huellas (por defecto `gloves`) |
| `GlovesBlocksDna` | Si es `true`, los guantes bloquean también el ADN (por defecto `false` — el ADN aún cae) |
| `DnaType` | Tipo de ADN dejado: `'blood'` o `'saliva'` |
| `HeatScaling` / `HeatFactor` | Más heat en la placa → más probabilidad de rastro (`chance × (1 + heat/100 × HeatFactor)`) |
| `Actions` | Probabilidad base (0..1) de **huella** y **ADN** por acción: `chop_part`, `vin_scratch`, `plate_steal`, `plate_forge`, `plate_apply` |

---

## Compatibilidad con frameworks

Este script **no depende de framework** para la lógica principal — el inventario es solo **ox_inventory**. El bridge en `bridge/server_framework.lua` detecta el framework automáticamente y lo usa para:

- `ServerPlayerIsReady` — saber si el jugador ya está cargado.
- `BridgeGetJob` / `BridgeIsPolice` — gate policial de la remoción de placa falsa.
- `BridgeGetCash` / `BridgeRemoveCash` / `BridgeAddCash` — tienda del NPC y bonos de las placas.

| Framework | Soporte |
|-----------|---------|
| QBox (`qbx_core`) | Completo — exports directos (`GetPlayer`, `AddMoney`, `job.name`) |
| QBCore (`qb-core`) | Soportado (portabilidad — `GetCoreObject`/`Functions.GetPlayer`); no probado en este entorno |
| ESX Legacy (`es_extended`) | Completo — usa `GetPlayerFromId`, `GetPlayers`, `xPlayer.job.name` |
| Ninguno | Funcional (tienda NPC y bonos en efectivo desactivados) |

**Llaves de vehículos:** usa `Config.VehicleKeys` para apuntar tu resource/export de llaves en ESX. Si prefieres desactivar la verificación, define `Config.RequireVehicleKeys = false`.

---

## Estructura de archivos

| Ruta | Función |
|---------|--------|
| `bridge/server_framework.lua` | Detección fw; `ServerPlayerIsReady`; `ServerChopPlayerKey`; dinero NPC |
| `bridge/server_inventory.lua` | Wrappers de ox_inventory (count/add/remove) |
| `bridge/client_notify.lua` | Notificaciones `lib.notify` |
| `bridge/evidence.lua` | Enlace forense con el resource `evidences` (`VPChopLeaveEvidence`) |
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
| `server/heat.lua` | Sistema de calor (VIN scratch, componentes MDT + piezas) |
| `server/plates.lua` | Robo de placa, forja/aplicación/remoción de placa falsa, persistencia + caché, despacho por testigos, export `GetRealPlateForProps` |
| `server/progression.lua` | XP y tiers (escucha event bus, persiste en `vp_chop_progression`) |
| `server/discord.lua` | Webhook Discord opcional |
| `server/main.lua` | Init, colocaciones, sync de mundo |
| `client/placement.lua` | Vista de modo colocación (raycast + preestreno) |
| `client/carry.lua` | Sistema de carga de piezas (`VPChopCarryingPart`) |
| `client/bench.lua` | Mesa y crafteo (client) |
| `client/welder.lua` | Soldadora (client) |
| `client/fence.lua` | Blip rotativo, targets NPC fence, carga de neumáticos |
| `client/alarm.lua` | Alarma vehicular: activación, skillcheck, dispatch |
| `client/plates.lua` | ox_target de robo/remoción de placa, skillcheck, score de testigos, export `useFakePlateItem`, sync de la placa visible |
| `client/progression.lua` | Texto flotante XP, notificación de tier |
| `client/main.lua` | Sistema gato hidr., Fases 1-4, sync, descarte |

---

## Versión

`1.11.0` — definida en `fxmanifest.lua`. Historial completo en [`CHANGELOG.md`](CHANGELOG.md).

> **v1.7.0–1.11.0:** auditoría (limpieza/seguridad/rendimiento), recompensa inmediata + emboscada,
> el **sistema completo de placas** (robo físico → forja → placa falsa que engaña al MDT,
> persistente y con reversión de garaje; despacho por testigos; soporte QBox/QBCore/ESX),
> y la **capa forense** (rastros de huella/ADN por acción, con guantes y escala por heat,
> mediante integración opcional con el resource `evidences`).
