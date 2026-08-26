-- Field GPS for Lightyear Frontier
-- Copyright (C) 2026 sceptiQ
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. This program is distributed WITHOUT ANY WARRANTY; see
-- the GNU General Public License for details: <https://www.gnu.org/licenses/>.

-- Zustandsanzeige: die Scheinwerfer des Mechs.
--
-- Scheinwerfer an = Spurhaltung aktiv.
--
-- Kein Text, kein Widget, keine gezeichneten Linien -- nur ein Bool auf dem
-- Mech, also dieselbe Art Aufruf wie SetSteering. Das ist Absicht: In diesem
-- Shipping-Build ist DrawDebugLine wirkungslos, das Spiel hat keine eigene
-- AHUD-Klasse, und selbst erzeugte UMG-Widgets haengen sich zwar ein, sind
-- aber nicht zu sehen.
--
-- Der vorherige Zustand der Scheinwerfer wird gemerkt und beim Abschalten
-- wiederhergestellt -- sonst nimmt der Mod dem Spieler eine Funktion weg,
-- die ihm gehoert.

local Config = require("config")
local Util   = require("util")

local Indicator = {}

-- nil = wir haben die Scheinwerfer noch nicht angefasst.
local wasOn = nil

-- Zustand anzeigen. Wird aus dem Takt gerufen und ist deshalb billig
-- gehalten: geschrieben wird nur, wenn sich der Zustand geaendert hat.
function Indicator.set(mech, on)
    if not Config.UseHeadlightIndicator then return false end
    if not Util.isValid(mech) then return false end

    if wasOn == nil then
        local ok, state = Util.call(mech, "AreHeadlightsOn")
        wasOn = (ok and state == true)
    elseif Indicator.shown == on then
        return true
    end

    -- Im Coop laeuft der Schalter ueber den Server; die lokale Funktion ist
    -- der Normalfall, der Server-Aufruf die Rueckfallebene.
    local ok = Util.call(mech, "SetHeadlightsOn", on, false)
    if not ok then
        ok = Util.call(mech, "Server_SetHeadlightsOn", on)
    end

    Indicator.shown = on
    return ok
end

-- Ursprungszustand wiederherstellen. Beim Abschalten der Spurhaltung, beim
-- Aussteigen und beim Verlassen des Traktormodus.
function Indicator.restore(mech)
    if wasOn == nil then return end

    if Util.isValid(mech) then
        local ok = Util.call(mech, "SetHeadlightsOn", wasOn, false)
        if not ok then Util.call(mech, "Server_SetHeadlightsOn", wasOn) end
    end

    wasOn          = nil
    Indicator.shown = nil
end

return Indicator
