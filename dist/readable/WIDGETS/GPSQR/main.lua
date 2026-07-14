-- SPDX-License-Identifier: BSD-3-Clause
--
-- EdgeTX GPS QR Code — color widget
--
-- This self-contained widget reads the active model's GPS-coordinate telemetry,
-- formats the last valid position as a geo: URI, and asks EdgeTX's native LVGL
-- QR-code object to render that URI. The implementation adapts to landscape,
-- portrait, full-screen, and compact widget zones without loading external Lua
-- modules. Keeping the color implementation in one file makes widget discovery
-- and startup reliable on radios with constrained Lua memory.
--
-- Runtime model
-- -------------
-- * create() allocates the widget state and constructs its initial LVGL tree.
-- * background() samples GPS telemetry while the widget is not in the foreground.
-- * refresh() updates dynamic state and rebuilds the LVGL tree only when needed.
-- * update() accepts option or zone changes supplied by EdgeTX.
--
-- Coordinates are stored internally as integer microdegrees. This avoids noisy
-- floating-point comparisons, gives deterministic six-decimal formatting, and
-- guarantees that the displayed coordinates exactly match the QR payload.
--
-- Copyright (c) 2012-2020, Patrick Gundlach and contributors
-- Copyright (c) 2024, alufers
-- Distributed under the BSD 3-Clause License. See LICENSE and
-- THIRD_PARTY_NOTICES.md in the repository root.

-- Application identity and timing policy.
-- EdgeTX time values are measured in 10 ms ticks, so multiplying seconds by 100
-- produces the callback intervals used below.
local APP_NAME = "GPS QR"
local APP_VERSION = "10.10.8"
local QR_REFRESH_TICKS = 15 * 100
local GPS_RETRY_TICKS = 2 * 100
local MIN_QR_PIXELS = 104

--[=[
firmwareSupportsLvgl()

Determines whether the current firmware can host the native LVGL widget.

The preferred path reads the structured major and minor values returned by
getVersion(). A string parser is retained as a defensive fallback for firmware
variants that do not return the numeric fields. When getVersion() is absent,
the function accepts an already-present LVGL API as the capability signal.

Returns:
  true when EdgeTX 2.11 or later, or an equivalent LVGL environment, is present;
  false when native color QR rendering cannot be used.
]=]
local function firmwareSupportsLvgl()
  if type(getVersion) ~= "function" then
    return type(lvgl) == "table" and type(lvgl.build) == "function"
  end

  local ok, version, _, major, minor = pcall(getVersion)
  if not ok then
    return false
  end

  if type(major) == "number" and type(minor) == "number" then
    return major > 2 or (major == 2 and minor >= 11)
  end

  if type(version) == "string" then
    local parsedMajor, parsedMinor = string.match(version, "^(%d+)%.(%d+)")
    parsedMajor = tonumber(parsedMajor)
    parsedMinor = tonumber(parsedMinor)
    if parsedMajor and parsedMinor then
      return parsedMajor > 2 or (parsedMajor == 2 and parsedMinor >= 11)
    end
  end

  return false
end

local USE_LVGL = firmwareSupportsLvgl()

--[=[
nowTicks()

Returns the current EdgeTX 10 ms tick counter without allowing a missing or
failing API to stop the widget. The protected call is useful in host tests and
unusual firmware environments where getTime may not exist.
]=]
local function nowTicks()
  if type(getTime) ~= "function" then
    return 0
  end

  local ok, value = pcall(getTime)
  if ok and type(value) == "number" then
    return value
  end

  return 0
end

--[=[
getConstant()

Looks up an EdgeTX global constant and supplies a safe fallback when that
constant is unavailable. This keeps the source usable across themes, firmware
revisions, and host-side test harnesses.
]=]
local function getConstant(name, fallback)
  local value = rawget(_G, name)
  if value ~= nil then
    return value
  end
  return fallback
end

local COLORS = {
  black = getConstant("BLACK", 0),
  white = getConstant("WHITE", 0xFFFFFF),
  text = getConstant("COLOR_THEME_PRIMARY2", getConstant("BLACK", 0)),
  muted = getConstant("COLOR_THEME_SECONDARY1", getConstant("BLACK", 0)),
  warning = getConstant("COLOR_THEME_WARNING", getConstant("RED", 0)),
  button = getConstant("COLOR_THEME_FOCUS", getConstant("BLACK", 0)),
  buttonText = getConstant("COLOR_THEME_PRIMARY1", getConstant("WHITE", 0xFFFFFF)),
}

local TITLE_FONT = getConstant("MIDSIZE", getConstant("STDSIZE", 0))
local BODY_FONT = getConstant("SMLSIZE", getConstant("STDSIZE", 0))

--[=[
isFullScreen()

Reports whether the widget is currently expanded to the full display.
Full-screen state controls QR sizing and whether interactive controls may be
created. Any API error is treated as a normal embedded-widget state.
]=]
local function isFullScreen()
  if type(lvgl) ~= "table" or type(lvgl.isFullScreen) ~= "function" then
    return false
  end

  local ok, value = pcall(lvgl.isFullScreen)
  return ok and value == true
end

--[=[
validGps()

Validates a telemetry value before it is accepted as a geographic position.
A valid sample must be a table containing finite numeric lat and lon fields
inside the legal latitude and longitude ranges.
]=]
local function validGps(value)
  if type(value) ~= "table" then
    return false
  end

  local latitude = value.lat
  local longitude = value.lon
  if type(latitude) ~= "number" or type(longitude) ~= "number" then
    return false
  end

  if latitude ~= latitude or longitude ~= longitude then
    return false
  end

  if latitude < -90 or latitude > 90 then
    return false
  end

  if longitude < -180 or longitude > 180 then
    return false
  end

  return true
end

--[=[
quantizeCoordinate()

Converts a floating-point degree value to a signed integer number of
microdegrees using symmetric rounding. Integer microdegrees are stable for
change detection and preserve six decimal places in the geo URI.
]=]
local function quantizeCoordinate(value)
  local scaled = value * 1000000
  local rounded

  if scaled >= 0 then
    rounded = math.floor(scaled + 0.5)
  else
    rounded = math.ceil(scaled - 0.5)
  end

  if rounded == 0 then
    return 0
  end

  return rounded
end

--[=[
formatCoordinate()

Formats a signed microdegree value as decimal degrees with exactly six
fractional digits. The explicit sign and integer arithmetic avoid negative-zero
text and keep the display text identical to the encoded payload.
]=]
local function formatCoordinate(microdegrees)
  local sign = ""
  local value = microdegrees

  if value < 0 then
    sign = "-"
    value = -value
  end

  local whole = math.floor(value / 1000000)
  local fraction = value % 1000000
  return sign .. tostring(whole) .. "." .. string.format("%06d", fraction)
end

-- Each configured telemetry sensor owns three consecutive source slots:
-- current value, minimum value, and maximum value. The current-value slot is
-- preferred because it remains unambiguous when multiple sensors share a name.
--[=[
resolveGpsSourceId()

Resolves a configured telemetry-sensor record to the source identifier used by
getValue(). Direct index arithmetic is preferred because each EdgeTX telemetry
sensor owns current, minimum, and maximum source slots. Name-based lookups are
fallbacks for firmware builds that do not expose MIXSRC_FIRST_TELEM.

Parameters:
  sensorIndex - zero-based model telemetry-sensor index, or nil for name lookup.
  sensorName  - configured sensor label shown in the model telemetry page.

Returns:
  source identifier and a short diagnostic description of the lookup method;
  nil values when the source cannot be resolved.
]=]
local function resolveGpsSourceId(sensorIndex, sensorName)
  local firstTelemetrySource = rawget(_G, "MIXSRC_FIRST_TELEM")
  if type(firstTelemetrySource) == "number" and type(sensorIndex) == "number" then
    return firstTelemetrySource + sensorIndex * 3, "sensor-unit"
  end

  -- Name lookup supports firmware variants that do not expose the telemetry
  -- source-base constant used by the direct index calculation.
  if type(getFieldInfo) == "function"
      and type(sensorName) == "string"
      and sensorName ~= "" then
    local ok, field = pcall(getFieldInfo, sensorName)
    if ok and type(field) == "table" and type(field.id) == "number" then
      return field.id, "sensor-name"
    end
  end

  if type(getSourceIndex) == "function"
      and type(sensorName) == "string"
      and sensorName ~= "" then
    local ok, sourceId = pcall(getSourceIndex, sensorName)
    if ok and type(sourceId) == "number" then
      return sourceId, "display-name"
    end
  end

  return nil, nil
end

-- Candidate deduplication prevents the semantic-unit scan and exact-name
-- fallback from adding the same telemetry source twice.
--[=[
appendGpsCandidate()

Adds a candidate GPS source unless the same configured sensor or source ID is
already present. Deduplication prevents the unit scan and compatibility fallback
from producing duplicate candidates.
]=]
local function appendGpsCandidate(candidates, candidate)
  for index = 1, #candidates do
    local existing = candidates[index]
    if candidate.sensorIndex ~= nil and existing.sensorIndex == candidate.sensorIndex then
      return
    end
    if candidate.sourceId ~= nil and existing.sourceId == candidate.sourceId then
      return
    end
  end

  candidates[#candidates + 1] = candidate
end

-- The model telemetry configuration is scanned by unit rather than by label,
-- so a GPS sensor remains discoverable after the user renames it.
--[=[
configuredGpsCandidates()

Enumerates the active model's telemetry configuration and returns every sensor
whose unit is UNIT_GPS. This makes discovery independent of the editable sensor
name. An exact-name GPS fallback supports older or reduced API environments.

Returns:
  an ordered array of candidate records containing sensor index, label, source
  identifier, and discovery method.
]=]
local function configuredGpsCandidates()
  local candidates = {}
  local gpsUnit = rawget(_G, "UNIT_GPS")
  local modelApi = rawget(_G, "model")

  if type(gpsUnit) == "number"
      and type(modelApi) == "table"
      and type(modelApi.getSensor) == "function" then
    local maxSensors = tonumber(rawget(_G, "MAX_SENSORS")) or 100
    maxSensors = math.max(1, math.min(200, math.floor(maxSensors)))

    for sensorIndex = 0, maxSensors - 1 do
      local ok, sensor = pcall(modelApi.getSensor, sensorIndex)
      if ok and type(sensor) == "table" and tonumber(sensor.unit) == gpsUnit then
        local sensorName = sensor.name
        if type(sensorName) ~= "string" or sensorName == "" then
          sensorName = "GPS " .. tostring(sensorIndex + 1)
        end

        local sourceId, method = resolveGpsSourceId(sensorIndex, sensorName)
        appendGpsCandidate(candidates, {
          sensorIndex = sensorIndex,
          sensorName = sensorName,
          sourceId = sourceId,
          method = method or "configured-unit",
        })
      end
    end
  end

  local fallbackId, fallbackMethod = resolveGpsSourceId(nil, "GPS")
  if fallbackId ~= nil then
    appendGpsCandidate(candidates, {
      sensorIndex = nil,
      sensorName = "GPS",
      sourceId = fallbackId,
      method = fallbackMethod or "exact-name",
    })
  end

  return candidates
end

--[=[
readGpsSource()

Reads one telemetry source and returns it only when it is a valid GPS sample.
Protected execution prevents a temporarily unavailable source from disabling the
entire widget.
]=]
local function readGpsSource(sourceId)
  if type(sourceId) ~= "number" or type(getValue) ~= "function" then
    return nil
  end

  local ok, value = pcall(getValue, sourceId)
  if ok and validGps(value) then
    return value
  end

  return nil
end

-- When several GPS sensors are configured, a source already providing valid
-- coordinates is preferred. Otherwise the existing selection is retained to
-- avoid unnecessary source switching while telemetry is temporarily absent.
--[=[
selectGpsCandidate()

Chooses the best GPS candidate and stores the selection in the widget state.
A candidate already producing coordinates wins. If none are live, the previous
selection is retained when possible, then the first resolvable configured GPS is
used. This policy avoids unnecessary source switching during telemetry dropouts.

Returns:
  the live GPS value associated with the selected candidate, or nil.
]=]
local function selectGpsCandidate(widget, candidates)
  local selected = nil
  local selectedValue = nil

  for index = 1, #candidates do
    local candidate = candidates[index]
    local value = readGpsSource(candidate.sourceId)
    if value ~= nil then
      selected = candidate
      selectedValue = value
      break
    end
  end

  if selected == nil and widget.gpsSourceId ~= nil then
    for index = 1, #candidates do
      if candidates[index].sourceId == widget.gpsSourceId then
        selected = candidates[index]
        break
      end
    end
  end

  if selected == nil then
    for index = 1, #candidates do
      if candidates[index].sourceId ~= nil then
        selected = candidates[index]
        break
      end
    end
  end

  if selected == nil then
    selected = candidates[1]
  end

  widget.gpsCandidateCount = #candidates
  widget.gpsConfigured = selected ~= nil

  if selected ~= nil then
    widget.gpsSourceId = selected.sourceId
    widget.gpsId = selected.sourceId
    widget.gpsSensorIndex = selected.sensorIndex
    widget.gpsSensorName = selected.sensorName
    widget.gpsDiscoveryMethod = selected.method
  else
    widget.gpsSourceId = nil
    widget.gpsId = nil
    widget.gpsSensorIndex = nil
    widget.gpsSensorName = nil
    widget.gpsDiscoveryMethod = nil
  end

  return selectedValue
end

-- Discovery is rate-limited because the sensor list is stable during normal
-- operation and scanning it on every widget callback would waste CPU time.
--[=[
discoverGps()

Runs the configured-sensor scan at a bounded interval. Sensor configuration is
normally stable, so rate limiting avoids repeating model API calls on every
widget callback. Passing force bypasses the interval check.
]=]
local function discoverGps(widget, now, force)
  if not force and now < widget.nextGpsDiscovery then
    return nil
  end

  widget.nextGpsDiscovery = now + GPS_RETRY_TICKS
  return selectGpsCandidate(widget, configuredGpsCandidates())
end

--[=[
readGps()

Samples the selected GPS source, rediscovers sources when required, and updates
all position-related widget state. New coordinates are quantized, formatted, and
assembled into the geo URI. A changed position marks the QR for a delayed rebuild.

Returns:
  true when the accepted microdegree position changed; false otherwise.
]=]
local function readGps(widget)
  local now = nowTicks()
  local value = nil

  if widget.gpsSourceId == nil then
    value = discoverGps(widget, now, false)
  else
    value = readGpsSource(widget.gpsSourceId)
  end

  if value == nil and now >= widget.nextGpsDiscovery then
    value = discoverGps(widget, now, true)
    if value == nil and widget.gpsSourceId ~= nil then
      value = readGpsSource(widget.gpsSourceId)
    end
  end

  if value == nil then
    return false
  end

  local latitudeE6 = quantizeCoordinate(value.lat)
  local longitudeE6 = quantizeCoordinate(value.lon)
  local changed = not widget.hasFix
    or latitudeE6 ~= widget.latitudeE6
    or longitudeE6 ~= widget.longitudeE6

  widget.hasFix = true
  widget.lastFixTime = now

  if changed then
    widget.latitudeE6 = latitudeE6
    widget.longitudeE6 = longitudeE6
    widget.latitudeText = formatCoordinate(latitudeE6)
    widget.longitudeText = formatCoordinate(longitudeE6)
    widget.payload = "geo:0,0?q=" .. widget.latitudeText .. "," .. widget.longitudeText
    widget.qrPending = true
  end

  return changed
end

--[=[
zoneDimensions()

Returns a sanitized widget-zone width and height. The function accepts EdgeTX
zone data when available and falls back to full LCD dimensions in test or legacy
environments. A small positive minimum prevents invalid LVGL geometry.
]=]
local function zoneDimensions(widget)
  local zone = widget.zone or {}
  local width = tonumber(zone.w) or tonumber(LCD_W) or 120
  local height = tonumber(zone.h) or tonumber(LCD_H) or 60
  return math.max(20, width), math.max(20, height)
end

--[=[
layoutSignature()

Builds a compact key describing the current zone dimensions and full-screen
state. A changed signature tells refresh() that the LVGL tree must be rebuilt.
]=]
local function layoutSignature(widget)
  local width, height = zoneDimensions(widget)
  return tostring(width) .. "x" .. tostring(height) .. ":" .. tostring(isFullScreen())
end

--[=[
gpsSensorLabel()

Returns the human-readable label of the selected GPS sensor, or the generic GPS
label when discovery has not produced a configured name.
]=]
local function gpsSensorLabel(widget)
  if type(widget.gpsSensorName) == "string" and widget.gpsSensorName ~= "" then
    return widget.gpsSensorName
  end
  return "GPS"
end

--[=[
statusText()

Constructs the current user-facing status line. The text distinguishes missing
configuration, unavailable source IDs, waiting telemetry, a pending QR refresh,
and the age of the last accepted fix.
]=]
local function statusText(widget)
  if widget.uiError then
    return "UI error: " .. tostring(widget.uiError)
  end

  if not widget.gpsConfigured then
    return "No configured GPS sensor"
  end

  local sensorLabel = gpsSensorLabel(widget)
  if widget.gpsSourceId == nil then
    return sensorLabel .. " source unavailable"
  end

  if not widget.hasFix then
    return "Waiting for " .. sensorLabel .. " telemetry"
  end

  local age = math.max(0, nowTicks() - widget.lastFixTime) / 100
  if widget.lastBuiltPayload and widget.payload ~= widget.lastBuiltPayload then
    return string.format("%s fix pending - %.0fs old", sensorLabel, age)
  end

  return string.format("%s fix %.0fs ago", sensorLabel, age)
end

--[=[
currentLatitude()

Returns the latitude text associated with the displayed QR. During a pending
refresh it deliberately preserves the last built QR's coordinate text.
]=]
local function currentLatitude(widget)
  return widget.displayLatitude or widget.latitudeText or "--"
end

--[=[
currentLongitude()

Returns the longitude text associated with the displayed QR. During a pending
refresh it deliberately preserves the last built QR's coordinate text.
]=]
local function currentLongitude(widget)
  return widget.displayLongitude or widget.longitudeText or "--"
end

--[=[
clearUi()

Requests that EdgeTX remove every LVGL object owned by this widget. The call is
protected because host test harnesses and older firmware may provide partial APIs.
]=]
local function clearUi()
  if type(lvgl) == "table" and type(lvgl.clear) == "function" then
    pcall(lvgl.clear)
  end
end

--[=[
buildErrorUi()

Replaces the normal widget view with an in-zone error display. Errors are stored
in widget state so statusText() and later rebuild attempts can report the cause.
This function avoids raising another Lua error when only part of LVGL is present.
]=]
local function buildErrorUi(widget, message)
  widget.uiError = tostring(message or "Unknown UI error")
  clearUi()

  if type(lvgl) ~= "table" or type(lvgl.build) ~= "function" then
    return
  end

  local width, height = zoneDimensions(widget)
  pcall(lvgl.build, {
    {
      type = "label",
      x = 4,
      y = 4,
      w = math.max(20, width - 8),
      h = 26,
      text = "GPS QR error",
      color = COLORS.warning,
      font = TITLE_FONT,
    },
    {
      type = "label",
      x = 4,
      y = 34,
      w = math.max(20, width - 8),
      h = math.max(20, height - 38),
      text = widget.uiError,
      color = COLORS.warning,
      font = BODY_FONT,
    },
  })
end

--[=[
addStatusOnly()

Appends a title and status message to an LVGL specification without creating a
QR code. This compact view is used while waiting for GPS, on unsupported firmware,
or when the assigned widget zone is too small for reliable scanning.
]=]
local function addStatusOnly(spec, widget, width, height, message)
  spec[#spec + 1] = {
    type = "label",
    x = 6,
    y = 4,
    w = math.max(20, width - 12),
    h = 26,
    text = "GPS QR " .. APP_VERSION,
    color = COLORS.text,
    font = TITLE_FONT,
  }

  spec[#spec + 1] = {
    type = "label",
    x = 6,
    y = 34,
    w = math.max(20, width - 12),
    h = math.max(20, height - 38),
    text = message or function() return statusText(widget) end,
    color = COLORS.muted,
    font = BODY_FONT,
  }
end

--[=[
buildWidgetUi()

Constructs the complete LVGL specification for the current zone and state.

The function selects compact status, landscape QR, or portrait QR layout. A QR
is rendered only when the zone is large enough or the widget is full screen.
When a new QR is committed, the displayed coordinates and payload are updated
atomically so the text can never describe a different location than the code.

Parameters:
  widget  - mutable widget state created by create().
  forceQr - commits the newest payload immediately when true.

Returns:
  true when the LVGL tree was built successfully; false after a recoverable UI
  failure or when LVGL is unavailable.
]=]
local function buildWidgetUi(widget, forceQr)
  if type(lvgl) ~= "table" or type(lvgl.build) ~= "function" then
    widget.uiError = "LVGL support is unavailable"
    return false
  end

  local width, height = zoneDimensions(widget)
  local fullScreen = isFullScreen()
  local signature = layoutSignature(widget)
  local spec = {}
  local margin = 8

  clearUi()

  if type(lvgl.qrcode) ~= "function" then
    addStatusOnly(spec, widget, width, height, "EdgeTX 2.11 or later is required")
  elseif not widget.hasFix then
    addStatusOnly(spec, widget, width, height)
  else
    local canShowQr = fullScreen
      or (math.min(width, height) >= MIN_QR_PIXELS + margin * 2 and width * height >= 30000)

    if not canShowQr then
      addStatusOnly(spec, widget, width, height, "Open the widget full screen to scan")
    else
      local landscape = width >= height
      local qrSize
      local qrX
      local qrY
      local infoX
      local infoY
      local infoW
      local infoH

      if landscape then
        qrSize = math.min(height - margin * 2, math.floor(width * 0.58))
        qrSize = math.max(MIN_QR_PIXELS, qrSize)
        qrX = margin
        qrY = math.max(margin, math.floor((height - qrSize) / 2))
        infoX = qrX + qrSize + margin
        infoY = margin
        infoW = math.max(40, width - infoX - margin)
        infoH = math.max(40, height - margin * 2)
      else
        qrSize = math.min(width - margin * 2, math.floor(height * 0.62))
        qrSize = math.max(MIN_QR_PIXELS, qrSize)
        qrX = math.max(margin, math.floor((width - qrSize) / 2))
        qrY = margin
        infoX = margin
        infoY = qrY + qrSize + margin
        infoW = math.max(40, width - margin * 2)
        infoH = math.max(40, height - infoY - margin)
      end

      if forceQr or widget.lastBuiltPayload == nil or widget.payload ~= widget.lastBuiltPayload then
        widget.lastBuiltPayload = widget.payload
        widget.displayLatitude = widget.latitudeText
        widget.displayLongitude = widget.longitudeText
        widget.lastQrBuildTime = nowTicks()
        widget.qrPending = false
      end

      spec[#spec + 1] = {
        type = "qrcode",
        x = qrX,
        y = qrY,
        w = qrSize,
        h = qrSize,
        data = widget.lastBuiltPayload,
        color = COLORS.black,
        bgColor = COLORS.white,
      }

      spec[#spec + 1] = {
        type = "label",
        x = infoX,
        y = infoY,
        w = infoW,
        h = 26,
        text = "GPS QR " .. APP_VERSION,
        color = COLORS.text,
        font = TITLE_FONT,
      }

      spec[#spec + 1] = {
        type = "label",
        x = infoX,
        y = infoY + 32,
        w = infoW,
        h = 22,
        text = function() return "Lat " .. currentLatitude(widget) end,
        color = COLORS.text,
        font = BODY_FONT,
      }

      spec[#spec + 1] = {
        type = "label",
        x = infoX,
        y = infoY + 56,
        w = infoW,
        h = 22,
        text = function() return "Lon " .. currentLongitude(widget) end,
        color = COLORS.text,
        font = BODY_FONT,
      }

      spec[#spec + 1] = {
        type = "label",
        x = infoX,
        y = infoY + 82,
        w = infoW,
        h = 26,
        text = function() return statusText(widget) end,
        color = COLORS.muted,
        font = BODY_FONT,
      }

      if fullScreen and type(lvgl.button) == "function" then
        spec[#spec + 1] = {
          type = "button",
          x = infoX,
          y = math.max(infoY + 112, infoY + infoH - 42),
          w = math.min(infoW, 150),
          h = 36,
          text = "Refresh QR",
          color = COLORS.button,
          textColor = COLORS.buttonText,
          press = function()
            widget.forceQr = true
          end,
        }
      end
    end
  end

  local ok, result = pcall(lvgl.build, spec)
  if not ok then
    buildErrorUi(widget, result)
    return false
  end

  widget.uiError = nil
  widget.layoutSignature = signature
  widget.uiBuilt = true
  return true
end

--[=[
enterEvent()

Recognizes the Enter event names used by different EdgeTX color-radio builds.
The function is intentionally tolerant of absent constants and ignores nil or
idle events.
]=]
local function enterEvent(event)
  if event == nil or event == 0 then
    return false
  end

  local names = {
    "EVT_VIRTUAL_ENTER",
    "EVT_ENTER_BREAK",
    "EVT_ENTER_FIRST",
  }

  for index = 1, #names do
    local value = rawget(_G, names[index])
    if value ~= nil and event == value then
      return true
    end
  end

  return false
end

--[=[
create()

EdgeTX widget factory callback. Allocates all persistent state, performs an
initial GPS sample, and constructs the first LVGL view. The returned table is the
widget instance passed to all subsequent callbacks.
]=]
local function create(zone, options)
  local widget = {
    zone = zone or {x = 0, y = 0, w = LCD_W, h = LCD_H},
    options = options or {},
    gpsId = nil,
    gpsSourceId = nil,
    gpsSensorIndex = nil,
    gpsSensorName = nil,
    gpsDiscoveryMethod = nil,
    gpsCandidateCount = 0,
    gpsConfigured = false,
    nextGpsDiscovery = 0,
    hasFix = false,
    latitudeE6 = 0,
    longitudeE6 = 0,
    latitudeText = nil,
    longitudeText = nil,
    payload = nil,
    lastFixTime = 0,
    lastQrBuildTime = 0,
    lastBuiltPayload = nil,
    displayLatitude = nil,
    displayLongitude = nil,
    qrPending = false,
    forceQr = false,
    layoutSignature = nil,
    uiBuilt = false,
    uiError = nil,
  }

  readGps(widget)
  if USE_LVGL then
    buildWidgetUi(widget, true)
  end
  return widget
end

--[=[
update()

EdgeTX widget update callback. Stores revised options, samples GPS, and rebuilds
the UI to reflect zone or configuration changes.
]=]
local function update(widget, options)
  if not widget then
    return
  end

  widget.options = options or widget.options or {}
  readGps(widget)
  if USE_LVGL then
    buildWidgetUi(widget, true)
  end
end

--[=[
background()

EdgeTX background callback. It performs only lightweight GPS sampling so the
last valid position continues to update even when the widget is not visible.
]=]
local function background(widget)
  if not widget then
    return
  end

  readGps(widget)
end

--[=[
refresh()

EdgeTX foreground callback. It processes manual refresh input, samples GPS,
and rebuilds the LVGL tree only for initial display, geometry changes, explicit
requests, or a due position update. On firmware without LVGL, it draws a concise
compatibility message through the color LCD API.
]=]
local function refresh(widget, event, touchState)
  if not widget then
    return
  end

  if not USE_LVGL then
    if type(lcd) == "table" then
      if type(lcd.clear) == "function" then
        lcd.clear()
      end
      if type(lcd.drawText) == "function" then
        local warning = rawget(_G, "COLOR_THEME_WARNING") or 0
        lcd.drawText(4, 4, "GPS QR " .. APP_VERSION, warning)
        lcd.drawText(4, 24, "EdgeTX 2.11+ required", warning)
      end
    end
    return
  end

  readGps(widget)

  if enterEvent(event) then
    widget.forceQr = true
  end

  local signature = layoutSignature(widget)
  local layoutChanged = signature ~= widget.layoutSignature
  local now = nowTicks()
  local refreshDue = widget.qrPending
    and (widget.lastBuiltPayload == nil or now - widget.lastQrBuildTime >= QR_REFRESH_TICKS)

  if not widget.uiBuilt or layoutChanged or widget.forceQr or refreshDue then
    local forceQr = widget.forceQr or layoutChanged or widget.lastBuiltPayload == nil
    widget.forceQr = false
    buildWidgetUi(widget, forceQr)
  end
end

return {
  name = APP_NAME,
  options = {},
  create = create,
  update = update,
  refresh = refresh,
  background = background,
  useLvgl = USE_LVGL,
}
