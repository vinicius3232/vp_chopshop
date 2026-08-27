# v1.15 — SECURITY HOTFIX / P0 — Entrega

Branch: `security/v1.15-p0-hotfix` (base `92ded33`)
Patches: `docs/audit/patches/000{1,2,3}-*.patch`
Escopo: **somente P0-1..P0-4**. Nada de ChopSession/ActionSession/Bolt/Catalytic/etc.

## Commits

| SHA | Título | P0 | Arquivos |
|---|---|---|---|
| `7aee5a9` | close tyre grant + unify authenticated truck load | P0-1, P0-3 | server/fence.lua, server/main.lua, client/main.lua, client/fence.lua |
| `529bdc4` | validate truck entity/model/distance in sellTyres | P0-2 | server/fence.lua |
| `0ba8332` | discardVehicle mutex + payment-first ordering | P0-4 | server/main.lua |
| `e5c26d4` | acknowledge tyre load and lock truck sale (follow-up) | — | server/fence.lua, client/main.lua, client/fence.lua |

> **Follow-up `e5c26d4`** (revisão pré-GO ChopSession) — ver seção dedicada no fim do doc.

> P0-1 e P0-3 ficaram no mesmo commit porque são uma única mudança coesa: não dá para
> unificar o caminho de carga sem também eliminar a rota morta de concessão, e o novo
> crédito `PlayerTyreStock` serve os dois. Os outros dois P0 são commits isolados.

Diff total vs baseline: **4 arquivos, +153 / −118**. Nenhum mega-commit.

---

## P0-1 — Truck storage: dois handlers concorrentes, incremento sem lastro

### Fluxo/código anterior
- `client/main.lua` (carry de pneu → truck) dispara `vp_chopshop:server:addTyreToTruck`.
- `client/fence.lua` (bloco de carry morto) dispara `vp_chopshop:tyre:truckLoad`.
- **Dois handlers server** escrevem o mesmo `ServerTyreCounts[netId]`:
  - `server/main.lua:143` `addTyreToTruck` — `IsValidSource` + proximidade 8m + cap.
  - `server/fence.lua:282` `tyre:truckLoad` — `IsValidSource` + rate-limit 3s + proximidade 8m + cap.
- **Nenhum dos dois consome item ou crédito.**

### Exploit
Lua executor perto de qualquer entidade cujo `netId` corresponda a um veículo:
`TriggerServerEvent('vp_chopshop:server:addTyreToTruck', truckNetId)` em loop (respeitando 8m,
sem rate-limit no handler de main.lua) → `ServerTyreCounts` sobe até `MaxTyresInTruck` sem
nenhum pneu ter sido removido → `sellTyres('truck', …)` → cash. Repetível por truck.

### Correção (`7aee5a9`)
- **Handler único** `vp_chopshop:tyre:loadToTruck` (server/fence.lua). Os dois antigos removidos.
- **Crédito server-authoritative** `PlayerTyreStock[src]`: `AddEventHandler(VPChopEvt.PART_CHOPPED)`
  credita +1 quando `ChopParts[partKey].kind == 'tyre'`. `PART_CHOPPED` só é emitido por
  `server/main.lua` **após** `VPChopServerTryPart` retornar ok (que já é single-use por
  `netId:partKey` via `ChoppedByNetId` + mutex `ChopInProgress`, e exige ferramenta + proximidade).
- `loadToTruck` **consome 1 crédito** (`< 1` → `LogSuspicious` + deny), valida entidade +
  **modelo** (`Config.TyreSelling.PickupTruckModels` via `GetHashKey`, novo) + proximidade 8m +
  capacidade, com **mutex por jogador** (`TruckLoadBusy`) + rate-limit 1.5s.
- Cap do crédito: `Config.TyreSelling.MaxPlayerTyreStock` (default 12).
- Cliente: 2 call sites em `client/main.lua` repontados. Bloco morto de `client/fence.lua`
  repontado + comentado (remoção completa fica p/ commit `chore:`).

### Call sites verificados
| Evento | Emissores (antes) | Situação |
|---|---|---|
| `vp_chopshop:tyres:jackstandTyreStolen` | **nenhum** (grep client+server) | dead → removido |
| `vp_chopshop:server:addTyreToTruck` | `client/main.lua:1519, 1561` | → `loadToTruck` |
| `vp_chopshop:tyre:truckLoad` | `client/fence.lua:584, 619` (funções `VPChopLoadTyreInTruck*`, **sem caller externo** — grep) | → `loadToTruck` (bloco morto) |
| `vp_chopshop:chopPart` (wheel_*) | `client/main.lua:996` (`doJackstandTyreSteal`), `client/main.lua:388` (menu) | inalterado; agora credita stock |

Nenhum fluxo legítimo órfão. O jogador continua: jack → minigame de parafuso → `chopPart(wheel_x)`
→ carrega prop → `loadToTruck` (consome crédito) → `sellTyres`.

---

## P0-2 — sellTyres: validação e ordem transacional

### Código anterior (`server/fence.lua:439`)
Ramo `truck`: só `DoesEntityExist(truck)`. **Zerava `ServerTyreCounts[nid]` ANTES** de pagar.
`BridgeAddCash` — retorno ignorado nos dois ramos.

### Exploit / falha
- Vender lendo contador de um truck remoto/alheio (sem checar distância nem modelo).
- Se `AddMoney` falha (conta cheia, framework, DB): contador já zerado / `chopshop_tyre` já
  removido → jogador perde os pneus sem receber.

### Correção (`529bdc4`)
- Ramo truck: exige **modelo pickup** (`isPickupTruckModel`) + **proximidade 8m ao truck**
  (`ValidatePlayerNearVehicle`), além da proximidade ao fence já existente.
- **Pagar antes de zerar**: `if not BridgeAddCash(...) then return release({err='payment'}) end`;
  só então `ServerTyreCounts[nid] = nil` + state bag.
- Ramo inventário: `RemoveItem` → `BridgeAddCash`; se falhar, **`AddItem` de volta** (compensação)
  + log.
- Mutex `SellTyresBusy` (já existia) preservado.

---

## P0-3 — jackstandTyreStolen: concessão direta sem prova de roda

### Código anterior (`server/fence.lua:228`)
`RegisterNetEvent('vp_chopshop:tyres:jackstandTyreStolen')` → `ox_inventory:AddItem(src, chopshop_tyre, 1)`
com rate-limit 5s + proximidade 8m + cap `JackstandTyreCount[netId] < 4`.

### Exploit
`TriggerServerEvent('vp_chopshop:tyres:jackstandTyreStolen', anyVehicleNetId)` → 1 `chopshop_tyre`
a cada 5s, 4 por netId, ilimitado no nº de veículos. Nenhuma prova de que uma roda foi desmontada.

### Correção (`7aee5a9`)
Handler **removido inteiro** (+ tabelas `JackstandStealCooldown`, `JackstandTyreCount`, +
2 limpezas em `playerDropped`). É **dead code** — o fluxo real de roubo de roda migrou para
`vp_chopshop:chopPart` na v1.14 (confirmado: zero `TriggerServerEvent`/`TriggerEvent` com esse
nome em todo o repo). A rota legítima de pneu passa a ser **exclusivamente** chopPart→crédito
(ver P0-1). Funcionalidade preservada.

---

## P0-4 — discardVehicle: sem mutex + ordem transacional

### Código anterior (`server/main.lua:473`)
Sem mutex. `BridgeAddCash(...)` (retorno ignorado) → `VPChopClearVehicle` → `DeleteEntity`.

### Exploit
Dois `lib.callback.await('vp_chopshop:discardVehicle', netId)` concorrentes (mesmo jogador via
executor, ou dois jogadores no mesmo carro): ambos passam `partCount >= minParts`, ambos
`BridgeAddCash` antes do `VPChopClearVehicle` → **double payout** (`deliverCar` tinha mutex;
`discardVehicle` não).

### Correção (`0ba8332`)
- **Mutex `DiscardBusy[netId]`** (por netId — o alvo do exploit é o mesmo veículo). Segunda
  chamada concorrente → `err='processing'` **antes de qualquer pagamento** (ponto 9 da revisão).
- **Ordem transacional**: validar → `BridgeAddCash`; se falhar → `err='payment'`, veículo
  **permanece** (nada perdido). Só no sucesso: `VPChopClearVehicle` + `AlarmActive` nil +
  `CAR_DISCARDED` + `DeleteEntity` (guardado por `DoesEntityExist`).
- Handler `entityRemoved` limpa `DiscardBusy[netId]` órfão (defesa contra edição futura que
  introduza yield; hoje o callback é yield-free e sempre libera).

---

## Testes executados

> **Sem servidor FiveM disponível neste ambiente.** Os testes abaixo são: (a) `luac -p`
> (Lua 5.4) em cada arquivo **e em cada commit** individualmente; (b) trace estático de
> caminho de exploit/regressão contra o código final; (c) revisão adversarial via OmniRoute
> (`challenge`, claude-sonnet-4.5). **Testes funcionais/multiplayer/performance em servidor
> real permanecem PENDENTES e são pré-requisito do GATE v1.15.**

### Sintaxe
| Commit | server/fence.lua | server/main.lua | client/main.lua |
|---|---|---|---|
| 7aee5a9 | ✅ | ✅ | ✅ |
| 529bdc4 | ✅ | ✅ | ✅ |
| 0ba8332 | ✅ | ✅ | ✅ |

(`client/fence.lua` usa hash-literal backtick — não validável por `luac` padrão; mudanças ali são
2 renomes de string + 1 comentário.)

### Exploit trace (esperado: DENY)
| # | Cenário | Resultado (trace) |
|---|---|---|
| E1 | `TriggerServerEvent('vp_chopshop:tyres:jackstandTyreStolen', x)` | **evento inexistente** — nenhum handler. DENY ✅ |
| E2 | `loadToTruck` sem nunca ter feito chopPart de roda | `PlayerTyreStock[src] < 1` → LogSuspicious + return. DENY ✅ |
| E3 | `loadToTruck` spam (10×/s) com 1 crédito | mutex + rate-limit 1.5s + `stock -= 1` na 1ª → 2ª vê stock 0. Máx +1. DENY ✅ |
| E4 | `loadToTruck` num `netId` que não é truck | `isPickupTruckModel` false → LogSuspicious + return. DENY ✅ |
| E5 | `loadToTruck` num truck a 200m | `ValidatePlayerNearVehicle(…,8.0)` false → return. DENY ✅ |
| E6 | `sellTyres('truck', truckRemoto)` | proximidade 8m ao truck → return `truck_range`. DENY ✅ |
| E7 | `sellTyres('truck', carroComumComStateBagForjado)` | lê `ServerTyreCounts` (server), não state bag; + `isPickupTruckModel`. DENY ✅ |
| E8 | 2× `discardVehicle(mesmo netId)` concorrente | `DiscardBusy[netId]` → 2ª = `processing` antes do pagamento. Máx 1 payout ✅ |
| E9 | `discardVehicle` com `AddMoney` falhando | `err='payment'`, veículo intacto, sem clear. ✅ |
| E10 | Crédito inflado: chopPart 2× na mesma roda | `WasChopped(netId,partKey)` + mutex `ChopInProgress` → 2ª = `done`. Sem crédito extra ✅ |
| E11 | 2 jogadores, rodas diferentes do mesmo carro | pKey distinto → ambos ok → +1 cada → cada um carrega o próprio pneu (correto, não é dupe) ✅ |

### Regressão (trace)
| # | Fluxo | Resultado |
|---|---|---|
| R1 | Jack → 4× (parafuso+chopPart wheel) → carregar 4 no truck → sellTyres | crédito 4 → 4 loads consomem → `ServerTyreCounts=4` → venda paga 4. ✅ |
| R2 | Vender `chopshop_tyre` do inventário (config manual do item) | ramo inventário: Remove → pay → (falha? refund). ✅ |
| R3 | discard normal (≥ minParts, cops bonus) | mutex → pay → clear → delete. Payout idêntico ao anterior. ✅ |
| R4 | Fence sellItems, deliverCar, orders, plates, serial, heat, tyremarks | **não tocados** por este hotfix. ✅ (regressão formal pendente em servidor) |

### Concorrência
- `loadToTruck`: mutex `TruckLoadBusy[src]` + decremento de stock atômico (sem yield entre
  check e `-= 1`). 2 disparos → 1 consumo. ✅
- `discardVehicle`: mutex `DiscardBusy[netId]`, callback yield-free. ✅
- `sellTyres`: mutex `SellTyresBusy[src]` (pré-existente). ✅

---

## Revisão adversarial (OmniRoute `challenge`)

6 pontos levantados; triagem:

| # | Ponto | Veredito |
|---|---|---|
| 1 | `DiscardBusy` leak no disconnect (playerDropped é por src) | **Aceito parcialmente.** Callback é yield-free → sem leak real hoje; ainda assim adicionado `entityRemoved` cleanup como defesa. |
| 2 | Crédito sem checar `phase` | **Improcedente.** `PART_CHOPPED` só é emitido pós-sucesso (grep dos emissores); `phase` é o número da fase (1), não status. |
| 3 | Race 2 jogadores / rodas diferentes | **Improcedente.** pKey distinto = 2 rodas reais removidas = 2 créditos legítimos. Mesma roda → `WasChopped` bloqueia. |
| 4 | sellTyres limpa antes de pagar | **Retirado pelo próprio revisor** — `return release()` no erro previne o clear. |
| 5 | Repontar código morto é suspeito | **Aceito como observação.** Confirmado sem caller (globals Lua são por-resource). Remoção completa = commit `chore:` no follow-up. |
| 6 | `PlayerTyreStock` não persiste entre sessões | **Aceito como limitação conhecida** (abaixo). |

---

## Regressões encontradas
Nenhuma no trace estático. Pendente confirmação em servidor real (functional + 2–4 players).

## Limitações conhecidas introduzidas
- **`PlayerTyreStock` é in-memory, limpo no disconnect.** Jogador que remove rodas e cai
  antes de carregar perde o crédito (as rodas do carro continuam removidas — trabalho perdido).
  Aceitável para hotfix; ChopSession transformará isso em entitlement da sessão.
- **Bloco morto em `client/fence.lua`** (`VPChopSpawnTyreProp`/`VPChopPickUpTyre`/
  `VPChopLoadTyreInTruck*`) repontado, não removido. Follow-up `chore:`.
- `Config.TyreSelling.MaxPlayerTyreStock` é uma chave nova não documentada no config exemplo
  (default 12 se ausente — sem breaking change).

## P0 ainda existentes
**Nenhum dos 4.** P0-1..P0-4 fechados no trace estático.
(P1/P2 do audit permanecem abertos por design — fora do escopo deste hotfix.)

---

## Decisão GO / NO-GO — iniciar ChopSession

**Recomendação: GO condicional.**

Os 4 P0 estão fechados na análise estática e na revisão adversarial. O que falta antes de
"GO pleno" é **execução em servidor** (não disponível aqui):
1. Teste funcional QBox: fluxo completo tyre + discard.
2. Teste 2 jogadores: E8, E11, load concorrente.
3. Regressão R4 (Fence/plates/serial/heat/tyremarks) — não tocados, mas confirmar.
4. `resmon` antes/depois (mudança é event-driven, sem thread nova — risco baixo).

**Sugestão:** o revisor humano aplica os 3 patches num servidor de teste, roda os itens
1–4 acima, e só então dá GO para ChopSession. Se algum falhar, é fix pontual dentro deste
mesmo hotfix — não desbloqueia a próxima fase (regra 136).

---

# Follow-up `e5c26d4` — acknowledge tyre load + lock truck sale

Ajuste de consistência pedido na review pré-GO ChopSession. **Não fecha novo P0**
(os 4 seguem fechados); endereça 2 itens de robustez do fluxo de pneu.
Diff: 3 arquivos, +85 / −40. `server/fence.lua`, `client/main.lua`, `client/fence.lua`.

## Mudança do contrato client ↔ server

`vp_chopshop:tyre:loadToTruck` passa de **`RegisterNetEvent` (fire-and-forget)** para
**`lib.callback.register` (request/response)**.

| | Antes (`7aee5a9`) | Agora (`e5c26d4`) |
|---|---|---|
| Client dispara | `TriggerServerEvent(evt, truckNetId)` | `lib.callback.await(evt, false, truckNetId)` |
| Client remove prop / encerra carry | **imediatamente**, sem esperar | **só se `res.ok == true`** |
| Notificação de sucesso | `L('tyre_stored_fmt', cur+1, max)` — **`cur+1` calculado no client** | `L('tyre_stored_fmt', res.count, res.max)` — **`count` vem do servidor** |
| Deny (cooldown / sem stock / truck inválido / cheio / lock) | client não sabia — fingia armazenamento local | prop **permanece**, carry **mantido**, notifica erro via `VPChopTyreLoadErr(err)` |

**Retorno do servidor:**
```
ok   → { ok = true,  count = <ServerTyreCounts pós-incremento>, max = <MaxTyresInTruck> }
deny → { ok = false, err = 'cooldown' | 'no_stock' | 'no_truck' | 'bad_truck'
                          | 'range' | 'truck_busy' | 'truck_full'
                          | 'processing' | 'net' | 'disabled' }
```

`VPChopTyreLoadErr(err)` (novo, `client/main.lua`) mapeia para chaves de locale **já
existentes** (`tyre_truck_full`, `tyre_no_truck_nearby`, `err_cooldown`,
`notify_generic_error`) — `shared/locale.lua` **não foi tocado**.

Call sites migrados para `lib.callback.await`: 2 vivos (`client/main.lua` — ground-prop
target e menu `[G]`), 2 mortos (`client/fence.lua` `VPChopLoadTyreInTruck*` — mantidos
contract-correct; remoção total continua sendo `chore:` futuro).

## Comportamento em DENY (novo)
1. Servidor valida; se falhar retorna `{ ok=false, err=... }`.
2. Client: `if not cbOk or not res or not res.ok then VPChopNotify(VPChopTyreLoadErr(res and res.err),'error'); return end`.
3. **O prop NÃO é deletado. O carry NÃO é encerrado.** O jogador pode tentar de novo.
4. `PlayerTyreStock` **não é consumido** (o decremento só ocorre após todas as validações, na seção síncrona final).

## Comportamento em SUCESSO
1. Servidor: valida → adquire `TruckStorageBusy[netId]` → `PlayerTyreStock[src] -= 1` →
   `ServerTyreCounts[netId] = cur+1` → `Entity(truck).state:set('chopTyreCount', newCount, true)` (broadcast) → libera locks → retorna `{ ok=true, count=newCount, max }`.
2. Client: remove o ox_target + `DeleteEntity(handProp)` (ou `VPChopDropCarryPart()`) e
   notifica `tyre_stored_fmt` com o **`count` do servidor**.

## Lock por truck — `TruckStorageBusy[netId]`

Adicionado ao lado do `SellTyresBusy[src]` (por jogador) já existente. **Não substitui**
o lock por jogador — os dois coexistem.

| Operação | Locks adquiridos | Release |
|---|---|---|
| `loadToTruck` | `TruckLoadBusy[src]` → (após validações) `TruckStorageBusy[netId]` | `releaseAll()` em todo return pós-acquire; `release()` (só player) nos returns anteriores |
| `sellTyres` (truck) | `SellTyresBusy[src]` → (no ramo truck) `TruckStorageBusy[netId]` | `releaseTruck()` encadeia `release()`; libera ambos em **todos** os returns do ramo |
| `sellTyres` (inventário) | `SellTyresBusy[src]` | `release()` |

- `loadToTruck` recusa `truck_busy` enquanto uma venda do mesmo `netId` corre (e vice-versa).
- Nenhum `return` pós-acquire pula o release (auditado — ver testes T-lock abaixo).
- `entityRemoved` limpa `ServerTyreCounts[netId]` **e** `TruckStorageBusy[netId]`.
- Nenhuma das seções críticas (read→write de `ServerTyreCounts`, `BridgeAddCash`→clear)
  contém `yield` hoje; os locks são a garantia caso uma validação futura passe a ceder
  (princípio do item 9 da review).

## Testes estáticos adicionais (trace)

| # | Cenário | Esperado | Resultado |
|---|---|---|---|
| T1 | Servidor rejeita `loadToTruck` (qualquer err) | prop continua com o jogador | `res.ok=false` → `return` antes de `DeleteEntity`/`DropCarryPart` ✅ |
| T2 | Truck cheio (`cur >= max`) | `err='truck_full'`; pneu continua; **stock não consumido** | check `cur>=maxTyres` ocorre **antes** de `PlayerTyreStock -= 1` ✅ |
| T3 | Sem crédito (`stock < 1`) | DENY; carry continua | `err='no_stock'` antes de tocar truck/stock ✅ |
| T4 | 2 jogadores `sellTyres` no MESMO truck | no máx **1** pagamento | A pega `TruckStorageBusy[nid]`; B → `truck_busy` **antes de `BridgeAddCash`** ✅ |
| T5 | 2 jogadores carregam pneus legítimos **diferentes** no mesmo truck | cada um armazenado **exatamente 1×**, respeitando capacidade | serializado por `TruckStorageBusy[netId]`: B espera A liberar, relê `cur`, incrementa. `ServerTyreCounts` = soma correta; nenhum crédito perdido ✅ |
| T6 | Resposta de sucesso | client usa `res.count` do servidor, não calcula | `tyre_stored_fmt(res.count, res.max or max)` ✅ |
| T-lock-1 | `loadToTruck` — todo return pós-`TruckStorageBusy[netId]=true` | libera o lock | só `releaseAll({truck_full})` e `releaseAll({ok})` ✅ |
| T-lock-2 | `sellTyres` ramo truck — todo return pós-`TruckStorageBusy[nid]=true` | libera **ambos** os locks | `releaseTruck()` em no_truck/bad_truck/truck_range/no_tyres/payment/ok ✅ |
| T-lock-3 | jogador cai no meio de `loadToTruck`/`sellTyres` | locks liberados | handlers são yield-free → sempre atingem o release; `playerDropped` limpa `TruckLoadBusy`/`SellTyresBusy`/stock; `entityRemoved` limpa `TruckStorageBusy` |

## Revisão adversarial (OmniRoute `challenge`)
6 vetores testados; 5 descartados pelo próprio revisor (locks liberam em todos os returns;
client não finge armazenamento local; 2º seller bloqueado antes do pagamento; caminho feliz
4-pneus OK; prop nunca deletado com `ok=false`). 1 apontamento — race de incremento entre
duas cargas concorrentes no mesmo truck — **endereçado** com `TruckStorageBusy[netId]` na
carga (não só na venda), embora o trecho seja síncrono hoje.

## Status pós follow-up
- P0-1 CLOSED · P0-2 CLOSED · P0-3 CLOSED · **P0-4 double-payout CLOSED**.
- ⚠️ **P1-4 NÃO fechado**: `discardVehicle` ainda usa `DeleteEntity` direto, sem
  `BridgeDeleteVehicle` nem guard de veículo owned/persistente. `discardVehicle` **não**
  está totalmente finalizado — isso entra na arquitetura seguinte.
- `PlayerTyreStock` continua sendo solução temporária: **prova apenas que o jogador
  removeu uma roda legítima; NÃO prova transporte físico do pneu.** A prova de transporte
  vira entitlement por `sessionId + partId` na ChopSession. Sem persistência/DB agora.

## GO
- **GO ARQUITETURAL para ChopSession** — sujeito a esta revisão estática passar.
- **GO DE RELEASE** permanece condicionado a: functional QBox + multiplayer (2–4) +
  regressão (Fence/plates/serial/heat/tyremarks) + `resmon` antes/depois, em servidor real.
