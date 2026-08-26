-- Field GPS for Lightyear Frontier
-- Copyright (C) 2026 sceptiQ
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. This program is distributed WITHOUT ANY WARRANTY; see
-- the GNU General Public License for details: <https://www.gnu.org/licenses/>.

-- Der Regler, der den Mech auf der Spur haelt.
--
-- Gelenkt wird ausschliesslich ueber SetSteering() des Beinmoduls (siehe
-- vehicle.lua) -- derselbe Eingang, den die Tasten A und D des Spiels
-- bedienen. Deshalb laufen Ketten und Animation korrekt, die Physik bleibt
-- unangetastet, und im Coop repliziert die Bewegung wie eine gewoehnliche
-- Spielereingabe.
--
-- Der Regler selbst ist bewusst schlicht: Proportionalanteil auf den
-- Winkelfehler, Daempfung ueber die Drehrate. Mehr braucht es nicht, solange
-- die Lenkung direkt anliegt.

local Config  = require("config")
local Util    = require("util")
local Vehicle = require("vehicle")
local Field   = require("field")

local Steer = {}

Steer.active    = false
Steer.lastSteer = 0.0

-- Geglaettete Drehrate und zuletzt ausgegebener Einschlag. Beides gehoert zum
-- Regler und wird beim Loslassen zurueckgesetzt.
local rateSmooth  = 0.0
local steerSmooth = 0.0

-------------------------------------------------------------------------------
-- Verfuegbarkeit
-------------------------------------------------------------------------------

-- Prueft, ob der Lenkweg gerade nutzbar ist. Wird beim Einschalten gerufen,
-- nicht zwischengespeichert: das Beinmodul wechselt beim Transformieren.
function Steer.detect(mech)
    local mod, why = Vehicle.getLegModule(mech)
    if not mod then
        Util.log("Kein Beinmodul erreichbar (%s).", why or "unbekannt")
        return false
    end

    if not Util.hasFunction(mod, "SetSteering") then
        Util.log("Beinmodul %s kennt SetSteering nicht.", Util.className(mod))
        return false
    end

    return true
end

-------------------------------------------------------------------------------
-- Spielereingabe
-------------------------------------------------------------------------------

-- Staerke und Richtung der aktuellen Spielereingabe (0 = nichts gedrueckt).
--
-- Gelesen ueber die parameterlose Engine-Funktion, nicht ueber die Property
-- ControlInputVector: Struct-Properties direkt zu lesen ist der Zugriff, der
-- UE4SS zum Absturz bringen kann.
function Steer.getPlayerInput(mech)
    local ok, v = Util.call(mech, "GetPendingMovementInputVector")
    if not ok or v == nil then
        ok, v = Util.call(mech, "GetLastMovementInputVector")
    end
    if not ok or v == nil then return 0.0, nil end

    local x, y = v.X or 0.0, v.Y or 0.0
    return math.sqrt(x * x + y * y), { X = x, Y = y }
end

-- Wie weit weicht die Spielereingabe von der Zielrichtung ab?
-- Rueckgabe in Grad, oder nil wenn keine Eingabe anliegt.
function Steer.playerDeviation(inputVec, targetYaw)
    if inputVec == nil then return nil end

    local mag = math.sqrt(inputVec.X * inputVec.X + inputVec.Y * inputVec.Y)
    if mag < 0.01 then return nil end

    local inputYaw = math.deg(math.atan(inputVec.Y, inputVec.X))
    return math.abs(Util.normalizeAngle(inputYaw - targetYaw))
end

-------------------------------------------------------------------------------
-- Fuehrung loslassen
--
-- Muss bei jedem Abschalten passieren -- auch beim Aussteigen und beim
-- Uebersteuern durch den Spieler. Bleibt ein Einschlag stehen, dreht sich der
-- Mech endlos im Kreis.
-------------------------------------------------------------------------------
function Steer.release(mech)
    Steer.active    = false
    Steer.lastSteer = 0.0
    rateSmooth      = 0.0
    steerSmooth     = 0.0

    if mech ~= nil then Vehicle.release(mech) end
end

-------------------------------------------------------------------------------
-- Ein Regelschritt
-------------------------------------------------------------------------------
function Steer.applyVehicle(mech, targetYaw, dt, yawRate, speed)
    local yaw = Util.getYaw(mech)
    if yaw == nil then return false end

    -- Im Stand nicht lenken: das Fahrwerk ist ein Kettenfahrzeug
    -- (bIsTank = true) und dreht sich bei vollem Einschlag ohne Gas auf der
    -- Stelle, wobei der Regler uebers Ziel schiesst.
    local sp = math.abs(speed or 0.0)
    if sp < (Config.VehicleMinSpeed or 0.0) then
        Vehicle.setSteering(mech, 0.0)
        Steer.lastSteer = 0.0
        rateSmooth      = 0.0
        steerSmooth     = 0.0
        Util.verbose("Fahrwerk: steht (Tempo %.0f) -- keine Lenkung", sp)
        return true
    end

    -- Nicht stur die Achse anpeilen, sondern die Spur: sonst faehrt der Mech
    -- perfekt parallel NEBEN der Reihe und merkt es nie (siehe field.lua).
    local pos = Util.getLocation(mech)
    local guided, cross, lane = Field.guidedYaw(targetYaw, pos, speed)

    local err = Util.normalizeAngle(guided - yaw)

    -- Drehrate tiefpassfiltern, BEVOR sie in den D-Anteil geht. Ohne das
    -- differenziert der Regler das Physik-Zittern des Fahrwerks.
    local tau = Config.VehicleRateSmoothing
    if tau and tau > 0.0 then
        local a = 1.0 - math.exp(-dt / tau)
        rateSmooth = rateSmooth + a * ((yawRate or 0.0) - rateSmooth)
    else
        rateSmooth = yawRate or 0.0
    end

    -- Innerhalb der Totzone geradeaus.
    local want
    if math.abs(err) <= Config.VehicleDeadzone then
        want = 0.0
    else
        want = Config.VehicleKp * err - Config.VehicleKd * rateSmooth
        want = Util.clamp(want, -Config.VehicleMaxSteer, Config.VehicleMaxSteer)
    end

    -- Lenkvollmacht waechst mit dem Tempo. Beim Kettenfahrwerk erzeugt
    -- derselbe Einschlag bei wenig Fahrt eine viel hoehere Drehrate.
    local authority = Util.clamp(sp / (Config.VehicleFullSteerSpeed or 250.0),
                                 0.0, 1.0)
    want = want * authority

    -- Einschlag nur begrenzt schnell aendern.
    local maxStep = (Config.VehicleSlewPerSecond or 999.0) * dt
    local delta   = Util.clamp(want - steerSmooth, -maxStep, maxStep)
    steerSmooth   = steerSmooth + delta

    local ok, back, why = Vehicle.setSteering(mech, steerSmooth)
    Steer.lastSteer = steerSmooth
    Steer.active    = ok

    if not ok then
        Util.log("Fahrwerk: Lenkung nicht moeglich (%s)", why or "unbekannt")
        return false
    end

    -- Der zurueckgelesene Wert ist die Erfolgskontrolle: weicht er dauerhaft
    -- vom geschriebenen ab, ueberschreibt das Spiel unsere Lenkung wieder.
    -- "Versatz" ist der Abstand zur Spurmitte -- die Zahl, an der sich
    -- seitliches Auslaufen zeigt, waehrend der Winkel perfekt stimmt.
    local versatz = "-"
    if cross ~= nil then
        versatz = string.format("%+.0f uu (Spur %d)", cross, lane or 0)
    end

    if math.abs(err) <= Config.VehicleDeadzone then
        Util.verbose("Fahrwerk: auf Spur | Rest %+.2f Grad | Versatz %s | "
                     .. "Lenkung %+.3f -> gelesen %+.3f",
                     err, versatz, steerSmooth, back or 0.0)
    else
        Util.verbose("Fahrwerk: Achse %.1f -> Spurziel %.1f | Yaw %.1f | "
                     .. "Rest %+.2f | Versatz %s | Drehrate %+.1f (roh %+.1f) "
                     .. "| Lenkung %+.3f -> gelesen %+.3f | Tempo %.0f",
                     targetYaw, guided, yaw, err, versatz,
                     rateSmooth, yawRate or 0.0,
                     steerSmooth, back or 0.0, speed or 0.0)
    end

    return true
end

return Steer
