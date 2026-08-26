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

-------------------------------------------------------------------------------
-- Anbaugeraet und Gas
--
-- Beides haengt am selben Beinmodul wie die Lenkung:
--
--   ATreadsLegModule::SetAttachmentActive(bool) / IsAttachmentActive()
--   AMechLegModule::SetThrottle(float, bool bForce) / GetThrottle()
--
-- Damit laesst sich das Ende einer Bahn in einem Zug erledigen, statt
-- Werkzeug, Gas und Spurhaltung einzeln wegzuschalten (siehe main.lua).
-------------------------------------------------------------------------------

-- Anbaugeraet ein- oder ausschalten -- das, was sonst die Leertaste tut.
-- Rueckgabe: erfolgreich, zurueckgelesener Zustand, Grund.
function Vehicle.setAttachmentActive(mech, on)
    local mod, why = Vehicle.getLegModule(mech)
    if not mod then return false, nil, why end

    if not Util.call(mod, "SetAttachmentActive", on) then
        return false, nil, "SetAttachmentActive nicht aufrufbar"
    end

    -- Nicht "(ok and back or nil)" schreiben: bei back == false ergaebe das
    -- nil, und ein erfolgreiches Ausheben saehe im Log wie ein Fehlschlag aus.
    local ok, back = Util.call(mod, "IsAttachmentActive")
    if ok and type(back) == "boolean" then return true, back end
    return true, nil
end

-- Ist das Anbaugeraet gerade eingeschaltet? Rueckgabe: lesbar, Zustand.
function Vehicle.isAttachmentActive(mech)
    local mod = Vehicle.getLegModule(mech)
    if not mod then return false, nil end

    local ok, back = Util.call(mod, "IsAttachmentActive")
    if ok and type(back) == "boolean" then return true, back end
    return false, nil
end

-- Gas setzen. Das Gas ist gerastet: einmal gestellt, bleibt es stehen -- ohne
-- Zuruecknehmen faehrt der Mech nach dem Abschalten der Spurhaltung weiter.
-- Rueckgabe: erfolgreich, zurueckgelesener Wert, Grund.
function Vehicle.setThrottle(mech, value, force)
    local mod, why = Vehicle.getLegModule(mech)
    if not mod then return false, nil, why end

    if not Util.call(mod, "SetThrottle", value, force == true) then
        return false, nil, "SetThrottle nicht aufrufbar"
    end

    local ok, back = Util.call(mod, "GetThrottle")
    if ok and type(back) == "number" then return true, back end
    return true, nil
end

-------------------------------------------------------------------------------
-- Auto-Fahren abbrechen
--
-- Der eigentliche Hebel fuer das, was sich wie Tempomat anfuehlt. Er sitzt am
-- MECH, nicht am Beinmodul:
--
--   AMechCharacter::StopAutoMoving()
--
-- Das Gas dagegen ist der falsche Kanal: gemessen wurde "gesetzt 0.0 /
-- wirksam 1.0" -- das Spiel schreibt Vollgas in jedem Frame nach, solange das
-- Auto-Fahren laeuft. Eine Abfrage des Zustands gibt es nicht; ob es gewirkt
-- hat, zeigt Vehicle.getThrottleInput().
-------------------------------------------------------------------------------
function Vehicle.stopAutoMoving(mech)
    if not Util.isValid(mech) then return false end
    return (Util.call(mech, "StopAutoMoving"))
end

-------------------------------------------------------------------------------
-- Auto-Fahren einschalten -- soweit das ueberhaupt geht
--
-- Ein Gegenstueck zu StopAutoMoving() gibt es nicht. Belegt an der Quelle: Die
-- Exe enthaelt genau drei passende Zeichenketten -- "ToggleAutoMove" (nur auf
-- AFarmerCharacter, dem Farmer zu Fuss), "StopAutoMoving" und "AutoMove", den
-- Namen der Eingabeaktion. Ein "InpActEvt_AutoMove" fehlt ebenfalls, die
-- Aktion wird also nativ gebunden -- und native Handler stehen nicht in der
-- Reflection.
--
-- Was NICHT geht, gemessen und damit erledigt:
--
--   ToggleAutoMove auf dem Piloten   Der Aufruf wird angenommen -- der Mech
--   (AMechCharacter.PilotCharacter)  bewegt sich aber nicht. Gemessen: "Gas
--                                    vorher 0.0", zwei Sekunden spaeter immer
--                                    noch 0.0. Es ist das Auto-Laufen des
--                                    Farmers zu Fuss, nicht das des Fahrzeugs.
--   ToggleAutoMove am Mech           Existiert dort gar nicht.
--   InpActEvt_AutoMove               Gibt es nicht; die Aktion wird nativ
--                                    gebunden, und native Handler stehen nicht
--                                    in der Reflection.
--
-- Bleibt der Gashebel selbst. Das Gas ist gerastet -- ein EINZELNER Aufruf
-- koennte also genau das sein, was die Taste G stellt. Ob er stehen bleibt,
-- sagt nicht der Rueckgabewert, sondern getThrottleInput() ein paar Sekunden
-- spaeter, ohne dass der Mod dazwischen schreibt (siehe control.lua).
function Vehicle.getPilot(mech)
    local p = Util.get(mech, "PilotCharacter")
    if Util.isValid(p) then return p end
    return nil
end

function Vehicle.startAutoMoving(mech, throttle)
    if not Util.isValid(mech) then return nil end

    local mod = Vehicle.getLegModule(mech)
    if mod and Util.call(mod, "SetThrottle", throttle or 1.0, true) then
        return "SetThrottle"
    end

    return nil
end

-------------------------------------------------------------------------------
-- Die Bewegungskomponente selbst
--
-- GetThrottle() am Beinmodul liest den Wert zurueck, den WIR gesetzt haben --
-- nicht den, mit dem das Fahrwerk faehrt. Gemessen: Gas 0.0 zurueckgelesen,
-- waehrend das Tempo von 519 auf 974 cm/s stieg. Der wirksame Wert steht in
-- der Chaos-Komponente (RawThrottleInput -> ThrottleInput), abfragbar ueber
-- GetThrottleInput().
-------------------------------------------------------------------------------
function Vehicle.getMovementComponent(mech)
    local mod = Vehicle.getLegModule(mech)
    if not mod then return nil end

    local ok, mc = Util.call(mod, "GetMovementComponent")
    if ok and Util.isValid(mc) then return mc end
    return nil
end

-- Der Gaswert, mit dem die Komponente wirklich rechnet. nil = nicht lesbar.
function Vehicle.getThrottleInput(mech)
    local mc = Vehicle.getMovementComponent(mech)
    if not mc then return nil end

    local ok, v = Util.call(mc, "GetThrottleInput")
    if ok and type(v) == "number" then return v end
    return nil
end

-- Handbremse. Ein vom Gas unabhaengiger Kanal -- das Spiel benutzt ihn selbst,
-- um bei Null-Eingabe anzuhalten (bApplyHandbrakeForZeroInput).
-- Rueckgabe: erfolgreich, zurueckgelesener Zustand, Grund.
function Vehicle.setHandbrake(mech, on)
    local mod, why = Vehicle.getLegModule(mech)
    if not mod then return false, nil, why end

    if not Util.call(mod, "SetHandbrake", on) then
        return false, nil, "SetHandbrake nicht aufrufbar"
    end

    local ok, back = Util.call(mod, "GetHandbrake")
    if ok and type(back) == "boolean" then return true, back end
    return true, nil
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
