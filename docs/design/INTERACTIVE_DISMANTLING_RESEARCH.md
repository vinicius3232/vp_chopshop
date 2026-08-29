# Research — referências para o Interactive Dismantling

> **Status:** RESEARCH / STUDY ONLY. Nenhuma linha de código runtime nesta etapa.
> **Baseline:** branch `pr-h/v1.15-delivercar-terminal-hardening`.
> **Gate:** este documento não concede GO para a Fase 2. Implementação bloqueada até
> QA Q1–Q4 (`../audit/V116_INTEGRATION_QA.md`) fecharem sem P0/P1.
> Companheiro: [`INTERACTIVE_DISMANTLING.md`](INTERACTIVE_DISMANTLING.md) (o design).
> Ver também [`WHEEL_BOLT_MINIGAME.md`](WHEEL_BOLT_MINIGAME.md).

Todas as referências externas foram usadas **apenas para estudo de comportamento,
UX, matemática e técnicas genéricas de plataforma**. Nada de porte, cópia de código,
cópia de estrutura de funções, nomes internos ou assets. A implementação do
`vp_chopshop` será original e aderente à arquitetura própria (servidor autoridade,
Part Registry declarativo, ActionSession/ChopSession).

---

## 0. Sumário de decisão (ADOPT / STUDY / REJECT)

| Conceito | Origem | Veredito | Nota |
|---|---|---|---|
| Projeção `world→screen` + acúmulo de movimento real do mouse por parafuso | **`runBoltSurface` interno** | **ADOPT** | já é o nosso baseline; generalizar |
| `DrawMarker` como fallback quando não há modelo | interno | **ADOPT** | minigame nunca cai silencioso no skillCheck |
| Degradar para `lib.skillCheck` quando nada projeta > 2.5 s | interno (RC-FINDING-01) | **ADOPT** | anti-tela-invisível |
| N parafusos radiais `2π/N` (cos/sin em raio pequeno) | filo_bolt + interno | **ADOPT (conceito)** | trig genérica |
| `AttachEntityToEntity` no wheel bone (segue o carro sem loop de tracking) | filo_bolt | **ADOPT (conceito)** | hoje o `runBoltSurface` re-projeta por frame; attach é upgrade |
| Câmera roteirizada contextual + esconder ped | filo_bolt + interno | **ADOPT** | já fazemos |
| Outline no elemento sob foco / cursor contextual | filo_bolt | **ADOPT (conceito)** | melhora leitura; hoje só temos marker+opacidade |
| `oneAtATime` opcional | filo_bolt | **ADOPT (opcional/config)** | ritmo |
| Parafuso caindo com física ao concluir | filo_bolt + interno | **ADOPT** | já temos `SetEntityVelocity` outward |
| Menu de peças por `World3dToScreen2d` em bones nomeados | **`offload_carmenu`** | **STUDY** | boa técnica de "apontar a peça"; mas é NUI-driven, ver §3 |
| Seleção de zona/porta/assento por clique projetado | offload_carmenu | **STUDY** | usar para o *ponto de corte* do provider `cut` |
| Anim "slide under" + câmera underbody (catalisador/escapamento) | **CHOPNET** | **ADOPT (conceito)** | nenhuma outra referência cobre underbody; ver §4.3 |
| Maçarico derretendo **pontos** de dobradiça (porta/capô/mala) | **CHOPNET** | **STUDY** | metáfora de "calor no ponto" vs. nosso "arrastar linha"; ver §4.8 |
| Prop carregável obrigatório, walking pace, hands-full | **CHOPNET** | **ADOPT** | reforça `carry` do registry + estado `CARRIED` |
| Co-op: peças paralelizáveis, lock por-peça (não serializar o carro) | **CHOPNET** | **ADOPT (princípio)** | orienta §5.3 |
| Loot escondido dentro da peça (roll por nível) | **CHOPNET** | **STUDY** | hook de reward server-side, nunca do minigame |
| Fluxo de contrato / caça a modelo em tráfego / tablet NUI / drone | **CHOPNET** | **REJECT (fora de escopo)** | o VP é a camada de desmanche, não o wrapper de heist; e ficamos no-NUI |
| Raycast 3D sobre entidades-parafuso spawnadas | filo_bolt | **REJECT (como mecanismo primário)** | ver §5 comparação A×B |
| `WHEEL_BONES` com offsets fixos aproximados por canto | filo_bolt | **REJECT** | usar bone real |
| `side` hardcoded (`-1.0`, ramos `side>0` mortos) | filo_bolt | **REJECT** | derivar do bone/veículo |
| `RequestModel` sem timeout (`while not HasModelLoaded do`) | filo_bolt | **REJECT** | interno já usa timeout 1500 ms |
| Autoridade 100% client (export devolve bool "verdade") | filo_bolt / offload / CHOPNET típicos | **REJECT** | ActionSession.revalidate é a verdade |
| Dependência obrigatória de `bolt_01.ydr` | filo_bolt | **REJECT** | modelo é opcional; fallback marker |
| Loop per-frame fora da duração estrita do minigame | filo_bolt (`startInputCapture` paralelo) | **REJECT** | uma thread, encerra no cleanup |
| `canCancel = x ~= nil and x or true` | filo_bolt | **REJECT** | idioma quebrado (sempre true) |
| Lifecycle de áudio: bank liberado logo após disparar o som | filo_bolt | **REJECT** | corrida; usar frontend sound ou segurar o bank |
| Vitória = "clicar N objetos", sem esforço acumulado | filo_bolt | **REJECT** | ver §6 — exigir rotação real acumulada |

---

## 1. Referência interna: `runBoltSurface` / `VPChopBoltMinigame` / `VPChopPlateBoltMinigame`

`client/main.lua` linhas ~635–949. **É o nosso ponto de partida** — não uma referência externa,
mas o código que o Interactive Dismantling generaliza.

**O que já resolve bem:**
- Recebe `points={vec3...}` no mundo + parâmetros de câmera/giro; serve roda (círculo) e placa (cantos).
- `world2screen` via `GetScreenCoordFromWorldCoord` (pcall — se a native falhar, `'fallback'`).
- **Esforço real:** enquanto segura LMB (control 24) e o cursor está sobre um parafuso,
  `hovered.deg += move * sens` onde `move` = deslocamento do cursor no frame, com **clamp `0.08`**
  (salto de 1º frame / borda de tela não conclui de uma vez). `needed = turns * 360`.
- Modelo `bolt.ydr` **opcional**: `IsModelValid` → `RequestModel` com timeout 1500 ms → se não,
  **modo marcador** (`DrawMarker`, cor vermelho→verde por progresso, opacidade maior sob cursor).
- **Anti-tela-invisível:** se nenhum parafuso ativo projeta por > 2500 ms → `result='fallback'`
  → caller chama `VPChop*BoltFallback()` (skillCheck). (RC-FINDING-01.)
- Cancelar: ESC (322) / BACKSPACE (177) / timeout (25–30 s config).
- Ao concluir um parafuso: solta física (`FreezeEntityPosition(false)`, `SetEntityCollision(true)`,
  `SetEntityVelocity(outward*0.6, ..., rand)`), som `Pin_Good`.
- `cleanup()` sempre (dentro/fora do `pcall`): `hideTextUI`, deleta entidades, `ClearPedTasks`,
  `RenderScriptCams(false)`, `DestroyCam`.
- Geometria da roda: `GetWorldPositionOfEntityBone(veh, boneId)` + `GetEntityForwardVector` +
  vetor lateral derivado — **sem offsets hardcoded**. `VPChopBoltMinigame` já faz `2π/N`.

**Limitações a corrigir na V2:**
- Re-projeta todos os pontos **todo frame** (`world2screen` em loop). Com attach ao bone e
  poucos pontos é barato, mas dá pra cachear índice de bone e só reprojetar os não-concluídos.
- Parafusos são pontos no mundo, **não** presos ao veículo → se o carro se mexer (empurrão,
  física), os pontos ficam para trás. Attach ao bone resolve.
- Sem `outline` real — só marker. Adotar `SetEntityDrawOutline` quando houver entidade.
- Um único "kind" de minigame (parafuso). `cut` / `mechanical` / `wiring` não existem.
- Não é dirigido pelo `Registry.action.minigame` — o caller escolhe na mão.
- Acoplado a `Config.Jackstand.Minigame` / `Config.Plates.Bolt3D` — precisa de um bloco `Config` próprio.
- Não integra com `ActionSession` START/COMPLETE — é chamado solto dentro de `onSelect`.

**Segurança:** o resultado (`true`) hoje é consumido por `onSelect` e vira um `lib.callback.await`
para o servidor, que revalida item/distância/cooldown. O minigame **não credita nada** — correto.
A V2 formaliza isso: o `bool` do provider é só o gate para pedir `ActionSession:complete`.

---

## 2. `filo-studios/filo_bolt`

Estudo completo em [`WHEEL_BOLT_MINIGAME.md`](WHEEL_BOLT_MINIGAME.md). Resumo aqui para o quadro §0.

- **O que resolve:** apresentação 3D de remoção de porca de roda — parafusos presos ao
  `wheel_*` bone via `AttachEntityToEntity`, câmera na roda, raycast do cursor (`StartShapeTestLosProbe`),
  outline amarelo, cursor contextual (`SetMouseCursorStyle` 2/4/5), `oneAtATime`, animação de
  360° com leve recuo na rosca, física ao soltar (afrouxar → `ActivatePhysics`, cai).
- **API:** `exports:Start({vehicle, wheelBone, lugnutCount, isTightening, canCancel}) -> bool` (promise).
- **Dependências:** `ox_lib` (só `cache.ped`). Assets streamed próprios (`bolt_01.ydr`, `.ytyp`, `.awc`, `.dat54`).
- **Licença:** **GPL-3.0**. `escrow_ignore { "**/*" }` (aberto, não escrow). → **Nenhum** código,
  estrutura ou asset é reutilizável sem contaminar o `vp_chopshop` inteiro com GPL. Só conceito.
- **Anti-patterns** (ver §0 REJECT): 100% client-authoritative; `WHEEL_BONES` aproximado;
  `side` hardcoded; `RequestModel` sem timeout; `canCancel` idioma quebrado; audio bank liberado
  cedo demais; vitória = "clicar N vezes" sem esforço (o clique dispara animação automática).
- **Diferença central p/ o VP:** filo_bolt é standalone e confia no client. No VP o minigame é
  um **gate visual** dentro de `ActionSession`; o servidor refaz toda a validação no COMPLETE.

**ADOPT como conceito:** attach no bone, `2π/N`, câmera contextual, raycast/cursor, outline,
cursor contextual, parafuso soltando fisicamente, `oneAtATime` opcional.

---

## 3. `Offload-Studio/offload_carmenu`

- **O que resolve:** menu 3D de veículo — dá pra "apontar" uma parte do carro (porta, assento,
  janela) na tela e clicar. Comando `/vehiclemenu` / radial / keybind.
- **Técnica:** pré-cacheia índices de bone (`GetEntityBoneIndexByName`), pega a posição mundo
  (`GetWorldPositionOfEntityBone`), projeta com `World3dToScreen2d` e **manda os pixels para a NUI**
  (Vue no `build/`). Hover/clique são detectados **no frontend NUI** sobre as coordenadas de tela;
  callbacks `doorClick` / `seatClick` / `windowClick` devolvem o identificador do bone.
  Câmera via `SetFollowVehicleCamViewMode`; foco via `SetNuiFocusKeepInput`.
- **Dependências:** frontend Vue/Vite compilado (`build/`), locales JSON. Client-only (`client/main.lua`, `config/client.lua`).
- **Licença:** **GPL-3.0** (LICENSE presente). Mesma implicação do filo_bolt — conceito só.
- **Limitações p/ o nosso caso:**
  - É **NUI-driven**. O `vp_chopshop` hoje não tem NUI para gameplay (só snippet de ox_items).
    Introduzir uma NUI Vue para o minigame é peso e superfície nova — contra o princípio "leve".
  - `World3dToScreen2d` (ScRT) vs `GetScreenCoordFromWorldCoord` (que já usamos): equivalentes;
    a segunda é a que o `runBoltSurface` já chama. Sem motivo para trocar.
  - Sem autoridade de servidor — é um menu cosmético que dispara ações.
- **STUDY (não ADOPT direto):** a ideia de **"projetar bones nomeados e deixar o jogador apontar
  a peça/zona"** é exatamente o que o provider `cut` precisa para escolher o *ponto/linha de corte*
  (dobradiça da porta, batente do capô). Mas fazemos isso **sem NUI**, com o mesmo
  `GetScreenCoordFromWorldCoord` + cursor nativo do `runBoltSurface`. offload_carmenu confirma
  que a técnica de projeção é o caminho certo para "apontar a parte do carro" — e que fazê-la
  por NUI é opcional, não necessário.

---

## 4. CHOPNET — "Advanced Co-Op Chop Shop"

**Referência:** vídeo showcase `youtu.be/SYFEKBgHBYE` + release oficial no fórum CFX
(`forum.cfx.re/t/chopnet-advanced-co-op-chop-shop/5423046`). Data do estudo: 2026-08-29.

> **Método:** o vídeo do YouTube não é extraível por ferramenta; este estudo é feito sobre a
> **descrição escrita do próprio desenvolvedor** no release CFX (mais estruturada que o vídeo)
> + resultados de busca. **Código não é acessível** — CHOPNET é **escrow (~6.500 linhas)**;
> nem se pretende ler. Só **comportamento e UX observáveis**. Nada de asset, código ou
> inferência de implementação que não temos.

### 4.1 Sequência física do desmanche (o que o dev descreve)

| Grupo de peça | Interação descrita | Ferramenta |
|---|---|---|
| **Portas / capô / porta-malas** | "queimar as dobradiças" (`burn through the hinges`) antes de remover — **maçarico**, ponto a ponto na dobradiça, não corte em linha | maçarico/torch |
| **Rodas** | minigame de **click-and-drag** para "tirar os lug bolts de cada roda" | (implícito: chave/ferramenta de roda) |
| **Underbody / catalisador** | jogador **desliza para baixo do carro** ("slide under") para extrair o catalisador | corte/serra |
| **Interior + elétrica** | puxar **bancos, bateria, rádio** (e o **escapamento**) | manual / desconexão |
| **Transporte** | **carrega um prop real de cada peça** até o comprador — "mãos ocupadas, ritmo de caminhada, imersão completa"; **não é loot de inventário** | — |

### 4.2 Como o jogador escolhe/interage com cada peça

- Não há vídeo-transcrição, mas a descrição implica **seleção por aproximação + alvo na peça**
  (target/zona), depois um minigame específico do grupo. Ordem entre grupos não é declarada como
  forçada (co-op: até 5 jogadores dividem o trabalho e o payout — sugere peças destraváveis em
  paralelo, não fila rígida).
- **Co-op de verdade:** crews de até 5; peças/tarefas paralelizáveis; payout dividido.
- **Loot escondido** em portas/porta-malas, rolado contra o nível do jogador — a peça removida
  às vezes "contém" algo. (Para nós: seria um hook de reward server-side no COMPLETE da porta,
  não algo do minigame.)

### 4.3 Diferenças roda × porta × motor × interior × underbody

| Peça | Metáfora física CHOPNET | O que isso ensina para o VP |
|---|---|---|
| Roda | click-and-drag nos lug bolts | confirma "parafuso é a linguagem da roda"; **nossa** rotação acumulada é mais expressiva que drag |
| Porta/capô/mala | **maçarico derretendo dobradiça** (ponto) | alternativa ao nosso "arrastar na linha": **ponto de calor** — segurar o maçarico no ponto até passar; sair do ponto esfria. Ver §6 |
| Motor | (não detalhado no release; "tear apart" genérico) | mantém nosso desenho `mechanical` multi-etapa |
| Interior (bancos) | puxar / desparafusar trilhos | confirma `bolt`/`mechanical` para banco |
| Underbody (catalisador/escapamento) | **animação de deslizar sob o carro** + trabalho embaixo | confirma §1.1.1: precisa de **anim "slide under"** + **câmera underbody** dedicadas |

### 4.4 Feedback visual / câmera / ferramenta / ritmo

- **Feedback:** o release enfatiza "hands-on" e imersão; faísca/queima nas dobradiças é explícita
  ("burn through"). Detalhe fino do HUD não é documentado — assumir indicador de progresso por peça.
- **Câmera:** não documentada em detalhe. A "slide under" implica troca de câmera para o underbody.
- **Ferramenta:** maçarico (dobradiças), ferramenta de roda, jack/drone (não relevante para o
  desmanche em si). **Perk tree de 8 nós** acelera o "stripping" — para nós, qualquer modificador
  de velocidade é **server-side** (mexe em `minDurationMs`, que é autoritativo) — nunca um número
  que o client escolhe.
- **Ritmo:** deliberadamente lento e físico — "walking pace, hands full". Alinha com o nosso
  `CARRIED` e com a decisão de exigir esforço real (não clique).

### 4.5 Transição "peça presa → liberada"

- Descrito como físico: dobradiça queimada → porta **se solta**; lug bolts removidos → roda sai;
  peça vira **prop carregável**. Sem menção a "peça some e aparece no inventário" — o oposto:
  **prop físico obrigatório**. Isto é exatamente o `REMOVED → CARRIED → STORED` do nosso §5.

### 4.6 Carry / storage

- **Carry:** prop real por peça, "mãos ocupadas, ritmo de caminhada". Entrega ao comprador
  (dealer) em mão — ou **drone** para saques/compras (não para as peças).
- **Storage:** o release fala em levar "cada peça ao comprador"; não descreve um depósito
  intermediário. O VP tem truck/stash (`TruckStorage`) — mantemos, é superior para logística de crew.

### 4.7 O que complementa filo_bolt / offload_carmenu

| Ideia CHOPNET | Complementa |
|---|---|
| Maçarico derretendo **pontos** de dobradiça | filo_bolt/offload são sobre *pontos*; CHOPNET dá a metáfora certa para porta (calor no ponto) vs. nosso "arrastar linha" |
| Anim **slide-under** + trabalho no underbody | nenhum dos outros dois cobre underbody |
| **Prop carregável obrigatório**, walking pace | reforça o `carry` do registry (`prop`, `animation`) e o estado `CARRIED` |
| Co-op: peças paralelizáveis, payout dividido | orienta o design de lock por-peça (§5.3) para **não** serializar o carro todo |
| Loot escondido na peça (roll por nível) | hook de reward server-side, não do minigame |

### 4.8 O que podemos superar

1. **Rodas:** CHOPNET = click-and-drag (ainda "input N vezes"). VP = **rotação acumulada real**
   com clamp anti-salto → mais skill, menos macro-friendly.
2. **Portas:** "burn through" provavelmente é hold temporizado. VP pode fazer **calor acumulado
   por ponto com escorregamento** (sair do ponto perde progresso) — interação, não timer.
3. **Robustez:** nenhuma referência descreve degradação graciosa. O VP **degrada para skillCheck**
   quando câmera/geometria falham (RC-FINDING-01) em vez de travar o jogador.
4. **Sem NUI / sem escrow:** CHOPNET é tablet-NUI pesado e 6.5k linhas escrow. O VP fica
   **no-NUI para gameplay**, aberto, testável no harness.
5. **Autoridade:** CHOPNET (como o gênero) trata o resultado do client como verdade. O VP
   **revalida no servidor** todo COMPLETE.
6. **Declaratividade:** no VP o procedimento de cada peça sai do Part Registry
   (`action.minigame` + futuros `steps`), não de código espalhado por peça.

### 4.9 Pendência remanescente

Se você quiser calibrar detalhes que **só o vídeo mostra** (enquadramento exato de câmera por
peça, timing, som, se a ordem entre grupos é forçada, aparência do HUD de progresso), me diga
os pontos específicos e eu incorporo — mas o **estudo de comportamento está completo** para
efeito de design. Nada aqui depende de assistir ao vídeo frame a frame.

---

## 5. Estratégia de interação: A (raycast 3D) × B (projeção world→screen)

| Critério | A — raycast em entidades bolt (filo_bolt) | B — projeção world→screen + cursor (runBoltSurface / offload_carmenu) |
|---|---|---|
| **Segurança** | igual (client só) | igual (client só) — nenhuma vantagem/desvantagem |
| **Performance** | `StartShapeTestLosProbe` + poll `GetShapeTestResult` **todo frame**, por cursor; precisa das N entidades spawnadas sempre | matemática pura `GetScreenCoordFromWorldCoord` por ponto; entidades **opcionais** (modo marker) |
| **Compat. entre veículos** | depende do collider do parafuso e de não haver oclusão (roda, lamela, chão) — probe pode bater na jante | independe de collider; só precisa da posição do bone. Funciona em qualquer `wheel_*` |
| **Oclusão / câmera ruim** | se a câmera não vê o parafuso, não dá pra acertar — trava | já temos degradação: nada projeta > 2.5 s → skillCheck |
| **UX** | cursor "gruda" no objeto 3D real, muito tátil; outline nativo fácil | cursor sobre um ponto projetado; precisa de raio de hover (`hoverR`); outline só com entidade |
| **Sem asset** | **não funciona** sem um modelo com collider | funciona (marker) |
| **Código existente no VP** | zero | `runBoltSurface` inteiro |

**Recomendação: B (projeção world→screen), com entidade 3D opcional por cima só para o
feedback visual/outline.**

Justificativa:
- **Compatibilidade entre veículos** é decisiva: A depende de collider e linha de visão limpa
  até um parafuso de ~2 cm atrás da jante — falha em muitos modelos e ângulos. B só precisa da
  posição do bone, que existe em 100% dos veículos.
- **Sem dependência de asset** é requisito do projeto. A não roda sem modelo; B já roda em modo marker.
- **Performance:** B é aritmética; A faz shape-test por frame. Com poucos pontos a diferença é
  pequena, mas B é estritamente mais barato e não spawna nada obrigatoriamente.
- **Já é o nosso baseline** — B significa evoluir `runBoltSurface`, não reescrever.
- **Degradação graciosa** (RC-FINDING-01) já existe em B; em A teríamos que inventar.

O que A tem de melhor (cursor grudando no objeto real, outline nativo) a gente recupera como
**camada opcional**: quando o modelo do parafuso carrega, spawna a entidade **attachada ao bone**
(conceito do filo_bolt), desenha `SetEntityDrawOutline` nela, e ainda assim decide hover/turn
pela projeção do ponto. Modelo ausente → marker, mesmo minigame.

---

## 6. "Clicar N objetos" × interação real (a pergunta do exemplo)

No `filo_bolt`, o clique **dispara** uma animação automática de 360° — o esforço do jogador é
"achar e clicar N vezes". Não há skill.

**No `vp_chopshop` isso já é diferente hoje:** `runBoltSurface` exige **movimento real do cursor
acumulado** enquanto segura LMB (`hovered.deg += move * sens`, `needed = turns*360`). O jogador
"rosqueia" girando o mouse. O `filo_bolt` aqui é um **downgrade** do que já temos.

**Decisão de design (a consolidar na P2.2, não fechar agora):** manter e reforçar a rotação
acumulada como mecânica base de todos os providers, com variações por tipo:
- **bolt:** girar (rotação acumulada) — como hoje. Opcional: alternar sentido (aperta/afrouxa) para dificultar.
- **cut:** arrastar o cursor **ao longo de uma linha** entre dois pontos (dobradiça→batente),
  com tolerância de desvio — progride pela distância percorrida sobre a linha, não por clique.
- **mechanical:** sequência ordenada de pontos (cada um um "girar" curto); etapa N+1 só habilita após N.
- **wiring:** "puxar" plugs — clicar e arrastar o cursor **para longe** do ponto do conector
  (vetor de saída), soltar quando passar um limiar; cabo/plug cai.
- **skillcheck:** `lib.skillCheck` puro (fallback universal e opção de servidores lite).

Nenhum parâmetro numérico (sensibilidade, voltas, tolerância, tempo) é fixado neste documento.

---

## 7. Implicações de licença (consolidado)

| Referência | Licença | Pode estudar código? | Pode usar conceito? | Pode portar/copiar? | Pode bundlar? |
|---|---|---|---|---|---|
| `runBoltSurface` (interno) | próprio | — | sim | é nosso | é nosso |
| `filo_bolt` | GPL-3.0 | sim (é aberto) | sim | **não** | **não** (contamina) |
| `offload_carmenu` | GPL-3.0 | sim | sim | **não** | **não** |
| CHOPNET | **escrow** (~6.5k linhas, Tebex) | **não** (encrypted) — só comportamento observável | sim (comportamento/UX) | **não** | **não** |

**Regra do projeto** (`AGENTS.md` §3, `docs/research/EXTERNAL_RESEARCH_MATRIX.md` §13):
reuso de **conceito**, reimplementação própria. Providers externos, se algum dia existirem,
ficam **atrás do bridge**, instalados à parte pelo server-op, nunca no repo.

---

## 8. Threat model das referências (o que não herdar)

Todas as três referências externas compartilham o mesmo furo: **o client decide o resultado**.
Num contexto Heavy RP com economia e `vp_gangs`, isso é explorável por:
- resource stop/replace do minigame → export sempre devolve `true`;
- hook no `promise`/callback → pular o minigame;
- editar o `Config` local (voltas = 0, timeout enorme, `oneAtATime` off).

**Mitigação (já é a arquitetura do VP):** o `bool` do minigame **nunca** é aceito como verdade.
Ele só autoriza o client a pedir `ActionSession:complete`, e o servidor então refaz **session +
veículo + distância + ferramenta + peça + estado + ownership** antes de qualquer commit de peça
ou pagamento. Minigame ausente/hackeado = pior caso o jogador pula a UX, mas o servidor ainda
exige `minDurationMs` decorrido e todas as gates. Detalhes no threat model do design doc.

---

## 9. Performance — o que as referências ensinam

- **filo_bolt:** thread de input **paralela** + loop principal, ambos `Wait(0)`, enquanto ativo.
  Aceitável só porque a duração é curta e limitada. **Nós usamos uma thread só**, e ela morre no cleanup.
- **offload_carmenu:** cacheia índices de bone, só manda update de NUI quando a posição muda.
  Bom princípio: **cachear `GetEntityBoneIndexByName` uma vez**, não por frame.
- **runBoltSurface:** re-projeta todos os pontos por frame. Barato para ≤ 6 pontos, mas a V2 deve
  pular os `done` e cachear bone index.
- **Budget alvo** (detalhado no design doc): 0.00 ms com minigame inativo (nenhuma thread);
  durante a sessão, < 0.10 ms/frame no client; nenhuma entidade persistente; uma câmera.

---

## 10. Diferenças estruturais vs. `vp_chopshop` (resumo)

| Aspecto | Referências | `vp_chopshop` |
|---|---|---|
| Autoridade | client | **servidor** (`ActionSession.revalidate`, `ChopSession`) |
| Fonte da definição de peça | config local / hardcoded | **Part Registry** (`shared/registry/parts.lua`, schema v2 congelado) declara `action.minigame` |
| Seleção de minigame | caller escolhe | **`Registry.action.minigame`** → provider (mapa declarativo) |
| Asset | obrigatório (filo/offload) | **opcional** (marker fallback) |
| NUI | Vue (offload) | nenhuma para gameplay — manter assim |
| Ciclo de vida | ad-hoc | START/SUCCESS/CANCEL/FALLBACK formal, cleanup determinístico |
| Estado de peça | booleano local | `ChopSession.parts[key] = {state}` server-side; V2 adiciona LOCKED/REMOVING |
| Recompensa | minigame concede | **nunca** pelo minigame — `RewardResolver` server no COMPLETE |
