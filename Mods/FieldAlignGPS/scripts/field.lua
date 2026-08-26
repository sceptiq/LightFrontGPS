-- Field GPS for Lightyear Frontier
-- Copyright (C) 2026 sceptiQ
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. This program is distributed WITHOUT ANY WARRANTY; see
-- the GNU General Public License for details: <https://www.gnu.org/licenses/>.

-- Feldachse und Spurfuehrung.
--
-- Zwei Aufgaben:
--
--   1. In welche Richtung laufen die Reihen des Feldes, ueber dem der Mech
--      gerade steht? (Field.pickTargetYaw)
--   2. Auf welcher Linie soll er fahren, und wie weit ist er daneben?
--      (Field.setAnchor, Field.crossTrack, Field.guidedYaw)
--
-- Die Achse wird laufend aus dem Feld unter dem Mech gelesen, nicht einmalig
-- gemerkt: Beete lassen sich frei drehen, ein festgehaltener Winkel waere auf
-- dem naechsten Feld zwangslaeufig falsch. Nur solange die Spurhaltung aktiv
-- ist, bleibt die beim Einrasten gemessene Achse stehen (siehe
-- Config.HoldAxisWhenLocked).

local Config = require("config")
local Util   = require("util")

local Field = {}

local cachedYaw     = nil       -- zuletzt bekannte Feldachse
local cachedFrom    = "keine"   -- woher sie stammt
local cachedSpacing = nil       -- Reihenabstand dieses Feldes
local tileSizeRead  = false

-------------------------------------------------------------------------------
-- Kachelgroesse
-------------------------------------------------------------------------------
function Field.readTileSize()
    if tileSizeRead then return Config.TileSize end
    tileSizeRead = true

    local cm = nil
    pcall(function() cm = FindFirstOf("BP_CropManager_C") end)
    if not Util.isValid(cm) then
        pcall(function() cm = FindFirstOf("CropManager") end)
    end
    if not Util.isValid(cm) then return Config.TileSize end

    local size = Util.get(cm, "TileSize")
    if type(size) == "number" and size > 1.0 then
        Config.TileSize = size
        Util.verbose("Kachelgroesse: %.1f uu", size)
    end

    return Config.TileSize
end

function Field.invalidateCache()
    tileSizeRead = false
end

-------------------------------------------------------------------------------
-- Hilfen
-------------------------------------------------------------------------------

-- Yaw aus einem Quaternion.
local function quatToYaw(q)
    local siny = 2.0 * (q.W * q.Z + q.X * q.Y)
    local cosy = 1.0 - 2.0 * (q.Y * q.Y + q.Z * q.Z)
    return math.deg(math.atan(siny, cosy))
end

-- Einen einzelnen Array-Wert auspacken. UE4SS liefert Elemente aus TArray als
-- RemoteUnrealParam-Wrapper, nicht als Lua-Werte -- reicht man den Wrapper an
-- eine UFunction weiter, lehnt sie den Aufruf ab.
local function unwrapValue(v)
    if v == nil then return nil end
    local ok, inner = pcall(function() return v:get() end)
    if ok and inner ~= nil then return inner end
    return v
end

-- TArray in eine Lua-Liste. Je nach UE4SS-Fassung kommt das als Tabelle oder
-- als eigenes Objekt zurueck, deshalb beide Wege.
local function arrayToList(arr, limit)
    local out = {}
    if arr == nil then return out end

    local n = nil
    pcall(function() n = #arr end)
    if type(n) ~= "number" then
        pcall(function() n = arr:GetArrayNum() end)
    end

    if type(n) == "number" then
        for i = 1, math.min(n, limit) do
            local v = nil
            pcall(function() v = arr[i] end)
            v = unwrapValue(v)
            if v ~= nil then out[#out + 1] = v end
        end
        return out
    end

    local c = 0
    pcall(function()
        for _, v in pairs(arr) do
            c = c + 1
            if c > limit then break end
            local u = unwrapValue(v)
            if u ~= nil then out[#out + 1] = u end
        end
    end)
    return out
end

-- Achse und Reihenabstand aus zwei benachbarten Rasterpunkten.
--
-- Die Punkte stehen im Raster. Nimmt man den dem Mech naechsten Punkt und
-- dazu dessen naechsten Nachbarn, liegt die Verbindungslinie auf einer
-- Rasterachse und ihre Laenge ist der Reihenabstand. Ob das die Reihe oder
-- die Spalte ist, spielt keine Rolle -- nearestAxis bildet daraus ohnehin
-- alle vier Fahrtrichtungen.
--
-- Rueckgabe: yaw, Abstand   ODER   nil
local function axisFromPoints(pts)
    local a = nil
    for _, p in ipairs(pts) do
        if a == nil or p.d < a.d then a = p end
    end
    if a == nil then return nil end

    local b, bd = nil, nil
    for _, p in ipairs(pts) do
        if p ~= a then
            local dx, dy = p.x - a.x, p.y - a.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 1.0 and (bd == nil or d < bd) then bd, b = d, p end
        end
    end
    if b == nil then return nil end

    return Util.normalizeAngle(math.deg(math.atan(b.y - a.y, b.x - a.x))), bd
end

-------------------------------------------------------------------------------
-- Quelle 1: die Feldfruechte des CropManagers
--
-- Angebautes Getreide ist in diesem Spiel KEIN Actor -- FindAllOf findet nur
-- Wildpflanzen. Die Fruechte stehen im CropManager:
--
--   ACropManager
--     SphereOverlapCrops(Ort, Radius) -> TArray<int32>   Kennungen in der Naehe
--     FindCrop(Id, FCropData& out)                       Daten dazu
--
-- FindCrop gibt genau einen bool zurueck; die Daten legt UE4SS in der
-- uebergebenen Tabelle ab.
-------------------------------------------------------------------------------
local function cropManager()
    for _, n in ipairs({ "BP_CropManager_C", "CropManager" }) do
        local cm = FindFirstOf(n)
        if Util.isValid(cm) then return cm, n end
    end
    return nil
end

-- Rueckgabe: yaw, Beschreibung, Reihenabstand   ODER   nil, Grund
function Field.readCropYaw(pos)
    if pos == nil then return nil, "keine Position" end

    local cm = cropManager()
    if cm == nil then return nil, "kein CropManager gefunden" end

    local radius = Config.CropSearchRadius or 1200.0
    local okIds, ids = Util.call(cm, "SphereOverlapCrops",
                                 { X = pos.X, Y = pos.Y, Z = pos.Z }, radius)
    if not okIds then return nil, "SphereOverlapCrops nicht aufrufbar" end

    local list = arrayToList(ids, Config.CropScanLimit or 60)
    if #list < 2 then
        return nil, string.format("nur %d Frucht/Fruechte im Umkreis von %.0f uu",
                                  #list, radius)
    end

    local pts = {}
    for _, id in ipairs(list) do
        local out = {}
        if Util.call(cm, "FindCrop", id, out) then
            local loc = nil
            pcall(function() loc = out.Location end)
            if loc ~= nil and loc.X ~= nil then
                local dx, dy = loc.X - pos.X, loc.Y - pos.Y
                pts[#pts + 1] = { x = loc.X, y = loc.Y,
                                  d = math.sqrt(dx * dx + dy * dy) }
            end
        end
    end

    if #pts < 2 then
        return nil, string.format("%d Kennungen, aber nur %d Positionen lesbar",
                                  #list, #pts)
    end

    local yaw, spacing = axisFromPoints(pts)
    if yaw == nil then return nil, "kein Nachbar gefunden" end

    return yaw,
           string.format("Feldfruechte (%d Stueck, Abstand %.0f uu)", #pts, spacing),
           spacing
end

-------------------------------------------------------------------------------
-- Quelle 2: das Beet unter dem Mech
--
-- Jedes Beet ist ein eigener Actor:
--
--   ABP_MoundPlot_C
--     K2_GetActorRotation()     die Drehung DIESES Beetes
--     K2_GetActorLocation()     sein Mittelpunkt
--     PlantBaseColumns/Rows     Rastergroesse
--     PlantBaseSpacing          Reihenabstand -- besser als eine globale
--                               Kachelgroesse, weil er je Beet gelten kann
--
-- Gesucht wird das naechstgelegene Beet in Reichweite. Faehrt der Mech ueber
-- eine Feldgrenze, wechselt die Achse damit von selbst mit.
-------------------------------------------------------------------------------

-- Halbe Ausdehnung eines Beetes, aus seinen Rasterangaben. Nur zur Bewertung,
-- welches Beet "unter" dem Mech liegt.
local function plotReach(plot)
    local cols = Util.get(plot, "PlantBaseColumns")
    local rows = Util.get(plot, "PlantBaseRows")
    local sp   = nil
    pcall(function() sp = plot.PlantBaseSpacing end)

    local sx = (sp and sp.X) or Config.TileSize
    local sy = (sp and sp.Y) or Config.TileSize
    if type(cols) ~= "number" then cols = 3 end
    if type(rows) ~= "number" then rows = 3 end

    -- Halbe Diagonale, plus eine Reihe Zugabe, damit der Rand mitzaehlt.
    local hx = cols * sx * 0.5
    local hy = rows * sy * 0.5
    return math.sqrt(hx * hx + hy * hy) + math.max(sx, sy)
end

-- Das naechstgelegene Beet zu einer Weltposition.
-- Rueckgabe: plot, Entfernung, liegt die Position in seiner Reichweite?
function Field.findPlot(pos)
    if pos == nil then return nil end

    local list = FindAllOf("BP_MoundPlot_C")
    if list == nil then return nil end

    local best, bestDist, bestInside = nil, nil, false
    local n = 0
    for _, plot in pairs(list) do
        n = n + 1
        if n > (Config.PlotScanLimit or 400) then break end

        if Util.isValid(plot) then
            local loc = Util.getLocation(plot)
            if loc ~= nil then
                local dx, dy = pos.X - loc.X, pos.Y - loc.Y
                local d = math.sqrt(dx * dx + dy * dy)
                if bestDist == nil or d < bestDist then
                    bestDist   = d
                    best       = plot
                    bestInside = (d <= plotReach(plot))
                end
            end
        end
    end

    return best, bestDist, bestInside
end

-- Rueckgabe: yaw, Beschreibung, Reihenabstand   ODER   nil, Grund
function Field.readPlotYaw(pos)
    local plot, dist, inside = Field.findPlot(pos)
    if plot == nil then return nil, "kein Beet in der Welt gefunden" end

    local maxDist = Config.PlotMaxDistance or 4000.0
    if not inside and dist > maxDist then
        return nil, string.format("naechstes Beet %.0f uu entfernt", dist)
    end

    local yaw = Util.getYaw(plot)
    if yaw == nil then return nil, "Beetdrehung nicht lesbar" end

    local spacing = nil
    local sp = nil
    pcall(function() sp = plot.PlantBaseSpacing end)
    if sp ~= nil and type(sp.X) == "number" and sp.X > 1.0 then
        spacing = sp.X
    end

    return yaw,
           string.format("Beet %s (%.0f uu%s)",
                         inside and "darunter" or "in der Naehe",
                         dist, inside and "" or ", ausserhalb"),
           spacing
end

-------------------------------------------------------------------------------
-- Quelle 3: die Anordnung der Pflanzen-Actors
--
-- Nicht die Drehung einzelner Pflanzen -- die dreht das Spiel zur
-- Auflockerung zufaellig. Verlaesslich ist ihre Geometrie: sie stehen im
-- Raster.
-------------------------------------------------------------------------------
local PLANT_CLASSES = { "BP_PlantBase_C", "BP_WaterPlantBase_C" }

local function gatherPlants(pos, radius)
    local out = {}
    local limit = Config.PlantScanLimit or 1500

    for _, cls in ipairs(PLANT_CLASSES) do
        local list = FindAllOf(cls)
        if list ~= nil then
            local n = 0
            for _, p in pairs(list) do
                n = n + 1
                if n > limit then break end
                if Util.isValid(p) then
                    local l = Util.getLocation(p)
                    if l ~= nil then
                        local dx, dy = l.X - pos.X, l.Y - pos.Y
                        local d = math.sqrt(dx * dx + dy * dy)
                        if d <= radius then
                            out[#out + 1] = { x = l.X, y = l.Y, d = d }
                        end
                    end
                end
            end
        end
    end

    return out
end

-- Rueckgabe: yaw, Beschreibung, Reihenabstand   ODER   nil, Grund
function Field.readPlantYaw(pos)
    if pos == nil then return nil, "keine Position" end

    local radius = Config.PlantSearchRadius or 1200.0
    local plants = gatherPlants(pos, radius)
    if #plants < 2 then
        return nil, string.format("nur %d Pflanze(n) im Umkreis von %.0f uu",
                                  #plants, radius)
    end

    local yaw, spacing = axisFromPoints(plants)
    if yaw == nil then return nil, "kein Nachbar gefunden" end

    return yaw,
           string.format("Pflanzenraster (%d Pflanzen, Abstand %.0f uu)",
                         #plants, spacing),
           spacing
end

-------------------------------------------------------------------------------
-- Quelle 4: das Lock-On des Samengewehrs
--
-- Erfasst bestehende Beete. Letzte Rueckfallebene, weil es nur etwas liefert,
-- solange der Spieler das Werkzeug tatsaechlich in der Hand hat.
--
-- Die Rastervorschau des Pflugs steht bewusst NICHT in der Liste: sie zeigt
-- das geplante neue Raster in Blickrichtung des Spielers und ignoriert das
-- bestehende Feld. Als Achsenquelle ist sie systematisch falsch.
-------------------------------------------------------------------------------

-- Die Lock-On-Komponente kann am Mech haengen oder frei in der Welt liegen.
local function findLockOnComponent(mech)
    local comp = nil

    if Util.isValid(mech) then
        for _, name in ipairs({ "LockOnComponent", "LockOn" }) do
            pcall(function() comp = mech[name] end)
            if Util.isValid(comp) then return comp end
        end
    end

    pcall(function() comp = FindFirstOf("LockOnComponent") end)
    if Util.isValid(comp) then return comp end

    return nil
end

function Field.readLockOnYaw(mech)
    local comp = findLockOnComponent(mech)
    if comp == nil then return nil end

    local yaw = nil

    -- Bevorzugt ueber die Funktion: parameterlos, liefert das Array direkt.
    pcall(function()
        local arr = comp:GetLockOnTransforms()
        if arr == nil then return end

        local num = nil
        pcall(function() num = arr:GetArrayNum() end)
        if num == nil then num = #arr end
        if type(num) ~= "number" or num < 1 then return end

        local t = arr[1]
        if t ~= nil then yaw = quatToYaw(t.Rotation) end
    end)

    if yaw ~= nil then return yaw, "Lock-On" end

    -- Ersatzweise ueber die Property.
    pcall(function()
        local arr = comp.LockOns
        if arr == nil then return end

        local num = nil
        pcall(function() num = arr:GetArrayNum() end)
        if num == nil then num = #arr end
        if type(num) ~= "number" or num < 1 then return end

        local entry = arr[1]
        if entry == nil then return end

        -- Der Eintrag kann ein Transform oder ein Actor sein.
        pcall(function() yaw = quatToYaw(entry.Rotation) end)
        if yaw == nil then
            pcall(function() yaw = entry:K2_GetActorRotation().Yaw end)
        end
    end)

    if yaw ~= nil then return yaw, "Lock-On (Property)" end
    return nil
end

-------------------------------------------------------------------------------
-- Achsen sind modulo 90 Grad dasselbe
--
-- Ein quadratisches Raster hat keine eindeutige Richtung: Reihe und Spalte
-- stehen senkrecht aufeinander und beschreiben dasselbe Feld. Der naechste
-- Nachbar eines Rasterpunktes liegt mal in der einen, mal in der anderen.
--
-- Vergleicht man solche Werte direkt, sieht jede zweite Messung wie ein
-- Feldwechsel aus. Deshalb: auf 0 bis unter 90 Grad zurueckfuehren und
-- Unterschiede ringfoermig messen -- 89 und 1 Grad liegen 2 Grad auseinander,
-- nicht 88. Verloren geht dabei nichts, weil nearestAxis aus der Achse
-- ohnehin wieder alle vier Fahrtrichtungen bildet.
-------------------------------------------------------------------------------
local function canonAxis(y)
    y = y % 90.0
    if y < 0.0 then y = y + 90.0 end
    return y
end

local function axisDelta(a, b)
    if a == nil or b == nil then return 999.0 end
    local d = math.abs(a - b) % 90.0
    if d > 45.0 then d = 90.0 - d end
    return d
end

-------------------------------------------------------------------------------
-- Die Feldachse bestimmen
-------------------------------------------------------------------------------
function Field.updateFromGame(mech)
    -- Achse eingefroren? Dann gilt, was beim Einrasten gemessen wurde: auf
    -- einem quadratischen Feld sind Reihe und Spalte gleichwertig, und welche
    -- von beiden gilt, soll die Fahrtrichtung des Spielers bestimmen.
    if Config.HoldAxisWhenLocked ~= false and Field.hasAnchor() then
        return cachedYaw ~= nil
    end

    local pos = Util.getLocation(mech)

    -- Quellen in absteigender Verlaesslichkeit.
    local yaw, from, spacing = Field.readCropYaw(pos)
    local exakt = (yaw ~= nil)

    if yaw == nil then
        yaw, from, spacing = Field.readPlotYaw(pos)
        exakt = (yaw ~= nil)
    end
    if yaw == nil then
        yaw, from, spacing = Field.readPlantYaw(pos)
        exakt = (yaw ~= nil)
    end
    if yaw == nil then
        yaw  = Field.readLockOnYaw(mech)
        from = "Samengewehr-Lock-On"
    end
    if yaw == nil then return false end

    -- Gerundet wird nur bei den verrauschten Quellen; eine gemessene
    -- Geometrie ist exakt und wuerde durchs Runden nur schlechter.
    local step = Config.GridStepDegrees
    if (not exakt) and step and step > 0.0 then
        yaw = math.floor(yaw / step + 0.5) * step
    end

    yaw = canonAxis(yaw)

    local delta = axisDelta(yaw, cachedYaw)

    cachedYaw     = yaw
    cachedFrom    = from or "unbekannt"
    cachedSpacing = spacing

    if delta > 0.5 then
        Util.log("Feldachse: %.2f Grad (%s)", yaw, cachedFrom)
    end

    return true
end

function Field.getFieldYaw()
    return cachedYaw, cachedFrom
end

-- Aus der Feldachse die vier Fahrtrichtungen bilden und die naechstliegende
-- waehlen. Verhindert eine 180-Grad-Wende mitten in der Bahn.
function Field.nearestAxis(fieldYaw, currentYaw)
    local bestYaw, bestErr = nil, nil
    for k = 0, 3 do
        local cand = fieldYaw + k * 90.0
        local err  = math.abs(Util.normalizeAngle(cand - currentYaw))
        if bestErr == nil or err < bestErr then
            bestErr = err
            bestYaw = Util.normalizeAngle(cand)
        end
    end
    return bestYaw, bestErr
end

-- Zielwinkel fuer den Mech.
-- Rueckgabe: targetYaw, Beschreibung   ODER   nil, Grund
function Field.pickTargetYaw(mech)
    local yaw = Util.getYaw(mech)
    if not yaw then return nil, "Rotation des Mechs nicht lesbar" end

    Field.readTileSize()
    Field.updateFromGame(mech)

    local fieldYaw, from = Field.getFieldYaw()

    if fieldYaw == nil then
        if not Config.UseWorldGridFallback then
            -- Beim ersten Fehlschlag einmal aufschluesseln, was in Reichweite
            -- ueberhaupt zu finden ist -- sonst steht im Log nur "unbekannt".
            if not Field.reportedSources then
                Field.reportedSources = true
                pcall(function() Field.reportSources(mech) end)
            end
            return nil, "Feldachse unbekannt -- kein Feld in Reichweite"
        end
        fieldYaw = Config.GridYawOffset
        from     = "Ersatzachse (geschaetzt)"
    end

    local target, err = Field.nearestAxis(fieldYaw, yaw)
    return target, string.format("%s, Achse %.2f Grad, %.1f Grad zu drehen",
                                 from, fieldYaw, err)
end

-------------------------------------------------------------------------------
-- Spurfuehrung: die AB-Linie
--
-- Eine reine Winkelregelung haelt den Kurs sehr genau und laeuft trotzdem
-- seitlich aus der Reihe -- sie kennt eine RICHTUNG, aber keine LINIE. Schon
-- 0.24 Grad Restfehler sind nach 100 m ueber 40 cm Seitenversatz, dazu kommen
-- Kettenschlupf und ein Startpunkt, der so gut wie nie exakt auf einer Reihe
-- liegt. Parallel neben der Reihe zu fahren ist fuer einen Winkelregler ein
-- perfektes Ergebnis.
--
-- Deshalb: Beim Einrasten wird die aktuelle Position als Anker gemerkt. Durch
-- ihn verlaeuft die Bezugslinie in Richtung der Feldachse, parallel dazu
-- liegen weitere Linien im Reihenabstand -- dasselbe Prinzip wie die AB-Linie
-- eines echten Spurfuehrungssystems.
--
-- Geregelt wird auf die JEWEILS NAECHSTE dieser Linien. Damit bleibt der
-- Spurwechsel dem Spieler ueberlassen: lenkt er hinueber zur naechsten Reihe,
-- rastet die Fuehrung dort ein, statt ihn zurueckzuzerren.
-------------------------------------------------------------------------------

local anchor    = nil   -- { X = , Y = }  Ursprung der Bezugslinie
local anchorYaw = nil   -- Richtung der Linienschar

-- Anker setzen oder verwerfen. Ein gesetzter Anker friert zugleich die
-- Feldachse ein (siehe updateFromGame).
function Field.setAnchor(pos, yaw)
    if pos == nil then
        anchor, anchorYaw = nil, nil
        return false
    end
    anchor    = { X = pos.X, Y = pos.Y }
    anchorYaw = yaw
    return true
end

function Field.hasAnchor()
    return anchor ~= nil and anchorYaw ~= nil
end

-- Abstand zwischen zwei Spuren.
function Field.trackSpacing()
    -- Der Reihenabstand des Feldes hat Vorrang: er kann je Feld anders sein.
    if type(cachedSpacing) == "number" and cachedSpacing > 1.0 then
        return cachedSpacing
    end
    local s = Config.TrackSpacing
    if type(s) == "number" and s > 1.0 then return s end
    return Config.TileSize
end

-- Seitenversatz zur naechstgelegenen Spur.
--
-- Rueckgabe: Versatz in Weltkoordinaten-Einheiten und die Nummer der Spur.
-- Das Vorzeichen folgt der Achse: positiv heisst, der Mech steht auf der
-- Seite, die 90 Grad "weiter" als die Fahrtrichtung liegt.
function Field.crossTrack(pos)
    if not Field.hasAnchor() or pos == nil then return nil, nil end

    local r = math.rad(anchorYaw)
    -- Normale zur Achse: die Richtung, in der die Spuren nebeneinanderliegen.
    local nx, ny = -math.sin(r), math.cos(r)

    local dx = pos.X - anchor.X
    local dy = pos.Y - anchor.Y
    local offset = dx * nx + dy * ny

    local spacing = Field.trackSpacing()
    local index   = math.floor(offset / spacing + 0.5)

    return offset - index * spacing, index
end

-- Zielrichtung inklusive Rueckfuehrung auf die Spur.
--
-- Statt stur die Achse anzustreben, wird ein Punkt auf der Spur angepeilt,
-- der eine Vorausschau-Distanz vor dem Mech liegt. Je weiter der Mech neben
-- der Spur steht, desto schraeger faehrt er darauf zu -- und je naeher er
-- kommt, desto flacher wird der Anstellwinkel von selbst.
function Field.guidedYaw(axisYaw, pos, speed)
    if not Config.TrackEnabled then return axisYaw, nil, nil end

    local cross, index = Field.crossTrack(pos)
    if cross == nil then return axisYaw, nil, nil end

    local look = Config.TrackLookahead
    if look == nil or look < 1.0 then look = 400.0 end

    -- Steht der Mech auf der Seite der Normalen, muss er dagegenhalten.
    local correction = -math.deg(math.atan(cross, look))

    -- Faehrt der Mech die Reihe zurueck, waehlt nearestAxis die um 180 Grad
    -- gedrehte Achse. Es ist dieselbe Linie, aber "links" und "rechts"
    -- vertauschen sich -- ohne diese Umkehr wuerde die Fuehrung den Mech von
    -- der Spur WEGdruecken statt darauf zu.
    if math.abs(Util.normalizeAngle(axisYaw - anchorYaw)) > 90.0 then
        correction = -correction
    end

    -- Rueckwaerts kehrt sich die Geometrie ebenfalls um.
    if speed ~= nil and speed < 0.0 then correction = -correction end

    local maxC = Config.TrackMaxCorrection or 30.0
    correction = Util.clamp(correction, -maxC, maxC)

    return Util.normalizeAngle(axisYaw + correction), cross, index
end

-------------------------------------------------------------------------------
-- Diagnose (Taste L): was ist hier eigentlich zu finden?
-------------------------------------------------------------------------------
function Field.reportSources(mech)
    local pos = Util.getLocation(mech)
    Util.log("-- Feldquellen --")

    for _, cls in ipairs({ "BP_MoundPlot_C", "BP_PlantBase_C",
                           "BP_WaterPlantBase_C", "BP_WildPlantBase_C" }) do
        local list = FindAllOf(cls)
        local n = 0
        if list ~= nil then for _ in pairs(list) do n = n + 1 end end
        Util.log("  %-22s %d in der Welt", cls, n)
    end

    if pos == nil then return end

    local y0, w0 = Field.readCropYaw(pos)
    Util.log("  Fruechte  : %s", y0 and string.format("%.2f Grad (%s)", y0, w0)
             or ("nein -- " .. tostring(w0)))

    local y1, w1 = Field.readPlotYaw(pos)
    Util.log("  Beet      : %s", y1 and string.format("%.2f Grad (%s)", y1, w1)
             or ("nein -- " .. tostring(w1)))

    local y2, w2, sp = Field.readPlantYaw(pos)
    Util.log("  Pflanzen  : %s", y2 and string.format("%.2f Grad (%s)", y2, w2)
             or ("nein -- " .. tostring(w2)))
    if sp then Util.log("  Reihenabstand aus dem Raster: %.0f uu", sp) end
end

return Field
