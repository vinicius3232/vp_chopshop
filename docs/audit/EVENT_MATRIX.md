# vp_chopshop — EVENT MATRIX (HEAD 92ded33)

Legenda efeito: 💰=mexe em cash · 📦=mexe em item · ⭐=XP · 🚗=altera veículo · 🗄=DB · ⚠️=chamável direto pelo cliente sem gate de sessão

## Callbacks (`lib.callback.register`) — resposta ao cliente

| Evento | Arquivo:linha | Params (client) | Validações | Efeito | Risco |
|---|---|---|---|---|---|
| `vp_chopshop:getWorld` | main.lua:202 | — | IsValidSource | leitura | P3 |
| `vp_chopshop:placeBench` | main.lua:212 | payload{x,y,z,heading} | ready, ValidateMapCoords, ValidatePlacementRange, InvCount+InvRemove, rollback DB | 📦🗄 | P3 |
| `vp_chopshop:chopPart` | main.lua:287 | netId, partKey | ready, rate-limit 2s, partKey len 3–32, cooldown, `VPChopHasTool`, proximidade, mutex `netId:partKey`, `WasChopped` | 📦⭐🚗🗄 | **P1-5** sem ActionSession/minigame proof |
| `vp_chopshop:benchCraft` | main.lua:446 | benchId, recipeIndex | ready, rate-limit, `BenchCraftBusy` mutex, welder perto | 📦 | P2 |
| `vp_chopshop:discardVehicle` | main.lua:473 | netId | ready, proximidade, `partCount>=minParts` | 💰🚗(DeleteEntity) | **P0-4** sem mutex · **P1-4** DeleteEntity direto |
| `vp_chopshop:npcAcceptMission` | main.lua:530 | — | IsValidSource | estado missão | P3 |
| `vp_chopshop:pickupBench` / `placeWelder` / `pickupWelder` | main.lua:538/560/589 | id/payload | ready, proximidade, InvCount | 📦🗄 | P3 |
| `vp_chopshop:adv:chopPart` | advanced_chop.lua:115 | netId, partKey | ready, cooldown 3s, partKey len, `isChopped`, `partDef.kind=='door'`, proximidade 6m, mutex, `consumeSaw` | 📦⭐🚗 | **P1-1** não checa RAISED · **P1-5** |
| `vp_chopshop:adv:chopEngine` | advanced_chop.lua:194 | netId | ready, cooldown, `isChopped('bonnet')`, `isChopped('adv_engine')`, proximidade, `VPChopHasTool(drill)`, mutex, consumeTool | 📦⭐🚗 | **P1-1 / P1-5** |
| `vp_chopshop:adv:chopCarcass` | advanced_chop.lua:254 | netId | ready, cooldown, `isChopped('adv_engine')`, proximidade 8m, welder perto server-side, mutex | 📦⭐🚗 | **P1-1 / P1-5** |
| `vp_chopshop:fence:introduce` | fence.lua:315 | — | IsValidSource, trust==0, RemoveItem `fence_referral`, pcall saveTrust + refund | 📦🗄 | P3 (refund checado) |
| `vp_chopshop:fence:sellItems` | fence.lua:363 | itemList[] | IsValidSource, rate-limit 3s, trust>=1, proximidade fence 5m, `#list<=50`, dry-run + paga só removido | 💰📦⭐ | **P1-3** `BridgeAddCash` retorno ignorado |
| `vp_chopshop:fence:sellTyres` | fence.lua:439 | source_type, truckNetId | IsValidSource, `SellTyresBusy` mutex, tipo válido, trust>=1, proximidade **fence** 5m, truck `DoesEntityExist` | 💰⭐ | **P0-2** sem distância/modelo do truck; limpa contador antes do pagamento; retorno ignorado |
| `vp_chopshop:fence:deliverCar` | fence.lua:501 | netId | IsValidSource, trust>=4, tier>=4, `DeliveryBusy` mutex, cooldown no MySQL, proximidade 6m | 💰🚗🗄 | P1-3 retorno ignorado (mutex OK) |
| `vp_chopshop:fence:getTrust` / `getOrder` / `getProgression` | fence.lua:578/613, progression.lua:159 | — | IsValidSource | leitura | P3 |
| `vp_chopshop:fence:buyBench` | fence.lua:586 | — | IsValidSource | 💰📦 | P2 (revisar retorno) |
| `vp_chopshop:fence:fulfillOrder` | fence.lua:659 | orderId | — (revisar) | 💰📦⭐🗄 | P1 (auditar: valida itens?) |
| `vp_chopshop:vinScratch` | heat.lua:127 | netId | IsValidSource, cooldown 3s, proximidade, RemoveItem `vin_kit` | 📦⭐🚗🗄 | P2 |
| `vp_chopshop:serial:scratch` | partserial.lua:167 | — | IsValidSource, ready, cooldown, bench perto | 📦🗄 | P2 |
| `vp_chopshop:serial:forge` | partserial.lua:205 | — | IsValidSource, ready, cooldown, bench perto | 📦🗄 | P2 |
| `vp_chopshop:serial:benchAvailability` | partserial.lua:262 | — | IsValidSource | leitura | P3 |
| `vp_chopshop:serial:buyLegal` | partserial.lua:336 | — | IsValidSource, ready, proximidade 4m, `BridgeRemoveCash` antes, refund se AddItem falha | 💰📦 | P3 (transacional OK) |
| `vp_chopshop:inspectParts` | partserial.lua:408 | targetServerId | IsValidSource(2×), ready, cooldown 2s | leitura de outro player | P2 (valida target próximo?) |
| `vp_chopshop:stealPlate` | plates.lua:145 | netId, **witnessScore** | IsValidSource, ready, cooldown, `PlateStolen[netId]`, proximidade, placa real server-side, InvCount tool, refund | 📦⭐🚗🗄 | **P1-2** confia witnessScore |
| `vp_chopshop:forgeFakePlate` / `applyFakePlate` / `removeFakePlate` | plates.lua:300/418/529 | sourcePlate / netId | cooldowns, proximidade (auditar profundamente) | 📦🚗🗄 | P1 (auditar dupe de placa) |
| `vp_chopshop:isFakePlated` / `getVisibleFakePlate` | plates.lua:572/586 | netId | IsValidSource | leitura | P3 |
| `vp_chopshop:examineTyreMark` | tyremarks.lua:160 | markId | TM.Enable, IsValidSource | leitura | P3 |

## Net events (`RegisterNetEvent`) — sem resposta, fire-and-forget

| Evento | Arquivo:linha | Params | Validações | Efeito | Risco |
|---|---|---|---|---|---|
| `vp_chopshop:tyres:jackstandTyreStolen` | fence.lua:228 | netId | IsValidSource, rate-limit 5s, proximidade 8m, `JackstandTyreCount[netId]<4`, só conta se AddItem ok | 📦 | **P0-3** sem prova de roda desmontada |
| `vp_chopshop:tyre:truckLoad` | fence.lua:282 | netId | IsValidSource, rate-limit 3s, proximidade 8m, cap `MaxTyresInTruck` | 🚗(state bag) | **P0-1** incremento sem consumir item |
| `vp_chopshop:server:addTyreToTruck` | main.lua:143 | netId | IsValidSource, proximidade 8m, cap | 🚗(state bag) | **P0-1** 2ª impl concorrente do mesmo contador |
| `vp_chopshop:server:alarmDisarmed` | main.lua:162 | netId | IsValidSource, rate-limit, `AlarmActive[netId].src==src`, InvCount `screwdriver` | estado alarme | P3 (OK) |
| `vp_chopshop:createTyreMark` | tyremarks.lua:79 | netId, coords | IsValidSource, cooldown 1.5s, (janela armada?) | 🗄 marca | P2 (coords do cliente — valida contra veículo?) |
| `vp_chopshop:requestTyreMarks` | tyremarks.lua:135 | — | TM.Enable, IsValidSource | leitura | P3 |
| `vp_chopshop:server:spawnFenceNpc` / `despawnFenceNpc` | fence.lua:181/201 | loc | **interno** (TriggerEvent local) mas `RegisterNetEvent`-adjacent — confirmar que não é net-exposto | spawn | P2 confirmar |

## Event bus interno (`VPChopEvt.*` via TriggerEvent) — não exposto à rede

| Evento | Emissores | Ouvintes |
|---|---|---|
| `PART_CHOPPED` | chop/advanced_chop/plates/heat | progression.lua:119, heat.lua:15 (ambos fazem SQL — N5) |
| `CAR_DISCARDED` | main.lua:522 | progression.lua:134 |
| `FENCE_DELIVERY` | fence.lua (sellItems/sellTyres/deliverCar/orders) | progression.lua:138 |
| `HEAT_CHANGED` | heat.lua | bridge/mdt.lua:68 |

## Exports

| Export | Arquivo | Nota |
|---|---|---|
| `IssueLegalParts(src, amount, source)` | partserial.lua:326 | interno; checa IsValidSource + ready |
| `GetRealPlateForProps(veh, props)` | plates.lua:697 | leitura |

## Ações prioritárias derivadas

1. Unificar `truckLoad` + `addTyreToTruck` → **1** API que **consome** entitlement da ChopSession (P0-1).
2. `sellTyres` truck-branch: exigir proximidade + modelo do truck; pagar via `Transaction` antes de limpar contador (P0-2).
3. Remover `jackstandTyreStolen`; pneu só via `completeAction` de roda (P0-3).
4. `discardVehicle`: mutex + `BridgeDeleteVehicle` + guard owned (P0-4).
5. `chopPart` / `adv:*` / `stealPlate` / `sellTyres` → ActionSession com `minimumActionDuration` e nonce single-use (P1-5).
