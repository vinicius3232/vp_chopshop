# MINIGAME_EXPANSION — vp_chopshop

**Status:** DESIGN CONGELADO — pronto para implementação em PRs pequenos
**Base:** branch atual pós-v1.18 · **Harness alvo:** manter 1983 PASS / 0 FAIL
**Referência de inspiração:** RareTeam *"[ESX/QB] Exhaust/Catalytic Robbery"* (script pago — **estudo clean-room, nada de código/asset copiado**; absorvemos só o fluxo e o *feel*: close-up → desparafusar → martelar).

---

## 0. Contexto — por que isto é barato

O stack de minigame físico (`client/minigame/`, UX-A..E, produção desde v1.16) já entrega tudo que precisamos:

- **`core.lua`** `VPChopDismantleMinigame.Start(vehicle, profileName, opts)` — câmera scriptada, geração de pontos 3D, projeção 3D→tela em loop, NUI, blindagem de cancelamento (ESC/morte/distância/timeout/`onResourceStop`). Retorna `true` só com 100% dos pontos.
- **`profiles.lua` + `profiles/*.lua`** — cada profile = `calculateCamera` + `generatePoints` + `toolClass`/`fov`/`minUxMs`/`reserveMs`. Cada ponto tem `primitive`, `holdTimeMs`/`neededDeg`, `label`.
- **`fallback.lua`** `VPChopMinigameFallback` — cai em `lib.skillCheck` se geometria/câmera falhar. Nunca trava.

### Primitivas que a NUI (`html/app.js`) já suporta

| primitive | interação | onde é usada hoje |
|---|---|---|
| `rotate` | segura clique + gira o mouse em círculo → acumula graus até `neededDeg` | roda (5 parafusos) |
| `cut` / `drill` / `hold` | segura o clique → preenche por tempo (`holdTimeMs`) | portas, capô, porta-malas, motor |
| `trace` | segue polilinha com o cursor, anti-cheese de velocidade/teleporte | carcaça |

Um profile é uma lista de pontos e **cada ponto pode ter primitive diferente** — é o que viabiliza "misturar" desparafusar + cortar num só minigame.

---

## 1. Decisões travadas

| # | Decisão | Escolha |
|---|---|---|
| 1 | Classe de ferramenta p/ martelo e lixa | **Gate de bancada** (proximidade + `InvCount(item) > 0` + `InvRemove`). NÃO promover classe nova no `shared/registry/tools.lua` — o split binário de `VPChopHasTool(src, wantDrill)` fica intacto. |
| 2 | Primitive do `serial_scratch` (lixa) | **Reusar `rotate`** — movimento circular = lixar. Zero mudança de NUI. |
| 3 | Primitive do `bench_teardown` (martelo) | **`strike` timing-click** — anel fechando; clica dentro da faixa-alvo; erro = sem progresso. É a única primitive nova. |
| 4 | Peça `state = 'legal'` na bancada | **Pula o minigame** — processa direto. Reforça a diferença mecânica legal × roubado. |
| 5 | Props (`prop_tool_hammer`, lixa) | Confirmar em jogo na implementação; ter fallback `IsModelInCdimage` como `spawnToolProp` já faz. |
| 6 | Ordem de entrega | (1) limpeza bolt morto → (2) `catalytic` → (3) `serial_scratch` → (4) `bench_teardown`. 4 PRs pequenos e testáveis. |

---

## 2. PR-1 — Limpeza do `runBoltSurface` morto

Pré-requisito das demais (tira ruído da área). **Comportamento em jogo não muda** — roubo de roda já usa o stack novo; roubo de placa já cai em `lib.skillCheck` desde a RC-FIX-2 (v1.15).

`stream/` + `data_file 'DLC_ITYP_REQUEST'` + `bolt.ydr` + `wheel_spacer.ytyp` (pacote pago `ls_bolt_minigame`) **já foram removidos** (`[P0.2b] stream/ removido por completo`, comentário no `fxmanifest.lua`). Resta só o Lua:

| Arquivo | Ação |
|---|---|
| `client/main.lua` ~910–1225 | deletar o bloco inline: `VPChopBoltMinigameFallback`, `runBoltSurface`, `VPChopBoltMinigame`, `VPChopPlateBoltMinigame` |
| `client/main.lua` ~2273 | deletar `VPChopRunBoltMinigame` (zero callers — confirmado por grep) |
| `client/main.lua` `runWheelUx` ~1322–1331 | `VPChopDismantleMinigame` está sempre presente (mesmo manifest). Remover o `else VPChopBoltMinigame(veh, wheelIdx)`; o novo `else` (defensivo) chama `_G.VPChopMinigameFallback(veh, boneKey, 'no_stack')` |
| `client/plates.lua` ~106–118 | remover o ramo `Config.Plates.Bolt3D` / `VPChopPlateBoltMinigame`; fica só o `lib.skillCheck` (`Config.Plates.SkillCheck`) |
| `shared/config.lua` ~475–479 | remover bloco `Config.Plates.Bolt3D` |
| `shared/config.lua` ~1048–1052 | remover bloco `Config.Jackstand.Minigame.Bolt3D` |
| `shared/locale.lua` | remover key órfã `bolt_minigame_help` (en/pt/es/fr/tr) |
| `README.md` / `README_pt.md` | remover parágrafos do Bolt3D (~609/623 e ~644/658) |

**Teste:** roubar roda via macaco (minigame de 5 parafusos entra normal), roubar placa frente e trás (skillcheck entra normal). Harness verde.

---

## 3. PR-2 — Profile `catalytic` (desparafusar + cortar, num só minigame)

### 3.1 Novo arquivo `client/minigame/profiles/catalytic.lua`

Espelha o padrão de `profiles/engine.lua`. Pontos mistos:

```
eng-style helper resolveExhaustData(vehicle):
  bone 'exhaust' → fallback 'exhaust_2' → fallback 'chassis' → GetOffsetFromEntityInWorldCoords(veh, 0, -2.2, 0.1)

generatePoints:
  cat_clamp_f   primitive 'drill'  holdTimeMs 1600   "BRAÇADEIRA DIANT."
  cat_clamp_r   primitive 'drill'  holdTimeMs 1600   "BRAÇADEIRA TRAS."
  cat_pipe_f    primitive 'cut'    holdTimeMs 2200   "TUBO DIANTEIRO"
  cat_pipe_r    primitive 'cut'    holdTimeMs 2200   "TUBO TRASEIRO"

calculateCamera: close por baixo/atrás do bone exhaust, FOV ~44
Profiles.list.catalytic = { title='FURTO DE CATALISADOR', toolClass='cut',
  fov=44, minUxMs=4500, reserveMs=4000, calculateCamera=..., generatePoints=... }
```

Adicionar `'client/minigame/profiles/catalytic.lua'` ao `fxmanifest.lua` **antes** de `client/minigame/profiles.lua` (mesmo padrão de panels/engine/carcass).

### 3.2 Integração em `doStealCatalytic` (`client/main.lua` ~1911)

O fluxo server-authoritative **não muda**: `catalytic:start` (token + `durationMs`) → UX → `catalytic:complete` (retorna `entitlementId`). Só troca o miolo:

- **Remover:** os 2 blocos `lib.progressBar(catalytic_cutting_stage_1/2)` + `lib.skillCheck` (etapa 1 e 2).
- **Colocar:**
  ```lua
  local ok = false
  if VPChopDismantleMinigame and VPChopDismantleMinigame.Start then
      ok = VPChopDismantleMinigame.Start(veh, 'catalytic', {
          boneKey = 'exhaust',
          timeout = startRes.durationMs or 20000,
      })
  else
      ok = _G.VPChopMinigameFallback(veh, 'exhaust', 'catalytic_no_stack')
  end
  if not ok then
      cleanupTheft(true)  -- já dispara VPChopCatalyticShouldDispatch + catalytic:cancel
      return
  end
  ```
- **Preservar como está:** `spawnToolProp` (serra), faíscas `ent_dst_sparking_wires` no bone `exhaust`, `VPChopCatalyticShouldDispatch` no fail e no sucesso, `spawnCarriedPartInHands('catalytic_converter', veh, res.entitlementId)` no fim.
- O timer server-side (`catalytic:start` retorna `durationMs`) continua sendo o gate real de tempo mínimo; o minigame só precisa caber nele (`minUxMs` + `reserveMs`).

### 3.3 Config

`Config.CatalyticTheft.Minigame` hoje tem `{ Enable, Stages, Difficulty, Inputs }` (formato skillCheck). Trocar por:
```lua
Minigame = {
    Enable = true,       -- false → cai em VPChopMinigameFallback (skillCheck)
    Profile = 'catalytic',
}
```
Manter `Config.CatalyticTheft.Anim` / `SparksVfx` / `PoliceAlertChance` / `PoliceAlertOnFail`.

### 3.4 NUI

**Zero mudança** — `drill` e `cut` já existem.

### 3.5 Custo

1 profile (~90 linhas) + 1 linha no manifest + ~20 linhas em `doStealCatalytic` + ajuste de 1 bloco de Config. **Server: nada.**

---

## 4. PR-3 — Profile `serial_scratch` (lixar o serial — reusa `rotate`)

Hoje "riscar série" (`Config.PartSerial.ScratchTier`, default 2) é opção **instantânea** no menu da bancada (`client/partserial.lua` → callback `vp_chopshop:serial:scratch` em `server/partserial.lua`). Vira minigame físico.

### 4.1 Novo arquivo `client/minigame/profiles/serial_scratch.lua`

```
Profiles.list.serial_scratch = {
    title    = 'ADULTERAR NÚMERO DE SÉRIE',
    helpText = 'Segure o clique e faça movimentos circulares para lixar o número',
    toolClass = nil,          -- gate é o item de bancada (decisão 1), não uma tool do registry
    fov = 40, minUxMs = 4000, reserveMs = 3000,
    calculateCamera = <close na área do serial: peça na bancada ou nas mãos>,
    generatePoints = function()
        return {
            { id = 'serial_1', primitive = 'rotate', neededDeg = 900.0, label = 'GRAVAÇÃO' },
            { id = 'serial_2', primitive = 'rotate', neededDeg = 720.0, label = 'RESÍDUO' },
        }
    end,
}
```

Câmera: se a peça estiver carregada nas mãos, usa offset do bone da mão; se estiver largada na bancada, close no prop. (Definir na implementação qual dos dois fluxos — provavelmente "na bancada", alinhado com o teardown.)

### 4.2 Integração

No handler da opção "riscar série" (`client/partserial.lua`):
```lua
-- gate de bancada (decisão 1): proximidade + item
if InvCount('sandpaper') < 1 then notify('sem lixa'); return end
local ok = VPChopDismantleMinigame.Start(nil, 'serial_scratch', { timeout = ... })
   or _G.VPChopMinigameFallback(nil, nil, 'serial_no_stack')
if not ok then return end
-- callback existente:
lib.callback.await('vp_chopshop:serial:scratch', false, <args atuais>)
```
`VPChopDismantleMinigame.Start` aceita `vehicle = nil`? **Verificar** — hoje faz `DoesEntityExist(vehicle)` logo no início. Se não aceitar, adicionar um modo "sem veículo" no `core.lua` (câmera relativa ao ped, sem checagens de distância a veículo). Alternativa: passar o **prop da peça** como "entidade" no lugar do veículo.

### 4.3 Server (`server/partserial.lua`)

Sem mudança de lógica. Opcional: aceitar um flag do minigame como o `action_session` faz nas fases avançadas — mas como scratch é local à bancada e barato, o gate de proximidade server-side que já existe basta. Consumo do item `sandpaper`: `InvRemove` no callback (server), não no client.

### 4.4 Item novo

`sandpaper` (ou `metal_file`) — registrar em `ox_inventory/data/items.lua` + `installation/ox_items_snippet.txt`. Som: `Config.ChopSounds.grinder` (já existe). Prop na mão: modelo base game de lixa/lixadeira (confirmar).

### 4.5 NUI

**Zero mudança** (`rotate` já existe). Cosmético opcional: quando `toolClass` indicar lixa, trocar o glyph do hotspot (`&#9881;` → outro). Não-bloqueante.

---

## 5. PR-4 — Profile `bench_teardown` (martelar peça roubada — primitive `strike` nova)

### 5.1 Gameplay

Peça roubada (`door`, `bonnet`, `boot`, `adv_engine`, `catalytic_converter`) largada na bancada → em vez de processar direto, o jogador **martela pra abrir/separar** antes de extrair materiais/`car_parts`.

- **Só entra** se `state ∈ { stolen, scratched, forged }`. `state == 'legal'` → processa direto, sem minigame (decisão 4).
- Prop de martelo na mão, som `chopshop_pneumatic_hammer.ogg` (**asset já existe** em `sounds/`) por golpe, leve shake de câmera.

### 5.2 Primitive `strike` — a única mudança de NUI

**`html/app.js`** — novo ramo em `startMinigame` + handler:

- Hotspot mostra um **anel externo fixo** + um **anel interno que fecha** (de raio grande → pequeno, loop, ~900ms por ciclo).
- Faixa-alvo: quando o anel interno está entre `r_target ± tol` (ex.: 40–55% do raio externo), o hotspot fica "armado" (cor verde).
- **Clique dentro da faixa** → +1 golpe (`hitsNeeded` config, ex.: 4). **Clique fora** → sem progresso, feedback vermelho rápido (sem penalidade de progresso — decisão: timing-click, não punitivo demais).
- `pt.progress = hits / hitsNeeded * 100`; ao chegar a 100 → `completePoint(pt)` (mesmo caminho dos outros).
- `postNui('minigamePointComplete', {id})` a cada golpe pra o Lua tocar o som + shake (o `core.lua` já escuta `minigamePointComplete` e toca `Pin_Good` — trocar por som de martelada quando `profile.toolClass == 'strike'`... ou passar um campo `soundOnHit` no profile).

**`html/style.css`** — `.primitive-strike`, `.strike-ring-outer`, `.strike-ring-inner`, `.strike-armed`, `.strike-miss` (~30 linhas).

Estimativa: ~50 linhas JS + ~30 CSS. `app.js` é bem isolado (IIFE, um dispatcher de mensagens) — baixo risco.

### 5.3 Novo arquivo `client/minigame/profiles/bench_teardown.lua`

```
Profiles.list.bench_teardown = {
    title = 'DESMONTE NA MARRETA',
    helpText = 'Clique no ritmo, quando o anel entrar na zona',
    toolClass = 'strike',   -- consumido como marcador de som/anim; gate real = item de bancada
    fov = 42, minUxMs = 5000, reserveMs = 3000,
    calculateCamera = <close na peça sobre a bancada>,
    generatePoints = function(prop)  -- prop = handle da peça largada
        return {
            { id='strike_1', primitive='strike', hitsNeeded=4, label='SOLDA / TRAVA 1' },
            { id='strike_2', primitive='strike', hitsNeeded=4, label='SOLDA / TRAVA 2' },
            { id='strike_3', primitive='strike', hitsNeeded=5, label='ABERTURA' },
        }
    end,
}
```

### 5.4 Integração + Server

- `client/bench.lua` / `client/partserial.lua` (handler de processar peça na bancada): antes de `lib.callback.await('vp_chopshop:benchProcessPart', ...)`, checar `state` da peça carregada. Se roubada → gate de bancada (`InvCount('hammer') > 0` + proximidade client) + `VPChopDismantleMinigame.Start(prop, 'bench_teardown', {...})`. Fail → aborta, não chama o callback.
- **`server/bench.lua`** já valida distância + faz rollback atômico de inventário. Encaixar no padrão `server/session/action_session.lua` (START → UX → COMPLETE) para o servidor não confiar no "minigame passou" vindo puro do client — **igual às fases avançadas de chop**. Item `hammer` consumido via `InvRemove` no server.
- Peça `legal`: pula tudo isso, cai direto no `benchProcessPart` como hoje.

### 5.5 Item novo

`hammer` — `ox_inventory/data/items.lua` + snippet. Prop `prop_tool_hammer` (confirmar) ou `prop_w_me_hatchet` como fallback temático.

---

## 6. Riscos / pontos de atenção

- **`core.lua` sem veículo:** `serial_scratch` e `bench_teardown` operam sobre uma **peça** (prop), não um veículo. `VPChopDismantleMinigame.Start` hoje exige `DoesEntityExist(vehicle)` e faz gate de distância a veículo no loop. Precisa de um "modo peça": passar o prop como entidade e trocar o gate de distância por distância à bancada / ao ped. ~15 linhas no `core.lua`, sem quebrar os profiles de veículo.
- **Anti-cheat server-side:** `catalytic` já é coberto pelo token temporal de `catalytic:start`. `bench_teardown` e `serial_scratch` **têm** que passar pela `ActionSession` (ou pelo menos por um gate de proximidade + cooldown server-side), senão um cheater pula o minigame e chama o callback direto. Não confiar no retorno booleano do client.
- **Tédio:** servidor pequeno / horário vazio. `minUxMs` conservador (4–6s), `hitsNeeded` baixo. Peça legal pulando o teardown já ajuda. Reavaliar in-game.
- **Props:** validar todos os modelos com `IsModelInCdimage` (o `spawnToolProp` já tem esse fallback pattern) antes de assumir.
- **NUI regression:** só o PR-4 toca `app.js`/`style.css`. Testar os 4 profiles antigos (roda/portas/motor/carcaça) depois da mudança.

---

## 7. Checklist de entrega por PR

- [x] **PR-1** limpeza bolt morto — feito na branch `chore/pr1-remove-dead-boltsurface` (commit `e9f2a74`). Grep limpo, harness 1983/0. **Falta:** teste in-game (roubar roda + placa) antes de merge.
- [x] **PR-2** `catalytic` — branch `feat/pr2-catalytic-profile`. Profile novo (2 `drill` + 2 `cut`), fxmanifest + `tools/run_spec.lua` + `minigame_spec.lua` (expectedProfiles), `doStealCatalytic` trocado (minigame + espera do piso `minMs` antes do `complete` p/ evitar `too_fast`), `Config.CatalyticTheft.Minigame` = `{Enable, Profile}`. Harness 1990/0. **Falta:** teste in-game. Locale órfão `catalytic_cutting_stage_1/2` deixado (5 idiomas).
- [x] **PR-3** `serial_scratch` — branch `feat/pr3-serial-scratch-minigame`. Profile `rotate`, item `sandpaper` (consumido em `serial:scratch`, gate no `canInteract` + `benchAvailability`), `doScratch()` trocado, Config `SandpaperItem`+`ScratchMinigame`, locale `serial_no_sandpaper` (5 idiomas), ox_items snippet. **`core.lua` NÃO precisou de "modo peça"** — passamos `cache.ped` como entidade (passa em todos os gates do core). Harness 1997/0. **Falta:** teste in-game + registrar `sandpaper` no `ox_inventory/data/items.lua`.
- [x] **PR-4** `bench_teardown` — branch `feat/pr4-bench-teardown-strike`. Primitive `strike` nova (`html/app.js` +89 / `style.css` +42): anel que fecha, clique na zona verde, N golpes/ponto, erro não pune. Profile `bench_teardown`, item `hammer`. **Anti-cheat: token temporal `bench:teardownStart` + `too_fast` em `benchProcessPart`** (padrão do catalisador, NÃO ActionSession — evitou refactor grande). Peça `catalytic_converter` isenta (já cortada no PR-2). Som `chopshop_pneumatic_hammer.ogg` + `CamCtrl.Jolt` (novo, shake ~180ms) por golpe. Harness 2004/0. **Falta:** teste in-game + registrar `hammer` no ox_inventory + confirmar `prop_tool_hammer`.
- [x] Bump `CHANGELOG.md` (1.19.0) + `fxmanifest.lua` + READMEs.

### Entrega final

Os 4 PRs foram **squashados numa única branch `feat/minigame-expansion`** (commit
`78797af`, 23 arquivos, +1216/−570), direto sobre `docs/post-v118-future-roadmap-prep`.
As branches intermediárias (`chore/pr1-…`, `feat/pr2-…`, `feat/pr3-…`, `feat/pr4-…`)
foram apagadas. Harness **2004 PASS / 0 FAIL**. Stub de `Config` do `tools/run_spec.lua`
sincronizado com a nova forma de `CatalyticTheft.Minigame` (era `{Stages,Difficulty,Inputs}`).

**Testes feitos:** harness completo (2004/0), `luac -p` em todos os `.lua` alterados
(config/main via conversão do literal joaat), `node --check html/app.js`, sweep estático
(zero ref viva ao bolt legado, 3 profiles registrados em fxmanifest+run_spec, locale keys
presentes nos 5 idiomas, ordem de símbolos no server OK).

**Testes que faltam (só possíveis em jogo, servidor rodando):**
- Registrar `sandpaper` e `hammer` no `ox_inventory/data/items.lua` (snippet em `installation/`)
- Roubar roda + placa (regressão do PR-1) · furto de catalisador (PR-2) · riscar série na
  bancada (PR-3) · desmontar peça roubada na marreta (PR-4, inclui a NUI nova)
- Confirmar `prop_tool_hammer` no base game
- Regressão dos 4 profiles antigos (roda/portas/motor/carcaça) após a mudança no `app.js`
