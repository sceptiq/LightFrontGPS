-- Field GPS for Lightyear Frontier
-- Copyright (C) 2026 sceptiQ
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version. This program is distributed WITHOUT ANY WARRANTY; see
-- the GNU General Public License for details: <https://www.gnu.org/licenses/>.

-- Zentrale Konfiguration des Feld-GPS.
--
-- UE4SS laedt Lua-Mods nur beim Spielstart. Nach einer Aenderung an dieser
-- Datei das Spiel also neu starten.

local Config = {}

-------------------------------------------------------------------------------
-- Tasten
--
-- K und L belegt Lightyear Frontier selbst nicht. Ebenfalls frei sind
-- O, P, U, die Null sowie F1-F7, F9, F11 und F12 -- falls K oder L mit einem
-- anderen Mod kollidiert.
--
-- Hinweis: UE4SS loest einen Keybind ohne Modifikator auch dann aus, wenn
-- Strg oder Alt mitgedrueckt sind.
-------------------------------------------------------------------------------

-- Zwei Betriebsarten, zwei Tasten.
--
--   K  Nur Spurhaltung. Werkzeug und Gas bedienst du selbst -- so wie in v1.
--   O  Vollautomatisch: senkt das Geraet, gibt Gas und haelt die Spur. Ein
--      zweiter Druck hebt aus, nimmt das Gas weg und bremst.
--
-- Abgeschaltet wird immer so, wie eingeschaltet wurde: Mit K gestartet, hoert
-- K auch nur mit der Spurhaltung auf.
--
-- Warum nicht J: Das Spiel belegt J mit "TogglePlanning". Nachgesehen in
-- %LOCALAPPDATA%\FarMech\Saved\Config\WindowsNoEditor\UINavInput.ini -- dort
-- steht die vollstaendige Standardbelegung. Wirklich frei sind nur C, K, L,
-- O, P, U und Y; Auto-Drive des Spiels liegt uebrigens auf G.
Config.KeyLock          = "K"
Config.KeyLockMods      = {}

Config.KeyAuto          = "O"
Config.KeyAutoMods      = {}

-- Diagnose ins UE4SS-Log schreiben.
Config.KeyDebugDump     = "L"
Config.KeyDebugDumpMods = {}

-- Module im laufenden Spiel neu laden.
--
-- UE4SS laedt Lua sonst nur beim Spielstart, jede geaenderte Zahl kostete also
-- einen Neustart. Damit wirkt eine Aenderung an dieser Datei oder an
-- field/steer/vehicle/indicator/control sofort -- Datei speichern, ins
-- Mods-Verzeichnis kopieren, Taste druecken.
--
-- Nicht erfasst: main.lua und hook.lua. Beide halten Tastenbelegung und
-- Tick-Hook, die sich nicht zurueckziehen lassen; dafuer weiterhin Neustart.
--
-- Auf nil setzen, um die Taste gar nicht erst zu belegen.
Config.KeyReload        = "F9"
Config.KeyReloadMods    = {}

-------------------------------------------------------------------------------
-- Was das Abschalten mit K sonst noch erledigt
--
-- Am Ende einer Bahn gehoeren drei Dinge zusammen: Werkzeug ausheben,
-- Auto-Fahren abbrechen, Spurhaltung aus. Eingeschaltet macht K daraus einen
-- einzigen Griff -- der Mech steht mit angehobenem Geraet bereit zum Wenden.
--
-- Jeder Schritt wird zurueckgelesen; das Ergebnis steht im Log.
-------------------------------------------------------------------------------

-- Anbaugeraet senken bzw. ausheben (sonst die Leertaste).
Config.LowerToolOnStart  = true
Config.LiftToolOnStop    = true

-- Beim Start selbst Gas geben (nur im Vollautomatik-Modus).
--
-- Das Auto-Fahren des Spiels laesst sich aus Lua NICHT einschalten. Gemessen:
-- Die Binary kennt genau drei passende Symbole -- ToggleAutoMove (nur auf
-- AFarmerCharacter), StopAutoMoving und den Aktionsnamen AutoMove. Ein
-- InpActEvt_AutoMove existiert nicht, die Aktion ist also nativ gebunden und
-- ihr Handler ueber Reflection nicht erreichbar. ToggleAutoMove auf dem
-- Piloten laesst sich aufrufen, bewegt aber nichts.
--
-- Deshalb haelt der Mod das Gas selbst, aus dem Takt heraus (siehe
-- holdThrottle in control.lua). Ein einzelnes SetThrottle genuegt nicht: Das
-- Spiel schreibt die Gasstellung in jedem Frame neu.
--
-- Das Anhalten ist davon unberuehrt -- StopAutoMoving() wirkt.
Config.AutoDriveOnStart  = true

-- Gasstellung, die beim Start gesetzt wird (0..1).
Config.AutoDriveThrottle = 1.0

-- Achse waehrend der Fahrt sanft nachziehen.
--
-- Alle wieviel Weltkoordinaten-Einheiten frisch gemessen wird (1000 = 10 m),
-- welcher Bruchteil der Abweichung uebernommen wird, und ab welcher Abweichung
-- die Messung als Ausreisser verworfen wird.
--
-- Traege ausgelegt: Die Achse soll ueber die Bahn stimmen, nicht auf jede
-- Einzelmessung reagieren. 0 als Abstand schaltet die Nachfuehrung ab.
Config.AxisCorrectionDistance   = 1000.0
Config.AxisCorrectionRate       = 0.35
Config.AxisCorrectionMaxDegrees = 2.0

-- Driftprotokoll: alle wieviel Sekunden eine Auswertungszeile geschrieben wird.
-- 0 schaltet es ab. Das ist ein Messwerkzeug fuer lange Bahnen, kein
-- Dauerbetrieb -- eine Zeile alle paar Sekunden, nicht je Frame.
Config.DriftLogSeconds  = 0.0

-- Auto-Fahren abbrechen (AMechCharacter::StopAutoMoving).
--
-- Ohne das faehrt der Mech nach dem Abschalten der Spurhaltung ungelenkt
-- weiter: das Spiel schreibt Vollgas in jedem Frame nach, solange das
-- Auto-Fahren laeuft.
Config.StopAutoDriveOnStop = true

-- Handbremse gegen den Restschwung ziehen. Am Ende des Fensters wieder loesen.
Config.HandbrakeOnStop   = true

-- Wie lange die Handbremse nach dem Abschalten gehalten wird (Sekunden).
--
-- Nur gegen den Restschwung: Das Gas ist zu dem Zeitpunkt schon weg. Rollt der
-- Mech noch merklich aus, hier erhoehen.
Config.StopBrakeSeconds = 1.5

-------------------------------------------------------------------------------
-- Feldraster
-------------------------------------------------------------------------------

-- Das Raster ist frei drehbar und NICHT an den Weltachsen ausgerichtet:
-- Beete rasten in Schritten von 11.25 Grad ein (RotationIncrement des Spiels).
-- Ein Snap auf 90-Grad-Achsen wuerde den Mech dauerhaft schief zum Feld
-- stellen, deshalb wird die Achse aus dem Spiel gelesen und nur gerundet.
Config.GridStepDegrees = 11.25

-- Ersatzachse, falls sich nirgends etwas messen laesst.
Config.GridYawOffset   = 0.0

-- Auf diese Ersatzachse zurueckfallen, wenn keine Messung vorliegt?
-- Aus, weil eine geratene Achse den Mech quer durchs Feld fuehren wuerde.
Config.UseWorldGridFallback = false

-- Kachelgroesse in Unreal-Units. Wird beim Einrasten aus CropManager.TileSize
-- uebernommen; dieser Wert ist nur der Startwert.
Config.TileSize        = 200.0

-------------------------------------------------------------------------------
-- Felderkennung
--
-- Die Feldachse kommt aus dem Feld, ueber dem der Mech gerade steht -- nicht
-- aus einem einmal gemerkten Wert. Beete lassen sich frei drehen, ein
-- gespeicherter Winkel waere auf dem naechsten Feld zwangslaeufig falsch.
-------------------------------------------------------------------------------

-- Wie weit ein Beet hoechstens entfernt sein darf, um noch als "das aktuelle
-- Feld" zu gelten (Weltkoordinaten). Innerhalb seiner Ausdehnung gilt es
-- ohnehin, unabhaengig von diesem Wert.
Config.PlotMaxDistance = 4000.0

-- Obergrenze fuer die Beetsuche. Schuetzt vor langen Schleifen auf dem
-- Spielthread, wenn eine Welt sehr viele Beete enthaelt.
Config.PlotScanLimit = 400

-- Umkreis, in dem nach Pflanzen gesucht wird, um die Rasterachse aus ihrer
-- Anordnung abzuleiten (Weltkoordinaten). Gross genug fuer mehrere Reihen.
Config.PlantSearchRadius = 1200.0

-- Obergrenze der Pflanzensuche je Klasse.
Config.PlantScanLimit = 1500

-- Umkreis und Obergrenze fuer die Suche nach Feldfruechten. Angebautes
-- Getreide ist in diesem Spiel kein Actor, sondern ein Datensatz im
-- CropManager -- deshalb eine eigene Abfrage statt FindAllOf.
Config.CropSearchRadius = 1200.0
Config.CropScanLimit    = 60

-- Achse beim Einrasten festhalten.
--
-- Auf einem quadratischen Feld sind Reihe und Spalte gleichwertig. Welche von
-- beiden gilt, soll die Fahrtrichtung beim Einrasten bestimmen -- nicht eine
-- Messung eine halbe Sekunde spaeter, die den Mech quer zur Bahn zieht.
Config.HoldAxisWhenLocked = true

-------------------------------------------------------------------------------
-- Erkennung des Mechs
-------------------------------------------------------------------------------
Config.MechClassNames      = { "BP_TractorMechCharacter_C" }

-- Traktor-/Erntemodus: AMechCharacter::IsTransformed(). Eine gleichnamige
-- Property gibt es nicht -- der Property-Weg ist nur Rueckfallebene, falls ein
-- Spielupdate das aendert.
Config.TransformedFunction = "IsTransformed"
Config.TransformedFlag     = "bIsTransformed"

-- Nur bestimmte Anbaugeraete zulassen? Leer = jedes.
Config.RequiredAttachments = {}

-------------------------------------------------------------------------------
-- Takt
--
-- Erste Wahl ist ein Hook auf das Blueprint-Ereignis ReceiveTick des Mechs:
-- Blueprint-Ereignisse sind UFunctions und damit hookbar, und der Hook laeuft
-- jeden Frame auf dem Spielthread an FESTER Stelle im Frame. Das ist die
-- Voraussetzung dafuer, dass ein Schreibvorgang auf die Bewegung ankommt.
--
-- LoopAsync bleibt als Rueckfallebene, damit ein Spielupdate den Mod nicht
-- stilllegt. Zum Lesen taugt es, zum Schreiben nur bedingt: der Zeitpunkt im
-- Frame ist dort unbestimmt.
-------------------------------------------------------------------------------
Config.PreferTickHook = true

-- Reihenfolge = Reihenfolge des Ausprobierens.
Config.TickHookPaths = {
    "/Game/Blueprints/Player/Mechs/BP_TractorMechCharacter.BP_TractorMechCharacter_C:ReceiveTick",
}

-- Takt der Rueckfallebene in Millisekunden.
Config.TickIntervalMs = 16      -- ~60 mal pro Sekunde

-- Intervall der Zielwinkel-Neuberechnung (Sekunden) und maximal zulaessiger
-- Sprung dabei (Grad). Ohne die Nachfuehrung wuerde der Mech nach einer Kehre
-- am Vorgewende zurueckgedreht statt die Gegenrichtung zu uebernehmen.
Config.RetargetInterval = 0.5
Config.RetargetMaxDelta = 45.0

-------------------------------------------------------------------------------
-- Lenkung
--
-- Gelenkt wird ueber SetSteering() des Beinmoduls, Wertebereich -1 .. +1 --
-- derselbe Eingang, den auch die Tasten A und D des Spiels bedienen.
-- Der Regler ist ein schlichter PD-Regler auf den Winkelfehler.
-------------------------------------------------------------------------------

-- Kp in Lenkeinheiten pro Grad Abweichung: 0.08 bedeutet vollen Einschlag ab
-- 12.5 Grad. Kd daempft ueber die Drehrate. Schiesst der Mech uebers Ziel
-- hinaus und pendelt, Kd erhoehen oder Kp senken.
Config.VehicleKp        = 0.08
Config.VehicleKd        = 0.03

-- Innerhalb dieser Abweichung wird nicht mehr gelenkt. Verhindert das
-- Zappeln um die Ideallinie.
-- Zusammen mit TrackLookahead bestimmt dieser Wert, wieviel Seitenversatz
-- dauerhaft stehen bleiben darf: Der Regler sieht nur den WINKEL, und ein
-- Versatz von TrackLookahead * tan(Totzone) erzeugt genau die Totzone.
--
--   0.4 Grad bei 400 uu Vorausschau  ->  2.8 uu Versatz bleiben unbemerkt
--   0.25 Grad bei 300 uu             ->  1.3 uu
--
-- Enger gesetzt, weil am Rand einer Reihe sonst ein Streifen stehen blieb --
-- das Anbaugeraet erwischt ihn nicht mehr. Faengt der Mech an zu pendeln,
-- diesen Wert wieder anheben (und TrackLookahead dazu).
Config.VehicleDeadzone  = 0.25

-- Begrenzung des Einschlags. Kleiner = sanfter, aber traeger.
Config.VehicleMaxSteer  = 1.0

-- Glaettung der Drehrate.
--
-- Der D-Anteil bildet die Drehrate als (yaw - lastYaw) / dt. Bei 16-ms-Frames
-- wird daraus das normale Physik-Zittern des Fahrwerks stark verstaerkt, und
-- die Lenkung schlaegt im Frametakt von Anschlag zu Anschlag. Der Tiefpass
-- davor nimmt das heraus.
--
-- Zeitkonstante in Sekunden. Groesser = ruhiger, aber die Daempfung reagiert
-- traeger auf echtes Ueberschwingen.
Config.VehicleRateSmoothing = 0.12

-- Zusaetzlich: wie schnell sich der Einschlag hoechstens aendern darf
-- (Lenkeinheiten pro Sekunde). Wie eine Hand am Hebel.
Config.VehicleSlewPerSecond = 4.0

-- Lenken nur in Fahrt.
--
-- Die Fahrwerkskomponente hat bIsTank = true. Ein Kettenfahrzeug lenkt ueber
-- gegenlaeufige Ketten -- bei Gas null dreht derselbe Befehl, der in Fahrt
-- eine ruhige Kurve ergibt, den Mech auf der Stelle. Darum zwei Massnahmen:
-- unterhalb von VehicleMinSpeed gar nicht lenken, und die Lenkvollmacht bis
-- VehicleFullSteerSpeed mit dem Tempo hochskalieren.
Config.VehicleMinSpeed       = 20.0     -- cm/s
Config.VehicleFullSteerSpeed = 250.0    -- cm/s

-- Weicht die Lenkeingabe des Spielers staerker als dieser Winkel vom Ziel ab,
-- gibt der Mod die Fuehrung ab und greift erst wieder, wenn der Spieler
-- loslaesst -- so laesst sich am Vorgewende normal wenden. Grosszuegig
-- gewaehlt, weil ohnehin immer die naechstliegende der vier Rasterachsen
-- angepeilt wird.
Config.PlayerOverrideDegrees = 120.0

-------------------------------------------------------------------------------
-- Spurfuehrung
--
-- Eine reine Winkelregelung haelt den Kurs sehr genau und laeuft trotzdem
-- seitlich aus der Reihe: sie kennt eine Richtung, aber keine Linie. Deshalb
-- wird beim Einrasten eine AB-Linie verankert und auf die jeweils naechste
-- Parallele dazu geregelt.
-------------------------------------------------------------------------------
Config.TrackEnabled = true

-- Wie weit voraus der Zielpunkt auf der Spur liegt (Weltkoordinaten).
-- Gross = sanftes Einscheren aus der Ferne, klein = energisches
-- Zurueckziehen, aber Neigung zum Pendeln.
--
-- 300 uu sind bei rund 330 cm/s knapp eine Sekunde Vorausschau. Enger als
-- frueher (400), weil ein grosser Wert den Versatz zwar sanft, aber eben auch
-- traege abbaut -- und am Reihenrand blieb dadurch ein Streifen stehen.
Config.TrackLookahead = 300.0

-- Hoechster Anstellwinkel gegen die Spur, in Grad. Begrenzt, damit der Mech
-- nie quer zur Reihe steht.
Config.TrackMaxCorrection = 30.0

-- Abstand benachbarter Spuren. nil = Reihenabstand des Feldes verwenden.
Config.TrackSpacing = nil

-------------------------------------------------------------------------------
-- Anzeige und Ausgabe
-------------------------------------------------------------------------------

-- Scheinwerfer als Zustandsanzeige: an = Spurhaltung aktiv. Der vorherige
-- Zustand wird gemerkt und beim Abschalten wiederhergestellt.
Config.UseHeadlightIndicator = true

Config.LogPrefix   = "[FieldGPS] "

-- true schreibt in JEDEM Frame eine Regelzeile ins Log. Nur zur Feinabstimmung
-- der Reglerwerte -- das Log waechst damit sehr schnell.
Config.VerboseTick = false

return Config
