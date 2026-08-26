-- Field GPS for Lightyear Frontier
-- Copyright (C) 2026 sceptiQ
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. This program is distributed WITHOUT ANY WARRANTY; see
-- the GNU General Public License for details: <https://www.gnu.org/licenses/>.

-- Das Kettenfahrwerk des Traktormodus -- der Lenkkanal des Mods.
--
-- Der Mech hat ZWEI Bewegungssysteme, und das ist die wichtigste Tatsache im
-- ganzen Projekt:
--
--   AMechCharacter
--     .MovementComponent ........... UBipedalMovementComponent
--     :GetEquippedLegModule() ...... ATreadsLegModule / BP_HarvesterLegModule_C
--        .MovementComponent ........ UCustomVehicleMovementComponent
--                                    : UChaosWheeledVehicleMovementComponent
--                                      bIsTank = true
--
-- Im Traktormodus faehrt die VEHICLE-Komponente. Die Bipedal-Komponente
-- tickt weiter, steuert aber nichts: ihr ActiveInputVector liest null,
-- waehrend der Mech mit ueber 300 cm/s faehrt, und ClearInput() in jedem
-- einzelnen Frame bremst ihn nicht ab.
--
-- Das Beinmodul bietet die Lenkung selbst an, als gewoehnliche UFunction:
--
--   SetSteering(-1 .. +1) / GetSteering() / GetThrottle() / GetForwardSpeed()
--
-- Das ist derselbe Eingang, den die Tastenbelegung des Spiels benutzt: kein
-- Eingriff in die Physik, keine erzwungene Rotation, coop-vertraeglich.

local Util = require("util")

local Vehicle = {}

Vehicle.available = nil     -- nil = noch nicht geprueft
Vehicle.lastSteer = 0.0
Vehicle.lastRead  = 0.0

-- Das aktive Beinmodul. Es wechselt beim Transformieren, deshalb wird es
-- jeden Takt frisch geholt statt zwischengespeichert -- ein Funktionsaufruf
-- ist billiger als ein falsch gemerkter Zeiger auf ein zerstoertes Modul.
function Vehicle.getLegModule(mech)
    if not Util.isValid(mech) then return nil, "kein Mech" end

    local ok, mod = Util.call(mech, "GetEquippedLegModule")
    if not ok then return nil, "GetEquippedLegModule nicht aufrufbar" end
    if not Util.isValid(mod) then return nil, "kein Beinmodul aktiv" end

    return mod
end

-- Lenkung setzen. Rueckgabe: erfolgreich, zurueckgelesener Wert, Grund.
--
-- Das Ruecklesen ist der Punkt: Es sagt, ob der Schreibvorgang tatsaechlich
-- angekommen ist, statt es aus dem Verhalten des Mechs erraten zu muessen.
function Vehicle.setSteering(mech, value)
    local mod, why = Vehicle.getLegModule(mech)
    if not mod then
        Vehicle.available = false
        return false, 0.0, why
    end

    value = Util.clamp(value, -1.0, 1.0)

    if not Util.call(mod, "SetSteering", value) then
        Vehicle.available = false
        return false, 0.0, "SetSteering nicht aufrufbar"
    end

    Vehicle.available = true
    Vehicle.lastSteer = value

    local okR, back = Util.call(mod, "GetSteering")
    if okR and type(back) == "number" then Vehicle.lastRead = back end

    return true, Vehicle.lastRead
end

-- Lenkung loslassen. Muss beim Abschalten passieren, sonst bleibt der
-- Einschlag stehen und der Mech dreht sich im Kreis.
function Vehicle.release(mech)
    local mod = Vehicle.getLegModule(mech)
    if not mod then return end
    Util.call(mod, "SetSteering", 0.0)
    Vehicle.lastSteer = 0.0
end

-- Messwerte des Fahrwerks, fuer die Diagnose.
function Vehicle.info(mech)
    local mod, why = Vehicle.getLegModule(mech)
    if not mod then return nil, why end

    local function num(fn)
        local ok, v = Util.call(mod, fn)
        if ok and type(v) == "number" then return v end
        return nil
    end

    return {
        klasse   = Util.className(mod),
        steering = num("GetSteering"),
        throttle = num("GetThrottle"),
        speed    = num("GetForwardSpeed"),
        rpm      = num("GetEngineRPM"),
    }
end

return Vehicle
