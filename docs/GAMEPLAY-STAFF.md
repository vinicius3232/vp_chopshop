# 🚗 Desmanche (vp_chopshop) — Resumo de Gameplay para a Staff

> Documento de visão geral para a equipe entender **como o script se joga** no servidor — tanto pro lado do **crime** quanto pro lado da **polícia**. Não é manual técnico; é o fluxo de RP.

---

## 🎯 A ideia em uma frase
O jogador rouba carros, **desmancha** num esconderijo, e transforma as peças em dinheiro — mas **cada ação deixa rastro**. A polícia vira **investigadora de verdade**: digitais, DNA, marcas de pneu e números de série contam a história do crime. É um jogo de gato e rato com **risco e perícia dos dois lados**.

---

## 🔪 O ciclo do bandido (passo a passo)

1. **Rouba um carro** na rua.
2. **Levanta com o macaco** (item) e **desmancha em fases**:
   - Fase 1: rodas, capô, porta-malas → materiais.
   - Fases 2–4 (avançado): portas → motor → carcaça → **peças de carro** (`car_parts`).
3. Durante o desmanche, vários **riscos** entram em cena:
   - **Alarme veicular** pode disparar (carro mais caro = mais chance) → tem que desarmar com chave de fenda antes da polícia ser avisada.
   - **Heat** (calor) sobe no veículo — carro "quente" chama mais atenção.
   - **Emboscada** pode acontecer (ladrões rivais / cães) — é também a fonte do convite pro **fence** (receptador).
4. **Cobre os rastros** (ou não):
   - Trabalhar **com luvas** evita deixar digitais; sem luvas, deixa.
   - Pode **raspar o VIN** pra baixar o heat (item + skill).
   - Pode **roubar a placa** e/ou **aplicar uma placa falsa** pra enganar a consulta da polícia.
5. **Vende ou usa as peças**:
   - Vende ao **fence** (receptador rotativo, localização muda) ou em RP com mecânicos.
   - As `car_parts` roubadas têm **número de série "quente"** — pode **riscar** (fica óbvio que é roubada) ou, com skill máximo, **forjar uma série** que faz a peça **parecer legal**.
6. **Foge** — se cantar pneu na fuga, deixa **marca de pneu** apontando o **modelo do carro**.

> O bandido **progride** (tiers): quanto mais joga, mais desbloqueia (raspar VIN, forjar placa, forjar série, confiança no fence).

---

## 👮 O lado da polícia (investigação de verdade)

Quando a polícia chega numa cena de crime (ou aborda um suspeito), ela tem **ferramentas reais de perícia**:

- **Coletar digitais e DNA** com o kit forense → o sistema **identifica o autor** pela biometria. O bandido pode ter fugido, mas a cena o entrega.
- **Marcas de pneu** → examina e descobre o **modelo/classe** do carro que fugiu (ex.: "um esportivo"). Não revela a placa — é uma pista, não uma prova fechada.
- **Cartuchos** ficam no chão em tiroteios (identificam a arma).
- **Inspecionar peças de carro** (com scanner): vê se a peça é **legal, roubada, com série riscada, ou forjada**.
  - Série **riscada** = claramente adulterada → flagrante.
  - Série **forjada** parece legal numa olhada — mas com **perícia (kit forense)** a polícia descobre que é falsa.
- **Furar disfarces de placa** → restaura a placa real do carro.

> Resultado: a polícia tem **cenários reais de investigação** — não é só "viu o crime acontecendo", é juntar provas depois.

---

## ⚖️ Por que é equilibrado (o que a staff deve saber)

Cada vantagem do crime tem um **counterplay**:

| Bandido faz... | ...mas |
|---|---|
| Trabalha rápido/sujo | deixa mais vestígio |
| Não usa luvas | deixa digitais (identificável) |
| Canta pneu na fuga | deixa marca apontando o carro |
| Aplica placa falsa | a polícia pode furar o disfarce; o heat continua no carro real |
| Forja série de peça | a perícia ainda flagra |
| Faxina a cena (água oxigenada) | leva tempo e precisa achar cada vestígio |

E o crime **não chama a polícia automaticamente do nada**: o alerta é por **chance e por testemunhas** (NPCs/jogadores por perto). Lugar deserto de madrugada = quase não chama. Lugar movimentado = chama mais (e rende **bônus de risco** pro bandido ousado).

---

## 🧩 Sistemas em resumo (para referência)

- **Desmanche em 4 fases** (macaco → serra → motor → carcaça).
- **Heat / MDT** — o "calor" do veículo, base de toda a investigação.
- **Alarme veicular** — risco no início do desmanche.
- **Emboscadas** — risco + porta de entrada pro fence.
- **Fence rotativo** — receptador que muda de lugar; confiança (trust) que sobe com o tempo.
- **Placas** — roubo de placa, placa falsa que engana o MDT (com reversão segura na garagem), remoção pela polícia.
- **Evidências** — digital + DNA por ação, luvas como counterplay, coleta e identificação pela polícia.
- **Marcas de pneu** — pista de fuga pelo modelo do carro.
- **Série das peças** — economia cinza: peça roubada → riscar/forjar → legal; perícia da polícia.
- **Progressão** — tiers que desbloqueiam mecânicas conforme o jogador evolui.

---

## 💬 Como isso vira RP (exemplos)

- **Mecânico** compra peças "baratas" e descobre (ou não) que são roubadas → dilema de RP.
- **Detetive** monta o quebra-cabeça: digital na cena + marca de pneu de um esportivo + peça forjada na oficina = caso construído.
- **Chefe do crime** ensina os novatos a trabalhar limpo (luvas, faxina, placa falsa) antes de subir de nível.
- **Blitz policial**: scanner de peças numa oficina suspeita revela séries forjadas.

---

*Tudo é configurável (chances, preços, tiers, jobs da polícia). A staff pode ajustar o equilíbrio sem mexer no código. Versão atual: 1.13.1 — auditada (bug/segurança/performance).*
