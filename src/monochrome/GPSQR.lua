--[[
EdgeTX GPS QR Code — v10.10.7 monochrome telemetry edition

Displays the last valid GPS telemetry position as a QR code containing a geo URI.
The source is intentionally readable and should be minified before radio deployment.

This program contains work derived from luaqrcode by Patrick Gundlach and
contributors, and from the EdgeTX adaptation by alufers.

Copyright (c) 2012-2020, Patrick Gundlach and contributors
Copyright (c) 2024, alufers

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of SPEEDATA nor the names of its contributors may be used
   to endorse or promote products derived from this software without specific
   prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]

--[=[
Implementation overview
-----------------------
This telemetry script targets one-bit and grayscale EdgeTX radios. It contains a
fixed QR Version 2-L encoder because those radios do not expose the native LVGL
QR object. The encoder uses byte-oriented data codewords, Reed-Solomon error
correction, packed 32-bit matrix rows, and run-length LCD drawing.

Expensive work is divided into a QR job state machine. background() advances a
bounded amount of work per callback while run() continues to display the last
completed QR. This double-buffered behavior keeps the radio responsive and
prevents partially generated symbols from reaching the screen.

The source is intentionally readable and fully documented. Radio deployment
uses the generated minified file in dist/minified/SCRIPTS/TELEMETRY/GPSQR.lua.
]=]

-- Runtime policy constants. All time intervals use EdgeTX 10 ms ticks. The
-- polarity override accepts "automatic", "normal", or "inverted".
local SCRIPT_VERSION = "10.10.7"
local POLARITY_OVERRIDE = "automatic"
local QUIET_ZONE_MODULES = 3
local AUTO_REFRESH = false
local AUTO_REFRESH_INTERVAL_TICKS = 30 * 100
local MINIMUM_MOVEMENT_E6 = 20
local SCREEN_REOPEN_GAP_TICKS = 1 * 100
local rsCodewordsPerStep = 4
local gcStepSize = 8
local VALIDATE_COMPLETED_QR = true

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift

-- Profiling is disabled in normal use. When enabled, measurements are printed
-- to the EdgeTX Lua console after each QR code is generated.
local PROFILE_ENABLED = false
local profileData = nil

--[=[
profileBegin()

Starts an optional generation profile. The profile records elapsed EdgeTX ticks,
initial Lua heap usage, peak heap usage, and per-stage timing. Profiling remains
disabled in normal radio operation.
]=]
local function profileBegin()
    if not PROFILE_ENABLED then return end
    profileData = {
        started = getTime(),
        memoryStarted = collectgarbage("count"),
        memoryPeak = collectgarbage("count"),
        stages = {},
        stageStarted = nil,
        stageName = nil,
    }
end

--[=[
profileStageStart()

Marks the beginning of one named profiling stage. A later call to
profileStageEnd() accumulates the elapsed ticks under that name.
]=]
local function profileStageStart(name)
    if not PROFILE_ENABLED or not profileData then return end
    profileData.stageName = name
    profileData.stageStarted = getTime()
end

--[=[
profileStageEnd()

Closes the active profiling stage, accumulates its elapsed time, and samples
the Lua heap for peak-memory reporting.
]=]
local function profileStageEnd()
    if not PROFILE_ENABLED or not profileData or not profileData.stageStarted then return end
    local elapsed = getTime() - profileData.stageStarted
    local name = profileData.stageName
    profileData.stages[name] = (profileData.stages[name] or 0) + elapsed
    local memory = collectgarbage("count")
    if memory > profileData.memoryPeak then profileData.memoryPeak = memory end
    profileData.stageStarted = nil
    profileData.stageName = nil
end

--[=[
profileFinish()

Prints one completed QR profile to the EdgeTX Lua console and releases the
profiling table. The QR version, chosen mask, and final penalty are included for
diagnostic comparison.
]=]
local function profileFinish(version, mask, penalty)
    if not PROFILE_ENABLED or not profileData then return end
    profileStageEnd()
    local total = getTime() - profileData.started
    print(string.format(
        "GPSQR %s total=%d ticks mem=%.1fKB peak=%.1fKB version=%d mask=%d penalty=%d",
        SCRIPT_VERSION,
        total,
        profileData.memoryStarted,
        profileData.memoryPeak,
        version,
        mask,
        penalty
    ))
    for name, elapsed in pairs(profileData.stages) do
        print(string.format("GPSQR stage=%s ticks=%d", name, elapsed))
    end
    profileData = nil
end

-- A compact bit buffer writes QR fields directly into byte codewords.
--[=[
createBitBuffer()

Allocates the byte-oriented bit buffer used to assemble QR mode, length,
payload, terminator, and padding fields.
]=]
local function createBitBuffer()
    return {bytes = {}, length = 0}
end

--[=[
appendBits()

Appends the requested number of most-significant-first bits to a bit buffer.
Bits are written directly into bytes so the encoder never constructs strings of
textual zeroes and ones.
]=]
local function appendBits(buffer, value, count)
    for sourceBit = count - 1, 0, -1 do
        local bit = band(rshift(value, sourceBit), 1)
        local byteIndex = math.floor(buffer.length / 8) + 1
        local destinationBit = 7 - (buffer.length % 8)
        if not buffer.bytes[byteIndex] then buffer.bytes[byteIndex] = 0 end
        if bit ~= 0 then
            buffer.bytes[byteIndex] = bor(buffer.bytes[byteIndex], lshift(1, destinationBit))
        end
        buffer.length = buffer.length + 1
    end
end

-- Multiplies two GF(256) values using the QR Code primitive polynomial.
--[=[
gfMultiply()

Multiplies two values in QR Code GF(256) using the 0x11D primitive polynomial.
The function returns one field element in the range 0 through 255.
]=]
local function gfMultiply(x, y)
    local product = 0
    for _ = 1, 8 do
        if band(y, 1) ~= 0 then product = bxor(product, x) end
        local highBit = band(x, 0x80)
        x = band(lshift(x, 1), 0xFF)
        if highBit ~= 0 then x = bxor(x, 0x1D) end
        y = rshift(y, 1)
    end
    return product
end

-- Builds a Reed-Solomon generator polynomial for the requested degree.
--[=[
createGeneratorPolynomial()

Builds the Reed-Solomon generator polynomial for a requested number of error
correction codewords. Version 2-L requires a degree-ten polynomial.
]=]
local function createGeneratorPolynomial(degree)
    local polynomial = {}
    for i = 1, degree do polynomial[i] = 0 end
    polynomial[degree] = 1

    local root = 1
    for _ = 1, degree do
        for i = 1, degree do
            polynomial[i] = gfMultiply(polynomial[i], root)
            if i < degree then
                polynomial[i] = bxor(polynomial[i], polynomial[i + 1])
            end
        end
        root = gfMultiply(root, 2)
    end
    return polynomial
end

-- Version 2-L provides 34 data codewords and safely contains every geo URI
-- produced from six-decimal latitude and longitude coordinates.
local QR_PARAMETERS = {
    version = 2,
    size = 25,
    dataCodewords = 34,
    ecCodewords = 10,
    alignment = 18,
    remainderBits = 7,
    maximumPayloadBytes = 32,
}

--[=[
selectQrParameters()

Returns the fixed Version 2-L parameter record when the payload fits its
32-byte byte-mode capacity. Longer payloads return a descriptive error.
]=]
local function selectQrParameters(payloadLength)
    if payloadLength <= QR_PARAMETERS.maximumPayloadBytes then return QR_PARAMETERS end
    return nil, "QR payload is too long for Version 2-L"
end

-- Encodes a byte-mode payload into the fixed Version 2-L data codewords.
-- Error-correction bytes are produced incrementally by the QR job state machine.
--[=[
encodeDataCodewords()

Encodes a geo URI into the 34 Version 2-L data codewords. The function writes
the byte-mode indicator and length, appends payload bytes, adds the terminator,
aligns to a byte boundary, and fills remaining capacity with 0xEC/0x11 pads.
]=]
local function encodeDataCodewords(payload, parameters)
    local capacityBits = parameters.dataCodewords * 8
    local buffer = createBitBuffer()

    appendBits(buffer, 4, 4)
    appendBits(buffer, #payload, 8)
    for i = 1, #payload do appendBits(buffer, string.byte(payload, i), 8) end

    appendBits(buffer, 0, math.min(4, capacityBits - buffer.length))
    while buffer.length % 8 ~= 0 do appendBits(buffer, 0, 1) end

    local useFirstPad = true
    while #buffer.bytes < parameters.dataCodewords do
        buffer.bytes[#buffer.bytes + 1] = useFirstPad and 0xEC or 0x11
        buffer.length = buffer.length + 8
        useFirstPad = not useFirstPad
    end
    return buffer.bytes
end

-- A 25-module matrix fits in one 32-bit integer per row. Separate row arrays
-- store dark modules and function-pattern reservations.
--[=[
createPackedMatrix()

Allocates a QR matrix represented by two arrays of 32-bit row integers. The
dark plane stores module color; the reserved plane marks function-pattern cells
that data placement must skip.
]=]
local function createPackedMatrix(size)
    local matrix = {size = size, dark = {}, reserved = {}}
    for y = 1, size do
        matrix.dark[y] = 0
        matrix.reserved[y] = 0
    end
    return matrix
end

--[=[
setRowBit()

Sets or clears one module bit in a packed row array. Matrix coordinates are
zero-based while Lua row storage is one-based.
]=]
local function setRowBit(rows, x, y, dark)
    local mask = lshift(1, x)
    if dark then
        rows[y + 1] = bor(rows[y + 1], mask)
    else
        rows[y + 1] = band(rows[y + 1], bnot(mask))
    end
end

--[=[
rowBit()

Reads one module from a packed row array and returns true for a set bit.
]=]
local function rowBit(rows, x, y)
    return band(rows[y + 1], lshift(1, x)) ~= 0
end

--[=[
setFunctionCell()

Writes a mandatory QR function-pattern module and marks the same cell reserved.
Coordinates outside the matrix are ignored so finder separators can be drawn with
a simple uniform loop.
]=]
local function setFunctionCell(matrix, x, y, dark)
    if x < 0 or y < 0 or x >= matrix.size or y >= matrix.size then return end
    setRowBit(matrix.dark, x, y, dark)
    setRowBit(matrix.reserved, x, y, true)
end

-- Draws a finder pattern and its one-module separator.
--[=[
drawFinderPattern()

Draws one seven-module finder target plus its one-module separator around the
specified center coordinates.
]=]
local function drawFinderPattern(matrix, centerX, centerY)
    for dy = -4, 4 do
        for dx = -4, 4 do
            local distance = math.max(math.abs(dx), math.abs(dy))
            setFunctionCell(matrix, centerX + dx, centerY + dy, distance ~= 2 and distance ~= 4)
        end
    end
end

-- Draws the Version 2 five-by-five alignment pattern.
--[=[
drawAlignmentPattern()

Draws the single five-by-five alignment target required by QR Version 2.
]=]
local function drawAlignmentPattern(matrix, centerX, centerY)
    for dy = -2, 2 do
        for dx = -2, 2 do
            local distance = math.max(math.abs(dx), math.abs(dy))
            setFunctionCell(matrix, centerX + dx, centerY + dy, distance ~= 1)
        end
    end
end

-- Reserves both copies of the format field and installs the fixed dark module.
--[=[
reserveFormatArea()

Reserves every matrix cell used by format information and the fixed dark module.
The actual format bits are written later for each candidate mask.
]=]
local function reserveFormatArea(matrix)
    for i = 0, 5 do setFunctionCell(matrix, 8, i, false) end
    setFunctionCell(matrix, 8, 7, false)
    setFunctionCell(matrix, 8, 8, false)
    setFunctionCell(matrix, 7, 8, false)
    for i = 9, 14 do setFunctionCell(matrix, 14 - i, 8, false) end

    for i = 0, 7 do setFunctionCell(matrix, matrix.size - 1 - i, 8, false) end
    for i = 8, 14 do setFunctionCell(matrix, 8, matrix.size - 15 + i, false) end
    setFunctionCell(matrix, 8, matrix.size - 8, true)
end

-- Creates the mask-independent function-pattern planes.
--[=[
createBaseMatrix()

Builds the mask-independent Version 2 matrix containing finder, timing,
alignment, separator, format-reservation, and fixed-dark patterns.
]=]
local function createBaseMatrix(parameters)
    local matrix = createPackedMatrix(parameters.size)
    drawFinderPattern(matrix, 3, 3)
    drawFinderPattern(matrix, matrix.size - 4, 3)
    drawFinderPattern(matrix, 3, matrix.size - 4)

    for i = 8, matrix.size - 9 do
        setFunctionCell(matrix, 6, i, i % 2 == 0)
        setFunctionCell(matrix, i, 6, i % 2 == 0)
    end

    drawAlignmentPattern(matrix, parameters.alignment, parameters.alignment)
    reserveFormatArea(matrix)
    return matrix
end

--[=[
integerBit()

Extracts one zero-based bit from an integer and returns it as 0 or 1.
]=]
local function integerBit(value, index)
    return band(rshift(value, index), 1) ~= 0
end

-- Writes the error-correction-level-L format field into a dark-row candidate.
--[=[
drawFormatBits()

Computes the error-correction/mask format word, applies the QR BCH remainder and
fixed XOR mask, then writes both required copies into the candidate rows.
]=]
local function drawFormatBits(rows, size, mask)
    local formatData = 8 + mask
    local remainder = formatData
    for _ = 1, 10 do
        remainder = bxor(lshift(remainder, 1), (rshift(remainder, 9) ~= 0) and 0x537 or 0)
    end
    local bits = bxor(bor(lshift(formatData, 10), remainder), 0x5412)

    for i = 0, 5 do setRowBit(rows, 8, i, integerBit(bits, i)) end
    setRowBit(rows, 8, 7, integerBit(bits, 6))
    setRowBit(rows, 8, 8, integerBit(bits, 7))
    setRowBit(rows, 7, 8, integerBit(bits, 8))
    for i = 9, 14 do setRowBit(rows, 14 - i, 8, integerBit(bits, i)) end

    for i = 0, 7 do setRowBit(rows, size - 1 - i, 8, integerBit(bits, i)) end
    for i = 8, 14 do setRowBit(rows, 8, size - 15 + i, integerBit(bits, i)) end
    setRowBit(rows, 8, size - 8, true)
end

-- Evaluates one of the eight QR mask formulae for zero-based coordinates.
--[=[
maskCondition()

Evaluates one of the eight QR data-mask formulas for a zero-based matrix cell.
]=]
local function maskCondition(mask, x, y)
    if mask == 0 then return (x + y) % 2 == 0 end
    if mask == 1 then return y % 2 == 0 end
    if mask == 2 then return x % 3 == 0 end
    if mask == 3 then return (x + y) % 3 == 0 end
    if mask == 4 then return (math.floor(y / 2) + math.floor(x / 3)) % 2 == 0 end
    if mask == 5 then return (x * y) % 2 + (x * y) % 3 == 0 end
    if mask == 6 then return ((x * y) % 2 + (x * y) % 3) % 2 == 0 end
    return ((x * y) % 3 + (x + y) % 2) % 2 == 0
end

-- Places codeword bits into a reusable packed-row candidate.
--[=[
placeData()

Places interleaved data and error-correction bits in the standard two-column
zigzag. Reserved function cells are skipped and the selected mask is applied as
modules are written.
]=]
local function placeData(rows, reservedRows, size, codewords, remainderBits, mask)
    local bitIndex = 0
    local right = size - 1

    while right >= 1 do
        if right == 6 then right = 5 end
        for vertical = 0, size - 1 do
            local upward = band(right + 1, 2) == 0
            local y = upward and (size - 1 - vertical) or vertical
            for offset = 0, 1 do
                local x = right - offset
                if not rowBit(reservedRows, x, y) then
                    local dark = false
                    if bitIndex < #codewords * 8 then
                        local codeword = codewords[math.floor(bitIndex / 8) + 1]
                        dark = integerBit(codeword, 7 - (bitIndex % 8))
                    end
                    if maskCondition(mask, x, y) then dark = not dark end
                    setRowBit(rows, x, y, dark)
                    bitIndex = bitIndex + 1
                end
            end
        end
        right = right - 2
    end

    assert(bitIndex == #codewords * 8 + remainderBits, "Unexpected QR data-module count")
end

-- Scores packed rows using the four QR mask-penalty rules.
--[=[
calculatePenalty()

Scores a completed QR candidate using the four ISO mask-selection rules: long
runs, two-by-two blocks, finder-like patterns, and dark-module balance. Lower
scores are more scanner-friendly.
]=]
local function calculatePenalty(rows, size)
    local penalty = 0

    for y = 0, size - 1 do
        local runColor = rowBit(rows, 0, y)
        local runLength = 1
        for x = 1, size - 1 do
            local color = rowBit(rows, x, y)
            if color == runColor then
                runLength = runLength + 1
            else
                if runLength >= 5 then penalty = penalty + runLength - 2 end
                runColor = color
                runLength = 1
            end
        end
        if runLength >= 5 then penalty = penalty + runLength - 2 end
    end

    for x = 0, size - 1 do
        local runColor = rowBit(rows, x, 0)
        local runLength = 1
        for y = 1, size - 1 do
            local color = rowBit(rows, x, y)
            if color == runColor then
                runLength = runLength + 1
            else
                if runLength >= 5 then penalty = penalty + runLength - 2 end
                runColor = color
                runLength = 1
            end
        end
        if runLength >= 5 then penalty = penalty + runLength - 2 end
    end

    for y = 0, size - 2 do
        for x = 0, size - 2 do
            local color = rowBit(rows, x, y)
            if rowBit(rows, x + 1, y) == color and
               rowBit(rows, x, y + 1) == color and
               rowBit(rows, x + 1, y + 1) == color then
                penalty = penalty + 3
            end
        end
    end

    for y = 0, size - 1 do
        for start = 0, size - 11 do
            local sequence = 0
            for offset = 0, 10 do
                sequence = lshift(sequence, 1) + (rowBit(rows, start + offset, y) and 1 or 0)
            end
            if sequence == 0x5D0 or sequence == 0x05D then penalty = penalty + 40 end
        end
    end

    for x = 0, size - 1 do
        for start = 0, size - 11 do
            local sequence = 0
            for offset = 0, 10 do
                sequence = lshift(sequence, 1) + (rowBit(rows, x, start + offset) and 1 or 0)
            end
            if sequence == 0x5D0 or sequence == 0x05D then penalty = penalty + 40 end
        end
    end

    local darkCount = 0
    for y = 1, size do
        local row = rows[y]
        for x = 0, size - 1 do
            if band(row, lshift(1, x)) ~= 0 then darkCount = darkCount + 1 end
        end
    end
    penalty = penalty + math.floor(math.abs(darkCount * 20 - size * size * 10) / (size * size)) * 10
    return penalty
end

-- Converts packed modules into horizontal rectangles measured in QR modules.
--[=[
buildHorizontalRuns()

Converts dark modules into horizontal filled-rectangle runs. Each run records
its starting module coordinate and length.
]=]
local function buildHorizontalRuns(rows, size)
    local runs = {}
    for y = 0, size - 1 do
        local x = 0
        while x < size do
            if rowBit(rows, x, y) then
                local startX = x
                repeat x = x + 1 until x >= size or not rowBit(rows, x, y)
                runs[#runs + 1] = {x = startX, y = y, width = x - startX, height = 1}
            else
                x = x + 1
            end
        end
    end
    return runs
end

-- Converts packed modules into vertical rectangles measured in QR modules.
--[=[
buildVerticalRuns()

Converts dark modules into vertical filled-rectangle runs. The renderer can use
these when they require fewer LCD calls than horizontal runs.
]=]
local function buildVerticalRuns(rows, size)
    local runs = {}
    for x = 0, size - 1 do
        local y = 0
        while y < size do
            if rowBit(rows, x, y) then
                local startY = y
                repeat y = y + 1 until y >= size or not rowBit(rows, x, y)
                runs[#runs + 1] = {x = x, y = startY, width = 1, height = y - startY}
            else
                y = y + 1
            end
        end
    end
    return runs
end

-- Selects the rectangle orientation requiring the fewest LCD drawing calls.
--[=[
buildRenderRuns()

Builds horizontal and vertical run lists and returns the orientation with fewer
rectangles, reducing repeated LCD draw calls.
]=]
local function buildRenderRuns(rows, size)
    local horizontal = buildHorizontalRuns(rows, size)
    local vertical = buildVerticalRuns(rows, size)
    if #vertical < #horizontal then return vertical, "vertical" end
    return horizontal, "horizontal"
end

-- Verifies that render rectangles reproduce the packed matrix without overlap
-- or out-of-bounds modules.
--[=[
validateRenderRuns()

Reconstructs the QR module matrix from cached rectangle runs and verifies that
it matches the packed source rows. This catches renderer-cache corruption in test
or diagnostic builds.
]=]
local function validateRenderRuns(qr)
    local rebuilt = {}
    for y = 1, qr.size do rebuilt[y] = 0 end

    for i = 1, #qr.runs do
        local run = qr.runs[i]
        if run.width < 1 or run.height < 1 or run.x < 0 or run.y < 0 or
           run.x + run.width > qr.size or run.y + run.height > qr.size then
            return false, "Render run is outside the QR matrix"
        end

        for y = run.y, run.y + run.height - 1 do
            for x = run.x, run.x + run.width - 1 do
                if rowBit(rebuilt, x, y) then return false, "Render runs overlap" end
                setRowBit(rebuilt, x, y, true)
            end
        end
    end

    for y = 1, qr.size do
        if rebuilt[y] ~= qr.rows[y] then return false, "Render runs do not match packed rows" end
    end
    return true
end

-- Checks structural invariants that can be evaluated without decoding the QR
-- payload. The validation runs only after a complete candidate is selected.
--[=[
validateCompletedQr()

Performs structural checks on a completed QR: dimensions, row ranges, finder
patterns, timing pattern, alignment pattern, fixed dark module, and render runs.
The function returns true or a descriptive failure string.
]=]
local function validateCompletedQr(qr)
    if type(qr) ~= "table" or qr.size ~= QR_PARAMETERS.size then
        return false, "Unexpected QR matrix size"
    end
    if type(qr.rows) ~= "table" or #qr.rows ~= qr.size then
        return false, "Packed row count is invalid"
    end
    if type(qr.mask) ~= "number" or qr.mask < 0 or qr.mask > 7 then
        return false, "QR mask is invalid"
    end

    local allowedBits = lshift(1, qr.size) - 1
    for y = 1, qr.size do
        if type(qr.rows[y]) ~= "number" then return false, "Packed row is not numeric" end
        if band(qr.rows[y], bnot(allowedBits)) ~= 0 then
            return false, "Packed row contains modules outside the matrix"
        end
    end

    local finderCenters = {{3, 3}, {qr.size - 4, 3}, {3, qr.size - 4}}
    for i = 1, #finderCenters do
        local centerX = finderCenters[i][1]
        local centerY = finderCenters[i][2]
        for dy = -3, 3 do
            for dx = -3, 3 do
                local expected = math.max(math.abs(dx), math.abs(dy)) ~= 2
                if rowBit(qr.rows, centerX + dx, centerY + dy) ~= expected then
                    return false, "Finder pattern integrity check failed"
                end
            end
        end
    end

    for dy = -2, 2 do
        for dx = -2, 2 do
            local expected = math.max(math.abs(dx), math.abs(dy)) ~= 1
            if rowBit(qr.rows, QR_PARAMETERS.alignment + dx, QR_PARAMETERS.alignment + dy) ~= expected then
                return false, "Alignment pattern integrity check failed"
            end
        end
    end

    return validateRenderRuns(qr)
end

-- Creates a cooperative QR generation job. Each call to stepQrJob performs
-- one bounded stage so EdgeTX can continue servicing the user interface.
--[=[
createQrJob()

Allocates the state machine for generating one QR payload. The job stores immutable
position text, Reed-Solomon state, mask candidates, best score, and the sequence
number used to coalesce later position updates.
]=]
local function createQrJob(payload, latitudeE6, longitudeE6, latitudeText, longitudeText, sequence)
    local parameters, errorMessage = selectQrParameters(#payload)
    if not parameters then return nil, errorMessage end

    profileBegin()
    return {
        stage = "ENCODE",
        payload = payload,
        parameters = parameters,
        latitudeE6 = latitudeE6,
        longitudeE6 = longitudeE6,
        latitudeText = latitudeText,
        longitudeText = longitudeText,
        sequence = sequence,
        dataCodewords = nil,
        divisor = nil,
        remainder = nil,
        rsIndex = 1,
        codewords = nil,
        base = nil,
        candidateRows = nil,
        bestRows = nil,
        bestPenalty = math.huge,
        bestMask = 0,
        mask = 0,
        result = nil,
    }
end

-- Advances Reed-Solomon division by one data codeword.
--[=[
processErrorCorrectionCodeword()

Processes one data codeword through the Reed-Solomon shift register. Splitting
this work into individual codewords lets background() enforce a bounded callback
cost.
]=]
local function processErrorCorrectionCodeword(job)
    local factor = bxor(job.dataCodewords[job.rsIndex], job.remainder[1])
    local degree = job.parameters.ecCodewords
    for i = 1, degree - 1 do job.remainder[i] = job.remainder[i + 1] end
    job.remainder[degree] = 0
    for i = 1, degree do
        job.remainder[i] = bxor(job.remainder[i], gfMultiply(job.divisor[i], factor))
    end
    job.rsIndex = job.rsIndex + 1
end

-- Advances a QR job by one bounded unit and returns true when a complete matrix
-- is available in job.result.
--[=[
stepQrJob()

Advances one QR job through encoding, Reed-Solomon calculation, base-matrix
construction, eight masked candidates, penalty scoring, and final run creation.

Returns:
  true when the job has reached a terminal ready or error state; false when more
  background steps are required.
]=]
local function stepQrJob(job)
    if job.stage == "ENCODE" then
        profileStageStart("encode")
        job.dataCodewords = encodeDataCodewords(job.payload, job.parameters)
        profileStageEnd()
        job.payload = nil
        job.stage = "RS_INIT"
        return false
    end

    if job.stage == "RS_INIT" then
        profileStageStart("rs_init")
        job.divisor = createGeneratorPolynomial(job.parameters.ecCodewords)
        job.remainder = {}
        for i = 1, job.parameters.ecCodewords do job.remainder[i] = 0 end
        profileStageEnd()
        job.stage = "RS"
        return false
    end

    if job.stage == "RS" then
        profileStageStart("rs")
        local stopIndex = math.min(
            #job.dataCodewords,
            job.rsIndex + rsCodewordsPerStep - 1
        )
        while job.rsIndex <= stopIndex do processErrorCorrectionCodeword(job) end
        profileStageEnd()

        if job.rsIndex > #job.dataCodewords then
            job.codewords = {}
            for i = 1, #job.dataCodewords do
                job.codewords[#job.codewords + 1] = job.dataCodewords[i]
            end
            for i = 1, #job.remainder do
                job.codewords[#job.codewords + 1] = job.remainder[i]
            end
            job.dataCodewords = nil
            job.divisor = nil
            job.remainder = nil
            job.stage = "BASE"
        end
        return false
    end

    if job.stage == "BASE" then
        profileStageStart("base")
        job.base = createBaseMatrix(job.parameters)
        job.candidateRows = {}
        job.bestRows = {}
        profileStageEnd()
        job.stage = "MASK"
        return false
    end

    if job.stage == "MASK" then
        profileStageStart("mask")
        for y = 1, job.parameters.size do
            job.candidateRows[y] = job.base.dark[y]
        end
        drawFormatBits(job.candidateRows, job.parameters.size, job.mask)
        placeData(
            job.candidateRows,
            job.base.reserved,
            job.parameters.size,
            job.codewords,
            job.parameters.remainderBits,
            job.mask
        )
        local penalty = calculatePenalty(job.candidateRows, job.parameters.size)
        if penalty < job.bestPenalty then
            job.bestPenalty = penalty
            job.bestMask = job.mask
            for y = 1, job.parameters.size do
                job.bestRows[y] = job.candidateRows[y]
            end
        end
        job.mask = job.mask + 1
        profileStageEnd()
        if job.mask > 7 then job.stage = "FINALIZE" end
        return false
    end

    if job.stage == "FINALIZE" then
        profileStageStart("finalize")
        local runs, runOrientation = buildRenderRuns(job.bestRows, job.parameters.size)
        local result = {
            version = job.parameters.version,
            size = job.parameters.size,
            rows = job.bestRows,
            runs = runs,
            runOrientation = runOrientation,
            drawCalls = #runs,
            mask = job.bestMask,
            penalty = job.bestPenalty,
        }
        if VALIDATE_COMPLETED_QR then
            local valid, validationError = validateCompletedQr(result)
            if valid then
                job.result = result
            else
                job.error = validationError
                job.result = nil
            end
        else
            job.result = result
        end
        job.base = nil
        job.candidateRows = nil
        job.codewords = nil
        profileStageEnd()
        profileFinish(job.parameters.version, job.bestMask, job.bestPenalty)
        job.stage = "DONE"
        return true
    end

    return job.stage == "DONE"
end


local GPS_RETRY_TICKS = 5 * 100
local displayMidpoint = LCD_W / 2
local gpsSourceId = nil
local gpsSensorIndex = nil
local gpsSensorName = nil
local gpsDiscoveryMethod = nil
local gpsConfigured = false
local gpsCandidateCount = 0
local nextGpsDiscovery = 0

local hasFix = false
local latestLatitudeE6 = 0
local latestLongitudeE6 = 0
local latestLatitudeText = "0.000000"
local latestLongitudeText = "0.000000"
local lastFixTime = 0

local activeQr = nil
local activeLatitudeE6 = 0
local activeLongitudeE6 = 0
local activeLatitudeText = "0.000000"
local activeLongitudeText = "0.000000"
local lastQrTime = 0

local requestPending = false
local requestedLatitudeE6 = 0
local requestedLongitudeE6 = 0
local requestedLatitudeText = "0.000000"
local requestedLongitudeText = "0.000000"
local requestSequence = 0
local qrJob = nil
local lastRunTime = 0
local lastQrError = nil

local radioId = "unknown"
local displayKind = "onebit"
local displayInverted = false
local layout = nil

-- Known panel-polarity hints are used only when automatic polarity is selected.
-- The override constant at the top of the file remains available for unusual
-- firmware builds or replacement display panels.
local INVERTED_RADIOS = {
    t14 = true,
}

-- Radios based on older STM32F2 targets receive smaller cooperative work units
-- to keep QR generation responsive while mixer and telemetry tasks continue.
local CONSERVATIVE_RADIOS = {
    x9d = true,
    x9dp = true,
    x9dp2019 = true,
    x9e = true,
}

local RADIO_ALIASES = {
    ["x9d+"] = "x9dp",
    ["x9d+2019"] = "x9dp2019",
    x9dplus = "x9dp",
    x9dplus2019 = "x9dp2019",
    ["jumper-t14"] = "t14",
}

--[=[
normalizeRadioId()

Normalizes the radio identifier returned by getVersion(): lowercase text is used
and the simulator suffix is removed so profile rules apply equally to hardware
and EdgeTX Simulator.
]=]
local function normalizeRadioId(value)
    if type(value) ~= "string" then return "unknown" end
    local normalized = string.lower(value)
    normalized = string.gsub(normalized, "%-simu$", "")
    return RADIO_ALIASES[normalized] or normalized
end

-- Runtime radio information selects only safe performance and polarity hints;
-- actual screen dimensions always come from LCD_W and LCD_H.
--[=[
detectRuntimeProfile()

Detects display dimensions, one-bit versus grayscale capability, radio ID,
polarity policy, and an initial cooperative-work budget. Known slower radio
families start with smaller Reed-Solomon and garbage-collection steps.
]=]
local function detectRuntimeProfile()
    if type(getVersion) == "function" then
        local ok, _, reportedRadio = pcall(getVersion)
        if ok then radioId = normalizeRadioId(reportedRadio) end
    end

    displayKind = type(rawget(_G, "GREY")) == "function" and "grayscale" or "onebit"

    if CONSERVATIVE_RADIOS[radioId] or LCD_W >= 200 then
        rsCodewordsPerStep = 2
        gcStepSize = 4
    else
        rsCodewordsPerStep = 4
        gcStepSize = 8
    end

    if POLARITY_OVERRIDE == "inverted" then
        displayInverted = true
    elseif POLARITY_OVERRIDE == "normal" then
        displayInverted = false
    else
        displayInverted = INVERTED_RADIOS[radioId] == true
    end
end

-- Rounds a numeric degree value to the nearest integer microdegree.
--[=[
toMicrodegrees()

Rounds a degree value to signed integer microdegrees for deterministic change
detection and formatting.
]=]
local function toMicrodegrees(value)
    local scaled = value * 1000000
    if scaled >= 0 then return math.floor(scaled + 0.5) end
    return math.ceil(scaled - 0.5)
end

-- Formats an integer microdegree coordinate with exactly six decimal places.
--[=[
formatMicrodegrees()

Formats signed integer microdegrees with exactly six fractional digits and no
negative-zero representation.
]=]
local function formatMicrodegrees(value)
    local sign = ""
    if value < 0 then
        sign = "-"
        value = -value
    end
    local degrees = math.floor(value / 1000000)
    local fraction = value % 1000000
    return sign .. tostring(degrees) .. "." .. string.format("%06d", fraction)
end

--[=[
isValidGpsSample()

Returns true only for a table containing finite, in-range numeric latitude and
longitude fields.
]=]
local function isValidGpsSample(sample)
    if type(sample) ~= "table" then return false end
    if type(sample.lat) ~= "number" or type(sample.lon) ~= "number" then return false end
    if sample.lat ~= sample.lat or sample.lon ~= sample.lon then return false end
    if sample.lat == math.huge or sample.lat == -math.huge then return false end
    if sample.lon == math.huge or sample.lon == -math.huge then return false end
    return sample.lat >= -90 and sample.lat <= 90 and sample.lon >= -180 and sample.lon <= 180
end

--[=[
captureGpsSample()

Accepts a valid telemetry sample, updates the last-fix timestamp, and stores new
microdegree coordinates. A changed position increments the request sequence so
intermediate QR requests can be coalesced.
]=]
local function captureGpsSample(sample, now)
    local latitudeE6 = toMicrodegrees(sample.lat)
    local longitudeE6 = toMicrodegrees(sample.lon)

    if not hasFix or latitudeE6 ~= latestLatitudeE6 then
        latestLatitudeE6 = latitudeE6
        latestLatitudeText = formatMicrodegrees(latitudeE6)
    end
    if not hasFix or longitudeE6 ~= latestLongitudeE6 then
        latestLongitudeE6 = longitudeE6
        latestLongitudeText = formatMicrodegrees(longitudeE6)
    end

    hasFix = true
    lastFixTime = now
end

-- Each configured telemetry sensor owns three consecutive source slots:
-- current value, minimum value, and maximum value. The current-value slot is
-- selected directly so duplicate or renamed sensor labels remain unambiguous.
--[=[
resolveGpsSourceId()

Maps a configured sensor index or label to the current-value telemetry source ID.
Direct source-slot arithmetic is preferred; field and display-name lookups provide
compatibility fallbacks.
]=]
local function resolveGpsSourceId(sensorIndex, sensorLabel)
    local firstTelemetrySource = rawget(_G, "MIXSRC_FIRST_TELEM")
    if type(firstTelemetrySource) == "number" and type(sensorIndex) == "number" then
        return firstTelemetrySource + sensorIndex * 3, "sensor-unit"
    end

    if type(getFieldInfo) == "function"
            and type(sensorLabel) == "string"
            and sensorLabel ~= "" then
        local ok, field = pcall(getFieldInfo, sensorLabel)
        if ok and type(field) == "table" and type(field.id) == "number" then
            return field.id, "sensor-name"
        end
    end

    if type(getSourceIndex) == "function"
            and type(sensorLabel) == "string"
            and sensorLabel ~= "" then
        local ok, source = pcall(getSourceIndex, sensorLabel)
        if ok and type(source) == "number" then
            return source, "display-name"
        end
    end

    return nil, nil
end

--[=[
appendGpsCandidate()

Adds a configured GPS candidate unless another record already represents the
same sensor index or source identifier.
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

-- Configured sensors are identified by UNIT_GPS rather than by their editable
-- label. Exact-name lookup remains a fallback for older EdgeTX builds.
--[=[
configuredGpsCandidates()

Enumerates model telemetry sensors with UNIT_GPS and builds candidate records.
An exact-name GPS fallback supports firmware environments without model.getSensor
or UNIT_GPS.
]=]
local function configuredGpsCandidates()
    local candidates = {}
    local gpsUnit = rawget(_G, "UNIT_GPS")
    local modelApi = rawget(_G, "model")

    if type(gpsUnit) == "number"
            and type(modelApi) == "table"
            and type(modelApi.getSensor) == "function" then
        local maxSensors = tonumber(rawget(_G, "MAX_SENSORS"))
        if not maxSensors then
            maxSensors = LCD_W >= 200 and 60 or 40
        end
        maxSensors = math.max(1, math.min(100, math.floor(maxSensors)))

        for sensorIndex = 0, maxSensors - 1 do
            local ok, sensor = pcall(modelApi.getSensor, sensorIndex)
            if ok and type(sensor) == "table" and tonumber(sensor.unit) == gpsUnit then
                local sensorLabel = sensor.name
                if type(sensorLabel) ~= "string" or sensorLabel == "" then
                    sensorLabel = "GPS " .. tostring(sensorIndex + 1)
                end
                local sourceId, method = resolveGpsSourceId(sensorIndex, sensorLabel)
                appendGpsCandidate(candidates, {
                    sensorIndex = sensorIndex,
                    sensorName = sensorLabel,
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

Reads one telemetry source and returns a valid GPS table, or nil when the source is
unavailable, stale, malformed, or out of range.
]=]
local function readGpsSource(sourceId)
    if type(sourceId) ~= "number" or type(getValue) ~= "function" then return nil end
    local ok, value = pcall(getValue, sourceId)
    if ok and isValidGpsSample(value) then return value end
    return nil
end

-- A currently live GPS source is preferred. During a telemetry interruption,
-- the existing selection is retained so the last valid fix remains available.
--[=[
selectGpsCandidate()

Chooses a live configured GPS candidate when possible, otherwise retains the
current selection or first resolvable candidate. The selected metadata is stored
in global telemetry state for status display and diagnostics.
]=]
local function selectGpsCandidate(candidates)
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

    if selected == nil and gpsSourceId ~= nil then
        for index = 1, #candidates do
            if candidates[index].sourceId == gpsSourceId then
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

    if selected == nil then selected = candidates[1] end

    gpsCandidateCount = #candidates
    gpsConfigured = selected ~= nil
    if selected then
        gpsSourceId = selected.sourceId
        gpsSensorIndex = selected.sensorIndex
        gpsSensorName = selected.sensorName
        gpsDiscoveryMethod = selected.method
    else
        gpsSourceId = nil
        gpsSensorIndex = nil
        gpsSensorName = nil
        gpsDiscoveryMethod = nil
    end

    return selectedValue
end

--[=[
discoverGps()

Runs unit-based GPS discovery immediately when forced or after the retry deadline.
]=]
local function discoverGps(now, force)
    if not force and now < nextGpsDiscovery then return nil end
    nextGpsDiscovery = now + GPS_RETRY_TICKS
    return selectGpsCandidate(configuredGpsCandidates())
end

--[=[
pollGps()

Samples the selected source, triggers rediscovery when needed, and passes a valid
sample to captureGpsSample().
]=]
local function pollGps(now)
    local sample = gpsSourceId and readGpsSource(gpsSourceId) or nil
    if sample == nil and now >= nextGpsDiscovery then
        sample = discoverGps(now, true)
        if sample == nil and gpsSourceId ~= nil then
            sample = readGpsSource(gpsSourceId)
        end
    end
    if sample then captureGpsSample(sample, now) end
end

--[=[
sensorLabel()

Returns the selected configured GPS label, falling back to the generic GPS text.
]=]
local function sensorLabel()
    if type(gpsSensorName) == "string" and gpsSensorName ~= "" then
        return gpsSensorName
    end
    return "GPS"
end

--[=[
compactText()

Truncates a status string to a display-safe maximum, preserving the beginning of
the message and adding a final period when truncation occurs.
]=]
local function compactText(text, maximumCharacters)
    text = tostring(text or "")
    if #text <= maximumCharacters then return text end
    if maximumCharacters <= 1 then return string.sub(text, 1, maximumCharacters) end
    return string.sub(text, 1, maximumCharacters - 1) .. "~"
end

-- Stores only the newest request snapshot. A request remains pending while an
-- earlier QR job finishes, so intermediate GPS positions are naturally merged.
--[=[
requestQrForLatestFix()

Copies the newest accepted position into the pending-generation slot. Repeated
requests replace older pending work so only the latest location must eventually be
encoded.
]=]
local function requestQrForLatestFix()
    requestedLatitudeE6 = latestLatitudeE6
    requestedLongitudeE6 = latestLongitudeE6
    requestedLatitudeText = latestLatitudeText
    requestedLongitudeText = latestLongitudeText
    requestSequence = requestSequence + 1
    requestPending = true
end

--[=[
startPendingJob()

Starts a QR job from the pending fix when no job is already active. The pending
slot is cleared only after its values have been copied into the new job.
]=]
local function startPendingJob()
    if not requestPending or qrJob then return end
    requestPending = false
    local payload = "geo:" .. requestedLatitudeText .. "," .. requestedLongitudeText
    qrJob = createQrJob(
        payload,
        requestedLatitudeE6,
        requestedLongitudeE6,
        requestedLatitudeText,
        requestedLongitudeText,
        requestSequence
    )
end

--[=[
finishJob()

Commits a ready QR atomically as the active display buffer, or records the job's
error. If a newer fix arrived during generation, another pending request remains
available for the next job.
]=]
local function finishJob(job)
    if not job.result then
        lastQrError = job.error or "QR generation failed"
        return
    end
    lastQrError = nil
    activeQr = job.result
    activeLatitudeE6 = job.latitudeE6
    activeLongitudeE6 = job.longitudeE6
    activeLatitudeText = job.latitudeText
    activeLongitudeText = job.longitudeText
    lastQrTime = getTime()
end

--[=[
eventMatches()

Compares an event value against a list of EdgeTX global event-constant names while
tolerating firmware variants where some constants are absent.
]=]
local function eventMatches(event, names)
    if not event or event == 0 then return false end
    for index = 1, #names do
        local value = rawget(_G, names[index])
        if value ~= nil and event == value then return true end
    end
    return false
end

-- Enter requests a fresh QR code on radios that expose either virtual or
-- hardware-specific key event constants.
--[=[
isManualRefreshEvent()

Recognizes Enter-key events that should request an immediate QR rebuild.
]=]
local function isManualRefreshEvent(event)
    return eventMatches(event, {
        "EVT_VIRTUAL_ENTER",
        "EVT_ENTER_BREAK",
        "EVT_ENTER_FIRST",
    })
end

--[=[
activePositionMovedEnough()

Compares the newest fix with the active QR coordinates using integer
microdegrees and the configured movement threshold.
]=]
local function activePositionMovedEnough()
    if not activeQr then return true end
    return math.abs(latestLatitudeE6 - activeLatitudeE6) >= MINIMUM_MOVEMENT_E6 or
        math.abs(latestLongitudeE6 - activeLongitudeE6) >= MINIMUM_MOVEMENT_E6
end

-- The largest integer module scale that leaves a usable coordinate panel is
-- selected from the actual LCD dimensions. Narrow displays fall back to a QR
-- centered above a compact status line.
--[=[
calculateLayout()

Computes integer module scale, QR origin, quiet-zone size, information-panel
placement, and compact-display fallbacks from LCD_W and LCD_H. The QR always uses
square integer modules for scanner reliability.
]=]
local function calculateLayout()
    local outerModules = QR_PARAMETERS.size + QUIET_ZONE_MODULES * 2
    local textMinimumWidth = 58
    local maximumScale = math.max(1, math.floor(LCD_H / outerModules))
    maximumScale = math.min(maximumScale, math.max(1, math.floor(LCD_W / outerModules)))
    maximumScale = math.min(maximumScale, 6)

    local sideScale = math.min(maximumScale, math.floor((LCD_W - textMinimumWidth) / outerModules))
    if sideScale >= 1 then
        local qrPixelSize = outerModules * sideScale
        local boxY = math.max(0, math.floor((LCD_H - qrPixelSize) / 2))
        return {
            scale = sideScale,
            qrBoxX = 0,
            qrBoxY = boxY,
            qrOriginX = QUIET_ZONE_MODULES * sideScale,
            qrOriginY = boxY + QUIET_ZONE_MODULES * sideScale,
            qrPixelSize = qrPixelSize,
            sidePanel = true,
            textX = qrPixelSize + 2,
            textY = 1,
            textWidth = LCD_W - qrPixelSize - 2,
        }
    end

    local reservedStatusHeight = LCD_H >= 48 and 14 or 0
    local scale = math.max(1, math.min(
        math.floor(LCD_W / outerModules),
        math.floor((LCD_H - reservedStatusHeight) / outerModules)
    ))
    local qrPixelSize = outerModules * scale
    local boxX = math.max(0, math.floor((LCD_W - qrPixelSize) / 2))
    return {
        scale = scale,
        qrBoxX = boxX,
        qrBoxY = 0,
        qrOriginX = boxX + QUIET_ZONE_MODULES * scale,
        qrOriginY = QUIET_ZONE_MODULES * scale,
        qrPixelSize = qrPixelSize,
        sidePanel = false,
        textX = 1,
        textY = math.min(LCD_H - 10, qrPixelSize + 1),
        textWidth = LCD_W - 2,
    }
end

--[=[
centeredTextX()

Returns an approximate horizontal origin for centering compact text on EdgeTX
monochrome fonts.
]=]
local function centeredTextX(text)
    local approximateWidth = #tostring(text) * 5
    return math.max(0, math.floor((LCD_W - approximateWidth) / 2))
end

--[=[
drawCenteredMessage()

Clears the display and draws one or two centered status lines.
]=]
local function drawCenteredMessage(line1, line2)
    local y = math.floor(LCD_H / 2) - (line2 and 8 or 4)
    lcd.drawText(centeredTextX(line1), y, line1)
    if line2 then lcd.drawText(centeredTextX(line2), y + 10, line2) end
end

--[=[
initFunction()

EdgeTX telemetry-script initialization callback. It detects runtime capabilities,
calculates layout, and performs an immediate GPS discovery pass.
]=]
local function initFunction()
    detectRuntimeProfile()
    layout = calculateLayout()
    discoverGps(getTime(), true)
end

-- Telemetry polling and QR generation are bounded so the script remains
-- cooperative with EdgeTX mixer, RF, and user-interface tasks.
--[=[
backgroundFunction()

EdgeTX background callback. It polls GPS, applies optional movement-based refresh
policy, advances the cooperative QR job, commits completed work, and performs a
small incremental garbage-collection step.
]=]
local function backgroundFunction()
    local now = getTime()
    pollGps(now)

    startPendingJob()
    if qrJob then
        if stepQrJob(qrJob) then
            finishJob(qrJob)
            qrJob = nil
        end
        collectgarbage("step", gcStepSize)
    end
end

--[=[
drawQrAndStatus()

Renders the active QR from cached rectangle runs and draws the sensor label,
coordinates, fix age, and generation status in the remaining display area.
]=]
local function drawQrAndStatus(now)
    if displayInverted then
        lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, INVERS)
    end

    if activeQr then
        for index = 1, #activeQr.runs do
            local run = activeQr.runs[index]
            lcd.drawFilledRectangle(
                layout.qrOriginX + run.x * layout.scale,
                layout.qrOriginY + run.y * layout.scale,
                run.width * layout.scale,
                run.height * layout.scale
            )
        end
    else
        local message = lastQrError and "QR error" or (qrJob and "QR building" or "QR queued")
        lcd.drawText(layout.qrBoxX + 2, layout.qrBoxY + 18, message)
    end

    if displayInverted and layout.sidePanel then
        lcd.drawFilledRectangle(layout.textX - 1, 0, LCD_W - layout.textX + 1, LCD_H, 0)
    end

    local latitude = activeQr and activeLatitudeText or latestLatitudeText
    local longitude = activeQr and activeLongitudeText or latestLongitudeText

    if layout.sidePanel then
        local sensorChars = math.max(5, math.floor(layout.textWidth / 5))
        lcd.drawText(layout.textX, layout.textY, compactText(sensorLabel(), sensorChars))
        lcd.drawText(layout.textX, layout.textY + 10, latitude)
        lcd.drawText(layout.textX, layout.textY + 20, longitude)
        lcd.drawText(layout.textX, layout.textY + 30,
            string.format("Fix %.0fs", (now - lastFixTime) / 100))

        local status
        if lastQrError then
            status = "QR error"
        elseif qrJob then
            status = "QR building"
        elseif activeQr then
            status = string.format("QR %.0fs", (now - lastQrTime) / 100)
        else
            status = "QR queued"
        end
        lcd.drawText(layout.textX, layout.textY + 40, status)

        if LCD_H >= 60 then
            lcd.drawText(layout.textX, layout.textY + 50,
                displayKind == "grayscale" and "GS" or radioId)
        end
    else
        local status = lastQrError and "QR error" or
            (qrJob and "Building" or string.format("Fix %.0fs", (now - lastFixTime) / 100))
        lcd.drawText(layout.textX, layout.textY, status)
    end
end

-- The last complete QR remains visible while a replacement is generated.
-- Work is scheduled on screen entry, explicit Enter, or an enabled movement
-- refresh policy.
--[=[
runFunction()

EdgeTX telemetry-screen foreground callback. It handles screen-open detection,
manual refresh, missing-sensor and waiting-fix states, display polarity, and the
active QR/status frame.
]=]
local function runFunction(event)
    lcd.clear()

    if not gpsConfigured then
        drawCenteredMessage("No GPS sensor", "Discover telemetry")
        return 0
    end

    if gpsSourceId == nil then
        drawCenteredMessage(compactText(sensorLabel(), 20), "Source unavailable")
        return 0
    end

    if not hasFix then
        drawCenteredMessage("Waiting for", compactText(sensorLabel(), 20))
        return 0
    end

    local now = getTime()
    local screenOpened = lastRunTime == 0 or now - lastRunTime > SCREEN_REOPEN_GAP_TICKS
    lastRunTime = now

    if isManualRefreshEvent(event) then
        requestQrForLatestFix()
    elseif screenOpened and
           (not activeQr or activeLatitudeE6 ~= latestLatitudeE6 or activeLongitudeE6 ~= latestLongitudeE6) then
        requestQrForLatestFix()
    elseif AUTO_REFRESH and activeQr and not qrJob and not requestPending and
           activePositionMovedEnough() and now - lastQrTime >= AUTO_REFRESH_INTERVAL_TICKS then
        requestQrForLatestFix()
    elseif not activeQr and not qrJob and not requestPending then
        requestQrForLatestFix()
    end

    drawQrAndStatus(now)
    return 0
end

-- Generates a complete QR matrix synchronously for host-side verification.
-- Test helpers are exported only when the host explicitly enables test mode.
--[=[
generateForTest()

Generates a QR synchronously for host-side verification. This function is exposed
only when GPS_QR_TEST_MODE is enabled and is never part of ordinary radio use.
]=]
local function generateForTest(payload)
    local job, errorMessage = createQrJob(payload, 0, 0, "0.000000", "0.000000", 1)
    if not job then return nil, errorMessage end
    for _ = 1, 200 do
        if stepQrJob(job) then return job.result, job.error end
    end
    return nil, "QR test job exceeded its step limit"
end

local exports = {run = runFunction, init = initFunction, background = backgroundFunction}
if rawget(_G, "GPS_QR_TEST_MODE") then
    exports._test = {
        generate = generateForTest,
        isDark = function(qr, x, y) return rowBit(qr.rows, x, y) end,
        validate = validateCompletedQr,
        toMicrodegrees = toMicrodegrees,
        formatMicrodegrees = formatMicrodegrees,
        formatGeoUri = function(latitudeE6, longitudeE6)
            return "geo:" .. formatMicrodegrees(latitudeE6) .. "," .. formatMicrodegrees(longitudeE6)
        end,
        configuredGpsCandidates = configuredGpsCandidates,
        discoverGps = function()
            return selectGpsCandidate(configuredGpsCandidates())
        end,
        getGpsState = function()
            return {
                sourceId = gpsSourceId,
                sensorIndex = gpsSensorIndex,
                sensorName = gpsSensorName,
                method = gpsDiscoveryMethod,
                configured = gpsConfigured,
                candidates = gpsCandidateCount,
                radioId = radioId,
                displayKind = displayKind,
                inverted = displayInverted,
                layout = layout,
            }
        end,
    }
end
return exports
