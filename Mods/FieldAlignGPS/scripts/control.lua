-- Field GPS for Lightyear Frontier
-- Copyright (C) 2026 sceptiQ
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. This program is distributed WITHOUT ANY WARRANTY; see
-- the GNU General Public License for details: <https://www.gnu.org/licenses/>.

-- Die Zustandsmaschine: an/aus, Regelkreis, Diagnose.
--
-- Warum das nicht in main.lua steht: main.lua haelt die Tastenbelegung und den
-- Tick-Hook und laesst sich deshalb nicht im laufenden Spiel austauschen. Alles
-- hier drin schon -- damit ist die eigentliche Logik mit F9 nachladbar (siehe
-- main.lua), und Aendern kostet keinen Spielneustart mehr.
--
-- main.lua setzt nach dem Laden Control.startLoop; von dort kommt der Takt.

local Config    = require("config")
local Util      = require("util")
local Field     = require("field")
local Steer     = require("steer")
local Indicator = require("indicator")
local Vehicle   = require("vehicle")
local Hook      = require("hook")

local Control = {}

-- Von main.lua gesetzt: startet Hook bzw. LoopAsync.
Control.startLoop = function() end

-- Fuehrt der Regler gerade? Nur hier drin verwendet.
local guiding = false

-- Betriebsart der laufenden Fahrt.
--
--   false  nur Spurhaltung -- Werkzeug und Gas bedient der Spieler
--   true   vollautomatisch -- Geraet, Gas und Spur uebernimmt der Mod
--
-- Gemerkt wird sie beim Einschalten, damit das Abschalten dazu passt: Wer mit
-- der Handtaste angefangen hat, soll nicht ploetzlich ein ausgehobenes Geraet
-- und eine Vollbremsung bekommen.
local autoMode = false

-- Restzeit der Anhaltephase in Sekunden.
Control.stopping = 0.0

-------------------------------------------------------------------------------
-- Control.active heisst "der Takt wird gebraucht", NICHT "der Regler fuehrt".
--
-- Der Unterschied ist der Grund, warum die Anhaltephase ueberhaupt laufen
-- kann: main.lua fragt dieses Feld in jedem Frame und kehrt sonst sofort
-- zurueck -- und main.lua laesst sich nicht neu laden. Bliebe active nach dem
-- Abschalten einfach false, bekaeme stopPhase nie einen Frame, und das liesse
-- sich ohne Spielneustart auch nicht mehr aendern.
--
-- Deshalb bleibt active wahr, solange noch angehalten wird. Ob gefuehrt wird,
-- sagt guiding.
-------------------------------------------------------------------------------
Control.active = false

local function refreshActive()
    Control.active = guiding or Control.stopping > 0.0
end

-------------------------------------------------------------------------------
-- Hat der Mod ueberhaupt etwas zu tun?
--
-- Diese Frage stellt main.lua in jedem Frame, und sie muss HIER beantwortet
-- werden, nicht dort: main.lua laesst sich nicht neu laden. Stuende die
-- Bedingung dort, koennte kein neuer Zustand mehr hinzukommen, ohne dass das
-- Spiel neu gestartet werden muss -- genau daran ist die Anhaltephase beim
-- ersten Anlauf gescheitert (Tick kehrte sofort zurueck, stopPhase bekam nie
-- einen Frame).
--
-- Billig halten: laeuft 60 mal pro Sekunde.
-------------------------------------------------------------------------------
function Control.busy()
    return guiding or Control.stopping > 0.0
end

local targetYaw      = nil     -- angepeilte Fahrtrichtung
local lastYaw        = nil     -- Yaw des letzten Frames, fuer die Drehrate
local retargetTimer  = 0.0
local lastError      = 0.0
local flagAvailable  = false   -- laesst sich der Traktormodus abfragen?
local activeMechName = nil     -- Ersatzpruefung, falls nicht

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
-- Abschalten
-------------------------------------------------------------------------------
local function turnOff(reason)
    if not guiding then return end

    guiding        = false
    targetYaw      = nil
    lastYaw        = nil
    refreshActive()

    local mech = Util.getLocalMech()
    Steer.release(mech)
    Indicator.restore(mech)
    Field.setAnchor(nil)   -- Bezugslinie verwerfen

    Util.log("Spurhaltung aus%s", reason and (" (" .. reason .. ")") or "")
end

-------------------------------------------------------------------------------
-- Arbeit beenden, nicht nur die Spurhaltung
--
-- Am Ende einer Bahn waren bisher drei Griffe noetig: Leertaste fuers
-- Werkzeug, Gas zurueck, dann die Spurhaltung aus. Der dritte Griff erledigt
-- jetzt alle drei -- eine Taste, und der Mech steht mit angehobenem Geraet
-- bereit zum Wenden.
--
-- Das laeuft NUR beim bewussten Tastendruck. Die automatischen Abschaltungen
-- (Traktormodus verlassen, Pawn gewechselt, Mech ungueltig) ruehren Werkzeug
-- und Gas nicht an: dort ist der Mech entweder ohnehin weg, oder er gehoert
-- gerade jemand anderem.
-------------------------------------------------------------------------------
-- Gegenstueck zu stopWork: Geraet senken. Das Gas uebernimmt danach der Tick
-- (siehe holdThrottle) -- einschalten laesst sich das Auto-Fahren des Spiels
-- nicht, alle Wege dahin sind gemessen und tot.
local function startWork(mech)
    if not Util.isValid(mech) then return end

    if Config.LowerToolOnStart then
        local ok, back, why = Vehicle.setAttachmentActive(mech, true)
        if ok then
            Util.log("Werkzeug gesenkt (aktiv: %s)", tostring(back))
        else
            Util.log("Werkzeug nicht gesenkt (%s)", why or "unbekannt")
        end
    end

    if Config.AutoDriveOnStart then
        Util.log("Gas uebernimmt der Mod (Ziel %.2f).",
                 Config.AutoDriveThrottle or 1.0)
    end
end

-------------------------------------------------------------------------------
-- Gas halten
--
-- Das Auto-Fahren des Spiels laesst sich aus Lua nicht einschalten -- alle
-- Wege sind gemessen und tot (siehe vehicle.lua). Also gibt der Mod im
-- Automatikbetrieb selbst Gas, jeden Frame aus dem Tick: dieselbe Stelle im
-- Frame, an der auch SetSteering ankommt.
--
-- Geschrieben wird nur, wenn der wirksame Wert zu niedrig ist -- bremst der
-- Spieler, faellt er, und der Mod schiebt erst im naechsten Frame nach.
--
-- Unterschied zum Auto-Fahren des Spiels: Das Gas endet, sobald der Mod
-- abschaltet. Am Vorgewende ist das eher von Vorteil.
-------------------------------------------------------------------------------
local function holdThrottle(mech)
    if not autoMode or not Config.AutoDriveOnStart then return end

    local ziel = Config.AutoDriveThrottle or 1.0
    local ist  = Vehicle.getThrottleInput(mech)

    if ist == nil or ist < ziel - 0.05 then
        Vehicle.setThrottle(mech, ziel, true)
    end
end

-------------------------------------------------------------------------------
-- Achse sanft nachziehen
--
-- Der Drift kam nicht vom Regler: Gemessen ueber 133 m blieb der Versatz zur
-- eigenen Linie unter 7 cm. Schief war die eingefrorene ACHSE -- bis zu 0.35
-- Grad, und das sind auf 133 m rund 81 cm seitlich, mehr als eine halbe Reihe.
--
-- Die Hauptursache ist inzwischen behoben (die Achsmessung mittelt jetzt ueber
-- viele Fruchtpaare statt ueber eines, siehe field.lua). Hier bleibt die
-- zweite Sicherung: alle paar Meter frisch messen und einen Bruchteil der
-- Abweichung uebernehmen.
--
-- Bewusst traege: Ein Bruchteil je Korrektur statt der vollen Differenz, und
-- Ausreisser fliegen raus. Im Protokoll stand einer mit +26.9 Grad, weil die
-- Messung eine diagonale Nachbarschaft erwischt hatte -- den ungeprueft zu
-- uebernehmen wuerde den Mech quer stellen.
-------------------------------------------------------------------------------
local lastAlignPos = nil

local function realignAxis(mech, pos)
    local schwelle = Config.AxisCorrectionDistance or 0.0
    if schwelle <= 0.0 or pos == nil then return end

    if lastAlignPos == nil then
        lastAlignPos = pos
        return
    end

    local dx, dy = pos.X - lastAlignPos.X, pos.Y - lastAlignPos.Y
    if math.sqrt(dx * dx + dy * dy) < schwelle then return end
    lastAlignPos = pos

    local gemessen = Field.readCropYaw(pos)
    if gemessen == nil then return end

    local fix = Field.getAnchorYaw()
    local off = Field.axisOffset(gemessen, fix)
    if off == nil then return end

    local grenze = Config.AxisCorrectionMaxDegrees or 2.0
    if math.abs(off) > grenze then
        Util.log("Achskorrektur verworfen: %+.2f Grad (Ausreisser, Grenze %.1f)",
                 off, grenze)
        return
    end

    local schritt = off * (Config.AxisCorrectionRate or 0.35)
    if Field.realign(pos, fix + schritt) then
        Util.log("Achse nachgezogen: %+.3f Grad (Abweichung war %+.3f)",
                 schritt, off)
    end
end

-------------------------------------------------------------------------------
-- Driftprotokoll
--
-- Fuer die Frage "warum laeuft er auf langen Bahnen seitlich weg?" taugt
-- VerboseTick nicht: 60 Zeilen je Sekunde sind nicht auswertbar. Hier steht
-- alle paar Sekunden eine Zeile mit genau den Groessen, die den Drift
-- unterscheiden koennen.
--
-- Die entscheidende Spalte ist "Achse fix / jetzt". Beim Einrasten friert der
-- Mod die Achse ein (HoldAxisWhenLocked). Ist sie um Bruchteile eines Grades
-- daneben, haelt der Regler seine eigene Linie tadellos -- und die laeuft
-- trotzdem langsam von den echten Reihen weg. 0.2 Grad sind auf 200 m rund
-- 70 cm.
--
-- Damit lassen sich die Faelle trennen:
--
--   Versatz waechst, Achsen gleich    -> der Regler kommt nicht auf die Linie
--   Versatz ~0, Achsen driften        -> die eingefrorene Achse war schief
--   Spur springt                      -> er rastet auf die Nachbarlinie
--   Abstand aendert sich              -> Reihenabstand falsch gemessen
--
-- Die frische Messung wird NICHT uebernommen -- sie dient nur dem Vergleich.
-------------------------------------------------------------------------------
local driftTimer = 0.0

local function driftLog(dt, mech, err, speed)
    local intervall = Config.DriftLogSeconds or 0.0
    if intervall <= 0.0 then return end

    driftTimer = driftTimer + dt
    if driftTimer < intervall then return end
    driftTimer = 0.0

    local pos = Util.getLocation(mech)
    if pos == nil then return end

    local cross, lane = Field.crossTrack(pos)
    local along       = Field.alongTrack(pos)
    local fix         = Field.getAnchorYaw()

    -- Frisch messen, ohne sie zu uebernehmen.
    local jetzt, _, abstand = Field.readCropYaw(pos)
    local delta = Field.axisOffset(jetzt, fix)

    local function z(v, fmt)
        if v == nil then return "-" end
        return string.format(fmt, v)
    end

    Util.log("Drift: Weg %s | Versatz %s (Spur %s) | Rest %s Grad | "
             .. "Achse fix %s / jetzt %s -> %s Grad | Abstand %s | Tempo %.0f",
             z(along, "%.0f"), z(cross, "%+.1f"), z(lane, "%d"),
             z(err, "%+.2f"), z(fix, "%.2f"), z(jetzt, "%.2f"),
             z(delta, "%+.3f"), z(abstand, "%.0f"), speed or 0.0)
end

local function stopWork(mech)
    if not Util.isValid(mech) then return end

    if Config.LiftToolOnStop then
        local ok, back, why = Vehicle.setAttachmentActive(mech, false)
        if ok then
            Util.log("Werkzeug ausgehoben (aktiv: %s)", tostring(back))
        else
            Util.log("Werkzeug nicht ausgehoben (%s)", why or "unbekannt")
        end
    end

    if Config.StopAutoDriveOnStop then
        -- Der entscheidende Griff: das Auto-Fahren abbrechen. Solange es
        -- laeuft, schreibt das Spiel in JEDEM Frame Vollgas nach, und jedes
        -- SetThrottle(0) verpufft (gemessen: gesetzt 0.0 / wirksam 1.0).
        local vorher = Vehicle.getThrottleInput(mech)
        local ok     = Vehicle.stopAutoMoving(mech)
        Util.log("Auto-Fahren abgebrochen (%s, Gas vorher %s)",
                 ok and "angenommen" or "nicht aufrufbar", tostring(vorher))

        -- Danach laeuft der Takt noch kurz weiter und raeumt den Rest ab:
        -- Restschwung ueber die Handbremse, siehe stopPhase.
        Control.stopping = Config.StopBrakeSeconds or 1.5
        refreshActive()
    end
end

-------------------------------------------------------------------------------
-- Anhaltephase: den Restschwung abraeumen
--
-- Das Auto-Fahren ist zu diesem Zeitpunkt bereits abgebrochen (stopWork). Was
-- bleibt, ist Schwung -- ein Kettenfahrzeug bei 350 cm/s rollt sonst noch ein
-- gutes Stueck. Dagegen die Handbremse, ueber ein kurzes Fenster aus dem Tick.
--
-- Der Weg dahin ist dokumentiert, weil er drei Fehlversuche gekostet hat:
--
--   SetThrottle(0) am Beinmodul   wirkungslos. Gemessen: gesetzt 0.0, waehrend
--                                 der wirksame Wert bei 1.0 blieb und das
--                                 Tempo von 519 auf 974 cm/s STIEG.
--   GetThrottle() als Kontrolle   wertlos -- gibt den eigenen Schreibwert
--                                 zurueck, nicht den der Komponente. Der
--                                 wirksame Wert kommt aus GetThrottleInput().
--   SetHandbrake(true) allein     haelt an, aber beim Loesen steht das Vollgas
--                                 noch an und der Mech faehrt sofort weiter.
--
-- Erst StopAutoMoving() am MECH nimmt das Gas wirklich weg; die Bremse ist nur
-- noch fuer den Schwung da.
-------------------------------------------------------------------------------
local stopLogTimer = 0.0

local function stopPhase(dt, mech)
    if not Util.isValid(mech) then
        Control.stopping = 0.0
        refreshActive()
        return
    end

    Control.stopping = Control.stopping - dt
    refreshActive()

    -- Zuerst der eigene Kanal: Handbremse. Sie haengt nicht am Gas und ist
    -- damit unabhaengig davon, wer das Gas gerade nachschreibt.
    local bremse = nil
    if Config.HandbrakeOnStop then
        local _, back = Vehicle.setHandbrake(mech, true)
        bremse = back
    end

    Vehicle.setThrottle(mech, 0.0, true)

    -- Der Wert, mit dem die Komponente wirklich rechnet -- im Gegensatz zu
    -- GetThrottle(), das nur unseren eigenen Schreibwert zurueckgibt.
    local wirksam = Vehicle.getThrottleInput(mech)

    -- Steht immer noch Gas an, laeuft das Auto-Fahren weiter. Dann nachfassen,
    -- diesmal aus dem Tick -- also an der Stelle im Frame, an der Schreib-
    -- vorgaenge auf die Bewegung nachweislich ankommen.
    if wirksam ~= nil and wirksam > 0.05 then
        Vehicle.stopAutoMoving(mech)
    end

    local yaw   = Util.getYaw(mech) or 0.0
    local speed = Util.getForwardSpeed(mech, yaw)

    -- Nicht jeden Frame loggen, sonst ist das Log unlesbar.
    stopLogTimer = stopLogTimer + dt
    if stopLogTimer >= 0.25 then
        stopLogTimer = 0.0
        Util.verbose("Anhalten: wirksames Gas %s | Bremse %s | "
                 .. "Tempo %.0f cm/s | noch %.1f s",
                 tostring(wirksam), tostring(bremse),
                 speed, math.max(Control.stopping, 0.0))
    end

    if Control.stopping <= 0.0 then
        Control.stopping = 0.0
        stopLogTimer     = 0.0
        refreshActive()

        -- Die Bremse wieder loesen -- sonst bleibt der Mech blockiert und
        -- laesst sich nicht mehr fahren.
        if Config.HandbrakeOnStop then
            Vehicle.setHandbrake(mech, false)
        end

        Util.log("Angehalten -- Tempo %.0f cm/s, Gas %s.", speed, tostring(wirksam))
    end
end

-------------------------------------------------------------------------------
-- Regelkreis. Wird aus main.lua je Frame gerufen, aber nur wenn active.
-------------------------------------------------------------------------------
function Control.tick(dt, mech)
    -- Anhalten hat Vorrang: Nach dem Abschalten laeuft der Takt noch kurz
    -- weiter, um das Gas auf null zu halten (siehe stopPhase).
    if Control.stopping > 0.0 then
        stopPhase(dt, mech)
        return
    end

    if not guiding then return end

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
    holdThrottle(mech)
    realignAxis(mech, Util.getLocation(mech))
    driftLog(dt, mech, lastError, speed)

    Util.verbose("err=%.2f rate=%.2f lenk=%.3f tempo=%.0f",
                 lastError, yawRate, Steer.lastSteer, speed)
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

    lastAlignPos   = nil
    lastYaw        = Util.getYaw(mech)
    retargetTimer  = 0.0
    flagAvailable  = (Util.getTransformedState(mech) ~= nil)
    activeMechName = Util.fullName(mech)

    return mech, source
end

-- auto = true  -> vollautomatisch (Taste O)
-- auto = false -> nur Spurhaltung  (Taste K)
--
-- Beim Abschalten zaehlt die Betriebsart, in der GESTARTET wurde, nicht die
-- gedrueckte Taste. Sonst wuerde ein Druck auf O eine Handfahrt unerwartet
-- ausheben und bremsen.
function Control.toggle(auto)
    if guiding then
        if autoMode then
            -- Reihenfolge: erst Werkzeug und Gas, dann die Fuehrung loslassen.
            -- Umgekehrt liefe der Mech nach dem Loslassen der Lenkung noch ein
            -- Stueck mit gesenktem Geraet weiter.
            stopWork(Util.getLocalMech())
        end
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

    autoMode = (auto == true)
    guiding  = true
    refreshActive()
    Indicator.set(mech, true)
    Control.startLoop()

    Util.log("%s an -- Spur %.0f Grad (%s), Abweichung %.1f Grad",
             autoMode and "Automatik" or "Spurhaltung",
             targetYaw or 0.0, source or "Feld", lastError)

    if autoMode then startWork(mech) end
end

-- Beim Neuladen: alles loslassen, ohne eine Meldung ueber "Spurhaltung aus".
function Control.shutdown()
    guiding          = false
    autoMode         = false
    Control.stopping = 0.0
    refreshActive()
    targetYaw        = nil
    lastYaw          = nil

    local ok, mech = pcall(Util.getLocalMech)
    if ok and mech then
        pcall(function() Steer.release(mech) end)
        pcall(function() Indicator.restore(mech) end)
    end
    pcall(function() Field.setAnchor(nil) end)
end

-------------------------------------------------------------------------------
-- Diagnose (Taste L)
-------------------------------------------------------------------------------
function Control.diagnose(takt)
    Util.log("---- Diagnose ----")
    Util.log("Betrieb: %s", guiding and (autoMode and "Automatik" or "nur Spurhaltung") or "aus")
    Util.log("Takt: %s", takt or (Hook.installed
             and ("Hook auf " .. tostring(Hook.source)) or "unbekannt"))

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

        local okA, aktiv = Vehicle.isAttachmentActive(mech)
        Util.log("Anbaugeraet aktiv: %s", okA and tostring(aktiv) or "nicht lesbar")

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

return Control
