# PART_PROCESSING_EXTERNAL_REVIEW

Confronta `docs/design/PART_PROCESSING_RFC.md` (interno, 639 linhas, já muito detalhado) com a evidência externa. **O RFC não é um esboço** — já decidiu Modelo A, `ProcessSession`, contrato de oficina §H, análise de arbitragem §G.3 e roadmap #12–#17. Esta revisão só pergunta: *algo externo contradiz o que o RFC já decidiu?*

---

## 1. Item de entrada — Modelo A (`vehicle_part` genérico + metadata)

| Fonte | O que mostra | Impacto no RFC |
|---|---|---|
| `ox_inventory` `modules/items/server.lua:169,220` | metadata dá unicidade; stack só com metadata idêntica — nativo | **Confirma A.** Modelo B (item por tipo) luta contra o design do inventário. |
| `renzu_projectcars` `server/server.lua:156-162` + `data/INVENTORY_IMAGE/*` | usou item-por-tipo (`engine`, `door`, `wheel`…) **e** metadata de modelo ao mesmo tempo → 9 itens + 9 imagens + entradas de config/locale por tipo | **Confirma o custo de B.** Expandir = novo item, nova imagem, nova linha de config. Com A, expandir = uma linha em `Config.PartProcessing.Types`. |
| `meta_chopshop` (leitura de README) | item-por-tipo (`vehicledoor_lf`, `vehiclehood`…) | Mesmo custo de B, com o agravante de granularidade por posição. |

**Veredito:** nenhuma evidência contradiz o Modelo A. A KB já dizia ADOPT CONCEPT / REJECT ITEM EXPLOSION (§4.2) e a evidência de código sustenta isso.

## 2. Autoridade servidor na transação de processamento

O RFC §E.1 (START→revalidate→COMMITTING→executor→COMPLETED, replay idempotente, `slotIdentity` hash) é **mais rigoroso** que qualquer referência externa auditada:

- `renzu_projectcars`: **zero** autoridade — client manda tudo (`updatechopcar`, `updateprojectcars`). É o anti-exemplo.
- `qbx_vehicles` `server/main.lua:284`: `saveVehicle` fail-closed em `not_owned` — mesmo espírito do RFC, mas escopo menor (não tem sessão temporal nem replay).
- `ox_inventory`: valida server-side, mas não provê a máquina de estados — é a camada de baixo que o `ProcessSession` usaria.

**Veredito:** o RFC não deve regredir para nenhum padrão externo. Manter `ProcessSession` próprio (não reusar `ActionSession` — a justificativa do §D.3 continua válida: `ActionSession` exige `ChopSession` ACTIVE + veículo `raised`).

## 3. Metadata — campos

RFC C.1: `{ partType, serial, state, sourceModel, sourceSession }`.

| Campo | Externo diz | Classificação |
|---|---|---|
| `partType` | chave em renzu (`Config.parts`), meta (nome do item) | **REQUIRED NOW** |
| `serial` | `ox_inventory` gera serial server-side para itens registrados (`:187`) | **REQUIRED NOW** (já é o padrão do `car_parts` roubado) |
| `state` | nenhum externo tem estados forenses; é diferencial do `vp_chopshop` | **REQUIRED NOW** |
| `sourceModel` | renzu guarda `model` na metadata (decorativo lá) | **REQUIRED NOW** (mas nunca placa — regra já no RFC) |
| `sourceSession` | ninguém externo tem; é anti-arbitragem (`cs:` de origem) | **USEFUL — manter.** Barato, e é o único elo de auditoria peça→desmanche. |
| `partId` (UUID individual) | — | **UNNECESSARY** para v1 — o stack por `(veículo,partType,state)` é o objetivo; UUID individual quebraria o empilhamento. USEFUL LATER só se houver "peça única rastreável". |
| `condition`/`quality` | `renzu_tuners` tem | **USEFUL LATER** — DEFER (KB §8). Adiciona superfície de balance/valuation/repair. |
| `compatibility` | renzu **não** checa (metadata decorativa) | **UNNECESSARY NOW** — o RFC não instala peça em carro; só processa para commodity. |
| `manufacturedAt`/`processedBatch` | — | **UNNECESSARY NOW** — o `processed` do RFC explicitamente perde rastro de lote (C.2). |

**Veredito:** a metadata do RFC está certa. Não adicionar campo.

## 4. Contrato de oficina (RFC §H)

O RFC §H (item+metadata versionados · eventos `PART_PROCESS_*` · exports `ConsumeCarParts`/`QueryCarParts`/`IssueLegalParts` · `bridge/workshop.lua` com adapters qs/qb/rcore/cd) **já é o desenho recomendado pela KB §GAP 4**. Externos relevantes (`renzu_engine`, `an-engineswap`) são STUDY para *quando* um adapter real for escrito (#17+), não antes.

Um ponto a checar em #17: os exports de `renzu`/`qs`/`qb` mechanic citados no RFC §H.2.4 são **estruturais** ("confirmar export real"). Isso continua verdade — não fixar nomes de export de terceiros até ter o resource-alvo do servidor definido.

## 5. Restart do processamento (RFC §E.2 / K.R5)

RFC aceita perda de sessão in-memory no restart, com a janela COMMITTING de ~1 frame como "risco idêntico ao já aceito no discard". O [RESTART_RECOVERY_STUDY](RESTART_RECOVERY_STUDY.md) §3 concorda: `ProcessSession` entra na **Regra 2** (sessões efêmeras podem ser perdidas). O output `car_parts processed` não tem barreira anti-dupe de operação terminal (não paga cash, não deleta entidade) → não precisa de DB tombstone. Coerente.

Uma nota: se algum dia o processamento envolver **múltiplos registros persistentes** (ledger + entitlement), aí sim `MySQL.transaction.await` (CommunityOx docs) entra — mas hoje não há.

---

## Conclusão

`PART_PROCESSING_RFC.md` **passa** no confronto externo sem mudança. A evidência de código reforça Modelo A e a autoridade server-side. Deliverable "D" da KB (confrontar RFC com externos) fica satisfeito por este documento — não precisa de arquivo separado maior. O próximo passo continua sendo: **RC verde primeiro**, depois PR #12.
