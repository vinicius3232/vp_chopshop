# vp_chopshop — Pesquisa externa v1 · Índice

**Data:** 2026-08-28 · **Baseline:** `pr-h/v1.15-delivercar-terminal-hardening` HEAD `dd1ee9f` (freeze de runtime `99371e4` intacto; os 2 commits acima são docs-only).
**Escopo desta rodada:** validação da diretiva + 4 auditorias externas reais + estudo de restart. Não mexe em runtime.

| # | Documento | O que responde |
|---|---|---|
| 1 | [EXTERNAL_RESEARCH_MATRIX.md](EXTERNAL_RESEARCH_MATRIX.md) | 4 repos auditados com evidência `arquivo:linha`; 14 restantes com nota curta. Veredito ADOPT/STUDY/REJECT por repo. |
| 2 | [RESTART_RECOVERY_STUDY.md](RESTART_RECOVERY_STUDY.md) | Tabela de estado (sobrevive? reconstrói? risco econômico?) para ChopSession, ActionSession, TyreEntitlement, TruckStorage, `vpChopDeliveredMark`, discard tombstone. Padrão qbx de referência. **Sem implementação.** |
| 3 | [PART_PROCESSING_EXTERNAL_REVIEW.md](PART_PROCESSING_EXTERNAL_REVIEW.md) | O RFC interno (`PART_PROCESSING_RFC.md`) vs. evidência externa. Modelo A confirmado. |
| 4 | [ROADMAP_RECONCILIATION.md](ROADMAP_RECONCILIATION.md) | Funde `PR-I0..I10` da KB com `#12..#17` do RFC numa lista única. Inclui proposta de CI mínima. |
| 5 | [ADOPT_STUDY_REJECT.md](ADOPT_STUDY_REJECT.md) | Lista priorizada de decisões. |

## Síntese de uma linha

A direção do `vp_chopshop` é confirmada pelas fontes: identidade forte de veículo (não placa), autoridade servidor, metadata rica em item genérico. O único ganho **acionável antes do RC** é nenhum — o gargalo continua sendo a QA rodar as fases 19–20 no servidor. O ganho **logo após o RC** é um `vp_chop_delivered` em DB + reconcile no boot (padrão qbx), que remove o risco P1 da Fase 19 de forma definitiva.

```
CODE CHANGED: NO
RUNTIME BEHAVIOR CHANGED: NO
RC FREEZE PRESERVED: YES
```
