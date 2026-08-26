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
--   K  = Arbeit starten / beenden
--   L  = Diagnose ins UE4SS-Log
--   F9 = Module neu laden, ohne das Spiel zu beenden
--
-- Scheinwerfer an = Spurhaltung aktiv.
-- Alle Parameter stehen in config.lua.
--
-- Diese Datei haelt nur die Teile, die sich NICHT austauschen lassen:
-- Tastenbelegung, Tick-Hook und die Rueckfallschleife. Die eigentliche
-- Steuerung steht in control.lua und ist damit nachladbar.

local Config  = require("config")
local Util    = require("util")
local Hook    = require("hook")
local Control = require("control")

local loopRunning  = false
local lastTickTime = nil
local reloading    = false

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

-- Ist etwas zu tun? Die Antwort gehoert nach control.lua, weil sich nur das
-- neu laden laesst -- steht die Bedingung hier, kostet jeder neue Zustand
-- einen Spielneustart. Der Rueckfall auf Control.active traegt einen aelteren
-- Stand von control.lua, falls dort busy() noch fehlt.
local function busy()
    local f = Control.busy
    if f then return f() end
    return Control.active == true
end

local function tickEntry(dt, mech)
    -- Waehrend die Module getauscht werden, hier nichts anfassen.
    if reloading then return end

    -- 1. Nichts zu tun? Dann kostet der Mod exakt nichts.
    --    Die Anhaltephase nach dem Abschalten zaehlt als "zu tun": dort wird
    --    das Gas noch kurz auf null gehalten (siehe control.lua).
    if not busy() then return end

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

    Control.tick(dt, mechCache)
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
        if not busy() then
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

Control.startLoop = startLoop

local function taktText()
    if Hook.installed then return "Hook auf " .. tostring(Hook.source) end
    if loopRunning then return "LoopAsync" end
    return "steht"
end

-------------------------------------------------------------------------------
-- Module im laufenden Spiel neu laden
--
-- UE4SS laedt Lua nur beim Spielstart. Ohne diesen Weg kostet jede geaenderte
-- Zahl einen kompletten Neustart -- bei einem Regler, den man einfahren muss,
-- ist das der Unterschied zwischen einer Sitzung und einem Abend.
--
-- Die Module werden aus package.loaded geworfen und neu angefordert. Die
-- Locals oben sind Upvalues der Funktionen hier, ein Neuzuweisen wirkt also
-- auch in tickEntry und in den Tastenbelegungen.
--
-- Zwei Dateien sind bewusst NICHT dabei:
--
--   hook.lua  Der Hook haengt an einer Closure, die tickEntry gefangen hat.
--             Wird das Modul ersetzt, laeuft der alte Hook ins Leere und der
--             Takt reisst ab -- ohne dass man den Grund im Log saehe.
--   main.lua  Diese Datei. Sie haelt Tastenbelegung und Hook; beides laesst
--             sich nicht zurueckziehen. Deshalb steht hier so wenig wie
--             moeglich und die Steuerung in control.lua.
-------------------------------------------------------------------------------
local RELOADABLE = { "config", "util", "field", "vehicle", "steer",
                     "indicator", "control" }

local function reloadModules()
    if reloading then return end
    reloading = true

    -- Jeder Schritt wird VOR seiner Ausfuehrung geloggt. Beim ersten Anlauf
    -- blieb das Spiel im Neuladen stehen, und im Log stand als letztes die
    -- Zeile aus Steer.release -- danach nichts. Ohne Zwischenschritte ist
    -- nicht zu erkennen, an welcher Stelle es haengt.
    local function schritt(t) Util.log("Neuladen: %s", t) end

    schritt("Fuehrung loslassen")
    pcall(function() Control.shutdown() end)

    schritt("Module verwerfen")
    for _, name in ipairs(RELOADABLE) do
        package.loaded[name] = nil
    end

    schritt("Module laden")
    local ok, err = pcall(function()
        Config  = require("config")
        Util    = require("util")
        Control = require("control")
    end)

    if not ok then
        -- Nicht Util.log: das Modul kann gerade das kaputte sein.
        print("[FieldGPS] NEU LADEN FEHLGESCHLAGEN: " .. tostring(err) .. "\n")
        print("[FieldGPS] Der alte Stand laeuft weiter. Fehler beheben und "
              .. "erneut neu laden.\n")
        reloading = false
        return
    end

    schritt("Takt wieder anhaengen")
    Control.startLoop = startLoop

    reloading = false
    Util.log("=== Module neu geladen -- Spurhaltung aus, Takt: %s ===", taktText())
    Util.log("Nicht erfasst: main.lua und hook.lua (dafuer Neustart).")
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

-- Zwei Betriebsarten: K nur Spurhaltung, O vollautomatisch. Welche gilt,
-- entscheidet der Parameter -- abgeschaltet wird spaeter in der Art, in der
-- gestartet wurde (siehe control.lua).
bind(Config.KeyLock, Config.KeyLockMods, function()
    ExecuteInGameThread(function() Control.toggle(false) end)
end)

if Config.KeyAuto then
    bind(Config.KeyAuto, Config.KeyAutoMods, function()
        ExecuteInGameThread(function() Control.toggle(true) end)
    end)
end

bind(Config.KeyDebugDump, Config.KeyDebugDumpMods, function()
    ExecuteInGameThread(function() Control.diagnose(taktText()) end)
end)

if Config.KeyReload then
    bind(Config.KeyReload, Config.KeyReloadMods, function()
        ExecuteInGameThread(reloadModules)
    end)
end

Util.log("=== Feld-GPS bereit ===")
Util.log("Tasten: %s Arbeit an/aus, %s Diagnose%s",
         Config.KeyLock, Config.KeyDebugDump,
         Config.KeyReload and (", " .. Config.KeyReload .. " Neuladen") or "")

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
