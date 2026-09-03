# Minigame Expansion — LIVE QA (v1.18.2 + FIX-1)

**Data:** 2026-09-03
**Branches:** `feat/minigame-expansion` (leva PR-2→4, merge `71d56e2`) + `fix/minigame-expansion-hardening` (FIX-1)
**Harness estático:** `lua tools/run_spec.lua .` → **0 FAIL**
**Referência de fluxo geral:** `docs/audit/RC_QA_TASKLIST.md` · `docs/audit/V116_INTEGRATION_QA.md`

Deploy num servidor QBox real. Este doc é o **subconjunto que mudou** com a expansão de minigames.

## Pré-requisitos

- [ ] `sandpaper` e `hammer` registrados no `ox_inventory/data/items.lua` (`hammer` já
  incluído; `sandpaper` já existia como "Lixa")
- [ ] Prop `prop_tool_hammer` existe no build (senão o minigame roda sem prop na mão — não bloqueia)
- [ ] `xsound` opcional (som de martelada usa `xsound`; sem ele, cai em `PlaySoundFrontend`)
- [ ] Itens de teste no inventário: `saw_pro`, `mechanic_drill`, `sandpaper` ×5, `hammer` ×5,
  `chopshop_jackstand`, `chopshop_bench`, `chopshop_welder`

---

## MG-A — Catalytic (PR-2 + FIX-1)

| # | Passo | Esperado |
|---|---|---|
| A1 | Estacionar um **sedan** na rua, sair do carro, mirar o **escapamento** com ox_target | opção "furtar catalisador" aparece **só no bone do escapamento** (não some ao mirar a lateral/teto) |
| A2 | Selecionar → minigame abre | câmera **por baixo/atrás** do carro; 2 pontos `drill` (braçadeiras) + 2 `cut` (tubos); faíscas no escapamento |
| A3 | Completar os 4 pontos rápido (spam) | ao terminar, **não** dá `too_fast` — o client espera o piso `ProgressMs`; catalisador cai na mão |
| A4 | Repetir com **SUV**, **pickup**, **sports/super** | idem A1–A3; câmera coerente em cada silhueta |
| A5 | Veículo **sem `exhaust_2/3/4`** (só `exhaust` ou nenhum) | A1: target ainda aparece se há `exhaust`; se **nenhum** bone de escapamento → target **não** aparece (esperado) |
| A6 | Cancelar no meio (ESC) | minigame fecha, `catalytic:cancel` disparado, sem catalisador, sem consumo; dispatch de polícia conforme `PoliceAlertOnFail` |
| A7 | Falhar o minigame (timeout) | idem A6 |
| A8 | Vender o catalisador no fence / processar na bancada | pagamento/materiais normais (economia inalterada) |

## MG-B — Serial scratch (PR-3)

| # | Passo | Esperado |
|---|---|---|
| B1 | Ter uma `car_parts` **stolen** + `sandpaper` no inventário, ir à bancada | opção "riscar série" aparece **só** com peça elegível + lixa + tier ≥ `ScratchTier` |
| B2 | Sem `sandpaper` no inventário | opção **não** aparece; se forçar o callback → `no_sandpaper` |
| B3 | Selecionar → minigame de **lixar** (girar o mouse em círculo, 2 pontos) | câmera nas mãos; ao completar → série apagada, peça vira `scratched`, **1× `sandpaper` consumido** |
| B4 | Perícia da polícia na peça resultante | "série riscada / adulterada" |
| B5 | Cancelar no meio | nada consumido, peça intacta |
| B6 | `Config.PartSerial.ScratchMinigame.Enable = false`, restart | cai na `lib.progressBar` de 5 s (sem stack de minigame) |

## MG-C — Bench teardown / marreta (PR-4 + FIX-1)

| # | Passo | Esperado |
|---|---|---|
| C1 | Chopar uma **porta** (Fase 2), carregar nos braços, ir à bancada com `hammer` | ao processar → **minigame de marreta** antes (não vai direto pro `progressBar`) |
| C2 | Sem `hammer` | erro `bench_teardown_no_hammer`; não abre minigame |
| C3 | Jogar o minigame: anel vermelho fecha/reabre; clicar na **zona verde** | acerto = golpe conta (fica verde), toca **martelada** + **solavanco de câmera**; N golpes/ponto |
| C4 | Clicar **fora** da zona | "miss" visual, **progresso não regride** |
| C5 | Completar → peça processada | materiais/`car_parts` normais; **`hammer` consumido exatamente 1×** |
| C6 | **Inventário cheio** ao completar o minigame | retorno `inventory_full`; **`hammer` NÃO consumido** (FIX-1) |
| C7 | Cancelar o minigame (ESC) | `bench:teardownCancel`; nada consumido; peça continua nos braços |
| C8 | Terminar o minigame muito rápido | `too_fast` no `benchProcessPart`? — o client espera o piso `MinDurationMs`, não deve ocorrer |
| C9 | Repetir o `benchProcessPart` com o **mesmo token** (replay) | 2ª chamada → `teardown_required`; **sem 2º processamento**, sem 2º consumo |
| C10 | Deixar o token **expirar** (>`MinDurationMs`+20 s parado) e completar | `expired`, fail-closed; `hammer` intacto |
| C11 | **Motor** (`adv_engine`) e **catalisador** carregados | motor: exige marreta; **catalisador: NÃO exige** (isento — já foi cortado no furto) |
| C12 | Peça `legal` (via `IssueLegalParts` / vendedor legal) na bancada | processa **sem** minigame (peça legal nunca entra no fluxo de carga física) |

## MG-D — Regressão dos minigames antigos (mudança no `app.js`)

| # | Passo | Esperado |
|---|---|---|
| D1 | Levantar carro no macaco, roubar **roda** (5 parafusos, girar mouse) | funciona igual à v1.16 |
| D2 | Fase 2: cortar **porta / capô / porta-malas** (segurar o clique, `cut`) | idem |
| D3 | Fase 3: **motor** (4 calços, `drill`) | idem |
| D4 | Fase 4: **carcaça** (5 traçados `trace`, maçarico, auto-pan de câmera) | idem — a primitive `trace` não foi tocada |
| D5 | Roubo de **placa** (frente e trás) | `lib.skillCheck` (desde a RC-FIX-2) — inalterado |
| D6 | Rodar tudo isso com resmon aberto | sem regressão de performance na NUI (a `strikeLoop` só roda quando há ponto `strike`) |

## MG-E — Validação espacial dos targets (FIX-1)

Para cada target, aproximar/afastar e confirmar que a distância "sente" igual à v1.16
(valores em `Config.TargetDistances`): `catalytic` 2.0 · `advDoor` 2.5 · `engine` 3.0 ·
`carcass` 3.5 · `jackLower` 3.5 · `baseDismantle` 3.0 · `discard` 3.5 · `wheel` 3.0.

| # | Target | Esperado |
|---|---|---|
| E1 | catalytic (escapamento) | pega perto do escapamento; **não** pega mirando o teto/porta |
| E2 | adv doors / engine / carcass | mesmo alcance de antes |
| E3 | jack lower / base dismantle / discard | mesmo alcance de antes |
| E4 | Editar `Config.TargetDistances.catalytic = 1.2`, restart | alcance encurta (config funciona) |

## MG-F — Comportamento de fallback

| # | Cenário | Esperado |
|---|---|---|
| F1 | `VPChopDismantleMinigame` ausente (stack não carregou) | catalytic/serial/teardown caem em `VPChopMinigameFallback` (`lib.skillCheck`) ou `progressBar`, sem travar |
| F2 | `xsound` parado | martelada usa `PlaySoundFrontend`, sem erro |
| F3 | Câmera falha ao criar (`CamCtrl.Create` = false) | `VPChopMinigameFallback` |
| F4 | Profile sem pontos (bug de geometria) | `VPChopMinigameFallback` |

## Cenários transversais

| # | Cenário | Esperado |
|---|---|---|
| X1 | **Restart do resource** no meio de um minigame | `onResourceStop` limpa NUI, câmera, props; nenhuma entidade órfã |
| X2 | Jogador **desconecta** durante teardown | `_benchTeardowns[src]` limpo no `playerDropped` |
| X3 | Dois jogadores desmontando na mesma bancada | tokens por `src`, sem colisão |
| X4 | **inventory full** em cada minigame que dá item | rollback correto; item de gate (`sandpaper`/`hammer`) só consumido no commit |
| X5 | **Sem `hammer`** / **sem `sandpaper`** | opção não aparece; callback recusa com a chave de locale certa |

---

## Critério de aprovação

- MG-A..MG-F sem falha funcional.
- Economia idêntica à v1.18.1 (payouts, materiais, XP, trust).
- 0 entidade/prop órfão após qualquer cancel/restart.
- `hammer`/`sandpaper` nunca consumidos em caminho de erro.
