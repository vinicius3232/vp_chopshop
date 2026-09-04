# Minigame Expansion — LIVE QA (v1.18.2 + FIX-1 + FIX-1.1 + FIX-1.2/1.3 + VISUAL)

**Plano criado:** 2026-09-03 · **Última revisão:** 2026-09-04
**Branch final:** `fix/minigame-expansion-hardening-rc11` — PR #55, base
`docs/post-v118-future-roadmap-prep` (`7023079`), HEAD `42df3ea`.
**Harness estático (HEAD `42df3ea`):** `lua tools/run_spec.lua .` → **2159 PASS / 0 FAIL**
(FIX1-TXN-* exercem `server/logistics/bench_txn.lua` real, não mock).
**Referência de fluxo geral:** `docs/audit/RC_QA_TASKLIST.md` · `docs/audit/V116_INTEGRATION_QA.md`

Deploy num servidor QBox real. Este doc é o **subconjunto que mudou** com a expansão de minigames.

> **Nota de escopo:** as tabelas MG-A / MG-C abaixo descrevem os fluxos das PRs 2–4 +
> FIX-1.1. A partir da FIX-1.2/1.3 o **furto de catalisador na rua** virou 4 porcas
> `rotate` + 2 golpes `strike` (jogador deitado), e o **desmonte na bancada** passou por
> peça física + `bench_catalytic` e, na revisão final, por **1 traçado com maçarico no
> contorno** com **gate de máquina de solda**. Ver `## RESULTADO — 2026-09-04`.

---

## RESULTADO — 2026-09-04 (branch `fix/minigame-expansion-hardening-rc11`, HEAD `42df3ea`)

**Estático (reproduzível):**

| Verificação | Resultado |
|---|---|
| `lua tools/run_spec.lua .` | **2159 PASS / 0 FAIL** |
| `luac -p` nos `.lua` alterados (backtick-stripped) | OK |
| `node -c html/app.js` | OK |
| GitHub Actions `harness` no HEAD | verde |
| `Config` economy diff vs base (`7023079`) | **sem drift** (só `TargetDistances` = RC parity + `ProgressMs` timing) |
| PR #52 (`feat/v1.18-rc-forensics-gate` @ `03838d63`) | intacta, não mergeada |

**In-game (servidor QBox real do owner):** o owner (`vinicius3232`) rodou os fluxos
abaixo e reportou **"todos os testes OK"** em 2026-09-04. Sign-off por confirmação
do owner — não há matriz per-caso individualmente logada.

| Fluxo | Owner-testado | Passou | Obs |
|---|---|---|---|
| Furto de catalisador na rua (4 porcas + 2 golpes, deitado, cai na mão) | sim | sim | iterado até o feel/anim ficarem certos |
| Painel de série (`serial_scratch`, lixa livre sobre a plaqueta) | sim | sim | plaqueta = visual; estado/refund seguem server-side |
| Peça física na bancada (colocar / pegar de volta / menu 2 níveis) | sim | sim | in-memory, some no restart (esperado) |
| Desmonte do catalisador na bancada — **maçarico no contorno** | sim | sim | traçar → carcaça abre → vira sucata |
| Gate de máquina de solda (sem solda perto → não abre + notifica) | sim | sim | `err='no_welder'` server + pré-check client |
| NUI limpa (sem badge/marcador de versão, sem debug visual) | sim | sim | badge de diagnóstico removido em `42df3ea` |
| Cancel / restart no meio (sem prop/entidade órfão) | sim | sim | — |
| `hammer` / `sandpaper` só consumidos no commit | sim | sim | coberto também por `FIX1-TXN-*` (estático) |
| Economia (payout / materiais) idêntica | sim | sim | confirma o diff estático |

**P0:** 0 · **P1:** 0 · **P2:** (1) matriz per-caso não foi logada individualmente —
o sign-off é do owner "em bloco"; (2) `exhaust_bolt_thread.png` órfão no repo
(a rua usa head/washer/hole; a bancada não usa mais fixação visual); (3)
`bench_catalytic` panel bolt/knock builder em `html/app.js` virou caminho morto
(profile só gera `trace`) — não quebra nada, limpeza futura.

---

## Pré-requisitos

- [ ] `sandpaper` e `hammer` registrados no `ox_inventory/data/items.lua` (`hammer` já
  incluído; `sandpaper` já existia como "Lixa")
- [ ] Prop `prop_tool_hammer` existe no build (senão o minigame roda sem prop na mão — não bloqueia)
- [ ] `xsound` opcional (som de martelada usa `xsound`; sem ele, cai em `PlaySoundFrontend`)
- [ ] Itens de teste no inventário: `/choptest` (ACE `command.chopshop_admin`) entrega o
  kit completo — `chopshop_bench`, `chopshop_welder`, todas as serras/`mechanic_drill`
  de `Config.Tools`, `chopshop_jackstand`, **`hammer` ×5** e **`sandpaper` ×5**
  (FIX-1.2). `/choptest <id>` entrega a outro jogador.

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
| B7 | (FIX-1.1) Forçar falha do `SetMetadata` (ex.: dropar a peça no exato instante) | callback retorna `scratch_failed`; **1× `sandpaper` devolvido** (log `Rollback da lixa`); sem double-refund |
| B8 | (FIX-1.1) Completar normal e reperícia | releitura server-side confirma `state == 'scratched'`; peça riscada de verdade |

## MG-C — Bench teardown / marreta (PR-4 + FIX-1 + FIX-1.1)

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
| C13 | (FIX-1.1) Modo inválido p/ peça (catalisador + `clean_serial` forjado no client) | `invalid_mode_for_part` **antes** do consumo do hammer — `hammer` intacto |
| C14 | (FIX-1.1) Simular `PartEntitlement.Consume` falhar após o golpe + `InvAdd` do refund falhar | retorno `refund_failed` (não `ok`); log `CRITICAL: hammer refund FAILED` + `LogSuspicious hammer_refund_failed`; **sem 2ª peça / sem payout** |

## MG-D — Regressão dos minigames antigos (mudança no `app.js`)

| # | Passo | Esperado |
|---|---|---|
| D1 | Levantar carro no macaco, roubar **roda** (5 parafusos, girar mouse) | funciona igual à v1.16 |
| D2 | Fase 2: cortar **porta / capô / porta-malas** (segurar o clique, `cut`) | idem |
| D3 | Fase 3: **motor** (4 calços, `drill`) | idem |
| D4 | Fase 4: **carcaça** (5 traçados `trace`, maçarico, auto-pan de câmera) | idem — a primitive `trace` não foi tocada |
| D5 | Roubo de **placa** (frente e trás) | `lib.skillCheck` (desde a RC-FIX-2) — inalterado |
| D6 | Rodar tudo isso com resmon aberto | sem regressão de performance na NUI (a `strikeLoop` só roda quando há ponto `strike`) |

## MG-E — Validação espacial dos targets (FIX-1.1 / RC parity)

Valores CONGELADOS do HEAD `03838d63` da PR #52 (`Config.TargetDistances`):
`catalytic` **1.4** · `advDoor` **1.5** · `engine` **1.6** · `carcass` **2.0** ·
`jackLower` **2.2** · `baseDismantle` **2.0** · `discard` **2.2** · `wheel` **1.5**.
Para cada target, aproximar/afastar e confirmar que o alcance "sente" igual à RC v1.15.

| # | Target | Esperado |
|---|---|---|
| E1 | catalytic (escapamento) | pega colado no escapamento (~1.4 m); **não** pega mirando o teto/porta |
| E2 | adv doors (1.5) / engine (1.6) / carcass (2.0) | alcance curto de RC; nada de 2.5/3.0/3.5 |
| E3 | jack lower (2.2) / base dismantle (2.0) / discard (2.2) / wheel (1.5) | idem RC |
| E4 | Editar `Config.TargetDistances.catalytic = 1.2`, restart | alcance encurta (config funciona) |

### MG-E engine bone locator (FIX-1.1 — porte da PR #52)

| # | Cenário | Esperado |
|---|---|---|
| E5 | Veículo com bone `engine` | target do motor ancora no `engine` (opção aparece sobre o motor) |
| E6 | Veículo sem `engine` mas com `bonnet` | target ancora no `bonnet` (fallback) |
| E7 | Veículo sem `engine` e sem `bonnet` | target do motor SEM bone (aparece pela proximidade, comportamento antigo) — nunca some nem crasha |

### MG-E catalytic exhaust bone parity (FIX-1.1)

Locator de `ox_target` continua **só** `exhaust`/`exhaust_2`/`exhaust_3`/`exhaust_4`
(sem `chassis`). A câmera do minigame tem o fallback extra `chassis` → offset.

| # | Cenário | Esperado |
|---|---|---|
| E8 | Veículo só com `exhaust_3` (sem `exhaust`/`_2`) | opção aparece no `exhaust_3`; câmera do minigame enquadra o escapamento |
| E9 | Veículo só com `exhaust_4` | idem no `exhaust_4` |
| E10 | Veículo sem nenhum bone de escapamento | opção de `ox_target` **não** aparece; (se forçado) a câmera cai no chassis/offset sem crash |

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
