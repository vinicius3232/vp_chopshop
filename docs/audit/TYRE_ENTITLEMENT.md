# Tyre Entitlement / Physical Logistics (v1.15 PR-E)

Elimina o workaround `PlayerTyreStock[src]` (contador genérico — só provava "removeu
ALGUMA roda"). Agora: **cada roda real removida → um entitlement single-use** que
segue por transporte físico específico.

**NÃO é ActionSession.** Não prova prop carregado honestamente, animação ou minigame.
Autoridade = PEÇA COMMITTED + SINGLE-USE + OWNER + STORAGE + LIFECYCLE.

## Arquivos

| Arquivo | Papel |
|---|---|
| `server/logistics/tyre_entitlement.lua` | `TyreEntitlement` — ledger de entitlement (independente da ChopSession) |
| `server/logistics/truck_storage.lua` | `TruckStorage` — caçamba do truck com identidade própria |
| `server/logistics/tyre_entitlement_spec.lua` | self-test E1–E28 + E20b/c (54 asserts) |
| `server/session/chop_session.lua` | +`GetPartOrigin(id, partKey)` |
| `server/main.lua` | `chopPart(wheel)` → `TyreEntitlement.Issue`; callback devolve `tyreEntitlementId` |
| `server/fence.lua` | `PlayerTyreStock`/`ServerTyreCounts` removidos; `loadToTruck`/`sellTyres` reescritos; +`getPendingEntitlements` |
| `client/main.lua`, `client/carry.lua` | `VPChopCarryingPart.entitlementId` (nunca gerado no client); enviado no `loadToTruck` |
| `shared/locale.lua` | +`tyre_already_stored` / `tyre_entitlement_invalid` / `tyre_storage_identity` (en+pt) |

## Entitlement

```lua
Entitlements['te:<n>'] = {
  id, source = { sessionId, vsid, partKey, model },   -- PROVENANCE (histórica)
  removedBy = <src>,
  state = 'REMOVED' | 'STORED' | 'SOLD' | 'LOST',
  storageId = nil | 'ts:<n>',
  createdAt, updatedAt,
}
BySourcePart['<sessionId>:<partKey>'] = 'te:<n>'      -- idempotência
```

- **Issue(sessionId, src, partKey)** → idempotente por `(sessionId, partKey)`. Só
  emite se: `Config.TyreSelling.Enable`, `ChopParts[partKey].kind=='tyre'` (servidor
  deriva do Part Def — client nunca diz "isto é tyre"), ChopSession ativa,
  `GetPartState==REMOVED`, `GetPartOrigin=='base'`.
- **Transições:** `MarkStored` (só REMOVED, storageId obrigatório), `MarkSold` (só
  STORED, **SOLD é permanente — nunca volta**), `MarkLost` (SOLD nunca vira LOST).
- **Cleanup:** `playerDropped` → REMOVED de `removedBy==src` → LOST (preserva
  `PlayerTyreStock[src]=nil`). STORED **não** depende do player. **Nenhum hook em
  `ChopSession.CleanupVehicle`** — o pneu já foi separado fisicamente.
- `GetPendingForPlayer(src)` — read-only, REMOVED do src, limite 12/24. Callback
  `vp_chopshop:tyre:getPendingEntitlements` (só recuperação/UX; não cria/recompensa).

## Truck storage

- `ts:<n>` cunhado no 1º load + marcador server-local `vpChopTyreStorageId`
  (**WRITE + READBACK**). Protege estado econômico → não-confirmável = **fail-closed**
  (`storage_identity`).
- `ByTruckNetId[netId]` = só lookup. Identidade autoritativa = `storageId` + marcador
  + model. netId reciclado (marcador não bate / model difere) ⇒ `storage_identity`
  (não devolve o storage antigo).
- **Contagem DERIVADA:** `Count(storageId)` = nº de entitlements com `State=='STORED'`.
  `chopTyreCount` (state bag replicado) = **só UX, nunca autoridade**.
- `entityRemoved(truck)` → `OnTruckRemoved` → STORED → LOST, storage removido.
  "Truck sumiu = carga perdida" (preservado; pode mudar com persistência futura).

## Fluxos

```
chopPart(wheel_lf) → commit (origin=base) → TyreEntitlement.Issue → te:N (REMOVED)
                                          → callback { ok=true, tyreEntitlementId='te:N' }
client: VPChopCarryingPart.entitlementId = 'te:N'   (nunca gerado no client)

loadToTruck(src, truckNetId, 'te:N'):
  owner? state==REMOVED? truck ent/model/range? → TruckStorage.Resolve (fail-closed)
  → lock TruckStorageBusy[storageId] → TruckStorage.Load → te:N REMOVED→STORED
  deny em QUALQUER ponto ⇒ te:N continua REMOVED (client mantém prop/carry)

sellTyres(truck): TruckStorage.Peek → snapshot STORED ids → BridgeAddCash
  → (pay-fail ⇒ entitlements intactos STORED) → CommitSold (STORED→SOLD) → clear
  retry ⇒ no_tyres, sem 2º payout
```

## Locks

- `TruckLoadBusy[src]` — double-fire do mesmo player.
- `TruckStorageBusy[storageId]` — **carga E venda do mesmo storage serializadas**
  (era `[netId]`). Cada handler libera o próprio lock em todo return.
- `TyreSaleQuarantine[playerKey]` — fail-closed econômico: `CommitSold` parcial +
  estorno (`BridgeRemoveCash`) FALHOU → o jogador ficou com dinheiro a mais. Novas
  vendas de pneu → `transaction_locked`. Ledger SOLD/LOST **não** é revertido. Log
  `SEVERE` (playerKey/storageId/count/sold/refund não recuperado). Limpa só por
  mecanismo admin futuro (não nesta série).

## Duas origens de pneu (temporário)

| Origem | Fonte |
|---|---|
| A) truck | tyre entitlement (`ts:<n>` storage) |
| B) inventory | item `chopshop_tyre` (rota separada, **NÃO** convertida nesta PR) |

Contadores não se misturam. `sellTyres` inventory path inalterado.

## Limitação operacional

`TyreEntitlement` e `TruckStorage` são **in-memory**. Restart do resource perde
entitlements + storages (mesma limitação da ChopSession — sem persistência nesta série).

## NÃO implementado

ActionSession · minigame proof · transferência de pneu entre jogadores · inventários
persistentes de truck · dropped-prop persistence · condition/value/serial · market
dinâmico · Part Registry completo.

## Testes — E1–E28 + E20b/c (`tyre_entitlement_spec`, 54 asserts)

ISSUE (E1–E5): 1 entitlement/roda · idempotência · door→nenhum · provenance · sobrevive
ao source vehicle. LOAD (E6–E13): STORED · already_stored · owner · fake id · truck
cheio (REMOVED preservado) · 2 callbacks → 1 STORED. STORAGE IDENTITY (E14–E17):
marcador confirmado · write/readback falha → nada criado · netId reuse → storage
antigo não reaparece · marker diferente → `storage_identity`. SELL (E18–E23): count
derivada · pay-fail → STORED · pay-ok → SOLD/vazio · retry → no_tyres · 2 sellers → 1
payout · SOLD não volta · load durante sale → truck_busy. CLEANUP (E24–E28):
player-drop REMOVED→LOST · player-drop STORED intacto · truck-removed STORED→LOST ·
CleanupVehicle não toca entitlement · `GetPendingForPlayer` read-only.

Fora daqui (TEST_PLAN de servidor): props/carry no client, ox_target, trust,
proximidade real, yield real de `BridgeAddCash`, multiplayer 2–4, `resmon`.
