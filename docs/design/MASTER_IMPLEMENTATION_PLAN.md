# MASTER_IMPLEMENTATION_PLAN — vp_chopshop

**Base:** `pr-h/v1.15-delivercar-terminal-hardening` · **Harness:** 2214 PASS / 0 FAIL / 2214 asserts  
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

### ✅ FASE 4 — Camada de Crime & Perícia Policial Profunda (v1.18)
- **P4.1 — `EvidenceBridge` Unificado:** Bridge multi-framework com detecção dinâmica de `qbx_policejob`, `ox_evidence`, `evidences` (CFX) ou standalone inerte.
- **P4.2 — Sistema de Rastreadores GPS / LoJack:** Veículos de alto valor com chance de rastreador ativo emitindo pings periódicos à polícia; minigame com alicate de corte para desativação física (`ActionSession(kind='tracker_removal')`).
- **P4.3 — Alertas Dispatch & Polícia Integrada:** Sistema de despacho e alertas de furto de catalisador/corte estrutural via `DispatchBridge`.
- **P4.4 — Scanner Policial & Séries Adulteradas:** Item policial `parts_scanner` e `forensic_kit` para perícia veicular (estado do motor, catalisador, VIN raspado, placa falsa e GPS).
- **v1.18-RC — Release Gate:** Homologado com 55 checks de release gate e 2038+ asserts (PR #52).

### ✅ FASE 4.5 — Expansão de Minigames Físicos & Polimento (v1.18.2)
- **Minigame SVG de Catalisador:** Painel interativo de corte de escapamento e fixadores em veículos de rua.
- **Minigame de Raspagem de Serial:** Lixamento abrasivo de números de série na bancada via painel interativo.
- **Desmonte com Martelo Pneumático:** Desmonte sonoro/vibratório de peças pesadas na bancada.
- **Auditoria v1.18:** Resolução de leaks de jackstands e props de bancada, otimização de IPC NUI por frame e harness com 2159 asserts.

### ✅ FASE 5 — Adaptadores de Oficina Mecânica (Workshop Live) (v1.19)
- **P5.1 — Adapter QBox Mechanics (`qbx_mechanics` / `qbx_customs`):** Conexão do provider SAGA real com contas de sociedade (`qbx_management`) e entrega em cofres/stashes do `ox_inventory`.
- **P5.2 — Adapter QS-Mechanic / Renzu / Custom:** Integração multi-API para ecossistemas mecânicos da comunidade e conector universal via exports.
- **P5.3 — Catálogo de Encomenda B2B & Escrow:** Ordens de compra de peças emitidas por oficinas retidas em garantia no `vp_chopshop`, mescladas aos contratos do Broker com liquidação e cancelamento atômicos.

---

## 3. Roadmap de Implementação Futura (v1.20+ / Fases 6 a 9)
> Especificações completas disponíveis na suíte de RFCs canônicas em [`docs/future/`](../future/).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       ROADMAP PÓS-v1.19 (FASES FUTURAS)                     │
├───────────────────┬─────────────────────────────────────────────────────────┤
│ FASE 6 (v1.20)    │ Territórios de Gangue & Chop Zones (Gangs Integration)  │
│ FASE 7 (v1.21)    │ Reconstrução Veicular & VIN Rebirth (Veículo Limpo)     │
│ FASE 8 (v1.22)    │ Emboscadas V2, Sindicato Rival & Polish de Áudio/VFX    │
│ FASE 9 (v1.23)    │ Logística Clandestina, Desmanche Náutico & Exportação   │
└───────────────────┴─────────────────────────────────────────────────────────┘
```

---

### 🎯 FASE 6 (v1.20) — Territórios de Gangue & Chop Zones (`VP_GANGS`) ✅ CONCLUÍDO (PR Aberto)
- **P6.1 — Taxa Territorial de Desmanche:** Desmanchar ou vender em território controlado por facção retém automaticamente porcentagem configurável (15%) e credita no cofre da gangue dominante via `VPChopGangs.CreditTerritoryTax`.
- **P6.2 — Bônus de Facção & Alívio de Heat:** Membros da facção dominante ganham bônus (+10%) no payout e 50% de redução na geração de heat policial/emboscadas ao operar em território próprio.
- **P6.3 — Alerta de Invasão & Informantes [REQUISITO CANÔNICO]:** Desmanche em território rival SÓ emite sinalização SE a gangue dona possuir informante/NPC ativo no turf (`VPChopGangs.HasTurfInformant`). Notificação despachada diretamente para smartphones via `PhoneBridge` (`lb-phone`, `qs-smartphone`, `yphone`, `gksphone`, `npwd`, `custom`).
- **P6.4 — Contratos Cooperativos de Gangue:** `server/broker/gang_contracts.lua` com squad de membros, consumo de peças físicas duráveis e rateio de lucros 100% server-authoritative.
- **P6-RC — Release Gate de Territórios:** 19 asserts cobrindo invariantes INV-P6-01 a INV-P6-08 (Harness em 2311 PASS / 0 FAIL).

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

### 🎯 FASE 9 (v1.23) — Logística Clandestina, Desmanche Náutico & Exportação
- **P9.1 — Cargas em Containers Marítimos:** Empacotamento de lotes de peças e veículos inteiros em docas portuárias.
- **P9.2 — Desmanche de Embarcações:** Desmanche aquático de lanchas e jet-skis com ferramentas estanques.
- **P9.3 — Exportação Internacional:** Rotas de entrega por cargueiros com janelas temporais dinâmicas e patrulha costeira.

---

## 4. Sistemas KEEP (Fundação Permanente — Não Tocar)
- VehicleSessionId · ChopSession FSM · Jackstand server-auth · ActionSession com `PinPartLock` · CarcassLedger persistente · Invariante "tempo sozinho nunca destrói committed state" · 100% SQL parametrizado · Bridges QBox-first.
