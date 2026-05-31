# [F3 garagem] Hook do vp_chopshop para qb-garages (PORTABILIDADE — QBCore)

> Este arquivo só é necessário se você usa **qb-garages** (QBCore). No servidor LIVE
> (QBox / qbx_garages) o hook já está aplicado em `qbx_garages/server/main.lua`.
> **qb-garages NÃO está instalado neste servidor — este snippet é portabilidade não testada.**

## Por que é preciso

Quando o jogador guarda um carro na garagem, o qb-garages captura as `props`/placa do veículo
(placa **visível**) e grava em `player_vehicles`. Se o carro estiver com **placa falsa** aplicada
pelo vp_chopshop, a garagem gravaria a placa FALSA — corrompendo o registro do veículo.

O vp_chopshop expõe o export `vp_chopshop:GetRealPlateForProps(veh, props)` que:
- detecta se o veículo tem disfarce ativo (statebag `vpFakeRealPlate` ou consulta DB);
- se tiver, devolve `props` com `props.plate` revertida para a placa **REAL**;
- **NÃO apaga** o mapeamento do disfarce — ele é re-aplicado no próximo spawn do carro.

## Onde colar

No qb-garages, localize o ponto do servidor onde a placa/props do veículo é capturada
**antes de salvar** em `player_vehicles`. Em versões comuns do qb-garages isso fica no
evento de estacionar, por volta de onde se lê `GetVehicleNumberPlateText(vehicle)` e/ou
se monta a tabela de update do `MySQL`. O nome exato do evento varia por versão (ex.:
`qb-garages:server:updateVehicleState`, `qb-garages:server:ParkVehicle`, ou similar).

### Caso A — você tem o handle do veículo (`vehicle`) e uma tabela `props`

```lua
-- [vp_chopshop F3 garagem] Reverter placa falsa antes de salvar.
-- AVISO: reaplicar se qb-garages for atualizado.
if GetResourceState('vp_chopshop') == 'started' then
    props = exports.vp_chopshop:GetRealPlateForProps(vehicle, props)
end
-- ... segue o SaveVehicle / update normal usando props.plate
```

### Caso B — qb-garages só usa uma variável `plate` (sem tabela props)

Monte uma tabela mínima, passe ao export e leia a placa corrigida de volta:

```lua
-- [vp_chopshop F3 garagem] Reverter placa falsa antes de salvar.
-- AVISO: reaplicar se qb-garages for atualizado.
if GetResourceState('vp_chopshop') == 'started' then
    local fixed = exports.vp_chopshop:GetRealPlateForProps(vehicle, { plate = plate })
    if fixed and fixed.plate then plate = fixed.plate end
end
-- ... segue o UPDATE de player_vehicles usando `plate`
```

## Notas

- O export é **defensivo**: se o vp_chopshop estiver parado, o `GetResourceState` evita o erro;
  se o carro não tiver disfarce, ele devolve `props` inalterada.
- O export roda **server-side** (precisa do handle server do veículo). Em qb-garages
  certifique-se de chamá-lo no servidor, com o `vehicle` resolvido via
  `NetworkGetEntityFromNetworkId(netId)` se você só tiver o netId.
- O disfarce só é removido pela **polícia** (target do vp_chopshop) ou remoção manual —
  guardar o carro NUNCA remove o disfarce; ele volta no próximo spawn.
