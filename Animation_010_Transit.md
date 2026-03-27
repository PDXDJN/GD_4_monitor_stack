📡 CLAUDE.MD — Orbital Transit Monitor (Berlin Sector)

Platform: Godot 4.5
Display: 4 vertical monitors (1×4 stack)
Mode: Real-time BVG/VBB departures
Stops:

Berlin Jannowitzbrücke station → S-Bahn + U-Bahn

Heinrich-Heine-Straße station → U-Bahn + Bus

🧠 Core Concept

Render Berlin transit as a docking schedule system:

Vehicles → inbound craft

Stops → docking hubs

Departures → launch windows

Delays → vector drift

System tone: calm, clinical, slightly condescending (optional but encouraged)

🧱 Scene Architecture (Godot 4.5)
Root Scene
OrbitalTransitControl (Control)
├── TopPanel (Control)
├── MidPanelA (Control)
├── MidPanelB (Control)
├── BottomPanel (Control)
├── DataController (Node)
├── AnimationController (Node)
🖥️ Monitor Layout
🟢 Monitor 1 — Top Panel (Strategic Header)
Purpose:

System identity + context

UI Elements:
[ORBITAL TRANSIT CONTROL // BERLIN SECTOR]

PRIMARY HUB: JANNOWITZBRÜCKE
SECONDARY HUB: HEINRICH-HEINE-STRASSE

LOCAL TIME: 16:05:23
LAST SYNC: 16:05:00

STATUS: LIVE DATA STREAM
DELAY FIELD: LOW
Optional visual:

rotating radar sweep (very slow)

thin vector grid background

🟡 Monitor 2 — Jannowitzbrücke (Rail Only)
Data Sources:

S-Bahn (S3, S5, S7, S9)

U-Bahn (U8)

Layout:
[DOCK: JANNOWITZBRÜCKE // RAIL]

LINE   DESTINATION         ETA   STATUS
-----------------------------------------
S5     STRAUSBERG NORD      2m   DOCKING
S7     POTSDAM              4m   FINAL APPROACH
U8     HERMANNSTRASSE       5m   INBOUND
S3     ERKNER               8m   INBOUND
Rules:

Sort by ETA ascending

Max 6–8 rows

Show only:

product = suburban (S-Bahn)

product = subway (U-Bahn)

🟠 Monitor 3 — Heinrich-Heine-Straße (Mixed)
Data Sources:

U-Bahn (U8)

Bus (e.g. 165, 265, N8, etc.)

Layout:
[DOCK: HEINRICH-HEINE-STRASSE // SURFACE + SUBWAY]

LINE   DESTINATION         ETA   STATUS
-----------------------------------------
U8     WITTENAU             1m   DOCKING
265    S SCHÖNEWEIDE        3m   FINAL APPROACH
N8     OSLOER STRASSE       6m   INBOUND
165    KÖPENICK             9m   INBOUND
Rules:

Include:

subway

bus

Same sorting + row rules

🔵 Monitor 4 — Bottom Panel (Telemetry + Detail)
Mode A (default): System telemetry
DATA SOURCE: BVG REST FEED
STOP IDS:
  JANNOWITZ: 900000100003
  HEINRICH-HEINE: 900000100004

LAST UPDATE: 16:05:00
NEXT POLL:   16:05:30

API STATUS: OK
CACHE: ACTIVE
Mode B (rotating every ~20s):

expanded detail for next departure

delay delta visualization

Mode C (flavor, optional):
COMMUTER ADVISORY:
YOU ARE CUTTING THIS CLOSE

SYSTEM NOTE:
PROCRASTINATION DETECTED
🔌 Data Layer
Source

Use:

https://v6.bvg.transport.rest/stops/{STOP_ID}/departures
Stop IDs

You’ll need to resolve once and cache:

Jannowitzbrücke → (example) 900000100003

Heinrich-Heine-Straße → (example) 900000100004

(Verify once via /locations?query= endpoint)

Fetch Logic
Polling interval:

every 30 seconds

Query params:
?duration=10
Normalized Data Model
class Departure:
    line: String
    product: String  # suburban, subway, bus
    direction: String
    when: datetime
    minutes: int
    delay: int
    status: String  # DOCKING / FINAL_APPROACH / INBOUND
Status Mapping
if minutes <= 1:
    status = "DOCKING"
elif minutes <= 5:
    status = "FINAL_APPROACH"
else:
    status = "INBOUND"

if delay > 2:
    status = "VECTOR_DRIFT"
⚙️ Godot DataController (GDScript)
extends Node

var stops = {
    "jannowitz": "900000100003",
    "heinrich": "900000100004"
}

var departures = {}

func _ready():
    fetch_all()
    set_process(true)

func _process(delta):
    # poll every 30 seconds
    if Time.get_ticks_msec() % 30000 < 16:
        fetch_all()

func fetch_all():
    for key in stops.keys():
        fetch_stop(key, stops[key])

func fetch_stop(name, stop_id):
    var url = "https://v6.bvg.transport.rest/stops/%s/departures?duration=10" % stop_id
    var http = HTTPRequest.new()
    add_child(http)
    http.request(url)
    http.connect("request_completed", Callable(self, "_on_response").bind(name))

func _on_response(result, code, headers, body, stop_name):
    var json = JSON.parse_string(body.get_string_from_utf8())
    departures[stop_name] = normalize(json)

func normalize(data):
    var result = []
    for d in data:
        var minutes = int((Time.get_unix_time_from_datetime_string(d["when"]) - Time.get_unix_time_from_system()) / 60)
        result.append({
            "line": d["line"]["name"],
            "product": d["line"]["product"],
            "direction": d["direction"],
            "minutes": minutes,
            "delay": d.get("delay", 0),
            "status": get_status(minutes, d.get("delay", 0))
        })
    return result

func get_status(minutes, delay):
    if delay > 2:
        return "VECTOR_DRIFT"
    if minutes <= 1:
        return "DOCKING"
    if minutes <= 5:
        return "FINAL_APPROACH"
    return "INBOUND"
🎨 Visual Style Rules

Background: pure black

Primary lines: cyan / desaturated green

Accent: amber (warnings)

Typography:

headers → bold geometric

data → monospaced

Borders:

1–2px vector lines

Animations:

rows slide upward on refresh

ETA ticks down smoothly

subtle pulse for DOCKING rows

🎬 Animation Behavior

refresh → rows interpolate position (0.2–0.4s)

ETA countdown → update every second

highlight next departure:

slight glow

bracket indicator

radar sweep (top panel):

~10–15 second cycle

🧯 Failure Handling

If API fails:

freeze last known data

show:

STATUS: SIGNAL DEGRADED
DATA AGE: 02:15

optional flicker or warning glyph

🚀 Phase 1 Deliverable

A fully working system that:

shows both stops simultaneously

updates every 30s

renders across 4 monitors

animates cleanly

never crashes on missing data

No overengineering. No “AI assistant.” No feature creep.