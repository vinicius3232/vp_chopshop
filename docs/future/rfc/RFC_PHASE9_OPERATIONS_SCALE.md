# RFC — Fase 9: Operations, Telemetry, Chaos QA & Scale

> **Status:** CANONICAL SPECIFICATION / RFC  
> **Fase:** FASE 9 (v1.23) — Operations, Telemetry & Scale  
> **Dependências:** `P5.5 Restart Recovery`, `P8.2 Specialized Demand`, `SAGA Journal`  
> **Escopo:** Telemetria de mercado, auditoria administrativa de transações, detecção de anomalias econômicas, testes de estresse com 20+ jogadores e metas de resmon

---

## 1. Telemetria de Mercado & Operações (P9.1)

O `vp_chopshop` expõe um painel de observabilidade em tempo real para a administração do servidor:

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ DASHBOARD DE TELEMETRIA EM TEMPO REAL                                                       │
├───────────────────────────────┬─────────────────────────────────────────────────────────────┤
│ Volume Financeiro (24h)       │ Payout total em dinheiro sujo/limpo distribuído             │
│ Transações B2B com Oficinas   │ Volume de compras processadas e taxa de sucesso SAGA (%)    │
│ Taxa de Quarentenas           │ Número de transações em quarentena / tentativas de replay    │
│ Top Commodities Vendidas      │ Ranking de peças mais desmanchadas no período               │
│ Índice de Atividade Policial  │ Total de alertas de scanner e perícias realizadas           │
└───────────────────────────────┴─────────────────────────────────────────────────────────────┘
```

---

## 2. Ferramentas Administrativas de Auditoria (P9.2)

Interface de comando ou menu restrito para desenvolvedores e administradores (`/chopadmin`):
- **Visualizador do SAGA Journal:** Consulta de transações em `vp_chop_workshop_journal` filtradas por status (`PREPARED`, `COMMITTED`, `ABORTED`, `QUARANTINE`).
- **Resolução Manual de Quarentena:** Comando para forçar a liberação ou cancelamento de uma peça/transação travada sem necessidade de editar o banco de dados manualmente.

---

## 3. Detecção Heurística de Anomalias Econômicas (P9.3)

Sensores heurísticos em background identificam comportamentos suspeitos antes que causem desequilíbrio na economia:

| Heurística / Gatilho | Condição de Alerta | Ação Automática do Servidor |
|---|---|---|
| **Velocity Spike de Venda** | Jogador entrega > 6 catalisadores em < 60 segundos | Bloqueia novas entregas por 5 min & Emite alerta para staff |
| **Payout Impossível** | Valor de recompensa > teto máximo configurado | Rejeita transação com fail-closed & Registra tentativa de exploit |
| **Replay de Token de Ação** | Mesmo `actionId` reenviado após commit | Rejeição silenciosa e log no Discord de auditoria |
| **Discrepância de Distância** | Ação concluída a > 15m do veículo | Invalida a ação e reseta a sessão |

---

## 4. Protocolo de Testes de Estresse & Caos (P9.4 / P9.5)

### Bateria de Soak Test (20+ Jogadores Simultâneos — P9.4):
- 10 duplas de jogadores desmanchando simultaneamente em diferentes oficinas e no mundo aberto.
- 5 oficinas emitindo e cancelando ordens de compra B2B simultaneamente.
- Polícia realizando inspeções de scanner e coleta de evidências concorrentes.

### Bateria de Testes de Caos (P9.5):
1. **Queda de Conexão no Commit:** Desconectar o client exatamente durante a transição de `COMMITTING`.
2. **Restart Forçado de Resource Mecânico:** Executar `restart qbx_mechanics` durante o estado `PREPARED`.
3. **Simulação de Queda de MySQL:** Interromper o serviço MySQL por 3 segundos durante uma transação em lote.
- **Critério de Sucesso:** Zero dinheiro duplicado, zero peças fantasmas criadas, recuperação elegante via fail-closed.

---

## 5. Metas Rigorosas de Performance & Resmon (P9.6)

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ LIMITES DE PERFORMANCE INEGOCIÁVEIS                                                        │
├───────────────────────────────┬─────────────────────────────────────────────────────────────┤
│ Resmon Client (Idle)          │ ≤ 0.01 ms                                                   │
│ Resmon Client (Desmanchando)  │ ≤ 0.03 ms (durante minigames e renderização de props)       │
│ Resmon Server Tick            │ ≤ 0.20 ms em pico com 64 jogadores conectados              │
│ Consultas SQL (oxmysql)       │ 100% queries parametrizadas com índices cobertos            │
│ Statebags de Rede             │ Zero sincronizações por-frame (apenas eventos de estado)    │
└───────────────────────────────┴─────────────────────────────────────────────────────────────┘
```
