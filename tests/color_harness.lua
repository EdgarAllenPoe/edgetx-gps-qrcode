-- Host-side EdgeTX color-widget harness.
--
-- The harness provides only the globals used by the production widget. LVGL
-- objects are captured as Lua specification tables rather than drawn, allowing
-- tests to validate geometry, payloads, and compact-zone behavior without an
-- EdgeTX simulator binary.

local scriptPath = assert(arg[1], "script path is required")
local width = tonumber(arg[2]) or 480
local height = tonumber(arg[3]) or 272
local fullscreen = arg[4] ~= "0"
local expectQr = arg[5] ~= "0"

-- Display, theme, telemetry-unit, and event constants exposed by EdgeTX.
LCD_W = width
LCD_H = height
BLACK = 0
WHITE = 0xFFFFFF
COLOR_THEME_PRIMARY1 = 1
COLOR_THEME_PRIMARY2 = 2
COLOR_THEME_SECONDARY1 = 3
COLOR_THEME_WARNING = 4
COLOR_THEME_FOCUS = 5
MIDSIZE = 6
SMLSIZE = 7
UNIT_GPS = 42
MAX_SENSORS = 8
MIXSRC_FIRST_TELEM = 1000
EVT_VIRTUAL_ENTER = 1001

-- EdgeTX uses a 10 ms monotonic timer. Incrementing on each call keeps the
-- harness deterministic while still exercising age and refresh calculations.
local ticks = 0
function getTime()
  ticks = ticks + 1
  return ticks
end

-- The production widget requires EdgeTX 2.11+ for lvgl.qrcode.
function getVersion()
  return "2.12.2", "tx16s-simu", 2, 12, 2, "EdgeTX"
end

-- Two configured telemetry sensors are exposed. The GPS label is deliberately
-- renamed to prove that discovery is based on UNIT_GPS rather than the name.
model = {}
local sensors = {
  [0] = {name = "RSSI", unit = 0},
  [1] = {name = "Position", unit = UNIT_GPS},
}
function model.getSensor(index)
  return sensors[index]
end

-- Name fallbacks are disabled so successful selection must use sensor-unit
-- enumeration and direct current-value source arithmetic.
function getFieldInfo(name)
  return nil
end

function getSourceIndex(name)
  return nil
end

function getValue(id)
  if id == MIXSRC_FIRST_TELEM + 3 then
    return {lat = 40.7128, lon = -74.006}
  end
  return 0
end

-- LVGL build specifications are retained for assertions. qrcode and button
-- symbols are present as capability probes even though lvgl.build performs the
-- actual object creation in EdgeTX.
local lastSpec = nil
lvgl = {}
function lvgl.isFullScreen()
  return fullscreen
end
function lvgl.clear()
  lastSpec = nil
end
function lvgl.qrcode() end
function lvgl.button() end
function lvgl.build(spec)
  lastSpec = spec
  return {}
end

local app = assert(loadfile(scriptPath))()
assert(app.name == "GPS QR", "widget registration name changed")
assert(app.useLvgl == true, "color widget did not request LVGL")

local widget = app.create({x = 0, y = 0, w = width, h = height}, {})
app.background(widget)
app.refresh(widget, 0, nil)
assert(type(lastSpec) == "table", "widget did not build an LVGL specification")

local qr = nil
local title = nil
local statusOnly = nil
for index = 1, #lastSpec do
  local item = lastSpec[index]
  if item.type == "qrcode" then
    qr = item
  end
  if item.type == "label" and type(item.text) == "string" then
    if string.find(item.text, "GPS QR", 1, true) then
      title = item.text
    end
    if string.find(item.text, "full screen", 1, true) then
      statusOnly = item.text
    end
  end
end

assert(title == "GPS QR 10.10.7", "wrong color version title")
if expectQr then
  assert(qr ~= nil, "native QR object was not requested")
  assert(qr.data == "geo:40.712800,-74.006000", "wrong color QR payload")
  assert(qr.w == qr.h and qr.w > 0, "QR dimensions are invalid")
  print(string.format(
    "color_payload=%s title=%s size=%d screen=%dx%d",
    qr.data,
    title,
    qr.w,
    width,
    height
  ))
else
  assert(qr == nil, "compact zone should not render an unreliable QR")
  assert(statusOnly ~= nil, "compact zone did not provide full-screen guidance")
  print(string.format(
    "color_status=%s title=%s screen=%dx%d",
    statusOnly,
    title,
    width,
    height
  ))
end
