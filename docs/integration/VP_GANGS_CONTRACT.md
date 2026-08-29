# VP_GANGS_CONTRACT.md — contrato de integração vp_chopshop → vp_gangs

> **INT-01 (V1 fechado — A · A.1 · B · B.1 · C).** Ponte pequena, versionada,
> fail-safe, **caminho único**. `vp_chopshop` observa atividade **válida** de
> desmanche e a publica pelo contrato **público** do `vp_gangs`. Nenhum resource
> conhece internals do outro. Nenhum acesso a DB cruzado. Nenhuma dependência
> rígida. **Nenhum fallback legado** (removido no INT-01C).

```
vp_chopshop  ── domínio de veículos (ChopSession, peça, Part Registry, serial)
     │
     │ PART_CHOPPED interno (pós-commit)
     ▼
bridge/vp_gangs.lua  ── ÚNICO arquivo que conhece exports.vp_gangs
     │
     │ exports.vp_gangs:recordExternalCrime(src, payload{v1})
     ▼
vp_gangs  ── domínio social/criminal (resolve gang/citizenid server-side)
```

## Ownership (fronteira)

| `vp_chopshop` é autoridade sobre | `vp_gangs` é autoridade sobre |
|---|---|
| veículo, ChopSession, ActionSession, peça removida, Part Registry, estado físico da peça (`state`: `stolen/scratched/forged/legal`), serial, procedência, processamento, anti-dupe, restart recovery, **payout do desmanche** | organização, gang, Contacts, trust, ContactMeet, mercado ilegal, território, reputação criminal, heat social/organizacional, fornecedores, Trap Phone, lavagem |

O `vp_gangs` é **consumidor econômico** dos estados de peça — nunca cria uma
segunda definição. O `vp_chopshop` **não conhece** Contacts/ContactMeet/Territory.

## O que INT-01 NÃO faz

- **Nenhum payout novo.** O `vp_chopshop` já paga o desmanche. O payload **não**
  carrega `amount`. O adapter no `vp_gangs` usa `money.pay = 'observe'`.
- Não altera balanceamento, XP, tiers, fence interno, ambush, heat do chopshop.
- Não implementa `vehicle_part` / PartProcessing / mercado ilegal de peças.
- Não conecta `vp_chopshop.heat` ao `vp_gangs` heat (eixos separados — ver `docs/audit/EVENT_MATRIX.md`).

## `PART_CHOPPED` — evento interno, NÃO é API pública

`VPChopEvt.PART_CHOPPED = 'vp_chopshop:evt:partChopped'` — `TriggerEvent` local
(não `RegisterNetEvent` → não chamável da rede). Disparado **pós-commit** por
`server/chop.lua` (phase 1), `server/advanced_chop.lua` (2/3/4),
`server/plates.lua` (`plate_theft`, phase 1), `server/heat.lua` (`vin_scratch`,
phase 0). Params: `(src, netId, partKey, phase)`.

`bridge/vp_gangs.lua` é o **único** ouvinte externo. Filtra e traduz para o
contrato v1.

### Filtro — exatamente os marcos que o crédito de gang já cobria

`bridge/vp_gangs.lua` só emite quando `VPChopGangsShouldEmit(partKey, phase)` —
que espelha **linha a linha** o gate do antigo call em `server/progression.lua`:

```lua
reason = (partKey == 'vin_scratch') and 'vin_scratch'
      or (partKey == 'plate_theft') and 'plate_theft'
      or ('phase' .. phase)
emite  = reason ∈ { 'phase1', 'phase2', 'phase3', 'phase4' }
```

| entrada | emite? |
|---|---|
| peça real, `phase` 1–4 | ✅ |
| `phase` 0 ou 5+ | ❌ |
| `vin_scratch` (qualquer phase) | ❌ |
| `plate_theft` (phase 1) | ❌ |
| `partKey` nil / vazio | ❌ |

## Payload — contractVersion 1

```lua
{
    contractVersion = 1,
    crime           = 'part_chopped',
    operationId     = 'cs:7:bonnet:p2',   -- ChopSession.id : partKey : phase
    partKey         = 'bonnet',           -- chave server-known do Part Registry
    phase           = 2,                  -- 1..4
}
```

**Não contém** (por design): `amount`/payout · `plate` · `netId` · `citizenid`
(autoridade) · `vsid` cru · ChopSession · locks/mutex · timestamps internos ·
detalhes de anti-cheat/compensação.

O `src` vai como 1º argumento de `recordExternalCrime(src, payload)` **só como
conexão atual** — o `vp_gangs` resolve `citizenid` + gang server-side no mesmo
tick (a emissão é síncrona, pós-commit).

## Identidade / idempotência

`operationId = ChopSession.GetByVehicle(netId).id .. ':' .. partKey .. ':p' .. phase`

- **same-resource-lifetime: garantida** — a barreira `MarkChopped` do
  `vp_chopshop` impede que a MESMA peça re-emita `PART_CHOPPED`; e o `vp_gangs`
  deduplica por `caller + operationId` (`server/external_dedup.lua`), com o
  namespace daquele caller limpo no `onResourceStart` do produtor.
- **cross-restart: NÃO GARANTIDA** — `_sidSeq` reseta no boot
  (`server/session/chop_session.lua`) → sessões voltam a `cs:1, cs:2, …`. Não há
  identidade **física** persistente de peça ainda.
  **Boundary conhecido**, a resolver quando existir `vehicle_part` /
  `sourceSession` (roadmap `docs/design/PART_PROCESSING_RFC.md`). **Não** usamos
  `netId` / `plate` / `timestamp` como substituto fraco — sem `ChopSession` ativa,
  o bridge **não emite** (fail-closed).

## Segurança / fail-safe

| | |
|---|---|
| server-only | `PART_CHOPPED` é `TriggerEvent` local; o bridge não expõe nada à rede |
| caller validation | do lado `vp_gangs`: `recordExternalCrime` já checa `GetInvokingResource() == 'vp_chopshop'` contra a allowlist de adapters |
| `vp_gangs` parado | `GetResourceState('vp_gangs') ~= 'started'` → não chama nada |
| export ausente / erro | `pcall` em toda chamada de export |
| **falha de integração ≠ falha de domínio** | o evento é pós-commit; o bridge nunca faz rollback do desmanche |

## Contrato de erro — **só diagnóstico, sempre**

Retorno de `VPChopGangsDispatch` (não usado pelo domínio):
`vp_gangs_stopped` · `pcall_error` · `no_result` · e o `reason` do próprio
`vp_gangs` (`forbidden_caller` / `adapter_disabled` / `bridge_disabled` /
`version_unsupported` / `bad_payload` / `no_gang` / `not_official` / `replay` /
`dedup_capacity` / `ok`).

**Qualquer** um deles → **só loga**. O `vp_chopshop` **nunca** credita gang por
outro caminho. Nenhum afeta o resultado do desmanche (`PART_CHOPPED` é pós-commit).

> **INT-01C fechou o cutover.** O fallback legado
> (`exports.vp_gangs:rewardGangActivity(cid, 'vehicle_chop', {})`) que existia em
> `bridge/vp_gangs.lua` durante a janela INT-01A↔INT-01B **foi removido**.
> `ACTIVITY_LEGACY`, a resolução de `citizenid` via `exports.qbx_core` e os
> ramos por `forbidden_caller`/`disabled`/`bridge_disabled` não existem mais.

## Caminho ÚNICO

```
PART_CHOPPED (pós-commit, vp_chopshop)
   ↓
bridge/vp_gangs.lua  (filtro phase/reason · operationId · payload V1)
   ↓
exports.vp_gangs:recordExternalCrime(src, payload)
   ↓
adapter 'vp_chopshop'  (config/external.lua)
   ↓
ExternalBridge.apply  (guards · dedup reserve · ... · consume)
   ↓
Progression.rewardGangActivity('vehicle_chop')   ← INTERNO do vp_gangs
```

## O que muda em `server/progression.lua`

Removido o bloco (linhas ~109-114 pré-INT-01A):
```lua
if GetResourceState('vp_gangs') == 'started' and (reason == 'phase1'..'phase4') then
    local okG, cidG = pcall(function() return exports.qbx_core:GetPlayer(src).PlayerData.citizenid end)
    if okG and cidG then exports.vp_gangs:rewardGangActivity(cidG, 'vehicle_chop', {}) end
end
```
`VPChopAddXp` não conhece mais `exports.vp_gangs`.

## Testes

`bridge/vp_gangs_spec.lua` (66 asserts, self-gated `vp_chopshop_selftest 1`):
filtro phase 1–4 (`vin_scratch`/`plate_theft`/nil/vazio não emitem) · `operationId`
domínio-derivado (nil sem sessão) · payload v1 sem `amount`/`plate`/`netId`/
`citizenid`/`reward` · `recordExternalCrime` ok → 1 chamada · **QUALQUER reason
(`forbidden_caller`/`adapter_disabled`/`bridge_disabled`/`version_unsupported`/
`bad_payload`/`no_gang`/`not_official`/`replay`/`dedup_capacity`/`pcall_error`/
`no_result`) → ZERO fallback** (canário: `rewardGangActivity`/`qbx_core:GetPlayer`
nunca tocados) · `vp_gangs` parado → domínio continua · handler end-to-end ·
**canário estático**: o fonte não faz `:rewardGangActivity(`, não acessa
`qbx_core`, não tem `ACTIVITY_LEGACY`.

`lua tools/run_spec.lua .` → **632 PASS / 0 FAIL** (566 + 66). `luac -p` limpo.

## Behavior change

```
gameplay/economia do desmanche = NONE   (o evento é pós-commit; XP/tiers/payout iguais)
crédito de gang líquido        = IDÊNTICO  (caminho único → adapter → rewardGangActivity interno)
DB migration                   = NONE
```

## Estado — INT-01 V1 FECHADO

| passo | onde | estado |
|---|---|---|
| INT-01A / A.1 | vp_chopshop | ✅ `#27` (bridge + fallback compat) |
| INT-01B / B.1 | vp_gangs | ✅ `#7` (adapter `['vp_chopshop']` + `server/external_dedup.lua` + `adapter_disabled` + `contractVersion`/`operationId`) |
| **INT-01C** | **vp_chopshop** | ✅ **este PR** — removeu o fallback legado; caminho único |

## Roadmap (não neste ciclo)

- `vehicle_part` / `sourceSession` (roadmap do `vp_chopshop`) → `operationId` cross-restart-safe.
- mercado ilegal de peças (engine → "Mecânico Fantasma" via ContactMeet, ecu →
  contato especializado, etc.) — tudo no lado `vp_gangs`, reusando Contacts /
  ContactMeet / Trap Phone.
