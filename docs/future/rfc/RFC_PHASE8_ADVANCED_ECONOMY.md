# RFC — Fase 8: Living Market & Advanced Dynamic Economy

> **Status:** CANONICAL SPECIFICATION / RFC  
> **Fase:** FASE 8 (v1.22) — Advanced Economy & Living Market  
> **Dependências:** `BrokerMarket` (v1.17), `P5.3 B2B Orders`, `P6.5 Specialized Buyers`  
> **Escopo:** Modificadores regionais, hierarquia de demanda unificada, choques de oferta, sumidouros de materiais e emboscadas escalonadas

---

## 1. Hierarquia Unificada de Demanda (P8.2)

Para evitar inflação ou duplicação de liquidez, toda a demanda do ecossistema é consolidada em uma **única fila de prioridade econômica**:

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ HIERARQUIA DE DEMANDA & PRECIFICAÇÃO                                                       │
├───────────────────────┬────────────┬────────────────────────────────────────────────────────┤
│ TIPO DE DEMANDANTE    │ PREMIUM    │ ORIGEM DO LASTRO FINANCEIRO                            │
├───────────────────────┼────────────┼────────────────────────────────────────────────────────┤
│ 1. Ordens B2B Oficina │ +15% a 30% │ Saldo real da empresa mecânica (qbx_management)        │
│ 2. Contratos Facção   │ +10% a 25% │ Fundo de gangue / recompensa especial do Trap Phone    │
│ 3. Compradores Nicho  │ +10% a 20% │ Receptadores do submundo (Mecânico Fantasma, etc.)     │
│ 4. Contratos Broker   │ +5% a 15%  │ Catálogo dinâmico do Broker (Pools de Demanda)         │
│ 5. Venda Balcão NPC   │ Baseline   │ Liquidez base de fallback do BrokerMarket              │
└───────────────────────┴────────────┴────────────────────────────────────────────────────────┘
```

- **Invariante:** Cada peça física pode ser vendida para apenas **um** demandante na hierarquia. A liquidez do NPC de balcão sempre serve como rede de segurança para garantir que o jogador nunca fique com estoque travado.

---

## 2. Modificadores de Mercado Regionais (P8.1)

O preço de cada commodity no `BrokerMarket` é calculado pela composição:

$$\text{Preço Final} = \text{Preço Base} \times \text{Modificador Global}(t) \times \text{Modificador Regional}(\text{Zona})$$

- **Zona Norte (Paleto Bay / Sandy Shores):** Alta demanda por peças de caminhões, off-road e motores diesel (+15% a +25%).
- **Zona Portuária (Docas de Los Santos):** Alta demanda por sucata a granel e catalisadores para exportação (+10% a +20%).
- **Zona Nobre (Vinewood / Rockford Hills):** Alta demanda por peças de superesportivos e blindados (+20% a +35%).

---

## 3. Eventos de Choque de Oferta & Escassez (P8.3)

O servidor pode disparar eventos temporários (duração de 2h a 6h):
- **"Greve nas Siderúrgicas":** O valor de `steel` e `metalscrap` sobe em +40%; oficinas pagam o dobro por peças brutas.
- **"Crise dos Catalisadores":** O valor de `catalytic_converter` dispara +50% nas docas, elevando a vigilância policial nas ruas.
- **"Corrida por SUVs":** Contratos de modelos `baller`, `granger` e `cavalcade` pagam bônus dobrado de Trust.

---

## 4. Sumidouros de Materiais & Reciclagem (P8.4)

Para impedir o acúmulo descontrolado de itens nos inventários dos jogadores:
- **Consumo em Oficinas:** `steel` e `metalscrap` são consumidos na reparação estrutural de lataria de carros civis.
- **Consumo em Recondicionamento (P7.3):** Retificar motores e forjar chassis consome grandes lotes de `copper` e `aluminum`.
- **Produção de Ferramentas:** Lotes de materiais podem ser fundidos na soldadora para criar novas serras (`saw_pro`) e brocas de furadeira (`mechanic_drill`).

---

## 5. Emboscadas de Sindicato V2 & Retaliação (P8.5 / P8.6)

- **Escalonamento de Risco:** O risco de emboscada (`server/ambush.lua`) deixa de ser uma chance estática e passa a ser uma função de:
  $$\text{Risco} = f(\text{Valor da Carga}, \text{Heat Acumulado}, \text{Território Hostil}, \text{Raridade da Peça})$$
- **Retaliação por Fraude:** Se um jogador aceitar um contrato de alta relevância do Broker ou de uma facção e tentar fraudar entregando peças danificadas/inválidas, o contratante envia veículos de perseguição armados para cobrar a dívida.
