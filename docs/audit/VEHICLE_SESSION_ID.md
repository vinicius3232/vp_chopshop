# VehicleSessionId (VSID) — decisão arquitetural

Contexto: v1.15 `arch/v1.15-chop-session`, ETAPA 1. Consumido por `server/session/chop_session.lua`.

## Problema

`netId` (network id do OneSync) **é reciclado**. Estado keyed por `netId` pode
vazar de um veículo A destruído para um veículo B novo que herdou o mesmo `netId`
(exatamente o `P2-4` da auditoria). Precisamos de uma identidade de entidade
**estável durante a sessão de desmanche**, não persistente.

## Auditoria de primitivos disponíveis

| Fonte | O que oferece | Serve? |
|---|---|---|
| OneSync / natives | `NetworkGetEntityFromNetworkId`, `NetworkGetNetworkIdFromEntity`, eventos `entityCreated`/`entityRemoved`. **Nenhum GUID estável por entidade.** | ❌ sozinho |
| `ox_lib` | — nenhum primitivo de identidade de entidade | ❌ |
| `qbx_core` | `Entity(veh).state.vehicleid` / `.state.vehicleData.id` — **só** para veículos *owned*/persistidos pelo framework. Veículo alvo de chop (não-owned, `Config.AllowOwnedVehicles=false` por padrão) **não tem**. | ⚠️ parcial |

Conclusão: **nenhum primitivo cobre o caso comum** (veículo não-owned). Construir
abstração fina própria e esconder a implementação atrás dela.

## Decisão

`VehicleSessionId` = string opaca **`"vsid:<n>"`**, `n` = contador monotônico pela
vida do resource (`_vsidSeq`). Cunhado **1× por sessão** em `ChopSession.Create`.
**Não reutilizado. Não persistido.**

Junto, a sessão guarda um **fingerprint** tirado no momento da cunhagem:

```lua
vehicle._fp = {
    netId    = <int>,
    model    = GetEntityModel(ent),          -- hash do modelo
    plate    = <placa real, trim>,           -- SÓ forense/log — nunca identidade
    ownedId  = Entity(ent).state.vehicleid,  -- se existir (veículo owned) — reforço
    mintedAt = os.time(),
}
```

### Invalidação (qualquer uma → sessão morta)

1. **`entityRemoved(ent)`** (server event) → `ChopSession.CleanupVehicle(netId)` **imediato**.
2. **Recheck de liveness em todo `Get`/`GetByVehicle`** (`vehicleStillValid`):
   - entidade do `netId` deve existir **E**
   - `GetEntityModel(ent)` deve **igualar** `_fp.model` → se difere, o `netId` foi
     reciclado noutro veículo → sessão stale → cleanup + retorna `nil`.
   - se ambos os lados têm `ownedId`, exigir match (mais forte, custo zero).
3. **Timeout por inatividade** (`SessionTimeoutMs`, default 15 min desde `lastActivity`)
   → sweeper cancela. Sweeper roda a cada `SweepIntervalMs` (30 s), percorre **só** a
   tabela de sessões (pequena) — **sem `GetGamePool` / sem polling de entidades**.

### Por que não `netId + plateHash`

- Placa é **mutável** (placas falsas — `applyFakePlate`). Identidade baseada em placa
  quebraria a cada disfarce e é justamente o vetor que a camada forense explora.
- `model + netId + liveness + entityRemoved` é mais barato (comparação de hash) e
  não depende da placa.

### Custo

O(1) por operação. O recheck é 1 native (`GetEntityModel`) + 1 comparação. Sem
alocação. Sweeper: 1 thread, `Wait(30s)`, itera N sessões vivas (tipicamente < 10).

## Superfície de API relacionada

`ChopSession` expõe apenas: `session.vehicle.identity` (o VSID) e
`session.vehicle.netId`. Consumidores nunca leem `_fp` diretamente. A troca da
implementação interna (ex.: se um dia OneSync ganhar GUID estável) não afeta
call sites.

## Limitações aceitas nesta fase

- Se `entityRemoved` **não disparar** (raro; bug de plataforma) e o `netId` for
  reciclado no **mesmo modelo** dentro da janela de timeout, o recheck de modelo
  não pega. Mitigação: timeout curto + `ownedId` quando disponível. Uma checagem
  adicional de `plate` seria falível (placas falsas) — deliberadamente fora.
- VSID não sobrevive a restart do resource (não persiste). Correto para o escopo:
  sessão de desmanche é efêmera.
