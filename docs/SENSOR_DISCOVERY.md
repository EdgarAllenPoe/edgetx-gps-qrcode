# GPS sensor discovery

## Why names are not enough

EdgeTX telemetry sensor labels are user-editable and protocol-dependent. A coordinate source may be named `GPS`, `Position`, `NavPos`, or something else. Looking up only `getFieldInfo("GPS")` therefore misses valid configurations.

## Unit-based enumeration

Both entry points call `model.getSensor(index)` and collect sensors whose `unit` equals `UNIT_GPS`. Each candidate record stores:

- Zero-based configured sensor index.
- User-visible sensor label.
- Current-value source identifier.
- Discovery method for diagnostics.

## Resolving the current-value source

EdgeTX assigns three consecutive telemetry sources to each configured sensor:

1. Current value.
2. Minimum value.
3. Maximum value.

When `MIXSRC_FIRST_TELEM` is available, the current source is calculated as:

```lua
MIXSRC_FIRST_TELEM + sensorIndex * 3
```

Name-based `getFieldInfo()` and `getSourceIndex()` lookups are retained as fallbacks for reduced or older API environments.

## Multiple GPS sensors

Candidate selection follows this order:

1. First configured GPS source currently returning valid `lat` and `lon`.
2. Previously selected source, when still configured.
3. First candidate with a resolvable source ID.
4. First configured GPS record.

This favors live coordinates without oscillating between sensors during a short outage.

## Validity rules

A sample is accepted only when:

- It is a Lua table.
- `lat` and `lon` are finite numbers.
- Latitude is between -90 and 90.
- Longitude is between -180 and 180.

Zero latitude or longitude is valid and is not treated as missing data.

## Last-fix retention

A lost telemetry stream does not erase the last accepted coordinates. This behavior is intentional for model recovery. The displayed fix age communicates staleness.
