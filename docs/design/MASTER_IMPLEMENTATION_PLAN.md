# MASTER_IMPLEMENTATION_PLAN — vp_chopshop

**Base:** `pr-h/v1.15-delivercar-terminal-hardening` · **Harness:** 1545 PASS / 0 FAIL / 1545 asserts  
**Progresso:** ver [`STATUS.md`](../../STATUS.md) na raiz. Este documento é o roadmap e plano mestre de implementação.

---

## 1. Registro de Arquitetura & Diretrizes

1. **Server-Authoritative First:** Toda lógica de negócio, cotação, payout, quota de contrato, locks de peças e transações SAGA pertencem exclusivamente ao servidor.
2. **Fail-Closed em Qualquer Falha:** Falha de DB, desconexão ou falha de inventário nunca duplica dinheiro nem gera replay indevido.
3. **Pequenas PRs Empilhadas:** Cada etapa possui sua PR isolada contra `pr-h`, com 100% de cobertura de testes e validação estática.

---

## 2. Histórico de Fases Consolidadas

### ✅ FASE 0 — Base & Concorrência Server-Side (v1.15)
- `ChopSession` e `ActionSession` com `VehicleSessionId` (`vsid`) autoritativo.
- `CarcassLedger` persistente e proteção anti-re-discard pós-restart.
- Terminalização atômica de `deliverCar` e `TyreEntitlement`.

### ✅ FASE 1 — Part Registry Schema v2 (v1.16)
- Registry autoritativo com schema v2 congelado (`shared/registry/parts.lua` e `tools.lua`).
- Eliminação definitiva de tabelas de peças client-authoritative.

### ✅ FASE 2 & 3 — Gameplay Físico & Minigames 3D (v1.16)
- Minigames contextuais de interação física (Rodas 5-bolt, Painéis, Motor com parafusadeira e Carcaça estrutural com maçarico de solda).
- Carregamento físico de peças nos braços (`PartEntitlement`), drop no chão e desmanche integrado na bancada.
- Dano dinâmico de motor (`EngineHealth`), furto de catalisadores e desmanche de peças em carros de jogadores com proteção anti-auto-farm (`BlockOwnVehicle`).

### ✅ FASE BROKER — Chop Broker, Dynamic Market & Workshop SAGA (v1.17)
- **BROKER-1 / 2:** Motor de mercado dinâmico (`BrokerMarket`) com curva de oferta/demanda elástica persistida no banco de dados.
- **BROKER-3:** Alta procura global rotativa e contratos pessoais sob medida (`BrokerContracts`).
- **BROKER-4:** Barramento transacional distribuído para oficinas mecânicas (`WorkshopBridge` SAGA com journal durável e `stablePartIdentity`).
- **BROKER-5 / 5.1:** Persona unificada do Intermediário com interface contextual `ox_lib` e paridade integral em 5 idiomas (`pt`, `en`, `es`, `fr`, `tr`).
- **BROKER-6 / 6.2:** Release Candidate gate, checklist de Live QA ([`docs/BROKER-6_LIVE_QA.md`](../BROKER-6_LIVE_QA.md)) e 12 invariantes canônicos congelados ([`docs/BROKER-6_RELEASE_INVARIANTS.md`](../BROKER-6_RELEASE_INVARIANTS.md)).

---

## 3. Roadmap de Implementação Futura (v1.18+)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       ROADMAP PÓS-v1.17 (FASES FUTURAS)                     │
├───────────────────┬─────────────────────────────────────────────────────────┤
│ FASE 4 (v1.18)    │ Camada de Crime & Perícia Policial Profunda (Forense V2) │
│ FASE 5 (v1.19)    │ Adaptadores Reais de Oficina Mecânica (Workshop Live)   │
│ FASE 6 (v1.20)    │ Territórios de Gangue & Chop Zones (Gangs Integration)  │
│ FASE 7 (v1.21)    │ Reconstrução Veicular & VIN Rebirth (Veículo Limpo)     │
│ FASE 8 (v1.22)    │ Emboscadas V2, Sindicato Rival & Polish de Áudio/VFX    │
└───────────────────┴─────────────────────────────────────────────────────────┘
```

---

### 🎯 FASE 4 (v1.18) — Camada de Crime & Perícia Policial Profunda
- **P4.1 — `EvidenceBridge` Unificado:** Bridge multi-framework com detecção dinâmica de `qbx_policejob`, `ox_evidence`, `evidences` (CFX) ou standalone inerte.
- **P4.2 — Sistema de Rastreadores GPS / LoJack:** Veículos de alto valor com chance de rastreador ativo emitindo pings periódicos à polícia; minigame com ferramenta de corte para desativação física (`ActionSession(kind='tracker_removal')`).
- **P4.3 — Scanner Policial & Séries Adulteradas:** Item policial `parts_scanner` para perícia forense de números de série gravados e forjados em inventários e veículos.
- **P4.4 — Release Gate v1.18:** Specs de integração policial e checklist de Live QA forense.

---

### 🎯 FASE 5 (v1.19) — Adaptadores de Oficina Mecânica (Workshop Live)
- **P5.1 — Adapter QBox Mechanics (`qbx_mechanics` / `qbx_customs`):** Conexão do provider SAGA real para abastecimento de peças clandestinas para oficinas de jogadores.
- **P5.2 — Adapter QS-Mechanic / Renzu:** Integração por exports com sistemas populares da comunidade.
- **P5.3 — Catálogo de Encomenda B2B:** Terminal de pedidos de oficinas para compra de peças raras com entrega via Broker.

---

### 🎯 FASE 6 (v1.20) — Territórios de Gangue & Chop Zones (`VP_GANGS`)
- **P6.1 — Taxa Territorial de Desmanche:** Desmanchar em território controlado por facção deposita automaticamente uma porcentagem configurável no cofre da gangue.
- **P6.2 — Bônus de Facção:** Gangues donas de setores industriais ganham bônus de cotação em contratos do Broker.
- **P6.3 — Alerta de Invasão de Área:** Desmanche em território rival sem aliança emite alerta de rádio aos membros da facção local.

---

### 🎯 FASE 7 (v1.21) — Reconstrução Veicular & VIN Rebirth
- **P7.1 — Salvage Title / Chassi Documentado:** Compra de carcaça legalizada no ferro-velho.
- **P7.2 — Montagem Completa na Bancada:** Fusão de 4 portas, capô, motor e soldagem com peças serializadas legítimas.
- **P7.3 — Registro Civil de Nova Placa:** Emissão de veículo civil limpo no banco QBox (`qbx_vehicles`), concluindo o ciclo do carro "esquentado".

---

### 🎯 FASE 8 (v1.22) — Emboscadas V2, Sindicato Rival & Polish
- **P8.1 — Emboscadas Táticas por Heat:** NPCs de sindicatos rivais interceptam transportes de peças e veículos valiosos.
- **P8.2 — Retaliação de Contrato:** Cobradores armados enviados contra jogadores que descumprem contratos de alta confiança.
- **P8.3 — Polish Audiovisual:** Efeitos sonoros espaciais dedicados e partículas de corte/solda aprimoradas.

---

## 4. Sistemas KEEP (Fundação Permanente — Não Tocar)
- VehicleSessionId · ChopSession FSM · Jackstand server-auth · ActionSession com `PinPartLock` · CarcassLedger persistente · Invariante "tempo sozinho nunca destrói committed state" · 100% SQL parametrizado · Bridges QBox-first.
