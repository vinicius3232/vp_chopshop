# BROKER MARKET MODEL — vp_chopshop v1.17

**Data:** 2026-09-01 (Revisão BROKER-0.1)  
**Autor:** Lead Gameplay Systems Architect & Economy Engineer  
**Status:** ESPECIFICAÇÃO MATEMÁTICA DO MERCADO DINÂMICO & REQUISITO DE SIMULAÇÃO ECONÔMICA

---

## 1. Fundamentos do Modelo Econômico

O modelo de mercado do Chop Broker substitui payouts puramente aleatórios ou constantes por uma **Engine de Oferta, Demanda e Pressão de Volume**.

### Princípios Inegociáveis:
1. **100% Server-Authoritative:** O cliente nunca calcula, envia ou sugere preços, multiplicadores ou índices de demanda.
2. **Sem Hiperinflação:** Preços possuem limites absolutos rigorosos (*Hard Ceiling* e *Hard Floor*).
3. **Sem Exploit de Volume:** Vendas massivas da mesma peça geram rendimentos decrescentes (*Diminishing Returns*) até a saturação temporária.
4. **Demanda Externa Desacoplada de Players Online:** A demanda de oficinas é informada exclusivamente via `WorkshopBridge.GetMarketSignal()` do adapter ativo, nunca por contagem ingênua de mecânicos online (`#mechanics_online`).
5. **Recuperação Temporal:** A demanda se recupera gradualmente ao longo do tempo em direção ao ponto de equilíbrio.

---

## 2. Requisito de Simulação Econômica Pré-Fixação (BROKER-1 Gate)

Antes de fixar os valores definitivos das constantes em `shared/config.lua`, a implementação do módulo de mercado (`BROKER-1`) **deve obrigatoriamente executar uma suíte de simulação estática** (`server/broker/market_sim_spec.lua`) contendo 1.000 iterações sintéticas para provar:
- Comportamento da fórmula combinada $\text{Base} \times D(t) \times M_{\text{trust}} \times M_{\text{tier}} \times M_{\text{night}} \times M_{\text{heat}} \times (1 + J)$.
- Que em nenhum cenário extremo o preço cai abaixo do *Hard Floor* ($0.40 \times \text{Base}$).
- Que em nenhum cenário extremo com todos os bônus empilhados o preço ultrapassa o *Hard Ceiling* ($2.50 \times \text{Base}$).
- Curva de saturação e velocidade de recuperação por hora.

---

## 3. Formulação Matemática da Demanda

### 3.1. Índice de Demanda ($D(t)$)
Para qualquer commodity $c$, o índice de demanda instantâneo $D_c(t)$ varia em torno de $1.0$ (equilíbrio padrão de mercado):

$$\text{Floor} \le D_c(t) \le \text{Ceiling}$$

- $\text{Hard Floor } (D_{\min}) = 0.40$ (40% do preço base no ápice da saturação)
- $\text{Hard Ceiling } (D_{\max}) = 1.30$ (130% do preço base em escassez/alta demanda padrão)

### 3.2. Impacto da Venda (Pressão de Volume)
Quando um jogador vende $k$ unidades da commodity $c$ ao Broker:

$$D_c^{\text{novo}} = \max\left(D_{\min}, D_c(t) - (k \times \Delta D_c)\right)$$

### 3.3. Recuperação Temporal Passiva (Lazy Evaluation)
A recuperação da demanda ocorre em direção ao equilíbrio ($1.0$) de forma contínua sob demanda:

$$D_c(t + \Delta t) = D_c(t) + \text{sgn}(1.0 - D_c(t)) \times \min\left(|1.0 - D_c(t)|, R_c \times \frac{\Delta t}{3600}\right)$$

Onde:
- $R_c$: Taxa de recuperação por hora (ex: $0.15/\text{h}$).
- $\Delta t$: Segundos decorridos desde a última atualização (`last_updated`).

---

## 4. Fórmula Final de Preço do Broker

O preço pago pelo Broker ao jogador por uma unidade de commodity $c$ é calculado no servidor como:

$$P = \left\lfloor P_{\text{base}} \times D_c(t) \times M_{\text{trust}} \times M_{\text{tier}} \times M_{\text{night}} \times M_{\text{heat}} \times (1 + J) \right\rfloor$$

### Multiplicadores:
1. **$P_{\text{base}}$:** Preço base configurado em `Config.Broker.BasePrices[c]`.
2. **$D_c(t)$:** Índice de demanda dinâmico da commodity ($0.40 \le D \le 1.30$).
3. **$M_{\text{trust}}$:** Multiplicador de confiança: Trust 0 (bloqueado), Trust 1 ($1.00$), Trust 2 ($1.15$), Trust 3 ($1.30$), Trust 4 ($1.50$).
4. **$M_{\text{tier}}$:** Multiplicador de progressão ($1.00 \to 1.25$).
5. **$M_{\text{night}}$:** Bônus noturno ($1.30$ entre 21h e 06h, senão $1.00$).
6. **$M_{\text{heat}}$:** Penalidade por nível de procurado (Frio: $1.00$, Morno: $0.90$, Quente: $0.75$, Queimando: $0.00$).
7. **$J$ (Jitter):** Variação de regateio pseudo-aleatória entre $-0.03$ e $+0.03$ ($\pm 3\%$).

### Trava Global (Hard Cap):
$$P \le P_{\text{base}} \times 2.50$$

---

## 5. Commodities Iniciais & Parâmetros Preliminares

| Commodity | Tipo de Objeto | Base Price ($) | Decay por Venda ($\Delta D$) | Taxa de Recuperação ($R_c$) |
|---|---|---|---|---|
| `catalytic_converter` | `PartEntitlement` | $1.600 | -4.0% / un | +15% / hora |
| `adv_engine` | `PartEntitlement` | $2.500 | -8.0% / un | +12% / hora |
| `tyres` | `TyreEntitlement` (Truck) | $400 / pneu | -2.0% / pneu | +20% / hora |
| `stolen_plate` | Item / Metadata | $250 | -3.0% / un | +15% / hora |
| `door` / `bonnet` | `PartEntitlement` | $600 | -3.0% / un | +15% / hora |
| `metalscrap` / `steel` | Item Inventário | $80 / $100 | -0.2% / un | +25% / hora |
| `copper` / `aluminum` | Item Inventário | $150 / $130 | -0.4% / un | +25% / hora |
