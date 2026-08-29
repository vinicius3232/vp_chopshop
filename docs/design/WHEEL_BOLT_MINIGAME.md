# Design brief — Wheel Bolt Minigame

> **Status:** DESIGN BRIEF — nenhuma linha de código nesta etapa.
> **Baseline:** branch `pr-h/v1.15-delivercar-terminal-hardening`.
> **Este documento NÃO inicia a P2.2 e NÃO concede GO para a Fase 2.**
> **Implementation gate: QA Q1–Q4 (`docs/audit/V116_INTEGRATION_QA.md`) precisam estar FECHADOS primeiro.**
> `P2.2 = NOT STARTED`.

Registro do estudo feito sobre `filo_bolt` como **brief de design e comportamento**.
Não é um port, não é uma tradução função-por-função e não reutiliza código, estrutura,
nomes internos nem assets da referência.

---

## 1. Problema

O futuro sistema de rodas do `vp_chopshop` precisa de uma interação visual de
remoção / aperto de parafusos que seja, ao mesmo tempo:

- **imersiva** — o jogador sente que está desmontando a roda, não clicando num HUD;
- **3D** — no mundo, na roda do veículo, não uma tela 2D;
- **leve** — sem thread global, sem loop de reposicionamento, entidades só durante a sessão;
- **compatível com a autoridade server-side existente** — `ActionSession` continua dono
  de início, conclusão, distância, ferramenta, peça, estado e recompensa;
- **independente de assets proprietários** — nada de `.ydr`/`.ytyp` pago ou de licença restritiva;
- **encapsulada por provider/bridge** — o caller não conhece a implementação.

---

## 2. Referência estudada

`filo_bolt` (filo-studios) foi usado **apenas como referência comportamental e de UX**.

**NÃO copiar da referência:**

- código;
- estrutura de funções;
- nomes internos;
- assets;
- implementação literal.

A implementação futura do `vp_chopshop` será **escrita do zero**, com a arquitetura,
o estilo e as invariantes deste projeto.

---

## 3. Conceitos aproveitáveis

Distribuição radial dos parafusos:

```text
N bolts distribuídos radialmente

step  = 2π / N
y     = radius * cos(angle)   -- angle = step * i,  i = 0 .. N-1
z     = radius * sin(angle)
```

Demais conceitos de UX/apresentação:

- objetos presos ao **wheel bone** via `AttachEntityToEntity` (seguem o veículo sem loop de tracking);
- câmera roteirizada focada na roda;
- cursor / raycast 3D a partir da tela para selecionar um parafuso;
- outline no parafuso sob foco;
- cursor contextual (estado neutro / "pegar" / "girando" / concluído);
- opção `oneAtATime` (só um parafuso em animação por vez, para dar ritmo);
- animação visual de desaperto (rotação + leve recuo do parafuso na rosca);
- parafuso podendo **cair fisicamente** ao final do desaperto;
- **cleanup obrigatório** de tudo que a sessão criou/alterou.

**Explícito:** trigonometria circular, raycast de tela, `AttachEntityToEntity`,
câmera roteirizada e outline de entidade são **técnicas genéricas da plataforma
FiveM/GTA**, não partes a serem portadas da implementação estudada. Qualquer
implementação séria dessas mecânicas converge para as mesmas natives.

---

## 4. Problemas da referência que NÃO devemos reproduzir

- minigame **100% client-authoritative** — nenhuma validação de servidor;
- resultado do client podendo ser tratado como verdade (remover peça / pagar / concluir);
- polling / trabalho per-frame além do estritamente necessário;
- offsets de roda **aproximados / hardcoded** em vez da posição real do bone;
- ausência de qualquer verificação server-side no fim do minigame;
- dependência de **asset próprio** (`.ydr`/`.ytyp`/`.awc`) streamed;
- cleanup frágil (fácil deixar entidade órfã em caminhos de erro);
- `canCancel` com fallback booleano incorreto
  (`x ~= nil and x or true` devolve `true` mesmo quando o valor é `false` explícito);
- ciclo de vida de áudio potencialmente incorreto
  (audio bank liberado imediatamente após disparar o som — corrida);
- **ausência de mecanismo real de dificuldade** além de "achar o parafuso e clicar".

---

## 5. Arquitetura alvo

Contrato conceitual:

```lua
runWheelBolts(vehicle, wheelId, opts) -> boolean
```

Local futuro sugerido: `bridge/minigames.lua` (ou equivalente já existente no
projeto, a confirmar em auditoria no início da P2.2).

O **caller não conhece** implementação nem provider — só recebe o booleano.

Fluxo:

```text
ActionSession START
        ↓
client executa minigame visual
        ↓
success / fail local
        ↓
client solicita COMPLETE
        ↓
ActionSession.revalidate()
        ↓
server verifica de novo:
  session
  veículo
  distância
  ferramenta
  peça
  estado
  ownership / action state
        ↓
somente então: commit da desmontagem / recompensa
```

**Regra central:** o sucesso do minigame **nunca** remove peça, entrega item,
paga reward ou conclui domínio diretamente. É apenas o sinal de que o gate visual
foi vencido. Mesma postura que o projeto já adota para `lib.skillCheck`.

---

## 6. Wheel bone real

No desenho futuro, preferir:

```text
GetEntityBoneIndexByName
GetWorldPositionOfEntityBone
```

Não depender dos offsets de roda aproximados usados pela referência.

Offsets locais pequenos, para o posicionamento **visual** dos parafusos em torno
do bone, podem continuar sendo configuráveis.

---

## 7. Lifecycle

```text
idle
→ starting
→ active
→ success | cancelled | failed
→ cleanup
```

Cleanup **deve** ocorrer em todos os caminhos:

- sucesso;
- falha;
- cancelamento;
- timeout;
- entidade desapareceu;
- veículo inválido;
- resource stop.

Restaurar sempre:

- câmera;
- alpha / estado do ped;
- controles;
- cursor;
- outline;
- objetos temporários.

**Nenhuma entidade órfã**, em nenhum caminho.

---

## 8. Provider strategy

- **Default futuro:** `vp_chopshop` native provider, escrito do zero.
- Outros providers podem existir **opcionalmente** atrás do bridge
  (ex.: um resource externo que o server-op instale por conta própria).
- Dependências externas e suas licenças ficam **isoladas** atrás do bridge e
  **nunca** definem o domínio. Se o provider externo some, o native assume.

---

## 9. Asset strategy

A P2.2 deverá decidir entre:

1. prop base-game apropriado;
2. representação por marker / scaleform / etc.;
3. asset mínimo realmente redistribuível / livre.

- **Não** adicionar asset neste PR.
- **Não** reutilizar `bolt_01.ydr` (nem qualquer asset) da referência.

---

## 10. UX futura

Separar **apresentação** de **dificuldade**.

A referência é essencialmente:

```text
find bolt
→ click
→ animation
→ next bolt
```

Para Heavy RP, a P2.2 poderá avaliar dificuldade adicional — mas isso **não** é
decisão deste documento. Apenas *future considerations*, nenhuma fechada agora:

- ordem de remoção;
- tolerância de precisão;
- torque / timing;
- ferramenta adequada;
- wheel condition;
- dificuldade por veículo / estado.

Não implementar nem fixar parâmetros agora.

---

## 11. Performance principles

- nenhuma thread global rodando quando o minigame está inativo;
- `Wait(0)` somente durante a interação ativa, e só se realmente necessário para
  cursor / raycast;
- objetos criados apenas durante a sessão;
- sem loop de reposicionamento se o attachment ao bone resolver;
- uma câmera por sessão;
- cleanup determinístico.

---

## 12. Segurança

```text
CLIENT = apresentação / input
SERVER = autoridade
```

O minigame é apenas um gate. O resultado do client é **dado não confiável** até
`ActionSession.revalidate()` concluir no servidor.

---

## 13. Gate de implementação

```text
P2.2 = NOT STARTED

Implementation gate:
QA Q1–Q4 must be CLOSED first.
```

Este documento **não concede GO** para a Fase 2. Ver
[`MASTER_IMPLEMENTATION_PLAN.md`](MASTER_IMPLEMENTATION_PLAN.md) §3 (CHECKPOINT DE QA)
e [`../audit/V116_INTEGRATION_QA.md`](../audit/V116_INTEGRATION_QA.md).

---

## 14. References / provenance

- **Referência:** `filo_bolt` — repositório `filo-studios/filo_bolt` (GitHub).
- **Data do estudo:** 2026-08-29.
- **Finalidade:** estudo de UX e comportamento (câmera, feedback de foco, ritmo,
  animação de desaperto).
- **Licença da referência:** GPL-3.0 — motivo pelo qual **nenhum** código, estrutura
  ou asset é reutilizado; a implementação futura do `vp_chopshop` é independente e
  escrita do zero a partir deste brief.

Não colar trechos extensos do código estudado neste documento. Não transformá-lo
em tradução função-por-função.
