-- Field GPS for Lightyear Frontier
-- Copyright (C) 2026 sceptiQ
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. This program is distributed WITHOUT ANY WARRANTY; see
-- the GNU General Public License for details: <https://www.gnu.org/licenses/>.

-- Hilfsfunktionen: Logging, Winkelmathematik und defensiver Zugriff auf
-- UObject-Properties und -Funktionen.
--
-- Alles hier drin muss auch dann noch funktionieren, wenn eine erwartete
-- Property oder Funktion im Spiel fehlt -- etwa nach einem Spielupdate.

local Config = require("config")

local Util = {}

-------------------------------------------------------------------------------
-- Logging
-------------------------------------------------------------------------------
function Util.log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print(Config.LogPrefix .. (ok and msg or tostring(fmt)) .. "\n")
end

function Util.verbose(fmt, ...)
    if Config.VerboseTick then Util.log(fmt, ...) end
end

-------------------------------------------------------------------------------
-- Mathematik
-------------------------------------------------------------------------------

-- Bringt einen Winkel auf (-180, 180].
function Util.normalizeAngle(deg)
    deg = deg % 360.0
    if deg > 180.0 then deg = deg - 360.0 end
    return deg
end

function Util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Vorwaertsvektor aus dem Yaw. Bewusst selbst gerechnet statt ueber
-- GetActorForwardVector, damit der Mod von einer UFunction weniger abhaengt.
function Util.yawToForward(yawDeg)
    local r = math.rad(yawDeg)
    return { X = math.cos(r), Y = math.sin(r), Z = 0.0 }
end

function Util.dot2D(a, b)
    return a.X * b.X + a.Y * b.Y
end

-------------------------------------------------------------------------------
-- Defensiver UObject-Zugriff
-------------------------------------------------------------------------------
function Util.isValid(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

-- Liest eine Property; gibt nil zurueck, wenn sie nicht existiert.
function Util.get(obj, propName)
    if not Util.isValid(obj) then return nil end
    local ok, value = pcall(function() return obj[propName] end)
    if ok then return value end
    return nil
end

-- Ruft eine Funktion auf; gibt (false, nil) zurueck, wenn sie nicht existiert.
--
-- Wichtig: Der Rueckgabewert sagt nur, ob der Aufruf angenommen wurde -- nicht,
-- ob er etwas bewirkt hat. Jeder Schreibvorgang ins Spiel sollte deshalb
-- zurueckgelesen werden (siehe Vehicle.setSteering).
--
-- Ebenso wichtig: niemals selbst gebaute Struct- oder FName-Parameter
-- uebergeben. Ein solcher Aufruf loest eine native Zugriffsverletzung aus, und
-- die faengt pcall nicht ab -- das Spiel stuerzt sofort ab. Werte, die aus dem
-- Spiel GELESEN wurden, gehen dagegen problemlos wieder hinein.
function Util.call(obj, fnName, ...)
    if not Util.isValid(obj) then return false, nil end
    local args = { ... }
    local ok, result = pcall(function()
        return obj[fnName](obj, table.unpack(args))
    end)
    if ok then return true, result end
    return false, nil
end

-- Prueft, ob eine UFunction auf der Klasse des Objekts existiert.
function Util.hasFunction(obj, fnName)
    if not Util.isValid(obj) then return false end
    local ok, found = pcall(function()
        return obj[fnName] ~= nil
    end)
    return ok and found == true
end

function Util.className(obj)
    if not Util.isValid(obj) then return "<ungueltig>" end
    local ok, name = pcall(function()
        return obj:GetClass():GetFName():ToString()
    end)
    if ok and name then return name end
    return "<unbekannt>"
end

function Util.fullName(obj)
    if not Util.isValid(obj) then return "<ungueltig>" end
    local ok, name = pcall(function() return obj:GetFullName() end)
    if ok and name then return name end
    return "<unbekannt>"
end

-------------------------------------------------------------------------------
-- Spielspezifische Abfragen
-------------------------------------------------------------------------------
function Util.getPlayerController()
    local ok, pc = pcall(function()
        local UEHelpers = require("UEHelpers")
        return UEHelpers.GetPlayerController()
    end)
    if ok and Util.isValid(pc) then return pc end

    -- Rueckfallebene ohne UEHelpers.
    local pc2 = FindFirstOf("PlayerController")
    if Util.isValid(pc2) then return pc2 end
    return nil
end

-- Der lokal kontrollierte Mech-Pawn, oder nil.
function Util.getLocalMech()
    local pc = Util.getPlayerController()
    if not Util.isValid(pc) then return nil, "kein PlayerController" end

    local pawn = Util.get(pc, "Pawn")
    if not Util.isValid(pawn) then
        pawn = Util.get(pc, "AcknowledgedPawn")
    end
    if not Util.isValid(pawn) then return nil, "kein Pawn (sitzt du im Mech?)" end

    local cls = Util.className(pawn)
    for _, want in ipairs(Config.MechClassNames) do
        if cls == want then return pawn end
    end

    -- Klassenname weicht ab: akzeptieren, wenn das Modus-Flag existiert.
    -- So bleibt der Mod nach einem Spielupdate funktionsfaehig.
    if Util.get(pawn, Config.TransformedFlag) ~= nil then
        return pawn
    end

    return nil, string.format("Pawn ist kein Mech (Klasse: %s)", cls)
end

-- Traktor-/Erntemodus aktiv? Gibt true/false zurueck, oder nil wenn sich der
-- Zustand nicht ermitteln laesst.
--
-- Das Spiel bietet dafuer die UFunction AMechCharacter::IsTransformed(); eine
-- gleichnamige Property gibt es nicht. Der Property-Weg bleibt nur als
-- Rueckfallebene fuer den Fall, dass ein Update das aendert.
function Util.getTransformedState(mech)
    local ok, result = Util.call(mech, Config.TransformedFunction)
    if ok and type(result) == "boolean" then return result end

    local flag = Util.get(mech, Config.TransformedFlag)
    if type(flag) == "boolean" then return flag end

    return nil
end

-- Ist der Mech aktuell im Traktor-/Erntemodus?
function Util.isInFieldMode(mech)
    local flag = Util.getTransformedState(mech)
    if flag == nil then
        -- Zustand unbekannt: nicht blockieren, aber einmal darauf hinweisen.
        return true, "Modus nicht ermittelbar, Pruefung uebersprungen"
    end
    if flag ~= true then
        return false, "nicht im Traktormodus"
    end

    if #Config.RequiredAttachments > 0 then
        local name = Util.get(mech, "EquippedTractorAttachmentName")
        if name ~= nil then
            local nameStr = tostring(name)
            if not pcall(function() nameStr = name:ToString() end) then
                nameStr = tostring(name)
            end
            for _, want in ipairs(Config.RequiredAttachments) do
                if nameStr == want then return true end
            end
            return false,
                   string.format("Anbaugeraet '%s' nicht freigegeben", nameStr)
        end
    end

    return true
end

function Util.getLocation(actor)
    local ok, loc = Util.call(actor, "K2_GetActorLocation")
    if ok and loc then return { X = loc.X, Y = loc.Y, Z = loc.Z } end
    return nil
end

function Util.getYaw(actor)
    local ok, rot = Util.call(actor, "K2_GetActorRotation")
    if ok and rot then return rot.Yaw end
    return nil
end

-- Spielzeit in Sekunden.
--
-- Dient zweierlei: der Erkennung, ob ein Frame schon verarbeitet wurde, und
-- der tatsaechlich verstrichenen Zeit auf der LoopAsync-Rueckfallebene, die
-- ihr Intervall nur ungefaehr einhaelt.
function Util.getGameTime(actor)
    local ok, t = Util.call(actor, "GetGameTimeSinceCreation")
    if ok and type(t) == "number" then return t end
    return nil
end

-- Signierte Vorwaertsgeschwindigkeit in cm/s (negativ = rueckwaerts).
function Util.getForwardSpeed(actor, yaw)
    local ok, vel = Util.call(actor, "GetVelocity")
    if not ok or vel == nil then return 0.0 end
    local fwd = Util.yawToForward(yaw)
    return Util.dot2D({ X = vel.X, Y = vel.Y }, fwd)
end

return Util
