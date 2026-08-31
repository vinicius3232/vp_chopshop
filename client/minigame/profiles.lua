-- client/minigame/profiles.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [UX-A] Profiles Registry para Desmanche Físico
--  Define os comportamentos de câmera, cálculo de pontos e interação para cada
--  categoria de componente do veículo.
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopProfiles = _G.VPChopProfiles or {}
local Profiles = _G.VPChopProfiles
local Proj = _G.VPChopProjection

Profiles.list = {
    -- ─── Profile DEMO (Técnico / Validação UX-A) ──────────────────────────────
    demo = {
        title = 'DEMO TÉCNICA — FIXADORES',
        helpText = 'Segure o botão esquerdo e faça movimentos circulares ao redor de cada ponto',
        toolClass = 'screw',
        fov = 42.0,
        calculateCamera = function(vehicle, boneKey)
            local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, boneKey or 'wheel_lf')
            local camPos = bonePos + (rightV * (sideSign * 1.4)) + (up * 0.15) + (fwd * 0.1)
            return camPos, bonePos
        end,
        generatePoints = function(vehicle, boneKey)
            local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, boneKey or 'wheel_lf')
            local radius = 0.14
            local outOffset = 0.05
            local points = {}
            local count = 3

            for i = 0, count - 1 do
                local angle = (2.0 * math.pi / count) * i
                local ca, sa = math.cos(angle), math.sin(angle)
                local worldP = bonePos + (up * (ca * radius)) + (fwd * (sa * radius)) + (rightV * (sideSign * outOffset))
                points[#points + 1] = {
                    id = 'demo_pt_' .. (i + 1),
                    worldPos = worldP,
                    label = 'FIXADOR #' .. (i + 1),
                    neededDeg = 540.0,
                }
            end
            return points
        end
    },

    -- ─── Profile WHEEL (4 Rodas — LF, RF, LR, RR) ────────────────────────────
    wheel = {
        title = 'REMOÇÃO DE RODA',
        helpText = 'Desparafuse os 5 parafusos da roda girando o mouse',
        toolClass = 'screw',
        fov = 40.0,
        calculateCamera = function(vehicle, boneKey)
            local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, boneKey)
            local camPos = bonePos + (rightV * (sideSign * 1.35)) + (up * 0.1)
            return camPos, bonePos
        end,
        generatePoints = function(vehicle, boneKey)
            local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, boneKey)
            local radius = 0.135
            local outOffset = 0.045
            local points = {}
            local boltCount = 5

            for i = 0, boltCount - 1 do
                local angle = (2.0 * math.pi / boltCount) * i
                local ca, sa = math.cos(angle), math.sin(angle)
                local worldP = bonePos + (up * (ca * radius)) + (fwd * (sa * radius)) + (rightV * (sideSign * outOffset))
                points[#points + 1] = {
                    id = 'bolt_' .. (i + 1),
                    worldPos = worldP,
                    label = 'PARAFUSO #' .. (i + 1),
                    neededDeg = 720.0,
                }
            end
            return points
        end
    },

    -- ─── Profile PANEL (Portas, Capô, Porta-malas) ───────────────────────────
    panel = {
        title = 'CORTE DE PAINEL E DOBRADIÇAS',
        helpText = 'Corte os pontos de sustentação da chapa',
        toolClass = 'cut',
        fov = 48.0,
        calculateCamera = function(vehicle, boneKey)
            local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, boneKey)
            local isDoor = boneKey:find('door') ~= nil
            local camPos
            if isDoor then
                camPos = bonePos + (rightV * (sideSign * 1.6)) + (up * 0.2)
            else
                camPos = bonePos + (fwd * (boneKey:find('bonnet') and 1.6 or -1.6)) + (up * 0.5)
            end
            return camPos, bonePos
        end,
        generatePoints = function(vehicle, boneKey)
            local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, boneKey)
            local points = {}
            -- 2 pontos principais de articulação/corte
            points[1] = {
                id = 'cut_pt_1',
                worldPos = bonePos + (up * 0.2) + (rightV * (sideSign * 0.05)),
                label = 'DOBRADIÇA SUP',
                neededDeg = 720.0,
            }
            points[2] = {
                id = 'cut_pt_2',
                worldPos = bonePos - (up * 0.2) + (rightV * (sideSign * 0.05)),
                label = 'DOBRADIÇA INF',
                neededDeg = 720.0,
            }
            return points
        end
    },

    -- ─── Profile ENGINE (Cofre do Motor) ─────────────────────────────────────
    engine = {
        title = 'DESACOPLAMENTO DO MOTOR',
        helpText = 'Remova os fixadores do bloco do motor com a parafusadeira',
        toolClass = 'screw',
        fov = 44.0,
        calculateCamera = function(vehicle, boneKey)
            local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, 'engine')
            if boneId == -1 then
                bonePos = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 1.4, 0.4)
            end
            local camPos = bonePos + (up * 1.1) - (fwd * 0.3)
            return camPos, bonePos
        end,
        generatePoints = function(vehicle, boneKey)
            local boneId, bonePos, sideSign, fwd, rightV, up = Proj.GetBoneData(vehicle, 'engine')
            if boneId == -1 then
                bonePos = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 1.4, 0.4)
            end
            local points = {}
            local offsets = {
                { x = -0.25, y = 0.2, label = 'CALÇO ESQ' },
                { x = 0.25,  y = 0.2, label = 'CALÇO DIR' },
                { x = 0.0,   y = -0.3, label = 'CARDAN/CÂMBIO' },
            }
            for i, off in ipairs(offsets) do
                points[#points + 1] = {
                    id = 'eng_pt_' .. i,
                    worldPos = bonePos + (rightV * off.x) + (fwd * off.y) + (up * 0.05),
                    label = off.label,
                    neededDeg = 720.0,
                }
            end
            return points
        end
    },

    -- ─── Profile CARCASS (Carcaça / Maçarico) ─────────────────────────────────
    carcass = {
        title = 'SECCIONAMENTO DA CARCAÇA',
        helpText = 'Corte as vigas estruturais com o maçarico',
        toolClass = 'cut',
        fov = 52.0,
        calculateCamera = function(vehicle, boneKey)
            local coords = GetEntityCoords(vehicle)
            local camPos = GetOffsetFromEntityInWorldCoords(vehicle, 2.0, 0.0, 1.2)
            return camPos, coords
        end,
        generatePoints = function(vehicle, boneKey)
            local coords = GetEntityCoords(vehicle)
            local fwd = GetEntityForwardVector(vehicle)
            local up = vector3(0, 0, 1)
            local rightV = vector3(fwd.y, -fwd.x, 0.0)
            local points = {
                { id = 'carcass_pt_1', worldPos = coords + (fwd * 0.8) + (up * 0.3), label = 'COLUNA A', neededDeg = 900.0 },
                { id = 'carcass_pt_2', worldPos = coords - (fwd * 0.8) + (up * 0.3), label = 'COLUNA C', neededDeg = 900.0 },
            }
            return points
        end
    }
}

--- Obtém a definição de um profile por nome.
---@param name string
---@return table|nil
function Profiles.Get(name)
    return Profiles.list[name]
end

return Profiles
