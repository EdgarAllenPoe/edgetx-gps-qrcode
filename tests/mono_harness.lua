-- Host-side EdgeTX monochrome/grayscale telemetry-script harness.
--
-- The harness implements the small subset of EdgeTX APIs used by GPSQR.lua,
-- records filled rectangles into a monochrome pixel buffer, and writes a PGM
-- image for independent QR decoding by the Python test suite.

local scriptPath = assert(arg[1], "script path is required")
local outputPath = assert(arg[2], "output path is required")
local latitude = assert(tonumber(arg[3]), "latitude is required")
local longitude = assert(tonumber(arg[4]), "longitude is required")
local width = tonumber(arg[5]) or 128
local height = tonumber(arg[6]) or 64
local radio = arg[7] or "boxer-simu"
local grayscale = arg[8] == "1"
local backgroundSteps = tonumber(arg[9]) or 100

-- EdgeTX constants used by the telemetry entry point.
LCD_W = width
LCD_H = height
INVERS = 1
EVT_VIRTUAL_ENTER = 1001
EVT_ENTER_BREAK = 1002
UNIT_GPS = 42
MAX_SENSORS = 8
MIXSRC_FIRST_TELEM = 1000
GPS_QR_TEST_MODE = true

-- GREY exists only on grayscale targets and is used by the production script as
-- a display-capability probe. Its value is not needed by this binary renderer.
if grayscale then
  function GREY(value)
    return value
  end
end

local ticks = 0
function getTime()
  ticks = ticks + 1
  return ticks
end

function getVersion()
  return "2.11.4", radio, 2, 11, 4, "EdgeTX"
end

-- Multiple configured GPS sensors exercise live-source preference and renamed
-- sensor support. HomeGPS is configured but silent; NavPos supplies coordinates.
model = {}
local sensors = {
  [0] = {name = "RSSI", unit = 0},
  [1] = {name = "HomeGPS", unit = UNIT_GPS},
  [2] = {name = "Alt", unit = 9},
  [3] = {name = "NavPos", unit = UNIT_GPS},
}
function model.getSensor(index)
  return sensors[index]
end

function getFieldInfo(name)
  return nil
end

function getSourceIndex(name)
  return nil
end

function getValue(id)
  if id == MIXSRC_FIRST_TELEM + 1 * 3 then
    return 0
  end
  if id == MIXSRC_FIRST_TELEM + 3 * 3 then
    return {lat = latitude, lon = longitude}
  end
  return 0
end

-- The LCD implementation stores white pixels by default and paints black pixels
-- for every filled rectangle. Text drawing is intentionally ignored because the
-- QR decoder needs only the module image.
local pixels = {}
local drawCalls = 0
local function clearPixels()
  pixels = {}
  drawCalls = 0
  for y = 0, LCD_H - 1 do
    pixels[y] = {}
    for x = 0, LCD_W - 1 do
      pixels[y][x] = 255
    end
  end
end
clearPixels()

lcd = {}
function lcd.clear()
  clearPixels()
end
function lcd.drawText(...) end
function lcd.drawFilledRectangle(x, y, rectWidth, rectHeight, flags)
  drawCalls = drawCalls + 1
  local startX = math.floor(x)
  local startY = math.floor(y)
  local endX = math.floor(x + rectWidth - 1)
  local endY = math.floor(y + rectHeight - 1)

  for py = startY, endY do
    if py >= 0 and py < LCD_H then
      for px = startX, endX do
        if px >= 0 and px < LCD_W then
          pixels[py][px] = 0
        end
      end
    end
  end
end

local app = assert(loadfile(scriptPath))()
assert(type(app) == "table")
assert(type(app.init) == "function")
assert(type(app.background) == "function")
assert(type(app.run) == "function")

-- A real radio alternates background callbacks with foreground draws. The loop
-- gives the cooperative QR state machine enough callbacks to finish all masks.
app.init()
app.background()
app.run(0)
for _ = 1, backgroundSteps do
  app.background()
end
app.run(0)

local state = assert(app._test).getGpsState()
assert(state.sensorName == "NavPos", "renamed live GPS sensor was not selected")
assert(state.sourceId == MIXSRC_FIRST_TELEM + 3 * 3, "wrong GPS source selected")
assert(state.displayKind == (grayscale and "grayscale" or "onebit"))

-- PGM is intentionally simple and lossless, making it suitable for QR decoder
-- validation without image-encoding libraries inside the Lua harness.
local file = assert(io.open(outputPath, "wb"))
file:write("P5\n", LCD_W, " ", LCD_H, "\n255\n")
for y = 0, LCD_H - 1 do
  local row = {}
  for x = 0, LCD_W - 1 do
    row[#row + 1] = string.char(pixels[y][x])
  end
  file:write(table.concat(row))
end
file:close()

print(string.format(
  "draw_calls=%d ticks=%d sensor=%s source=%d radio=%s kind=%s scale=%d side=%s inverted=%s",
  drawCalls,
  ticks,
  tostring(state.sensorName),
  tonumber(state.sourceId) or -1,
  tostring(state.radioId),
  tostring(state.displayKind),
  tonumber(state.layout and state.layout.scale) or -1,
  tostring(state.layout and state.layout.sidePanel),
  tostring(state.inverted)
))
