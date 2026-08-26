-- Field GPS for Lightyear Frontier
-- Copyright (C) 2026 sceptiQ
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. This program is distributed WITHOUT ANY WARRANTY; see
-- the GNU General Public License for details: <https://www.gnu.org/licenses/>.

-- Takt aus dem Spiel selbst.
--
-- Warum das wichtig ist: Ein eigener Zeitgeber (LoopAsync) wacht alle 16 ms
-- auf und schiebt seine Arbeit per ExecuteInGameThread in den Spielthread.
-- Das ist thread-sicher, landet aber an einer UNBESTIMMTEN Stelle im Frame --
-- mal vor, mal nach der Bewegungsberechnung. Zum Lesen ist das egal, zum
-- Schreiben von Bewegungswerten nicht: liegt der Schreibvorgang hinter dem
-- Tick der Bewegungskomponente, wird der Wert ueberschrieben, bevor ihn
-- jemand auswertet.
--
-- BP_TractorMechCharacter_C implementiert ReceiveTick, das Event-Tick des
-- Blueprints. Blueprint-Ereignisse sind UFunctions und damit hookbar; der
-- Hook laeuft jeden Frame, auf dem Spielthread, an fester Stelle im Frame.
--
-- (PlayerTick ist dagegen eine native virtuelle Methode und keine UFunction --
-- RegisterHook scheitert daran.)
--
-- LoopAsync bleibt als Rueckfallebene, damit ein Spielupdate den Mod nicht
-- stilllegt.

local Config = require("config")
local Util   = require("util")

local Hook = {}

Hook.installed = false
Hook.source    = "none"

local callback = nil
local warned   = false   -- Fehlschlaege nur einmal melden, nicht alle 2 s

-- Hook-Parameter kommen je nach Typ als Wrapper oder direkt. Beides annehmen.
local function unwrap(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return p
end

-- Installiert den Hook. Gibt true zurueck, wenn ein Takt gefunden wurde.
function Hook.install(fn)
    if Hook.installed then return true end
    callback = fn

    for _, path in ipairs(Config.TickHookPaths or {}) do
        local ok, err = pcall(function()
            -- Dieser Rumpf laeuft in JEDEM Frame und muss deshalb so wenig
            -- tun wie irgend moeglich. Ob ueberhaupt etwas zu tun ist,
            -- entscheidet der Aufgerufene -- dort steht die Frage vor allen
            -- teuren Pruefungen.
            RegisterHook(path, function(self, deltaParam)
                if not callback then return end

                local mech = unwrap(self)
                if not Util.isValid(mech) then return end

                local dt = unwrap(deltaParam)
                if type(dt) ~= "number" or dt <= 0.0 then dt = 1.0 / 60.0 end
                if dt > 0.25 then dt = 0.25 end

                callback(dt, mech)
            end)
        end)

        if ok then
            Hook.installed = true
            Hook.source    = path
            Util.log("Takt: Hook auf %s steht.", path)
            return true
        elseif not warned then
            Util.log("Takt: Hook auf %s noch nicht moeglich (%s) -- "
                     .. "wird wiederholt, sobald das Level steht.",
                     path, tostring(err))
        end
    end

    warned = true
    return false
end

return Hook
