# EXTERNAL_RESEARCH_MATRIX

Auditoria real (clone + leitura de código) de 4 repositórios. Os outros 14 da KB ficam com nota de leitura superficial no fim — não justificam clone durante o freeze.

Clones em `../_ext/`. Datas de checagem: 2026-08-28.

---

## 1. renzuzu/renzu_projectcars — **REJECT (segurança) / STUDY (modelo de dados)**

- **Licença:** ausente (sem `LICENSE`, só README). ⇒ **não reutilizar nenhuma linha**; conceito apenas.
- **Framework:** ESX + QBCore, wrapper próprio. `@ox_lib`. Não é QBox-nativo.
- **Arquivo lido:** `server/server.lua` (789 linhas, não-escrow).

### Server authority — **ausente**
Todo mutador de estado é `RegisterNetEvent` sem `IsValidSource`, sem rate-limit, sem mutex:

| Evidência | Problema |
|---|---|
| `server/server.lua:38` `buyshell` | preço = `data.price * Config.PercentShellPrice` — **preço vem do client**. |
| `server/server.lua:170-175` `updateprojectcars` | `GlobalState.ProjectCars = data` — o client **sobrescreve o estado global inteiro do servidor**. |
| `server/server.lua:417-454` `updatechopcar` | client manda `data.plate`, `data.part`, `data.net`; servidor aplica sem validar posse nem proximidade. |
| `server/server.lua:126-168` `buyparts` | `item` e `info.model` vêm do client; metadata montada a partir disso. |
| `server/server.lua:561` `changestate` | client manda `props`, `plate`, `net`; `DELETE FROM owned_vehicles` + re-INSERT a partir de dados do client. |

**Isto é exatamente o modelo que o `vp_chopshop` abandonou.** Serve como caso-controle: confirma o valor de `ChopSession`/`ActionSession`/`IsValidSource` na 1ª linha.

### Modelo de peça — **item genérico + metadata (mesma direção do RFC Modelo A)**
- `server/server.lua:45-51` shell = item `vehicle_shell`, metadata `{ type, model, label, description }`.
- `server/server.lua:156-162` peça = item nomeado por tipo (`engine`, `door`, `bonnet`, `wheel`, `brake`, `transmition`, `exhaust`, `trunk`, `seat`) + metadata `{ type=model, model, label, description }`.
- Compatibilidade peça↔modelo: **não há checagem** — a metadata `model` é decorativa; o "build" é rastreado por um blob JSON `status` por placa (`server/server.lua:227-253`), decrementado quando uma peça é "instalada".
- **Insight para o RFC:** renzu mistoura os dois modelos (item-por-tipo **e** metadata de modelo). O RFC interno é mais limpo: 1 item `vehicle_part`, `partType` na metadata. Nada aqui contradiz o Modelo A; ao contrário, mostra o custo de não escolher (9 itens de inventário + imagens por tipo em `data/INVENTORY_IMAGE/`).

### Persistência / restart
- DB table `renzu_projectcars` (`status` JSON por placa) — sobrevive a restart.
- `GlobalState.ChopVehicles` / `GlobalState.ProjectCars` — **in-memory + statebag global**, reidratados no boot a partir do DB (`server/server.lua:30-36`) e de KVP (`:23-28`).
- Crash no meio de um build: a linha DB fica com `status` parcial; `GlobalState.ChopVehicles` (chop em progresso) **é perdido** e não é reconstruído. Mesmo tipo de perda que a ChopSession in-memory do `vp_chopshop` teria — mas sem tombstone nem idempotência, então re-chopar/duplicar é trivial aqui.

### Bugs de brinde observados (não afetam nós)
`server/server.lua:512-524` `GenerateGarageId` recursivo sem `return` na colisão → devolve `nil`. `math.randomseed(GetGameTimer())` a cada char em `GetRandomLetter`/`GetRandomNumber` → placas pouco aleatórias.

**Veredito:** REJECT como referência de arquitetura/segurança. STUDY só para confirmar que "item genérico + metadata" é padrão de mercado e que a explosão de itens-por-tipo tem custo real.

---

## 2. Qbox-project/qbx_core — `server/vehicle-persistence.lua` — **ADOPT AS FRAMEWORK AUTHORITY**

- **Licença:** GPL-3.0.
- **Arquivo lido:** `server/vehicle-persistence.lua` (295 linhas).

### Identidade de veículo
- `getVehicleId(vehicle)` = `Entity(vehicle).state.vehicleid` **e só depois** `exports.qbx_vehicles:GetVehicleIdByPlate(...)` como fallback (`:25-27`). Placa é lookup, nunca identidade. ⇒ confirma `BridgeResolveVehiclePersistence` do `vp_chopshop`.
- `Entity(veh).state:set('vehicleid', id, false)` (`:121`, `:220`) — **3º arg `false` = server-local, NÃO replicado**. `persisted`/`sessionId` usam `true` (replicado).

### Restart resilience — o padrão a copiar
| Gatilho | Ação | Linha |
|---|---|---|
| `onResourceStart` (`qbx_vehicles`) | reconstrói `cachedVehicles` do DB (`GetPlayerVehicles({states=0})`), pulando os que `isVehicleSpawned` já achou no `GetGamePool('CVehicle')` | `:234-246` |
| `onResourceStop` (`cache.resource`) | `saveAllVehicle()` — persiste posição/props de tudo que tem `state.persisted` | `:248-252` |
| `txAdmin:events:scheduledRestart` @ `secondsRemaining == 60` | `saveAllVehicle()` | `:254-258` |
| `entityRemoved` de entidade `persisted` | respawn imediato com props do DB | `:95-127` |

**O núcleo:** o qbx **nunca confia que memória/statebag sobrevive a restart**. Ele persiste em DB no stop + antes de restart programado, e **reconcilia contra `GetGamePool` no start**. Startup reconciliation não é opcional no design deles.

### Concorrência
`vehicleSpawnQueue` + `isProcessingQueue` (`:196-228`) — fila de 1 thread, `isVehicleSpawned` checado antes de cada spawn para não duplicar. `spawnVehicle` (evento de rede `:260`) revalida `cachedCoords` contra o que o client mandou antes de agir.

**Veredito:** ADOPT. É a referência primária para o [RESTART_RECOVERY_STUDY](RESTART_RECOVERY_STUDY.md). GPL-3.0 permite reuso mas o `vp_chopshop` deve reimplementar o padrão, não colar o arquivo (questão de licença de distribuição — ver §13 da KB).

---

## 3. Qbox-project/qbx_vehicles — `server/main.lua` — **ADOPT (identidade canônica)**

- **Licença:** GPL-3.0. **Arquivo lido:** `server/main.lua` (298 linhas).

- `player_vehicles` com `id` PK, `citizenid`, `plate`, `state` enum (`OUT=0/GARAGED=1/IMPOUNDED=2`), `mods` (JSON props), `coords`. `id` é a identidade canônica; `getVehicleIdByPlate` (`:209-213`) é lookup.
- `saveVehicle(vehicle, options)` (`:284`): resolve `Entity(vehicle).state.vehicleid or getVehicleIdByPlate(...)`; se nenhum → `return false, {code='not_owned'}`. **Fail-closed exatamente como o `deliverCar`/`discard` do `vp_chopshop`.**
- 100% SQL parametrizado; `buildWhereClause` monta `state = ? OR state = ?` só com placeholders (`:65-78`).
- `triggerEventHooks('createPlayerVehicle', ...)` / `'changeVehicleOwner'` (`:151`, `:176`) — pontos de cancelamento para outros resources. Padrão de seam que o `vp_chopshop` já faz via `VPChopEvt`.

**Veredito:** ADOPT. `vehicleid` do qbx_vehicles = fonte de verdade preferida; placa = fallback. Já é o que o projeto faz.

---

## 4. communityox/ox_inventory — metadata / stack — **ADOPT**

- **Licença:** GPL-3.0. **Arquivos lidos:** `README.md`, `modules/items/server.lua` (grep dirigido).

- README:1 "*items are stored per-slot, with customisable metadata to support item uniqueness*".
- `Items.Metadata(inv, item, metadata, count)` (`modules/items/server.lua:169`): metadata string vira `{type=metadata}` (`:171`); `serial` gerado server-side para armas registradas (`:187` `GenerateSerial`); `durability`/`degrade` em `setItemDurability` (`:148-158`).
- `if count > 1 and not item.stack then` (`:220`) — stack só quando `item.stack` **e** metadata compatível. `item.stack = item.stackable == nil and true or item.stackable` (`:68`).

**Confirma o desenho do RFC:** `vehicle_part` genérico com metadata `{partType, serial, state, sourceModel, sourceSession}` empilha só com metadata idêntica → "1 stack por (veículo, partType, state)" (RFC C.1) é o comportamento nativo, sem código extra. `car_parts state='processed'` com `serial=nil, sourceModel=nil` empilha como commodity homogêneo — também nativo.

**Veredito:** ADOPT. Criar dezenas de itens (Modelo B) contraria o design do próprio inventário.

---

## 5. Os 14 restantes — leitura superficial (sem clone)

| Repo | Nota | Veredito |
|---|---|---|
| stevoscriptsteam/stevo_chopshop | "continua após crash" no README não é provado; auditar só se/quando restart persistence virar feature | STUDY (adiado) |
| metascripts-ux/meta_chopshop | confirma `veículo→peça física→material`; usa item-por-tipo (`vehicledoor_lf`…) = Modelo B, que renzu mostra ser custoso | ADOPT CONCEITO / REJECT explosão de itens |
| MrZainRP/mz-scrap | separação tipo-de-peça × ferramenta × qualidade; alimenta Tool Registry futuro | STUDY (pós-#17) |
| jimathy/jim-recycle | economia de salvage/material; referência para não deixar o chop ser a única fonte de material | STUDY economia |
| qbcore-framework/qb-scrapyard | usa placa como lookup de ownership | REJECT baseline de segurança |
| Giana/qb-Lenzh_chopshop | linhagem histórica ESX→QB | REFERENCE only |
| cadburry6969/cad-chopshop | bridges multi-inventory; loops de contrato/missão | STUDY produto |
| Qbox-project/qbx_garages | fluxo `entity→vehicleid→GetVehicleIdByPlate→ownership→SaveVehicle→DeleteVehicle` | ADOPT pattern (já seguido) |
| Qbox-project/qbx_vehicleshop | operação econômica começa pela identidade persistida, não pelo input do client | ADOPT princípio (já seguido) |
| CommunityOx/docs | doc do `MySQL.transaction.await` — unidade atômica multi-query | ADOPT quando houver múltiplos registros persistentes (ProcessSession não tem hoje) |
| DaemonAlex/dps-vehiclepersistence | "startup reconciliation" explícito | STUDY — mesma lição que qbx_core já dá |
| seeseal/qb-reservedgarage | server-authoritative spawn + fallback impound + proteção disconnect | STUDY recovery |
| renzuzu/renzu_engine | engine como item + statebag + OneSync | STUDY integração oficina (pós-#17) |
| Annalouu/an-engineswap | engine swap com mechanic zones | STUDY integração oficina (pós-#17) |
| renzuzu/renzu_tuners | mileage/degradation/quality tiers | DEFER (pós primeiro PhysicalPart) |
