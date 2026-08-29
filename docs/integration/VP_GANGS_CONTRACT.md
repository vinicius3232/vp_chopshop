# VP_GANGS_CONTRACT.md — contrato de integração vp_chopshop → vp_gangs

> **INT-01A.** Ponte pequena, versionada, fail-safe. `vp_chopshop` observa
> atividade **válida** de desmanche e a publica pelo contrato **público** do
> `vp_gangs`. Nenhum resource conhece internals do outro. Nenhum acesso a DB
> cruzado. Nenhuma dependência rígida.

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

## O que INT-01A NÃO faz

- **Nenhum payout novo.** O `vp_chopshop` já paga o desmanche. O payload **não**
  carrega `amount`. O `vp_gangs` recebe `money.pay = 'observe'` (INT-01B).
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
  deduplica por `caller + operationId` (INT-01B).
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

## Contrato de erro (retorno de `VPChopGangsDispatch`, só diagnóstico)

`vp_gangs_stopped` · `pcall_error` · `no_result` · e o `reason` do próprio
`vp_gangs` (`forbidden_caller` / `disabled` / `no_gang` / `not_official` /
`bad_payload` / `replay` / `version_unsupported` / `ok`). **Nenhum** afeta o
resultado do desmanche.

## Compat temporário `[INT-01B REMOVE]`

Enquanto o `vp_gangs` não registrar o adapter `['vp_chopshop']` em
`config/external.lua`, `recordExternalCrime` devolve `forbidden_caller`. Nesse
caso (e só nesse — `disabled`/`bridge_disabled`/`pcall_error`/`no_result`), o
bridge cai no call legado `exports.vp_gangs:rewardGangActivity(cid, 'vehicle_chop', {})`
(opts vazio → 0 payout) para **preservar exatamente** o crédito de gang atual
durante a janela entre INT-01A e INT-01B. Rejeições **legítimas** do `vp_gangs`
(`no_gang`, `not_official`, `replay`, …) **não** caem no compat.

**INT-01B liga o adapter e apaga este fallback** de `bridge/vp_gangs.lua`.

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

`bridge/vp_gangs_spec.lua` (44 asserts, self-gated `vp_chopshop_selftest 1`):
filtro phase 1–4 (`vin_scratch`/`plate_theft`/nil/vazio não emitem) · `operationId`
domínio-derivado (nil sem sessão) · payload v1 sem `amount`/`plate`/`netId`/
`citizenid`/`reward` · caminho novo · compat só em `forbidden_caller`/`disabled` ·
rejeição legítima não cai no compat · `vp_gangs` parado → nada · handler
end-to-end.

`lua tools/run_spec.lua .` → **610 PASS / 0 FAIL** (566 + 44). `luac -p` limpo.

## Behavior change

```
gameplay/economia do desmanche = NONE   (o evento é pós-commit; XP/tiers/payout iguais)
crédito de gang líquido        = IDÊNTICO (caminho novo, ou compat → mesmo rewardGangActivity)
DB migration                   = NONE
```

## Roadmap (não neste PR)

- **INT-01B** (`vp_gangs`): adapter `['vp_chopshop']` em `config/external.lua`
  (`mode='active'`, `credit='activity'`, `money.pay='observe'`, `requireOfficial=true`)
  + dedup `caller+operationId` (TTL/LRU) em `server/external.lua` + `contractVersion` check.
- `vehicle_part` / `sourceSession` → `operationId` cross-restart-safe.
- mercado ilegal de peças (engine → "Mecânico Fantasma" via ContactMeet, ecu →
  contato especializado, etc.) — tudo no lado `vp_gangs`, reusando Contacts /
  ContactMeet / Trap Phone.
