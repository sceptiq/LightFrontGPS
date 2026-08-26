-- Field GPS for Lightyear Frontier
-- Copyright (C) 2026 sceptiQ
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. This program is distributed WITHOUT ANY WARRANTY; see
-- the GNU General Public License for details: <https://www.gnu.org/licenses/>.

-- Feld-GPS fuer Lightyear Frontier
--
-- Spurhaltung fuer den Traktormodus des Mechs: der Mod richtet das
-- Kettenfahrwerk an der Reihenrichtung des Feldes aus und haelt die Spur.
--
--   K = Spurhaltung an/aus
--   L = Diagnose ins UE4SS-Log
--
-- Scheinwerfer an = Spurhaltung aktiv.
-- Alle Parameter stehen in config.lua.

local Config    = require("config")
local Util      = require("util")
local Field     = require("field")
local Steer     = require("steer")
local Indicator = require("indicator")
local Hook      = require("hook")
local Vehicle   = require("vehicle")

-------------------------------------------------------------------------------
-- Zustand
-------------------------------------------------------------------------------
local active         = false   -- Spurhaltung an?
local targetYaw      = nil     -- angepeilte Fahrtrichtung
local lastYaw        = nil     -- Yaw des letzten Frames, fuer die Drehrate
local retargetTimer  = 0.0
local lastError      = 0.0
local flagAvailable  = false   -- laesst sich der Traktormodus abfragen?
local activeMechName = nil     -- Ersatzpruefung, falls nicht

local loopRunning  = false
local lastTickTime = nil

-------------------------------------------------------------------------------
-- Zielwinkel neu bestimmen und uebernehmen.
--
-- allowJump = true erlaubt beliebige Spruenge (beim Einschalten), sonst wird
-- ein zu grosser Sprung verworfen.
-------------------------------------------------------------------------------
local function refreshTarget(mech, allowJump)
    local newYaw, source = Field.pickTargetYaw(mech)
    if not newYaw then return false, source end

    if targetYaw and not allowJump then
        local delta = math.abs(Util.normalizeAngle(newYaw - targetYaw))
        if delta > Config.RetargetMaxDelta then return true, nil end
    end

    targetYaw = newYaw
    return true, source
end

-------------------------------------------------------------------------------
-- Regelkreis
-------------------------------------------------------------------------------
local function turnOff(reason)
    if not active then return end

    active     = false
    targetYaw  = nil
    lastYaw    = nil

    local mech = Util.getLocalMech()
    Steer.release(mech)
    Indicator.restore(mech)
    Field.setAnchor(nil)   -- Bezugslinie verwerfen

    Util.log("Spurhaltung aus%s", reason and (" (" .. reason .. ")") or "")
end

local function onTick(dt, mech)
    if not Util.isValid(mech) then
        turnOff("Mech nicht mehr gueltig")
        return
    end

    -- Nach dem Aussteigen liefert der Controller den Farmer statt des Mechs.
    -- Auf keinen Fall weiterfuehren.
    if flagAvailable then
        if Util.getTransformedState(mech) ~= true then
            turnOff("Traktormodus verlassen")
            return
        end
    elseif Util.fullName(mech) ~= activeMechName then
        turnOff("Pawn gewechselt")
        return
    end

    local yaw = Util.getYaw(mech)
    if not yaw then return end

    -- Ziel regelmaessig nachfuehren, damit es nach einer Kehre auf die
    -- Gegenrichtung umspringt, statt den Mech zurueckzudrehen.
    retargetTimer = retargetTimer + dt
    if retargetTimer >= Config.RetargetInterval then
        retargetTimer = 0.0
        refreshTarget(mech, false)
    end
    if not targetYaw then return end

    local yawRate = 0.0
    if lastYaw then yawRate = Util.normalizeAngle(yaw - lastYaw) / dt end
    lastYaw = yaw

    lastError = Util.normalizeAngle(targetYaw - yaw)

    Indicator.set(mech, true)

    local speed = Util.getForwardSpeed(mech, yaw)
    local _, playerVec = Steer.getPlayerInput(mech)

    -- Steuert der Spieler deutlich woanders hin, wird nicht dagegengehalten.
    -- Die Spurhaltung bleibt dabei an und greift wieder, sobald er loslaesst
    -- -- so laesst sich am Vorgewende normal wenden.
    local deviation = Steer.playerDeviation(playerVec, targetYaw)
    if deviation and deviation > Config.PlayerOverrideDegrees then
        Steer.release(mech)
        return
    end

    Steer.applyVehicle(mech, targetYaw, dt, yawRate, speed)

    Util.verbose("err=%.2f rate=%.2f lenk=%.3f tempo=%.0f",
                 lastError, yawRate, Steer.lastSteer, speed)
end

-------------------------------------------------------------------------------
-- Gemeinsamer Einstieg fuer Hook und LoopAsync
--
-- Die Reihenfolge ist hier das Entscheidende: Diese Funktion laeuft in jedem
-- Frame, im Coop einmal je Mech-Instanz. Deshalb steht die billigste und
-- haeufigste Frage ganz vorn -- ist ueberhaupt etwas zu tun? Ist die
-- Spurhaltung aus, kehrt sie sofort zurueck, ohne ein einziges Spielobjekt
-- anzufassen.
-------------------------------------------------------------------------------
local frameStamp = nil   -- Spielzeit des zuletzt verarbeiteten Frames
local mechCache  = nil   -- gemerkter eigener Mech
local mechAge    = 0     -- wie viele Frames er schon gilt

local function tickEntry(dt, mech)
    -- 1. Nichts zu tun? Dann kostet der Mod exakt nichts.
    if not active then return end

    -- 2. Eigenen Mech holen. Util.getLocalMech baut einen Klassennamen als
    --    Zeichenkette, deshalb wird das Ergebnis gemerkt und nur zweimal je
    --    Sekunde neu ermittelt -- oft genug, um Aussteigen oder einen
    --    Pawn-Wechsel zu bemerken, selten genug, um nicht ins Gewicht zu
    --    fallen.
    mechAge = mechAge + 1
    if not Util.isValid(mechCache) or mechAge >= 30 then
        mechCache = Util.getLocalMech()
        mechAge   = 0
    end
    if not Util.isValid(mechCache) then return end

    -- 3. Der Hook feuert einmal je Mech-Instanz. Statt Objektpfade zu
    --    vergleichen, wird pro Frame nur der erste Aufruf verarbeitet --
    --    erkennbar an der Spielzeit, die innerhalb eines Frames gleich bleibt.
    local now = Util.getGameTime(mechCache)
    if now ~= nil then
        if now == frameStamp then return end
        frameStamp = now
    end

    onTick(dt, mechCache)
end

-------------------------------------------------------------------------------
-- Takt
--
-- Erste Wahl ist der Hook auf das Blueprint-Ereignis ReceiveTick: jeden
-- Frame, auf dem Spielthread, an fester Stelle im Frame. LoopAsync bleibt als
-- Rueckfallebene, damit ein Spielupdate den Mod nicht stilllegt.
-------------------------------------------------------------------------------
local function startLoop()
    -- Der Hook wird einmalig gesetzt und bleibt danach stehen; er kostet
    -- nichts, solange tickEntry sofort zurueckkehrt.
    if Config.PreferTickHook and Hook.install(tickEntry) then
        loopRunning = true
        return
    end

    if loopRunning then return end
    loopRunning = true

    local dt = Config.TickIntervalMs / 1000.0

    LoopAsync(Config.TickIntervalMs, function()
        if not active then
            loopRunning = false
            return true          -- Schleife beenden
        end

        ExecuteInGameThread(function()
            local mech = Util.getLocalMech()
            if not mech then return end

            -- Tatsaechlich verstrichene Zeit statt des Sollintervalls:
            -- LoopAsync haelt seinen Takt nur ungefaehr ein.
            local now  = Util.getGameTime(mech)
            local real = dt
            if now and lastTickTime and now > lastTickTime then
                real = Util.clamp(now - lastTickTime, 0.001, 0.25)
            end
            lastTickTime = now

            tickEntry(real, mech)
        end)

        return false
    end)
end

-------------------------------------------------------------------------------
-- Einschalten
-------------------------------------------------------------------------------

-- Voraussetzungen pruefen und Ausgangszustand herstellen.
local function prepare()
    local mech, why = Util.getLocalMech()
    if not mech then
        Util.log("Nicht moeglich: %s", why or "kein Mech")
        return nil
    end

    local inMode, modeWhy = Util.isInFieldMode(mech)
    if not inMode then
        Util.log("Nicht moeglich: %s", modeWhy or "falscher Modus")
        return nil
    end
    if modeWhy then Util.log("Hinweis: %s", modeWhy) end

    Field.invalidateCache()

    local ok, source = refreshTarget(mech, true)
    if not ok then
        Util.log("Kein Feld erkannt: %s", source or "unbekannt")
        return nil
    end

    lastYaw        = Util.getYaw(mech)
    retargetTimer  = 0.0
    flagAvailable  = (Util.getTransformedState(mech) ~= nil)
    activeMechName = Util.fullName(mech)

    return mech, source
end

local function toggle()
    if active then
        turnOff()
        return
    end

    local mech, source = prepare()
    if not mech then return end
    if not Steer.detect(mech) then return end

    -- Die aktuelle Position wird zum Anker der Bezugslinie -- das "A" einer
    -- AB-Linie. Der Anker friert zugleich die Feldachse ein: ab jetzt gilt
    -- die Fahrtrichtung, die der Spieler beim Einrasten hatte, und nicht eine
    -- Messung eine halbe Sekunde spaeter (siehe field.lua).
    if Field.setAnchor(Util.getLocation(mech), targetYaw) then
        Util.log("Spuranker gesetzt -- Spurabstand %.0f uu", Field.trackSpacing())
    end

    active = true
    Indicator.set(mech, true)
    startLoop()

    Util.log("Spurhaltung an -- Spur %.0f Grad (%s), Abweichung %.1f Grad",
             targetYaw or 0.0, source or "Feld", lastError)
end

-------------------------------------------------------------------------------
-- Diagnose (Taste L)
-------------------------------------------------------------------------------
local function debugDump()
    Util.log("---- Diagnose ----")
    Util.log("Spurhaltung: %s", active and "an" or "aus")
    Util.log("Takt: %s", Hook.installed
             and ("Hook auf " .. tostring(Hook.source))
             or (loopRunning and "LoopAsync" or "steht"))

    local mech, why = Util.getLocalMech()
    if not mech then
        Util.log("Mech: %s", why or "nicht gefunden")
    else
        Util.log("Mech: %s", Util.className(mech))
        Util.log("Traktormodus: %s", tostring(Util.getTransformedState(mech)))

        -- Das Fahrwerk ist im Traktormodus die einzig relevante Bewegung.
        local v, vWhy = Vehicle.info(mech)
        if v then
            Util.log("Fahrwerk: %s", v.klasse)
            Util.log("  Lenkung %s / Gas %s / Tempo %s / Drehzahl %s",
                     tostring(v.steering), tostring(v.throttle),
                     tostring(v.speed), tostring(v.rpm))
        else
            Util.log("Fahrwerk: nicht erreichbar (%s)", vWhy or "unbekannt")
        end

        local yaw = Util.getYaw(mech)
        if yaw then
            local mag = Steer.getPlayerInput(mech)
            Util.log("Yaw: %.1f Grad, Tempo: %.0f cm/s, Eingabe: %.2f",
                     yaw, Util.getForwardSpeed(mech, yaw), mag)
        end

        pcall(function() Field.reportSources(mech) end)
    end

    Util.log("Kachelgroesse: %.1f uu", Config.TileSize)
    if targetYaw then
        Util.log("Ziel: %.1f Grad, Abweichung %.2f Grad", targetYaw, lastError)
    end
    Util.log("------------------")
end

-------------------------------------------------------------------------------
-- Tasten
-------------------------------------------------------------------------------
local function resolveKey(name)
    local k = Key[name]
    if k == nil then
        Util.log("Unbekannte Taste in config.lua: %s", tostring(name))
    end
    return k
end

local function resolveMods(names)
    local mods = {}
    for _, n in ipairs(names or {}) do
        local m = ModifierKey[n]
        if m ~= nil then mods[#mods + 1] = m end
    end
    return mods
end

local function bind(keyName, modNames, callback)
    local key = resolveKey(keyName)
    if key == nil then return end

    local mods = resolveMods(modNames)
    if #mods > 0 then
        RegisterKeyBind(key, mods, callback)
    else
        RegisterKeyBind(key, callback)
    end
end

bind(Config.KeyLock, Config.KeyLockMods, function()
    ExecuteInGameThread(toggle)
end)

bind(Config.KeyDebugDump, Config.KeyDebugDumpMods, function()
    ExecuteInGameThread(debugDump)
end)

Util.log("=== Feld-GPS bereit ===")
Util.log("Tasten: %s Spurhaltung an/aus, %s Diagnose",
         Config.KeyLock, Config.KeyDebugDump)

-------------------------------------------------------------------------------
-- Hook nachreichen
--
-- Beim Laden des Mods steht das Level noch nicht, die Blueprint-Klasse ist
-- also noch nicht bekannt und ein Hook darauf schlaegt zwangslaeufig fehl.
-- Deshalb wird es wiederholt versucht. Ohne diese Wiederholung bliebe es beim
-- einen Fehlversuch und der Mod liefe dauerhaft auf LoopAsync -- brauchbar
-- zum Lesen, aber nicht zum Schreiben von Bewegungswerten.
-------------------------------------------------------------------------------
if Config.PreferTickHook then
    local tries = 0
    LoopAsync(2000, function()
        if Hook.installed then return true end

        tries = tries + 1
        if tries > 30 then
            Util.log("Takt: Hook nach %d Versuchen nicht gesetzt -- "
                     .. "LoopAsync uebernimmt.", tries)
            return true
        end

        ExecuteInGameThread(function() Hook.install(tickEntry) end)
        return false
    end)
end
