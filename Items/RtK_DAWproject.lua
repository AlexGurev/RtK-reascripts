-- @description DAWproject for REAPER
-- @version 1.1
-- @author Reach the Knob
-- @about 
--   # DAWproject for REAPER
--
--   This script imports DAWproject files into the open REAPER project and exports REAPER projects in the DAWproject format.
--
--   ### Key Features
--   * **Two-way transfer:** Import DAWproject files into REAPER or export the current project.
--   * **Project structure:** Transfers tracks, folders, media items, markers, tempo and time signature changes, and supported automation.
--   * **Audio editing:** Preserves supported item splits, overlaps, fades, crossfades, playback rates, and stretch markers.
--   * **Plug-ins and routing:** Transfers supported plug-in data and track routing between compatible DAWs.
--   * **Troubleshooting:** Saves detailed operation logs in the relevant project folder.
--
--   The data available after import depends on how each DAW implements the DAWproject format.
--
-- @changelog
--   + Added automatic interface scaling based on DPI settings
--   + Improved automation export for Cubase

local proj = 0
local function msg(s) reaper.ShowMessageBox(s, "DAWproject for REAPER", 0) end
local projectStateSection = "DAWprojectForREAPER"
local _, projectIdentity = reaper.GetSetProjectInfo_String(proj, "PROJECT_GUID", "", false)
if not projectIdentity or projectIdentity == "" then
  projectIdentity = tostring(reaper.GetProjectPathEx(proj) or "") .. "|" .. tostring(reaper.GetProjectName(proj) or "")
end
projectIdentity = projectIdentity:gsub("[^%w]", "")
if projectIdentity == "" then projectIdentity = "unsaved" end
local function getProjectPathState(key)
  return reaper.GetExtState(projectStateSection, key .. "_" .. projectIdentity) or ""
end
local function setProjectPathState(key, value)
  reaper.SetExtState(projectStateSection, key .. "_" .. projectIdentity, tostring(value or ""), true)
end
local osId = reaper.GetOS()
local isWindows = osId:match("Win") ~= nil
local isMac = osId:match("OSX") ~= nil
local pathSep = isWindows and "\\" or "/"
local function nativePath(p)
  if isWindows then return (p:gsub("/", "\\")) end
  return (p:gsub("\\", "/"))
end
local function joinPath(a, b)
  a, b = nativePath(a), nativePath(b)
  return a:gsub("[\\/]$", "") .. pathSep .. b:gsub("^[\\/]", "")
end
local function parentPath(p)
  local parent = nativePath(p):match("^(.*)[\\/][^\\/]+$")
  if not parent then return "." end
  if parent == "" then return pathSep end
  if isWindows and parent:match("^%a:$") then return parent .. "\\" end
  return parent
end
local tempBase = isWindows and (os.getenv("TEMP") or os.getenv("TMP") or ((os.getenv("LOCALAPPDATA") or ".") .. "\\Temp"))
  or (os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp")
local logDir = nativePath(tempBase):gsub("[\\/]$", "")
local logPath
local loggingEnabled = reaper.GetExtState(projectStateSection, "logging_enabled") == "1"
local logWriteWarningShown = false
local function setLogLocation()
  local _, projectFile = reaper.EnumProjects(-1, "", 1024)
  local folder
  if projectFile and projectFile ~= "" then folder = parentPath(projectFile) end
  if not folder or folder == "" then
    local projectFolder = reaper.GetProjectPathEx(proj)
    if projectFolder and projectFolder ~= "" then folder = nativePath(projectFolder):gsub("[\\/]$", "") end
  end
  logPath = folder and joinPath(folder, "RtK_DAWproject.log") or nil
end
setLogLocation()
local function log(s)
  if not loggingEnabled then return end
  if not logPath then
    if not logWriteWarningShown then reaper.ShowConsoleMsg("DAWproject: save the project to a folder before enabling its log.\n"); logWriteWarningShown = true end
    return
  end
  local f = io.open(logPath, "ab")
  if f then
    f:write(os.date("[%Y-%m-%d %H:%M:%S] "), tostring(s), "\r\n")
    f:close()
  elseif not logWriteWarningShown then
    reaper.ShowConsoleMsg("DAWproject: could not write the log in the project folder.\n")
    logWriteWarningShown = true
  end
end
local function setLoggingEnabled(enabled)
  enabled = not not enabled
  if loggingEnabled and not enabled then log("Logging disabled") end
  loggingEnabled = enabled
  reaper.SetExtState(projectStateSection, "logging_enabled", enabled and "1" or "0", true)
  setLogLocation()
  if enabled then log("Logging enabled") end
end
local function checkExec(label, result)
  if result == nil then error(label .. ": ExecProcess could not start the command") end
  local firstLine, detail = result:match("^([^\r\n]*)\r?\n?(.*)$")
  local exitCode = tonumber(firstLine)
  log(label .. " exit code: " .. tostring(exitCode) .. "\n" .. tostring(detail))
  if exitCode and exitCode ~= 0 then
    error(label .. " failed (exit " .. tostring(exitCode) .. "):\n" .. tostring(detail))
  end
  if not exitCode then error(label .. " returned an unrecognized ExecProcess result:\n" .. result) end
  return detail
end
local function esc(s)
  s = tostring(s or "")
  return s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
end
local function fmt(n)
  if not n or n ~= n or n == math.huge or n == -math.huge then return "0" end
  local s = string.format("%.9f", n):gsub(",", ".")
  return s:gsub("0+$", ""):gsub("%.$", "")
end
local function xmlwrite(path, content)
  local f, e = io.open(path, "wb")
  if not f then error("Cannot write " .. path .. ": " .. tostring(e)) end
  local ok, writeErr = f:write(content)
  if not ok then f:close(); error("Cannot write " .. path .. ": " .. tostring(writeErr)) end
  local closed, closeErr = f:close()
  if not closed then error("Cannot finish writing " .. path .. ": " .. tostring(closeErr)) end
end
local function readname(t)
  local _, name = reaper.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
  return name ~= "" and name or "Track"
end
local idCounter = 0
local function newId()
  local n = idCounter
  idCounter = idCounter + 1
  return "id" .. n
end
local function nativeColor(t)
  local c = reaper.GetTrackColor(t)
  if not c or c == 0 then return nil end
  local r, g, b = reaper.ColorFromNative(c)
  return string.format("#%02x%02x%02x", r, g, b)
end
local function beatsAt(t)
  local b = reaper.TimeMap2_timeToQN(proj, t)
  return b or 0
end
local function exportEnvelopes(track, label, parameterIDs, fxParameters, warnings, timeUnit)
  local xml = {}
  local mappedFxEnvelopes = {}
  timeUnit = timeUnit or "beats"
  local function pointsFor(env, kind, targetID, targetName)
    local count = reaper.CountEnvelopePoints(env)
    if not count or count < 1 or not targetID then return false end
    local points = {}
    for i = 0, count - 1 do
      local ok, t, value, shape = reaper.GetEnvelopePoint(env, i)
      if ok then
        local pointTime = timeUnit == "seconds" and t or beatsAt(t)
        local v = value
        if kind == "volume" and reaper.ScaleFromEnvelopeMode then
          v = reaper.ScaleFromEnvelopeMode(reaper.GetEnvelopeScalingMode(env), value)
        end
        if kind == "pan" then v = (value + 1) / 2 end
        local tag = kind == "mute" and "BoolPoint" or "RealPoint"
        local val = kind == "mute" and tostring(value >= 0.5) or fmt(v)
        local interp = (shape == 1) and ' interpolation="hold"' or ' interpolation="linear"'
        points[#points + 1] = '<' .. tag .. ' time="' .. fmt(pointTime) .. '" value="' .. val .. '"' .. (tag == "RealPoint" and interp or '') .. '/>'
      end
    end
    if #points > 0 then
      local unit = kind == "volume" and ' unit="linear"' or ((kind == "pan" or kind == "fx") and ' unit="normalized"' or "")
      local pointName = targetName or ({volume = "Volume", pan = "Pan", mute = "Mute"})[kind]
      local name = pointName and (' name="' .. esc(pointName) .. '"') or ""
      xml[#xml + 1] = '<Points id="' .. newId() .. '"' .. unit .. name .. '><Target parameter="' .. targetID .. '"/>' .. table.concat(points) .. '</Points>'
      log("Export automation: " .. label .. " -> " .. kind .. " (" .. #points .. " points)")
      return true
    end
    return false
  end
  if fxParameters and reaper.GetFXEnvelope then
    for _, p in ipairs(fxParameters) do
      if p.track == track and p.fxIndex ~= nil and p.paramIndex ~= nil then
        local env = reaper.GetFXEnvelope(track, p.fxIndex, p.paramIndex, false)
        if env then
          mappedFxEnvelopes[env] = true
          local exported = pointsFor(env, "fx", p.id, p.paramName)
          if exported then
            if p.parameterIDSource ~= "REAPER identifier" and p.parameterIDSource ~= "verified plug-in mapping" then
              warnings[#warnings + 1] = label .. ": plug-in automation for " .. p.fxName .. " / " .. p.paramName .. " uses " .. tostring(p.parameterIDSource or "no") .. "; Studio Pro may not bind it"
              log("Plug-in automation parameter ID is not host-stable: " .. p.fxName .. " / " .. p.paramName .. "; ID=" .. tostring(p.parameterID or "missing") .. "; source=" .. tostring(p.parameterIDSource or "unavailable"))
            else
              log("Plug-in automation parameter ID: " .. p.fxName .. " / " .. p.paramName .. "; ID=" .. tostring(p.parameterID) .. "; source=" .. p.parameterIDSource)
            end
          end
        end
      end
    end
  end
  for ei = 0, reaper.CountTrackEnvelopes(track) - 1 do
    local env = reaper.GetTrackEnvelope(track, ei)
    local ok, envName = reaper.GetEnvelopeName(env, "")
    envName = ok and (envName or "") or ""
    local lower = envName:lower()
    local handled = mappedFxEnvelopes[env] == true
    for _, kind in ipairs({"volume", "pan", "mute"}) do
      if not handled and (lower == kind or lower == "track " .. kind or lower == "master " .. kind) then
        pointsFor(env, kind, parameterIDs[kind])
        handled = true
        break
      end
    end
    if not handled and fxParameters and #fxParameters > 0 then
      for _, p in ipairs(fxParameters) do
        if lower:find(p.fxName:lower(), 1, true) and lower:find(p.paramName:lower(), 1, true) then
          local exported = pointsFor(env, "fx", p.id, p.paramName)
          if exported then
            if p.parameterIDSource ~= "REAPER identifier" and p.parameterIDSource ~= "verified plug-in mapping" then
              warnings[#warnings + 1] = label .. ": plug-in automation for " .. p.fxName .. " / " .. p.paramName .. " uses " .. tostring(p.parameterIDSource or "no") .. "; Studio Pro may not bind it"
              log("Plug-in automation parameter ID is not host-stable: " .. p.fxName .. " / " .. p.paramName .. "; ID=" .. tostring(p.parameterID or "missing") .. "; source=" .. tostring(p.parameterIDSource or "unavailable"))
            else
              log("Plug-in automation parameter ID: " .. p.fxName .. " / " .. p.paramName .. "; ID=" .. tostring(p.parameterID) .. "; source=" .. p.parameterIDSource)
            end
          end
          handled = true
          break
        end
      end
    end
    if not handled then warnings[#warnings + 1] = label .. ': automation envelope not mapped: ' .. envName end
  end
  return table.concat(xml)
end
local function basename(p)
  return (p:gsub("\\", "/"):match("([^/]+)$") or "media.wav")
end
local function safeName(s)
  s = s:gsub("[^%w%._%-]", "_")
  return s ~= "" and s or "media.wav"
end
local function jsonString(s)
  return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n") .. '"'
end
local function winarg(s)
  s = tostring(s)
  return '"' .. s:gsub('(\\*)"', '%1%1\\"'):gsub('(\\+)$', '%1%1') .. '"'
end
local function posixarg(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
local function copyFile(src, dst)
  local input, err = io.open(src, "rb")
  if not input then error("Cannot read media file " .. src .. ": " .. tostring(err)) end
  local output, outErr = io.open(dst, "wb")
  if not output then input:close(); error("Cannot create staged media file " .. dst .. ": " .. tostring(outErr)) end
  while true do
    local chunk = input:read(1024 * 1024)
    if not chunk then break end
    local ok, writeErr = output:write(chunk)
    if not ok then input:close(); output:close(); error("Cannot write staged media file " .. dst .. ": " .. tostring(writeErr)) end
  end
  input:close()
  output:close()
end

local b64alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64map = {}
for i = 1, #b64alphabet do b64map[b64alphabet:sub(i, i)] = i - 1 end
local function decodeBase64(text)
  text = (text or ""):gsub("%s", "")
  local out = {}
  for i = 1, #text, 4 do
    local a, b = b64map[text:sub(i, i)], b64map[text:sub(i + 1, i + 1)]
    local cChar, dChar = text:sub(i + 2, i + 2), text:sub(i + 3, i + 3)
    local c, d = b64map[cChar] or 0, b64map[dChar] or 0
    if a == nil or b == nil then error("Invalid Base64 in REAPER FX state") end
    local n = a * 262144 + b * 4096 + c * 64 + d
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if cChar ~= "=" and cChar ~= "" then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
    if dChar ~= "=" and dChar ~= "" then out[#out + 1] = string.char(n % 256) end
  end
  return table.concat(out)
end
local function encodeBase64(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    b, c = b or 0, c or 0
    local n = a * 65536 + b * 256 + c
    out[#out + 1] = b64alphabet:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
    out[#out + 1] = b64alphabet:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
    out[#out + 1] = i + 1 <= #data and b64alphabet:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
    out[#out + 1] = i + 2 <= #data and b64alphabet:sub(n % 64 + 1, n % 64 + 1) or "="
  end
  return table.concat(out)
end
local function u32le(s, p)
  if p + 3 > #s then error("Truncated REAPER FX state") end
  local a, b, c, d = s:byte(p, p + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end
local function be32(n)
  n = n % 4294967296
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end
local function le32(n)
  n = n % 4294967296
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function tokens(line)
  local out = {}
  local i = 1
  while i <= #line do
    while line:sub(i, i):match("%s") do i = i + 1 end
    if i > #line then break end
    local ch = line:sub(i, i)
    if ch == '"' then
      local j = line:find('"', i + 1, true)
      if not j then break end
      out[#out + 1] = line:sub(i + 1, j - 1); i = j + 1
    else
      local j = line:find("%s", i) or (#line + 1)
      out[#out + 1] = line:sub(i, j - 1); i = j
    end
  end
  return out
end
local function scanFXChunks(chunkText)
  local roots, stack = {}, {}
  for raw in (tostring(chunkText) .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local line = raw:match("^%s*(.-)%s*$")
    if line == ">" then
      stack[#stack] = nil
    elseif line:sub(1, 1) == "<" then
      local node = {header = line, children = {}, tag = line:match("^<([^%s>]+)")}
      if #stack > 0 then stack[#stack].children[#stack[#stack].children + 1] = node else roots[#roots + 1] = node end
      stack[#stack + 1] = node
    elseif #stack > 0 and line ~= "" then
      stack[#stack].children[#stack[#stack].children + 1] = line
    end
  end
  local found = {}
  local function visit(n)
    if n.tag == "VST" or n.tag == "CLAP" then found[#found + 1] = n end
    for _, child in ipairs(n.children) do if type(child) == "table" then visit(child) end end
  end
  for _, root in ipairs(roots) do visit(root) end
  return found
end
local function matchingFXChunk(track, fxName, cache)
  if not cache.chunks then
    local ok, text = reaper.GetTrackStateChunk(track, "", false)
    cache.chunks = ok and scanFXChunks(text) or {}
    cache.used = {}
  end
  for i, node in ipairs(cache.chunks) do
    if not cache.used[i] then
      local headerTokens = tokens(node.header:sub(2))
      local desc = headerTokens[2] or ""
      if desc == fxName or desc:find(fxName, 1, true) or fxName:find(desc, 1, true) then
        cache.used[i] = true
        return node, headerTokens
      end
    end
  end
  local candidate, candidateTokens
  for i, node in ipairs(cache.chunks) do
    if not cache.used[i] then
      if candidate then return nil end
      candidate = node; candidateTokens = tokens(node.header:sub(2))
    end
  end
  if candidate then
    for i, node in ipairs(cache.chunks) do if node == candidate then cache.used[i] = true; break end end
  end
  return candidate, candidateTokens
end
local function decodedVSTState(node)
  local lines = {}
  for _, child in ipairs(node.children) do if type(child) == "string" then lines[#lines + 1] = child end end
  if #lines < 2 then error("VST chunk has no Base64 state/footer") end
  local footer = decodeBase64(lines[#lines])
  table.remove(lines)
  local payload = decodeBase64(table.concat(lines))
  local p = 1
  local vstID, dataType = u32le(payload, p), u32le(payload, p + 4); p = p + 8
  if dataType ~= 0xFEED5EEE and dataType ~= 0xFEED5EEF then error("Unknown REAPER VST chunk type") end
  local nIn = u32le(payload, p); p = p + 4 + 8 * nIn
  local nOut = u32le(payload, p); p = p + 4 + 8 * nOut
  local dataSize = u32le(payload, p); p = p + 4 + 8
  local magic1, magic2 = u32le(payload, p), u32le(payload, p + 4)
  if magic1 == 0xDEADBEEF and magic2 == 0xDEADF00D then p = p + 8; dataSize = dataSize - 8 end
  if dataSize < 0 or p + dataSize - 1 > #payload then error("Invalid REAPER VST data length") end
  local data = payload:sub(p, p + dataSize - 1)
  local null1 = footer:find("\0", 1, true) or (#footer + 1)
  local programName = footer:sub(1, null1 - 1)
  local null2 = footer:find("\0", null1 + 1, true) or (#footer + 1)
  local presetName = footer:sub(null1 + 1, null2 - 1)
  return vstID, dataType, data, presetName ~= "" and presetName or programName
end
local function makeFXP(vstID, dataType, data, name)
  local opaque = dataType == 0xFEED5EEE
  local title = (name or ""):gsub("[^%g ]", "?"):sub(1, 27)
  title = title .. string.rep("\0", 28 - #title)
  local head = "CcnK" .. be32(48 + #data) .. (opaque and "FPCh" or "FxCk") .. be32(1) .. be32(vstID) .. be32(1) .. be32(opaque and 0 or math.floor(#data / 4)) .. title
  if opaque then head = head .. be32(#data) end
  return head .. data
end
local function makeVST3Preset(deviceID, reaperData)
  local chunks, p = {}, 1
  while p + 7 <= #reaperData do
    local size = u32le(reaperData, p); p = p + 8
    if size < 0 or p + size - 1 > #reaperData then error("Invalid REAPER VST3 chunk size") end
    chunks[#chunks + 1] = reaperData:sub(p, p + size - 1); p = p + size
  end
  if #chunks < 1 or #chunks > 2 then error("REAPER VST3 state must contain one or two chunks") end
  local classID = tostring(deviceID or ""):gsub("[^%x]", "")
  if #classID ~= 32 then error("Could not read the 32-character VST3 class ID from REAPER FX chunk") end
  local classBytes = classID
  local dataArea, infos, offset = {}, {}, 48
  local labels = {"Comp", "Cont"}
  for i, data in ipairs(chunks) do
    dataArea[#dataArea + 1] = data
    infos[#infos + 1] = labels[i] .. le32(offset) .. le32(0) .. le32(#data) .. le32(0)
    offset = offset + #data
  end
  return "VST3" .. le32(1) .. classBytes .. le32(offset) .. le32(0) .. table.concat(dataArea) .. "List" .. le32(#chunks) .. table.concat(infos)
end
local function stateForPlugin(node, headerTokens, tag, deviceID)
  if tag == "ClapPlugin" then
    for _, child in ipairs(node.children) do
      if type(child) == "table" and child.tag == "STATE" then
        local lines = {}
        for _, line in ipairs(child.children) do if type(line) == "string" then lines[#lines + 1] = line end end
        return ".clap-preset", decodeBase64(table.concat(lines))
      end
    end
    error("CLAP state block is missing")
  end
  local vstID, dataType, data, presetName = decodedVSTState(node)
  if tag == "Vst2Plugin" then return ".fxp", makeFXP(vstID, dataType, data, presetName) end
  local classToken = headerTokens and headerTokens[6] or ""
  local classID = classToken:match("{([%x%-]+)}") or deviceID
  return ".vstpreset", makeVST3Preset(classID, data)
end

local pluginParameterIDOverrides = {
  ["1802725230"] = { ["gain"] = 4100 }
}
local function fxDeviceXML(tr, fx, warnings, trackName, pluginMedia, stateCache, fxParameters)
  local okName, fxName = reaper.TrackFX_GetFXName(tr, fx, "")
  if not okName then fxName = "Unknown plug-in" end
  local _, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  local _, fxType = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_type")
  ident = ident or ""
  fxType = (fxType or ""):upper()
  local tag, role
  if fxType:find("VST3", 1, true) or ident:match("^VST3:") then tag, role = "Vst3Plugin", "audioFX"
  elseif fxType:find("VST", 1, true) or ident:match("^VST:") then tag, role = "Vst2Plugin", "audioFX"
  elseif fxType:find("CLAP", 1, true) or ident:match("^CLAP:") then tag, role = "ClapPlugin", "audioFX"
  else tag, role = "Device", "audioFX" end
  if ident:match("^VSTi:") or ident:match("^VST3i:") or ident:match("^CLAPi:") then role = "instrument" end
  local enabled = reaper.TrackFX_GetEnabled(tr, fx)
  local deviceID = ident ~= "" and ident or fxName
  if tag == "Vst2Plugin" then deviceID = deviceID:match("^(.-)<") or deviceID end
  local fxChunk, fxHeaderTokens
  if tag == "Vst2Plugin" or tag == "Vst3Plugin" or tag == "ClapPlugin" then
    local chunkOK, foundChunk, foundTokens = pcall(function() return matchingFXChunk(tr, fxName, stateCache) end)
    if chunkOK then fxChunk, fxHeaderTokens = foundChunk, foundTokens end
    if fxHeaderTokens then
      if tag == "Vst2Plugin" then deviceID = (fxHeaderTokens[6] or ""):match("^(.-)<") or deviceID
      elseif tag == "Vst3Plugin" then deviceID = (fxHeaderTokens[6] or ""):match("{([%x%-]+)}") or deviceID
      elseif tag == "ClapPlugin" then deviceID = fxHeaderTokens[3] or deviceID end
    end
  end
  local pluginName, vendor = fxName, nil
  if fxHeaderTokens and fxHeaderTokens[2] then
    local desc = fxHeaderTokens[2]
    local unprefixed = desc:gsub("^VST3i?:%s*", ""):gsub("^VSTi?:%s*", ""):gsub("^CLAPi?:%s*", "")
    local parsedName, parsedVendor = unprefixed:match("^(.-)%s+%((.-)%)$")
    pluginName = parsedName or unprefixed
    vendor = parsedVendor
    if desc:match("^VST3i:") or desc:match("^VSTi:") or desc:match("^CLAPi:") then
      role = "instrument"
    else
      role = "audioFX"
    end
  end
  local parameters, paramCount = {}, reaper.TrackFX_GetNumParams(tr, fx)
  for pi = 0, (paramCount or 0) - 1 do
    local _, pname = reaper.TrackFX_GetParamName(tr, fx, pi, "")
    local normalized = reaper.TrackFX_GetParamNormalized(tr, fx, pi)
    if normalized ~= nil then
      local paramName = pname ~= "" and pname or ("Parameter " .. pi)
      local parameterID
      local parameterIDSource = "unavailable"
      if reaper.TrackFX_GetParamIdent then
        local okIdent, paramIdent = reaper.TrackFX_GetParamIdent(tr, fx, pi)
        if okIdent and paramIdent then
          local numericID = tostring(paramIdent):match("^%s*([+-]?%d+)%s*$") or tostring(paramIdent):match("[%.:/]([+-]?%d+)%s*$")
          if numericID then
            local candidateID = tonumber(numericID)
            if tag ~= "Vst2Plugin" or candidateID ~= pi then
              parameterID = tostring(candidateID)
              parameterIDSource = "REAPER identifier"
            end
          end
        end
      end
      if not parameterID and tag == "Vst2Plugin" then
        parameterID = tostring(pi)
        parameterIDSource = "VST2 parameter index"
      end
      local knownIDs = pluginParameterIDOverrides[tostring(deviceID)]
      local knownID = knownIDs and knownIDs[paramName:lower()]
      if knownID then
        parameterID = tostring(knownID)
        parameterIDSource = "verified plug-in mapping"
      end
      local paramXMLID = newId()
      local idAttr = parameterID and (' parameterID="' .. esc(parameterID) .. '"') or ''
      parameters[#parameters + 1] = '<RealParameter id="' .. paramXMLID .. '" name="' .. esc(paramName) .. '" min="0" max="1"' .. idAttr .. ' unit="normalized" value="' .. fmt(normalized) .. '"/>'
      fxParameters[#fxParameters + 1] = {fxName = fxName, paramName = paramName, parameterID = parameterID, parameterIDSource = parameterIDSource, id = paramXMLID, track = tr, fxIndex = fx, paramIndex = pi}
    end
  end
  local parameterXML = #parameters > 0 and ('<Parameters>' .. table.concat(parameters) .. '</Parameters>') or ''
  local stateXML = ""
  if tag == "Vst2Plugin" or tag == "Vst3Plugin" or tag == "ClapPlugin" then
    if fxChunk then
      local stateOk, extension, stateData = pcall(stateForPlugin, fxChunk, fxHeaderTokens, tag, deviceID)
      if stateOk and stateData then
        local statePath = "plugins/" .. newId() .. extension
        pluginMedia[#pluginMedia + 1] = {target = statePath, data = stateData, name = fxName}
        stateXML = '<State path="' .. statePath .. '" external="false"/>'
        log("Converted plug-in state: " .. fxName .. " [" .. tag .. ", role=" .. role .. "] -> " .. statePath .. " (" .. #stateData .. " bytes)")
      else
        warnings[#warnings + 1] = trackName .. ': could not convert state for ' .. fxName .. ': ' .. tostring(extension)
        log("Plug-in state conversion failed: " .. fxName .. ": " .. tostring(extension))
      end
    else
      warnings[#warnings + 1] = trackName .. ': could not read REAPER FX state chunk for ' .. fxName
    end
  end
  local vendorAttr = vendor and (' deviceVendor="' .. esc(vendor) .. '"') or ''
  log("Plug-in device: " .. fxName .. "; type=" .. tag .. "; role=" .. role .. "; id=" .. deviceID)
  local xml = '<' .. tag .. ' id="' .. newId() .. '" name="' .. esc(pluginName) .. '" deviceName="' .. esc(pluginName) .. '"' .. vendorAttr .. ' deviceID="' .. esc(deviceID) .. '" deviceRole="' .. role .. '" loaded="true">' .. parameterXML .. '<Enabled id="' .. newId() .. '" name="Enabled" value="' .. tostring(enabled) .. '"/>' .. stateXML .. '</' .. tag .. '>'
  warnings[#warnings + 1] = trackName .. ': ' .. fxName .. (#parameters > 0 and (' — ' .. #parameters .. ' normalized parameter values exported') or ' — no parameters exposed');
  if stateXML ~= "" then warnings[#warnings + 1] = trackName .. ': embedded plug-in state for ' .. fxName .. ' (destination still needs a compatible plug-in)' end
  return xml
end

local overwriteApprovedPath = nil
local function run(outputPath)
  setLogLocation(outputPath)
  log("Export started; exporter 0.1; REAPER " .. tostring(reaper.GetAppVersion()) .. "; OS " .. osId)
  if not isWindows and not isMac then error("This exporter currently supports Windows and macOS; detected: " .. tostring(osId)) end
  local tempoMarkerCount = reaper.CountTempoTimeSigMarkers(proj)

  local pname = reaper.GetProjectName(proj)
  pname = pname:gsub("%.[^%.]+$", "")
  if pname == "" then pname = "REAPER_Project" end
  local outPath = nativePath(outputPath or "")
  if outPath == "" then return end
  if not outPath:lower():match("%.dawproject$") then outPath = outPath .. ".dawproject" end
  local overwrite = false
  if reaper.file_exists(outPath) then
    local pickerApproved = overwriteApprovedPath and nativePath(overwriteApprovedPath):lower() == outPath:lower()
    if pickerApproved then
      overwrite = true
      log("Overwrite already approved in REAPER file picker: " .. outPath)
    else
    local answer = reaper.ShowMessageBox("A project file already exists at this location:\n\n" .. outPath .. "\n\nOverwrite it?", "DAWproject for REAPER", 4)
    if answer ~= 6 then
      log("Export cancelled by user; existing destination preserved: " .. outPath)
      return
    end
    overwrite = true
    log("User approved overwriting existing destination: " .. outPath)
    end
  end
  overwriteApprovedPath = nil
  log("Destination: " .. outPath)

  local tempDir = nativePath(tempBase):gsub("[\\/]$", "")
  log("Temporary directory: " .. tempDir)
  math.randomseed(os.time() + math.floor((reaper.time_precise() % 1) * 1000000))
  local function makeSeed()
    return joinPath(tempDir, "REAPER_DAWproject_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999)))
  end
  local seed = makeSeed()
  local attempts = 0
  while reaper.file_exists(seed .. "_package.sh") or reaper.file_exists(seed .. "_package.cmd") or reaper.file_exists(seed .. "_package.ps1") do
    attempts = attempts + 1
    if attempts > 20 then error("Could not reserve a unique temporary filename in " .. tempDir) end
    seed = makeSeed()
  end
  local stage = seed .. "_stage"
  local stagePath = nativePath(stage)
  reaper.RecursiveCreateDirectory(stagePath, 0)
  local audioDir = joinPath(stagePath, "audio")
  reaper.RecursiveCreateDirectory(audioDir, 0)
  log("Created staging folder: " .. stagePath)

  local tracks, laneXML, map, videoMap, pluginMedia = {}, {}, {}, {}, {}
  local audioTargetBySource = {}
  local fxStateCaches = {}
  local audioClipCount, audioReferences, audioRanges = 0, {}, {}
  local exportedEventCount = 0
  local generatedMediaTrackCount = 0
  local warnings = {}
  local masterChannel = newId()
  local masterTrackId = newId()
  local trackCount = reaper.CountTracks(proj)
  local channelIds = {}
  for ti = 0, trackCount - 1 do channelIds[reaper.GetTrack(proj, ti)] = newId() end
  local folderParentByTrack, openFolderTracks = {}, {}
  for ti = 0, trackCount - 1 do
    local folderTrack = reaper.GetTrack(proj, ti)
    folderParentByTrack[folderTrack] = openFolderTracks[#openFolderTracks]
    local depth = reaper.GetMediaTrackInfo_Value(folderTrack, "I_FOLDERDEPTH") or 0
    if depth > 0 then openFolderTracks[#openFolderTracks + 1] = folderTrack end
    if depth < 0 then
      for _ = 1, math.min(-depth, #openFolderTracks) do openFolderTracks[#openFolderTracks] = nil end
    end
  end
  for ti = 0, trackCount - 1 do
    local tr = reaper.GetTrack(proj, ti)
    local name = readname(tr)
    local channelId, trackId, laneId, clipsId = channelIds[tr], newId(), newId(), newId()
    local color = nativeColor(tr)
    local vol = reaper.GetMediaTrackInfo_Value(tr, "D_VOL") or 1
    local pan = reaper.GetMediaTrackInfo_Value(tr, "D_PAN") or 0
    local mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") or 0
    local solo = (reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") or 0) ~= 0
    local content, itemXML, midiExpressions = {}, {}, {}
    local alternateTakeClips, alternateTakeExpressions = {}, {}
    local fixedLaneMode = (reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") or 0) == 2
    local fixedLaneCount = fixedLaneMode and math.max(1, math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") or 1)) or 1
    local fixedLaneClips, fixedLaneExpressions = {}, {}
    local laneItemIntervals, overlappingLaneItems = {}, {}
    local trackAudioSourceCounts = {}
    local trackItemCount = reaper.CountTrackMediaItems(tr)
    local trackVideoOnly = trackItemCount > 0
    local trackHasMediaTime = false
    for ii = 0, trackItemCount - 1 do
      local item = reaper.GetTrackMediaItem(tr, ii)
      local take = reaper.GetActiveTake(item)
      for takeIndex = 0, reaper.CountTakes(item) - 1 do
        local sourceTake = reaper.GetTake(item, takeIndex)
        if sourceTake and not reaper.TakeIsMIDI(sourceTake) then
          local source = reaper.GetMediaItemTake_Source(sourceTake)
          local sourcePath = source and reaper.GetMediaSourceFileName(source) or ""
          if sourcePath ~= "" and reaper.file_exists(sourcePath) then
            local sourceKey = sourcePath:gsub("\\", "/")
            if isWindows then sourceKey = sourceKey:lower() end
            trackAudioSourceCounts[sourceKey] = (trackAudioSourceCounts[sourceKey] or 0) + 1
          end
        end
      end
      if not take or reaper.TakeIsMIDI(take) then
        trackVideoOnly = false
      else
        trackHasMediaTime = true
        local src = reaper.GetMediaItemTake_Source(take)
        local sourceType = src and reaper.GetMediaSourceType and reaper.GetMediaSourceType(src, "") or ""
        local sourcePath = src and reaper.GetMediaSourceFileName(src) or ""
        if reaper.CountTakes(item) ~= 1 or not tostring(sourceType):upper():find("VIDEO", 1, true) or sourcePath == "" or not reaper.file_exists(sourcePath) then trackVideoOnly = false end
      end
      if take and not reaper.TakeIsMIDI(take) then
        local lane = fixedLaneMode and math.max(0, math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE") or 0)) or 0
        laneItemIntervals[lane] = laneItemIntervals[lane] or {}
        local startPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0
        laneItemIntervals[lane][#laneItemIntervals[lane] + 1] = {
          item = item,
          startPos = startPos,
          endPos = startPos + (reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 0)
        }
      end
    end
    if reaper.TrackFX_GetCount(tr) > 0 or reaper.GetTrackNumSends(tr, 0) > 0 or reaper.GetTrackNumSends(tr, -1) > 0 then
      trackVideoOnly = false
    end
    for _, laneItems in pairs(laneItemIntervals) do
      table.sort(laneItems, function(a, b) return a.startPos < b.startPos end)
      for i = 1, #laneItems do
        local left = laneItems[i]
        for j = i + 1, #laneItems do
          local right = laneItems[j]
          if right.startPos >= left.endPos then break end
          if math.min(left.endPos, right.endPos) - math.max(left.startPos, right.startPos) > 0.000001 then
            overlappingLaneItems[left.item] = true
            overlappingLaneItems[right.item] = true
          end
        end
      end
    end
    local fxParameters = {}
    local hasAudio, hasMidi, hasVideo = false, false, false
    local deviceXML = {}
    local fxCache = fxStateCaches[tr] or {}
    fxStateCaches[tr] = fxCache
    for fi = 0, reaper.TrackFX_GetCount(tr) - 1 do
      deviceXML[#deviceXML + 1] = fxDeviceXML(tr, fi, warnings, name, pluginMedia, fxCache, fxParameters)
    end
    local sendXML, sendCount = {}, reaper.GetTrackNumSends(tr, 0)
    for si = 0, sendCount - 1 do
      local dest = reaper.GetTrackSendInfo_Value(tr, 0, si, "P_DESTTRACK")
      local destChannel = dest and channelIds[dest] or (dest == reaper.GetMasterTrack(proj) and masterChannel or nil)
      if destChannel then
        local sendVol = reaper.GetTrackSendInfo_Value(tr, 0, si, "D_VOL") or 1
        local sendPan = reaper.GetTrackSendInfo_Value(tr, 0, si, "D_PAN") or 0
        local sendMute = (reaper.GetTrackSendInfo_Value(tr, 0, si, "B_MUTE") or 0) ~= 0
        local sendMode = reaper.GetTrackSendInfo_Value(tr, 0, si, "I_SENDMODE") or 0
        local sendType = sendMode ~= 0 and "pre" or "post"
        sendXML[#sendXML + 1] = '<Send id="' .. newId() .. '" destination="' .. destChannel .. '" type="' .. sendType .. '"><Enable id="' .. newId() .. '" name="Enable" value="' .. tostring(not sendMute) .. '"/><Pan id="' .. newId() .. '" name="Pan" min="0" max="1" unit="normalized" value="' .. fmt((sendPan + 1) / 2) .. '"/><Volume id="' .. newId() .. '" name="Volume" min="0" max="2" unit="linear" value="' .. fmt(sendVol) .. '"/></Send>'
        log("Export send: " .. name .. " -> " .. readname(dest) .. "; mode=" .. sendType .. "; gain=" .. fmt(sendVol) .. "; pan=" .. fmt(sendPan))
      else
        warnings[#warnings + 1] = name .. ': omitted an unroutable or hardware output send'
      end
    end
    local hardwareSendCount = reaper.GetTrackNumSends(tr, 1)
    if hardwareSendCount and hardwareSendCount > 0 then
      warnings[#warnings + 1] = name .. ": hardware outputs cannot be represented in DAWproject (they depend on the local audio device configuration)"
    end
    local volumeID, panID, muteID = newId(), newId(), newId()
    local automationTimeUnit = trackHasMediaTime and "seconds" or "beats"
    local trackAutomation = exportEnvelopes(tr, name, {volume = volumeID, pan = panID, mute = muteID}, fxParameters, warnings, automationTimeUnit)
    local folderDepth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") or 0
    local parentFolder = folderParentByTrack[tr]
    local channelDestination = parentFolder and channelIds[parentFolder] or masterChannel

    for ii = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local item = reaper.GetTrackMediaItem(tr, ii)
      local activeTake = reaper.GetActiveTake(item)
      local fixedLaneIndex = fixedLaneMode and math.max(0, math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE") or 0)) or 0
      if fixedLaneMode then
        fixedLaneClips[fixedLaneIndex] = fixedLaneClips[fixedLaneIndex] or {}
        fixedLaneExpressions[fixedLaneIndex] = fixedLaneExpressions[fixedLaneIndex] or {}
        fixedLaneCount = math.max(fixedLaneCount, fixedLaneIndex + 1)
      end
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local startBeat, endBeat = beatsAt(pos), beatsAt(pos + len)
          local beatLen = math.max(0.000001, endBeat - startBeat)
      local takeCount = reaper.CountTakes(item)
      if takeCount > 1 then
        warnings[#warnings + 1] = name .. ": alternate takes are exported as separate DAWproject lanes; Studio Pro's layer mapping is not confirmed"
      end
      for takeIndex = 0, takeCount - 1 do
      local take = reaper.GetTake(item, takeIndex)
      local clipTarget = fixedLaneMode and fixedLaneClips[fixedLaneIndex] or itemXML
      local expressionTarget = fixedLaneMode and fixedLaneExpressions[fixedLaneIndex] or midiExpressions
      if take ~= activeTake then
        alternateTakeClips[takeIndex] = alternateTakeClips[takeIndex] or {}
        alternateTakeExpressions[takeIndex] = alternateTakeExpressions[takeIndex] or {}
        clipTarget = alternateTakeClips[takeIndex]
        expressionTarget = alternateTakeExpressions[takeIndex]
      end
      local takeName = take and reaper.GetTakeName(take) or ("Item " .. (ii + 1))
      if take and reaper.TakeIsMIDI(take) then
        hasMidi = true
        local notes = {}
        local _, noteCount = reaper.MIDI_CountEvts(take)
        for ni = 0, noteCount - 1 do
          local rv, _, mutedNote, ppq0, ppq1, ch, key, vel = reaper.MIDI_GetNote(take, ni)
          if rv and not mutedNote then
            local nt0 = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq0)
            local nt1 = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq1)
            local n0 = beatsAt(nt0) - startBeat
            local n1 = beatsAt(nt1) - startBeat
            notes[#notes + 1] = '<Note time="' .. fmt(n0) .. '" duration="' .. fmt(math.max(0.000001, n1 - n0)) ..
              '" channel="' .. tostring(ch) .. '" key="' .. tostring(key) .. '" vel="' .. fmt((vel or 0) / 127) ..
              '"/>'
          end
        end
        local expressionGroups = {}
        local _, _, ccCount = reaper.MIDI_CountEvts(take)
        for ci = 0, (ccCount or 0) - 1 do
          local rv, _, mutedCC, ppq, msg, ch, d1, d2 = reaper.MIDI_GetCC(take, ci)
          if rv and not mutedCC then
            local exp, key, value, valueTag
            if msg == 176 then exp, key, value, valueTag = "channelController", tostring(d1), (d2 or 0) / 127, "RealPoint"
            elseif msg == 160 then exp, key, value, valueTag = "polyPressure", tostring(d1), (d2 or 0) / 127, "RealPoint"
            elseif msg == 208 then exp, key, value, valueTag = "channelPressure", "", (d1 or 0) / 127, "RealPoint"
            elseif msg == 224 then exp, key, value, valueTag = "pitchBend", "", (((d2 or 0) * 128 + (d1 or 0)) - 8192) / 8192, "RealPoint"
            elseif msg == 192 then exp, key, value, valueTag = "programChange", "", d1 or 0, "IntegerPoint" end
            if exp then
              local groupKey = exp .. ":" .. tostring(ch) .. ":" .. key
              local group = expressionGroups[groupKey]
              if not group then
                group = {expression = exp, channel = ch, key = key, points = {}, valueTag = valueTag}
                expressionGroups[groupKey] = group
              end
              local eventTime = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
              local eventBeat = beatsAt(eventTime)
              local targetAttrs = ' expression="' .. exp .. '" channel="' .. tostring(ch) .. '"'
              if exp == "channelController" then targetAttrs = targetAttrs .. ' controller="' .. key .. '"' end
              if exp == "polyPressure" then targetAttrs = targetAttrs .. ' key="' .. key .. '"' end
              group.targetAttrs = targetAttrs
              group.points[#group.points + 1] = '<' .. valueTag .. ' time="' .. fmt(eventBeat) .. '" value="' .. fmt(value) .. '"/>'
            end
          end
        end
        for _, group in pairs(expressionGroups) do
          expressionTarget[#expressionTarget + 1] = '<Points id="' .. newId() .. '" timeUnit="beats" unit="linear"><Target' .. group.targetAttrs .. '/>' .. table.concat(group.points) .. '</Points>'
        end
        local midiClipTime, midiClipLength = startBeat, beatLen
        if trackHasMediaTime then midiClipTime, midiClipLength = pos, len end
        clipTarget[#clipTarget + 1] = '<Clip time="' .. fmt(midiClipTime) .. '" duration="' .. fmt(midiClipLength) .. '" contentTimeUnit="beats" name="' .. esc(takeName) .. '"><Notes id="' .. newId() .. '">' .. table.concat(notes) .. '</Notes></Clip>'
        exportedEventCount = exportedEventCount + 1
      elseif take then
        local src = reaper.GetMediaItemTake_Source(take)
        local srcPath = reaper.GetMediaSourceFileName(src)
        if srcPath and srcPath ~= "" and reaper.file_exists(srcPath) then
          local sourceType = reaper.GetMediaSourceType and reaper.GetMediaSourceType(src, "") or ""
          if tostring(sourceType):upper():find("VIDEO", 1, true) then
            hasVideo = true
            local sourceLen = reaper.GetMediaSourceLength(src)
            local sampleRate = reaper.GetMediaSourceSampleRate(src)
            if not sampleRate or sampleRate <= 0 then sampleRate = 48000 end
            local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
            local offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
            local rel = string.format("video/%04d_%s", #videoMap + 1, safeName(basename(srcPath)))
            videoMap[#videoMap + 1] = {source = srcPath, target = rel}
            local videoSource = '<Video duration="' .. fmt(sourceLen) .. '" channels="2" sampleRate="' .. tostring(sampleRate) .. '" algorithm="stretch" id="' .. newId() .. '"><File external="false" path="' .. esc(rel) .. '"/></Video>'
            local videoWarps = '<Warps timeUnit="seconds" contentTimeUnit="seconds" id="' .. newId() .. '">' .. videoSource .. '<Warp time="0" contentTime="' .. fmt(offset) .. '"/><Warp time="' .. fmt(len) .. '" contentTime="' .. fmt(offset + len * rate) .. '"/></Warps>'
            clipTarget[#clipTarget + 1] = '<Clip time="' .. fmt(pos) .. '" duration="' .. fmt(len) .. '" playStart="0" playStop="' .. fmt(len) .. '" contentTimeUnit="seconds" name="' .. esc(takeName) .. '"><Clips id="' .. newId() .. '" timeUnit="seconds"><Clip time="0" duration="' .. fmt(len) .. '" playStart="0" contentTimeUnit="seconds">' .. videoWarps .. '</Clip></Clips></Clip>'
            exportedEventCount = exportedEventCount + 1
            warnings[#warnings + 1] = name .. ": video is embedded as a DAWproject video clip; audio streams inside the video file may require separate extraction"
          else
          hasAudio = true
          audioClipCount = audioClipCount + 1
          if reaper.TakeFX_GetCount(take) > 0 then warnings[#warnings + 1] = name .. ": take/item FX are not exported; DAWproject 1.0 has no plug-in chain inside an audio event" end
          local sourceLen = reaper.GetMediaSourceLength(src)
          local sampleRate = reaper.GetMediaSourceSampleRate(src)
          local channels = reaper.GetMediaSourceNumChannels(src)
          local offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
          local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
          local loopSource = (reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") or 0) ~= 0
          local stretchCount = reaper.GetTakeNumStretchMarkers and reaper.GetTakeNumStretchMarkers(take) or 0
          local loopPlayback = loopSource and sourceLen and sourceLen > offset and offset + len * rate > sourceLen + 0.0000001
          local sourceSelectionClip = (stretchCount or 0) == 0 and math.abs(rate - 1) < 0.0000001
          local safeRate = math.max(rate, 0.000001)
          local sourceTimelineLen = sourceLen and sourceLen / safeRate or len
          local clipPlayStart = sourceSelectionClip and offset or offset / safeRate
          local warpPoints = sourceSelectionClip and {{time = offset, content = offset}} or {{time = 0, content = 0}}
          if not sourceSelectionClip then
            warpPoints[#warpPoints + 1] = {time = clipPlayStart, content = offset}
          end
          if not sourceSelectionClip and stretchCount and stretchCount > 0 and reaper.GetTakeStretchMarker then
            for sm = 0, stretchCount - 1 do
              local rv, markerPos, sourcePos = reaper.GetTakeStretchMarker(take, sm)
              local warpTime = markerPos and (clipPlayStart + markerPos / safeRate)
              if rv and markerPos and sourcePos and markerPos >= 0 and markerPos <= len + 0.0000001 and (not sourceLen or (sourcePos >= 0 and sourcePos <= sourceLen + 0.0000001)) then
                if markerPos > 0.0000001 and warpTime < sourceTimelineLen - 0.0000001 then
                  warpPoints[#warpPoints + 1] = {time = warpTime, content = sourcePos}
                end
              end
            end
          end
          local sourceEnd = offset + len * safeRate
          if not sourceSelectionClip then
            if sourceLen and sourceEnd <= sourceLen + 0.0000001 then
              warpPoints[#warpPoints + 1] = {time = clipPlayStart + len, content = math.min(sourceEnd, sourceLen)}
            end
            if sourceTimelineLen > 0.0000001 then
              warpPoints[#warpPoints + 1] = {time = sourceTimelineLen, content = sourceLen}
            end
          end
          table.sort(warpPoints, function(a, b) return a.time < b.time end)
          local warpXML = {}
          local lastWarpTime = nil
          for _, wp in ipairs(warpPoints) do
            if not lastWarpTime or math.abs(wp.time - lastWarpTime) > 0.0000001 then
              warpXML[#warpXML + 1] = '<Warp time="' .. fmt(wp.time) .. '" contentTime="' .. fmt(wp.content) .. '"/>'
              lastWarpTime = wp.time
            end
          end
          local sourceKey = srcPath:gsub("\\", "/")
          if isWindows then sourceKey = sourceKey:lower() end
          local rel
          local needsIsolatedWarpSource = not sourceSelectionClip and (trackAudioSourceCounts[sourceKey] or 0) > 1
          if not needsIsolatedWarpSource then
            rel = audioTargetBySource[sourceKey]
            if not rel then
              rel = string.format("audio/%04d_%s", #map + 1, safeName(basename(srcPath)))
              audioTargetBySource[sourceKey] = rel
              map[#map + 1] = {source = srcPath, target = rel}
            end
          else
            rel = string.format("audio/%04d_%s", #map + 1, safeName(basename(srcPath)))
            map[#map + 1] = {source = srcPath, target = rel}
          end
          audioReferences[#audioReferences + 1] = rel
          audioRanges[#audioRanges + 1] = rel .. ": time=" .. fmt(pos) .. " seconds, length=" .. fmt(len) .. " seconds"
          if (rate ~= 1 or stretchCount > 0) then warnings[#warnings + 1] = name .. ": audio timing is represented with DAWproject warp markers; REAPER stretch-marker curve/slope is approximated with straight segments" end
          local fadeIn = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN") or 0
          local fadeOut = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN") or 0
          if overlappingLaneItems[item] then
            fadeIn = math.max(fadeIn, reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO") or 0)
            fadeOut = math.max(fadeOut, reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO") or 0)
          end
          local isMuted = (reaper.GetMediaItemInfo_Value(item, "B_MUTE") or 0) ~= 0
          if fadeIn > 0 or fadeOut > 0 then log("Export clip fades: " .. name .. " / " .. takeName .. "; in=" .. fmt(fadeIn) .. " seconds; out=" .. fmt(fadeOut) .. " seconds") end
          local fadeAttrs = ' fadeTimeUnit="seconds" fadeInTime="' .. fmt(fadeIn) .. '" fadeOutTime="' .. fmt(fadeOut) .. '"'
          local attrs = fadeAttrs
          if isMuted then attrs = attrs .. ' enable="false"' end
          local loopAttrs = ""
          if loopPlayback then
            local loopLength
            loopLength = sourceLen
            loopAttrs = ' loopStart="0" loopEnd="' .. fmt(sourceLen) .. '"'
            log("Export loop source: " .. name .. " / " .. takeName .. "; loop length=" .. fmt(loopLength) .. " seconds")
          end
          local nestedDuration = sourceSelectionClip and sourceLen or sourceTimelineLen
          local playRangeAttrs, clipContentUnitAttr
          if sourceSelectionClip then
            playRangeAttrs = clipPlayStart > 0.0000001 and (' playStart="' .. fmt(clipPlayStart) .. '"') or ''
            clipContentUnitAttr = ' contentTimeUnit="seconds"'
          else
            playRangeAttrs = ' playStart="' .. fmt(clipPlayStart) .. '"'
            clipContentUnitAttr = ' contentTimeUnit="seconds"'
          end
          local audioXML = '<Audio duration="' .. fmt(sourceLen) .. '" channels="' .. tostring(channels or 2) .. '" sampleRate="' .. tostring(sampleRate or 44100) .. '"' .. (sourceSelectionClip and '' or ' algorithm="stretch"') .. ' id="' .. newId() .. '"><File external="false" path="' .. esc(rel) .. '"/></Audio>'
          local mediaContent = sourceSelectionClip and audioXML or ('<Warps timeUnit="seconds" contentTimeUnit="seconds" id="' .. newId() .. '">' .. audioXML .. table.concat(warpXML) .. '</Warps>')
          clipTarget[#clipTarget + 1] = '<Clip time="' .. fmt(pos) .. '" duration="' .. fmt(len) .. '"' .. playRangeAttrs .. clipContentUnitAttr .. ' name="' .. esc(takeName) .. '"' .. attrs .. loopAttrs .. '><Clips id="' .. newId() .. '" timeUnit="seconds"><Clip time="0" duration="' .. fmt(nestedDuration) .. '" contentTimeUnit="seconds">' .. mediaContent .. '</Clip></Clips></Clip>'
          if sourceSelectionClip then log("Export source range: " .. name .. " / " .. takeName .. "; start=" .. fmt(clipPlayStart) .. " seconds") end
          exportedEventCount = exportedEventCount + 1
          end
        else
          warnings[#warnings + 1] = name .. ": skipped an audio item with an unavailable/unsupported source"
        end
      end
      end
    end
    if hasAudio then content[#content + 1] = "audio" end
    if hasMidi then content[#content + 1] = "notes" end
    if hasVideo then content[#content + 1] = "video" end
    local ownContentTypes = content
    local hasReceives = reaper.GetTrackNumSends(tr, -1) > 0
    local splitFolderMedia = folderDepth > 0 and #content > 0
    if folderDepth > 0 then content = {"tracks"} end
    if hasReceives and not splitFolderMedia then
      local containsAudio = false
      for _, kind in ipairs(content) do if kind == "audio" then containsAudio = true; break end end
      if not containsAudio then table.insert(content, 1, "audio") end
    end
    local contentType = #content > 0 and table.concat(content, " ") or "audio notes"
    local channelRole = hasReceives and "effect" or (folderDepth > 0 and "submix" or "regular")
    if hasReceives then log("Marking receive track as DAWproject effect channel: " .. name) end
    local trackHead = '<Track id="' .. trackId .. '" name="' .. esc(name) .. '" contentType="' .. contentType .. '" loaded="true"' .. (color and ' color="' .. color .. '"' or '')
    local trackXML
    if trackVideoOnly and not splitFolderMedia then
      trackXML = trackHead .. '/>'
    else
      trackXML = trackHead .. '><Channel id="' .. channelId .. '" destination="' .. channelDestination .. '" role="' .. channelRole .. '" audioChannels="2" solo="' .. tostring(solo) .. '"><Devices>' .. table.concat(deviceXML) .. '</Devices><Mute id="' .. muteID .. '" name="Mute" value="' .. tostring(mute ~= 0) .. '"/><Pan id="' .. panID .. '" name="Pan" min="0" max="1" unit="normalized" value="' .. fmt((pan + 1) / 2) .. '"/><Sends>' .. table.concat(sendXML) .. '</Sends><Volume id="' .. volumeID .. '" name="Volume" min="0" max="2" unit="linear" value="' .. fmt(vol) .. '"/></Channel></Track>'
    end
    tracks[#tracks + 1] = {id = trackId, depth = folderDepth, xml = trackXML}
    local function appendFixedLaneXML(targetTrackId)
      local laneTimeAttr = trackHasMediaTime and ' timeUnit="seconds"' or ' timeUnit="beats"'
      for laneIndex = 0, fixedLaneCount - 1 do
        local laneClips = fixedLaneClips[laneIndex] or {}
        local laneExpressions = fixedLaneExpressions[laneIndex] or {}
        local automation = laneIndex == 0 and trackAutomation or ""
        laneXML[#laneXML + 1] = '<Lanes track="' .. targetTrackId .. '" id="' .. newId() .. '"' .. laneTimeAttr .. ' name="Lane ' .. tostring(laneIndex + 1) .. '"><Clips id="' .. newId() .. '">' .. table.concat(laneClips) .. '</Clips>' .. table.concat(laneExpressions) .. automation .. '</Lanes>'
      end
    end
    if splitFolderMedia then
      local mediaTrackId, mediaChannelId = newId(), newId()
      local mediaTrackName = name .. " (clips)"
      local mediaContentType = table.concat(ownContentTypes, " ")
      local mediaTrackHead = '<Track id="' .. mediaTrackId .. '" name="' .. esc(mediaTrackName) .. '" contentType="' .. mediaContentType .. '" loaded="true"' .. (color and ' color="' .. color .. '"' or '')
      local mediaTrackXML = trackVideoOnly and (mediaTrackHead .. '/>') or (mediaTrackHead .. '><Channel id="' .. mediaChannelId .. '" destination="' .. channelId .. '" role="regular" audioChannels="2" solo="false"><Devices></Devices><Mute id="' .. newId() .. '" name="Mute" value="false"/><Pan id="' .. newId() .. '" name="Pan" min="0" max="1" unit="normalized" value="0.5"/><Sends></Sends><Volume id="' .. newId() .. '" name="Volume" min="0" max="2" unit="linear" value="1"/></Channel></Track>')
      tracks[#tracks + 1] = {id = mediaTrackId, depth = 0, xml = mediaTrackXML}
      laneXML[#laneXML + 1] = '<Lanes track="' .. trackId .. '" id="' .. laneId .. '"' .. (trackHasMediaTime and ' timeUnit="seconds"' or ' timeUnit="beats"') .. '><Clips id="' .. clipsId .. '"></Clips>' .. trackAutomation .. '</Lanes>'
      if fixedLaneMode then
        appendFixedLaneXML(mediaTrackId)
      else
        laneXML[#laneXML + 1] = '<Lanes track="' .. mediaTrackId .. '" id="' .. newId() .. '"' .. (trackHasMediaTime and ' timeUnit="seconds"' or ' timeUnit="beats"') .. '><Clips id="' .. newId() .. '">' .. table.concat(itemXML) .. '</Clips>' .. table.concat(midiExpressions) .. '</Lanes>'
      end
      generatedMediaTrackCount = generatedMediaTrackCount + 1
      log("Split folder track's own clips onto child track: " .. name .. " -> " .. mediaTrackName)
    elseif fixedLaneMode then
      appendFixedLaneXML(trackId)
    else
      laneXML[#laneXML + 1] = '<Lanes track="' .. trackId .. '" id="' .. laneId .. '"' .. (trackHasMediaTime and ' timeUnit="seconds"' or ' timeUnit="beats"') .. '><Clips id="' .. clipsId .. '">' .. table.concat(itemXML) .. '</Clips>' .. table.concat(midiExpressions) .. trackAutomation .. '</Lanes>'
    end
    local takeIndexes = {}
    for takeIndex in pairs(alternateTakeClips) do takeIndexes[#takeIndexes + 1] = takeIndex end
    table.sort(takeIndexes)
    for _, takeIndex in ipairs(takeIndexes) do
      local altClips = alternateTakeClips[takeIndex]
      local altExpressions = alternateTakeExpressions[takeIndex] or {}
      if #altClips > 0 then
        local layerName = "Alternate Take " .. tostring(takeIndex + 1)
        local alternateTrackId = splitFolderMedia and tracks[#tracks].id or trackId
        laneXML[#laneXML + 1] = '<Lanes track="' .. alternateTrackId .. '" id="' .. newId() .. '"' .. (trackHasMediaTime and ' timeUnit="seconds"' or ' timeUnit="beats"') .. ' name="' .. layerName .. '"><Clips id="' .. newId() .. '">' .. table.concat(altClips) .. '</Clips>' .. table.concat(altExpressions) .. '</Lanes>'
        log("Export alternate-take lane: " .. name .. "; " .. layerName .. "; clips=" .. #altClips)
      end
    end
  end

  local num, den, bpm = reaper.TimeMap_GetTimeSigAtTime(proj, 0)
  if not bpm or bpm <= 0 then bpm = 120 end
  if not num or num <= 0 then num = 4 end
  if not den or den <= 0 then den = 4 end
  local tempoId, signatureId = newId(), newId()
  local tempoAutomation, signatureAutomation = "", ""
  if tempoMarkerCount > 1 then
    local tempoPoints, signaturePoints = {}, {}
    for mi = 0, tempoMarkerCount - 1 do
      local rv, timepos, _, _, markerBpm, markerNum, markerDen, linear = reaper.GetTempoTimeSigMarker(proj, mi)
      if rv then
        tempoPoints[#tempoPoints + 1] = '<RealPoint time="' .. fmt(timepos) .. '" value="' .. fmt(markerBpm) .. '" interpolation="' .. (linear and 'linear' or 'hold') .. '"/>'
        if markerNum and markerNum > 0 and markerDen and markerDen > 0 then
          signaturePoints[#signaturePoints + 1] = '<TimeSignaturePoint time="' .. fmt(timepos) .. '" numerator="' .. tostring(markerNum) .. '" denominator="' .. tostring(markerDen) .. '"/>'
        end
      end
    end
    tempoAutomation = '<TempoAutomation id="' .. newId() .. '" timeUnit="seconds" unit="bpm"><Target parameter="' .. tempoId .. '"/>' .. table.concat(tempoPoints) .. '</TempoAutomation>'
    if #signaturePoints > 0 then signatureAutomation = '<TimeSignatureAutomation id="' .. newId() .. '" timeUnit="seconds"><Target parameter="' .. signatureId .. '"/>' .. table.concat(signaturePoints) .. '</TimeSignatureAutomation>' end
    log("Export tempo map in seconds: " .. #tempoPoints .. " tempo points; " .. #signaturePoints .. " time-signature points")
  end
  local masterDevices = {}
  local masterFX = reaper.GetMasterTrack(proj)
  local masterFxParameters = {}
  local masterCache = fxStateCaches[masterFX] or {}
  fxStateCaches[masterFX] = masterCache
  for fi = 0, reaper.TrackFX_GetCount(masterFX) - 1 do
    masterDevices[#masterDevices + 1] = fxDeviceXML(masterFX, fi, warnings, "Master", pluginMedia, masterCache, masterFxParameters)
  end
  local masterVol = reaper.GetMediaTrackInfo_Value(masterFX, "D_VOL") or 1
  local masterPan = reaper.GetMediaTrackInfo_Value(masterFX, "D_PAN") or 0
  local masterMute = (reaper.GetMediaTrackInfo_Value(masterFX, "B_MUTE") or 0) ~= 0
  local masterSolo = (reaper.GetMediaTrackInfo_Value(masterFX, "I_SOLO") or 0) ~= 0
  local masterVolumeID, masterPanID, masterMuteID = newId(), newId(), newId()
  local masterAutomation = exportEnvelopes(masterFX, "Master", {volume = masterVolumeID, pan = masterPanID, mute = masterMuteID}, masterFxParameters, warnings, "beats")
  local markerXML, markerCount = {}, reaper.CountProjectMarkers(proj)
  local regionClipXML = {}
  for mi = 0, (markerCount or 0) - 1 do
    local rv, isRegion, pos, regionEnd, markerName, _, markerColor = reaper.EnumProjectMarkers3(proj, mi)
    if rv and not isRegion then
      local colorAttr = ''
      if markerColor and markerColor ~= 0 then
        local r, g, b = reaper.ColorFromNative(markerColor)
        colorAttr = ' color="' .. string.format("#%02x%02x%02x", r, g, b) .. '"'
      end
      markerXML[#markerXML + 1] = '<Marker id="' .. newId() .. '" name="' .. esc(markerName) .. '" time="' .. fmt(beatsAt(pos)) .. '"' .. colorAttr .. '/>'
    elseif rv and isRegion then
      local baseName = tostring(markerName or "Region")
      markerXML[#markerXML + 1] = '<Marker id="' .. newId() .. '" name="' .. esc(baseName .. " [Start]") .. '" time="' .. fmt(beatsAt(pos)) .. '"/>'
      markerXML[#markerXML + 1] = '<Marker id="' .. newId() .. '" name="' .. esc(baseName .. " [End]") .. '" time="' .. fmt(beatsAt(regionEnd)) .. '"/>'
      local regionStartBeat, regionEndBeat = beatsAt(pos), beatsAt(regionEnd)
      regionClipXML[#regionClipXML + 1] = '<Clip time="' .. fmt(regionStartBeat) .. '" duration="' .. fmt(math.max(0.000001, regionEndBeat - regionStartBeat)) .. '" playStart="0" name="' .. esc(baseName) .. '"/>'
      exportedEventCount = exportedEventCount + 1
    end
  end
  local regionsTrackId, regionsLaneXML, regionsTrackXML = nil, "", ""
  if #regionClipXML > 0 then
    regionsTrackId = newId()
    regionsTrackXML = '<Track id="' .. regionsTrackId .. '" name="REAPER Regions" contentType="markers" loaded="true"/>'
    regionsLaneXML = '<Lanes track="' .. regionsTrackId .. '" id="' .. newId() .. '" timeUnit="beats"><Clips id="' .. newId() .. '">' .. table.concat(regionClipXML) .. '</Clips></Lanes>'
    warnings[#warnings + 1] = "Project regions are exported as duration events on a markers track; Studio Pro's display/import of this representation is not confirmed"
  end
  local structureRoot = {children = {}}
  local folderStack = {structureRoot}
  for _, node in ipairs(tracks) do
    node.children = {}
    local parent = folderStack[#folderStack]
    parent.children[#parent.children + 1] = node
    if node.depth > 0 then
      folderStack[#folderStack + 1] = node
      if node.depth > 1 then warnings[#warnings + 1] = "Nested REAPER folder depth greater than one may need manual review" end
    elseif node.depth < 0 then
      for _ = 1, math.min(-node.depth, #folderStack - 1) do folderStack[#folderStack] = nil end
    end
  end
  local function renderTrack(node)
    local children = {}
    for _, child in ipairs(node.children) do children[#children + 1] = renderTrack(child) end
    if #children == 0 then return node.xml end
    return node.xml:gsub("</Track>$", table.concat(children) .. "</Track>")
  end
  local structureXML = {}
  for _, node in ipairs(structureRoot.children) do structureXML[#structureXML + 1] = renderTrack(node) end
  local markersElement = #markerXML > 0 and ('<Markers id="' .. newId() .. '" timeUnit="beats">' .. table.concat(markerXML) .. '</Markers>') or ''
  local projectXML = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Project version="1.0"><Application name="REAPER" version="' .. esc(reaper.GetAppVersion()) .. '"/><Transport><Tempo id="' .. tempoId .. '" name="Tempo" min="20" max="666" unit="bpm" value="' .. fmt(bpm) .. '"/><TimeSignature id="' .. signatureId .. '" numerator="' .. tostring(num) .. '" denominator="' .. tostring(den) .. '"/></Transport><Structure>' .. table.concat(structureXML) .. regionsTrackXML .. '<Track id="' .. masterTrackId .. '" name="Master" contentType="audio notes" loaded="true"><Channel id="' .. masterChannel .. '" role="master" audioChannels="2" solo="' .. tostring(masterSolo) .. '"><Devices>' .. table.concat(masterDevices) .. '</Devices><Mute id="' .. masterMuteID .. '" name="Mute" value="' .. tostring(masterMute) .. '"/><Pan id="' .. masterPanID .. '" name="Pan" min="0" max="1" unit="normalized" value="' .. fmt((masterPan + 1) / 2) .. '"/><Volume id="' .. masterVolumeID .. '" name="Volume" min="0" max="2" unit="linear" value="' .. fmt(masterVol) .. '"/></Channel></Track></Structure><Arrangement id="' .. newId() .. '"><Lanes timeUnit="beats" id="' .. newId() .. '">' .. table.concat(laneXML) .. regionsLaneXML .. '<Lanes track="' .. masterTrackId .. '" id="' .. newId() .. '" timeUnit="beats"><Clips id="' .. newId() .. '"/></Lanes>' .. masterAutomation .. '</Lanes>' .. markersElement .. tempoAutomation .. signatureAutomation .. '</Arrangement><Scenes/></Project>'
  local metadataXML = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><MetaData><Title>' .. esc(pname) .. '</Title></MetaData>'
  xmlwrite(joinPath(stagePath, "project.xml"), projectXML)
  xmlwrite(joinPath(stagePath, "metadata.xml"), metadataXML)
  log("Wrote project.xml and metadata.xml; audio clips: " .. tostring(audioClipCount) .. "; audio files: " .. tostring(#map) .. "; plug-in states: " .. tostring(#pluginMedia))
  for _, ref in ipairs(audioReferences) do log("Audio XML File reference: " .. ref) end
  for _, range in ipairs(audioRanges) do log("Audio clip timing: " .. range) end
  for _, media in ipairs(map) do
    local dest = joinPath(stagePath, media.target)
    copyFile(media.source, dest)
    log("Staged media: " .. media.target .. " from " .. media.source)
  end
  if #videoMap > 0 then
    local videoDir = joinPath(stagePath, "video")
    reaper.RecursiveCreateDirectory(videoDir, 0)
    for _, media in ipairs(videoMap) do
      local dest = joinPath(stagePath, media.target)
      copyFile(media.source, dest)
      log("Staged video: " .. media.target .. " from " .. media.source)
    end
  end
  if #pluginMedia > 0 then
    local pluginsDir = joinPath(stagePath, "plugins")
    reaper.RecursiveCreateDirectory(pluginsDir, 0)
    for _, media in ipairs(pluginMedia) do
      local dest = joinPath(stagePath, media.target)
      xmlwrite(dest, media.data)
      log("Staged plug-in state: " .. media.target .. " (" .. tostring(#media.data) .. " bytes; " .. media.name .. ")")
    end
  end
  reaper.RecursiveCreateDirectory(parentPath(outPath), 0)
  local tempZip = outPath .. ".partial.zip"
  os.remove(tempZip)
  if isWindows then
    local tarExe = joinPath(os.getenv("WINDIR") or "C:\\Windows", "System32\\tar.exe")
    local packageScript = seed .. "_package.ps1"
    local ps = [=[
param(
  [Parameter(Mandatory = $true)][string]$SourceRoot,
  [Parameter(Mandatory = $true)][string]$ArchivePath
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
$sourceRoot = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@('\', '/'))
$archivePath = [System.IO.Path]::GetFullPath($ArchivePath)
if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
$archiveStream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
$archive = $null
try {
  $archive = [System.IO.Compression.ZipArchive]::new($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
  $files = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | Sort-Object -Property FullName)
  $orderedFiles = @($files | Where-Object { $_.Name -ine 'project.xml' }) + @($files | Where-Object { $_.Name -ieq 'project.xml' })
  foreach ($file in $orderedFiles) {
    $relativePath = $file.FullName.Substring($sourceRoot.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
    $entry = $archive.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::Optimal)
    $inputStream = [System.IO.File]::OpenRead($file.FullName)
    try {
      $entryStream = $entry.Open()
      try { $inputStream.CopyTo($entryStream, 1048576) }
      finally { $entryStream.Dispose() }
    }
    finally { $inputStream.Dispose() }
  }
}
finally {
  try { if ($archive) { $archive.Dispose() } }
  finally { if ($archiveStream) { $archiveStream.Dispose() } }
}
]=]
    xmlwrite(packageScript, ps)
    local psExe = joinPath(os.getenv("WINDIR") or "C:\\Windows", "System32\\WindowsPowerShell\\v1.0\\powershell.exe")
    if not reaper.file_exists(psExe) then psExe = "powershell.exe" end
    local cmd = winarg(psExe) .. " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " .. winarg(packageScript) .. " " .. winarg(stagePath) .. " " .. winarg(tempZip)
    log("Creating ZIP with Windows PowerShell ZipArchive: " .. cmd)
    local archiveResult = reaper.ExecProcess(cmd, 0)
    os.remove(packageScript)
    checkExec("Create DAWproject ZIP", archiveResult)
    local listCmd = winarg(tarExe) .. ' -t -f ' .. winarg(tempZip)
    local listResult = reaper.ExecProcess(listCmd, 0)
    local listed = checkExec("Verify DAWproject ZIP entries", listResult)
    for _, media in ipairs(map) do
      local expected = media.target
      if not ("\n" .. listed:gsub("\\", "/"):gsub("\r", "\n") .. "\n"):find("\n" .. expected .. "\n", 1, true) then
        error("Media entry missing from DAWproject ZIP: " .. expected .. "\nArchive listing:\n" .. listed)
      end
    end
    for _, media in ipairs(videoMap) do
      local expected = media.target
      if not ("\n" .. listed:gsub("\\", "/"):gsub("\r", "\n") .. "\n"):find("\n" .. expected .. "\n", 1, true) then
        error("Video entry missing from DAWproject ZIP: " .. expected .. "\nArchive listing:\n" .. listed)
      end
    end
    for _, media in ipairs(pluginMedia) do
      if not ("\n" .. listed:gsub("\\", "/"):gsub("\r", "\n") .. "\n"):find("\n" .. media.target .. "\n", 1, true) then
        error("Plug-in state missing from DAWproject ZIP: " .. media.target .. "\nArchive listing:\n" .. listed)
      end
    end
  else
    local shPath = seed .. "_package.sh"
    local packageEntries = 'audio' .. (#pluginMedia > 0 and ' plugins' or '') .. (#videoMap > 0 and ' video' or '') .. ' metadata.xml project.xml'
    local sh = "#!/bin/sh\nset -eu\ncd \"$1\"\nexec /usr/bin/zip -q -r -X \"$2\" " .. packageEntries .. "\n"
    xmlwrite(shPath, sh)
    local cmd = "/bin/sh " .. posixarg(shPath) .. " " .. posixarg(stagePath) .. " " .. posixarg(tempZip)
    log("Creating ZIP with macOS /usr/bin/zip: " .. cmd)
    local archiveResult = reaper.ExecProcess(cmd, 0)
    checkExec("Create DAWproject ZIP", archiveResult)
    local listCmd = "/usr/bin/unzip -Z1 " .. posixarg(tempZip)
    local listedResult = reaper.ExecProcess(listCmd, 0)
    local listed = checkExec("Verify DAWproject ZIP entries", listedResult)
    os.remove(shPath)
    for _, media in ipairs(map) do
      if not ("\n" .. listed:gsub("\r", "\n") .. "\n"):find("\n" .. media.target .. "\n", 1, true) then
        error("Media entry missing from DAWproject ZIP: " .. media.target .. "\nArchive listing:\n" .. listed)
      end
    end
    for _, media in ipairs(videoMap) do
      if not ("\n" .. listed:gsub("\r", "\n") .. "\n"):find("\n" .. media.target .. "\n", 1, true) then
        error("Video entry missing from DAWproject ZIP: " .. media.target .. "\nArchive listing:\n" .. listed)
      end
    end
    for _, media in ipairs(pluginMedia) do
      if not ("\n" .. listed:gsub("\r", "\n") .. "\n"):find("\n" .. media.target .. "\n", 1, true) then
        error("Plug-in state missing from DAWproject ZIP: " .. media.target .. "\nArchive listing:\n" .. listed)
      end
    end
  end
  log("Archive listing verified; audio entries: " .. tostring(#map) .. "; plug-in states: " .. tostring(#pluginMedia))
  if not reaper.file_exists(tempZip) then error("The archive utility finished without creating: " .. tempZip) end
  if reaper.file_exists(outPath) then
    if not overwrite then error("Destination appeared during export; refusing to overwrite without confirmation.") end
    local backup = outPath .. ".previous"
    os.remove(backup)
    local movedOld, moveOldErr = os.rename(outPath, backup)
    if not movedOld then error("Cannot move existing destination to backup: " .. tostring(moveOldErr)) end
    local movedNew, moveNewErr = os.rename(tempZip, outPath)
    if not movedNew then os.rename(backup, outPath); error("Cannot install new archive: " .. tostring(moveNewErr)) end
    os.remove(backup)
  else
    local moved, moveErr = os.rename(tempZip, outPath)
    if not moved then error("Cannot move completed archive into destination: " .. tostring(moveErr)) end
  end
  reaper.ExecProcess(isWindows and ('cmd.exe /c rmdir /s /q ' .. winarg(stagePath)) or ('/bin/rm -rf ' .. posixarg(stagePath)), 0)
  log("Export completed: " .. outPath)
  for _, warning in ipairs(warnings) do log("NOTE: " .. warning) end
  return trackCount + generatedMediaTrackCount, exportedEventCount
end

local function utf8NextByte(s, pos)
  local b = s:byte(pos) or 0
  if b < 0x80 then return pos + 1 end
  if b < 0xE0 then return pos + 2 end
  if b < 0xF0 then return pos + 3 end
  return pos + 4
end
local function utf8PrevByte(s, pos)
  local i = math.max(1, pos - 1)
  while i > 1 and (s:byte(i) or 0) >= 0x80 and (s:byte(i) or 0) < 0xC0 do i = i - 1 end
  return i
end
local function openExternalURL(url)
  if reaper.CF_ShellExecute then return reaper.CF_ShellExecute(url) end
  local command
  if isWindows then command = 'cmd.exe /c start "" "' .. url .. '"'
  elseif isMac then command = 'open "' .. url .. '"'
  else return false end
  reaper.ExecProcess(command, 0)
  return true
end
local showErrorNotice
showErrorNotice = function(operation)
  local width, height = 680, 210
  local openButton = {x=172, y=145, w=150, h=40}
  local cancelButton = {x=358, y=145, w=150, h=40}
  local wasDown = false
  local function color(r,g,b) gfx.set(r/255,g/255,b/255,1) end
  local function drawModalButton(button,label,primary,hover)
    if primary then
      color(hover and 218 or 197, hover and 179 or 160, hover and 105 or 89)
      local radius = 7
      gfx.rect(button.x + radius, button.y, button.w - radius * 2, button.h, 1)
      gfx.rect(button.x, button.y + radius, button.w, button.h - radius * 2, 1)
      gfx.circle(button.x + radius, button.y + radius, radius, 1, 1)
      gfx.circle(button.x + button.w - radius, button.y + radius, radius, 1, 1)
      gfx.circle(button.x + radius, button.y + button.h - radius, radius, 1, 1)
      gfx.circle(button.x + button.w - radius, button.y + button.h - radius, radius, 1, 1)
      gfx.roundrect(button.x, button.y, button.w, button.h, radius, 1)
    else
      color(hover and 76 or 54, hover and 76 or 54, hover and 76 or 54)
      gfx.roundrect(button.x,button.y,button.w,button.h,7,1)
    end
    color(primary and 24 or 238, primary and 24 or 239, primary and 24 or 242)
    gfx.setfont(2,"Arial",15,primary and "b" or "")
    local tw=gfx.measurestr(label)
    gfx.x,gfx.y=button.x+(button.w-tw)/2,button.y+(button.h-gfx.texth)/2
    gfx.drawstr(label)
  end
  gfx.init("DAWproject for REAPER", width, height, 0)
  local function draw()
    local key = gfx.getchar()
    if key < 0 or key == 27 then gfx.quit(); return end
    color(19,19,19); gfx.rect(0, 0, width, height, 1)
    color(197,160,89); gfx.rect(0, 0, 4, height, 1)
    color(245,245,245); gfx.setfont(1, "Arial", 20, "b")
    gfx.x, gfx.y = 30, 24; gfx.drawstr(operation .. " failed")
    local canOpenLog = loggingEnabled and logPath ~= nil
    color(165,165,165); gfx.setfont(1, "Arial", 13)
    gfx.x, gfx.y = 30, 65
    gfx.drawstr(canOpenLog and "Details are in the project log:" or "Logging is disabled or unavailable for this project.")
    local shownPath = canOpenLog and logPath or ""
    while #shownPath > 0 and gfx.measurestr(shownPath) > width - 60 do shownPath = shownPath:sub(utf8NextByte(shownPath, 1)) end
    if canOpenLog and shownPath ~= logPath then shownPath = "…" .. shownPath end
    color(197,160,89); gfx.x, gfx.y = 30, 88; gfx.drawstr(shownPath)
    local mx, my = gfx.mouse_x, gfx.mouse_y
    local openHover = mx >= openButton.x and mx <= openButton.x + openButton.w and my >= openButton.y and my <= openButton.y + openButton.h
    local cancelHover = mx >= cancelButton.x and mx <= cancelButton.x + cancelButton.w and my >= cancelButton.y and my <= cancelButton.y + cancelButton.h
    drawModalButton(openButton,canOpenLog and "Open log" or "Log unavailable",canOpenLog,openHover and canOpenLog)
    drawModalButton(cancelButton,"Cancel",false,cancelHover)
    gfx.update()
    local down = (gfx.mouse_cap & 1) ~= 0
    if down and not wasDown then
      if openHover and canOpenLog then
        if reaper.CF_ShellExecute then reaper.CF_ShellExecute(logPath)
        elseif isWindows then reaper.ExecProcess("cmd.exe /c start \"\" " .. winarg(logPath), -1)
        elseif isMac then reaper.ExecProcess("/usr/bin/open " .. posixarg(logPath), -1)
        else reaper.ExecProcess("xdg-open " .. posixarg(logPath), -1) end
        gfx.quit(); return
      elseif cancelHover then gfx.quit(); return end
    end
    wasDown = down
    reaper.defer(draw)
  end
  draw()
end
local function xmlUnescape(s)
  return (tostring(s or ""):gsub("&(#?[%w]+);", function(entity)
    local named = {amp="&", lt="<", gt=">", quot='"', apos="'"}
    if named[entity] then return named[entity] end
    local dec = entity:match("^#(%d+)$")
    local hex = entity:match("^#x([%x]+)$")
    local n = dec and tonumber(dec) or (hex and tonumber(hex, 16))
    if n and n > 0 and n < 0x110000 then local ok, value = pcall(utf8.char, n); if ok then return value end end
    return "&" .. entity .. ";"
  end))
end
local function parseXML(text)
  local root, stack = {tag="ROOT", attr={}, children={}}, {}
  stack[1] = root
  text = text:gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
  for token in text:gmatch("<[^>]+>[^<]*") do
    local openTag, tail = token:match("^(<[^>]+>)(.*)$")
    if openTag then
      local closing = openTag:match("^</") ~= nil
      local selfClose = openTag:match("/%s*>$") ~= nil
      if closing then
        if #stack > 1 then stack[#stack] = nil end
      else
        local tag = openTag:match("^<%s*([^%s/>]+)")
        if tag then
          local node = {tag=tag, attr={}, children={}}
          for key, value in openTag:gmatch('([%w_:%.%-]+)%s*=%s*"(.-)"') do node.attr[key] = xmlUnescape(value) end
          for key, value in openTag:gmatch("([%w_:%.%-]+)%s*=%s*'(.-)'") do node.attr[key] = xmlUnescape(value) end
          local parent = stack[#stack]; parent.children[#parent.children + 1] = node
          if not selfClose then stack[#stack + 1] = node end
        end
      end
      if tail and tail:match("%S") then stack[#stack].text = (stack[#stack].text or "") .. xmlUnescape(tail) end
    end
  end
  return root.children[1]
end
local function xmlChildren(node, tag)
  local out = {}
  if node then for _, child in ipairs(node.children or {}) do if not tag or child.tag == tag then out[#out + 1] = child end end end
  return out
end
local function xmlFind(node, tag)
  if not node then return nil end
  if node.tag == tag then return node end
  for _, child in ipairs(node.children or {}) do local found = xmlFind(child, tag); if found then return found end end
end
local function xmlAll(node, tag, out)
  out = out or {}
  if node and node.tag == tag then out[#out + 1] = node end
  if node then for _, child in ipairs(node.children or {}) do xmlAll(child, tag, out) end end
  return out
end
local function attrNumber(node, key, default)
  local value = node and tonumber(node.attr and node.attr[key])
  return value or default
end
local function attrBool(node, key)
  local value = node and node.attr and node.attr[key]
  return value == "true" or value == "1"
end
local function safeArchivePath(path)
  local normalized = tostring(path or ""):gsub("\\", "/")
  if normalized:sub(1,1) == "/" or normalized:match("^%a:") then return false end
  for segment in normalized:gmatch("[^/]+") do if segment == ".." or segment == "." then return false end end
  return true
end
local function xmlColor(value)
  if not value or (#value ~= 7 and #value ~= 9) or not value:match("^#%x+$") then return 0 end
  local r, g, b = value:sub(2,3), value:sub(4,5), value:sub(6,7)
  return reaper.ColorToNative(tonumber(r,16), tonumber(g,16), tonumber(b,16)) | 0x1000000
end
local pluginImportCounts = {loaded=0, missing=0, failed=0}
local function applyPluginParameters(track, fxIndex, device)
  local mapped = {}
  local params = xmlFind(device, "Parameters")
  for _, p in ipairs(xmlChildren(params, "RealParameter")) do
    local value = tonumber(p.attr.value)
    local target = nil
    if p.attr.parameterID and reaper.TrackFX_GetParamIdent then
      for i = 0, reaper.TrackFX_GetNumParams(track, fxIndex) - 1 do
        local ok, ident = reaper.TrackFX_GetParamIdent(track, fxIndex, i)
        if ok and tostring(ident) == tostring(p.attr.parameterID) then target = i; break end
      end
    end
    if not target then
      for i = 0, reaper.TrackFX_GetNumParams(track, fxIndex) - 1 do
        local ok, name = reaper.TrackFX_GetParamName(track, fxIndex, i, "")
        if ok and name == p.attr.name then target = i; break end
      end
    end
    if not target and p.attr.parameterID then
      local candidate = tonumber(p.attr.parameterID)
      if candidate and candidate >= 0 and candidate < reaper.TrackFX_GetNumParams(track, fxIndex) then target = candidate end
    end
    if target then
      if value then
        reaper.TrackFX_SetParamNormalized(track, fxIndex, target, math.max(0, math.min(1, value)))
      end
      if p.attr.id then mapped[p.attr.id] = target end
    end
  end
  return mapped
end
local function importPluginDevice(track, device, unpackDir, trackName, automationTargets)
  local tag = device.tag
  if tag ~= "Vst2Plugin" and tag ~= "Vst3Plugin" then return end
  local name = device.attr.name or device.attr.deviceName or ""
  local vendor = device.attr.deviceVendor
  local deviceName = device.attr.deviceName or ""
  local plugName = name .. (vendor and vendor ~= "" and (" (" .. vendor .. ")") or "")
  local prefix = tag == "Vst3Plugin" and "VST3: " or "VST2: "
  local chainCount = reaper.TrackFX_GetCount(track)
  local insertion = -1000 - chainCount
  local fxIndex = -1
  local attempted = {}
  local function tryAdd(candidate)
    if fxIndex >= 0 then return end
    if not candidate or candidate == "" or attempted[candidate] then return end
    attempted[candidate] = true
    local index = reaper.TrackFX_AddByName(track, candidate, false, insertion)
    if index and index >= 0 then fxIndex = index end
  end
  if tag == "Vst2Plugin" then
    local uid = tonumber(device.attr.deviceID)
    local function enumerateInstalled(matchByID)
      if not reaper.EnumInstalledFX then return end
      local wanted = {}
      local function normalize(value)
        value = (value or ""):lower():gsub("^%s*vst2?:%s*", "")
        value = value:gsub("%s*%([^()]*%)%s*$", "")
        return value:gsub("[^%w]", "")
      end
      wanted[normalize(name)] = true
      wanted[normalize(deviceName)] = true
      wanted[normalize(plugName)] = true
      for i = 0, 65535 do
        local ok, installedName, ident = reaper.EnumInstalledFX(i)
        if not ok then break end
        installedName = installedName or ""
        ident = ident or ""
        local isVst2 = installedName:match("^%s*VST2?:") ~= nil
        local matched = false
        if isVst2 and matchByID and uid then
          for token in ident:gmatch("<([^<>]+)") do
            local numeric = tonumber(token:match("^%s*([%-]?%d+)"))
            if numeric and numeric == uid then matched = true; break end
          end
        elseif isVst2 and not matchByID then
          local listedName = normalize(installedName)
          matched = listedName ~= "" and wanted[listedName] == true
        end
        if matched then
          tryAdd(installedName)
          if fxIndex < 0 then tryAdd("VST2: " .. installedName:gsub("^VST2?:%s*", "")) end
          if fxIndex >= 0 then return end
        end
      end
    end
    if uid then enumerateInstalled(true) end
    if fxIndex < 0 then enumerateInstalled(false) end
    if fxIndex < 0 then
      local names = {name, deviceName}
      for _, candidateName in ipairs(names) do
        if candidateName ~= "" then
          tryAdd("VST2: " .. candidateName)
          if vendor and vendor ~= "" then tryAdd("VST2: " .. candidateName .. " (" .. vendor .. ")") end
          if fxIndex >= 0 then break end
        end
      end
    end
  else
    tryAdd(prefix .. plugName)
  end
  if not fxIndex or fxIndex < 0 then
    pluginImportCounts.missing = pluginImportCounts.missing + 1
    log("Plug-in not installed or not found: " .. plugName .. " on " .. trackName)
    return
  end
  local state = xmlFind(device, "State")
  local stateOK, stateMessage = false, "No embedded state"
  if state and state.attr.path and safeArchivePath(state.attr.path) then
    local statePath = joinPath(unpackDir, state.attr.path:gsub("/", pathSep))
    if reaper.file_exists(statePath) then
      if tag == "Vst3Plugin" then
        stateOK = reaper.TrackFX_SetPreset(track, fxIndex, statePath)
        stateMessage = stateOK and "VST3 preset loaded" or "REAPER could not load the embedded VST3 preset"
      else
        local f = io.open(statePath, "rb")
        local fxp = f and f:read("*a") or nil
        if f then f:close() end
        if fxp and #fxp >= 64 and fxp:sub(1,4) == "CcnK" and fxp:sub(9,12) == "FPCh" then
          local b1, b2, b3, b4 = fxp:byte(61, 64)
          local size = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
          local chunk = fxp:sub(65, 64 + size)
          if #chunk == size and reaper.TrackFX_SetNamedConfigParm then
            stateOK = reaper.TrackFX_SetNamedConfigParm(track, fxIndex, "vst_chunk", encodeBase64(chunk))
            stateMessage = stateOK and "VST2 state chunk loaded" or "REAPER rejected the embedded VST2 state chunk"
          else stateMessage = "Embedded VST2 state chunk is incomplete" end
        else
          stateMessage = "Embedded VST2 state is not a chunk preset; parameter values will be restored where available"
        end
      end
    else stateMessage = "Embedded plug-in state file is missing" end
  end
  local mappedParams = applyPluginParameters(track, fxIndex, device)
  for parameterId, parameterIndex in pairs(mappedParams) do
    automationTargets[parameterId] = {track=track, fxIndex=fxIndex, paramIndex=parameterIndex, type="fx"}
  end
  local enabled = xmlFind(device, "Enabled")
  if enabled then reaper.TrackFX_SetEnabled(track, fxIndex, attrBool(enabled, "value")) end
  if reaper.TrackFX_Show then
    reaper.TrackFX_Show(track, fxIndex, 2)
    reaper.TrackFX_Show(track, fxIndex, 0)
  end
  if stateOK then pluginImportCounts.loaded = pluginImportCounts.loaded + 1 else pluginImportCounts.failed = pluginImportCounts.failed + 1 end
  log("Plug-in import: " .. plugName .. " on " .. trackName .. "; " .. stateMessage)
end
local function importChannelPlugins(track, channel, unpackDir, trackName, automationTargets)
  local devices = channel and xmlFind(channel, "Devices")
  for _, device in ipairs(xmlChildren(devices)) do importPluginDevice(track, device, unpackDir, trackName, automationTargets) end
end
local function zipExtract(archive, destination)
  reaper.RecursiveCreateDirectory(destination, 0)
  local listing
  if isWindows then
    local tarExe = joinPath(os.getenv("WINDIR") or "C:\\Windows", "System32\\tar.exe")
    listing = checkExec("Inspect DAWproject archive", reaper.ExecProcess(winarg(tarExe) .. " -tf " .. winarg(archive), 0))
    for entry in listing:gmatch("([^\r\n]+)") do
      if not safeArchivePath(entry) then error("Archive contains an unsafe path: " .. entry) end
    end
    checkExec("Extract DAWproject", reaper.ExecProcess(winarg(tarExe) .. " -xf " .. winarg(archive) .. " -C " .. winarg(destination), 0))
  else
    listing = checkExec("Inspect DAWproject archive", reaper.ExecProcess("/usr/bin/unzip -Z1 " .. posixarg(archive), 0))
    for entry in listing:gmatch("([^\r\n]+)") do
      if not safeArchivePath(entry) then error("Archive contains an unsafe path: " .. entry) end
    end
    checkExec("Extract DAWproject", reaper.ExecProcess("/usr/bin/unzip -q " .. posixarg(archive) .. " -d " .. posixarg(destination), 0))
  end
end
local function startImport(archivePath, closeWaitNotice)
  setLogLocation(archivePath)
  local ok, importedTracks, importedEvents, notes = xpcall(function()
    local archive = nativePath(archivePath or "")
    if archive == "" or not reaper.file_exists(archive) then error("The selected DAWproject file was not found") end
    if not archive:lower():match("%.dawproject$") then error("Choose a file with the .dawproject extension") end
    local seed = joinPath(logDir, "REAPER_DAWproject_import_" .. tostring(math.floor(reaper.time_precise() * 1000000)))
    local unpackDir = seed .. "_unpack"
    zipExtract(archive, unpackDir)
    local projectFile = joinPath(unpackDir, "project.xml")
    local f, readErr = io.open(projectFile, "rb"); if not f then error("The archive does not contain project.xml: " .. tostring(readErr)) end
    local xml = f:read("*a"); f:close()
    local project = parseXML(xml)
    if not project or project.tag ~= "Project" then error("project.xml could not be parsed as a DAWproject") end
    local structure = xmlFind(project, "Structure")
    local arrangement = xmlFind(project, "Arrangement")
    if not structure or not arrangement then error("The DAWproject is missing Structure or Arrangement data") end
    local tracksById, ordered, depth, masterChannel, masterTrackId = {}, {}, 0, nil, nil
    local standaloneChannelNames = {}
    for _, child in ipairs(structure.children or {}) do
      if child.tag == "Channel" and child.attr.name then standaloneChannelNames[child.attr.name:lower()] = true end
    end
    local function walkTracks(node)
      for _, child in ipairs(node.children or {}) do
        if child.tag == "Track" then
          -- A Track may contain nested Tracks. Only a Channel that is a direct
          -- child belongs to this Track; a recursive search steals a child's
          -- channel and creates phantom routing on the organizational folder.
          local roleChannel = xmlChildren(child, "Channel")[1]
          local role = roleChannel and roleChannel.attr.role or "regular"
          local childTracks = {}
          for _, sub in ipairs(child.children or {}) do if sub.tag == "Track" then childTracks[#childTracks + 1] = sub end end
          local trackName = child.attr.name or "Track"
          local isMasterTrack = role == "master" and #childTracks == 0 and
            (not next(standaloneChannelNames) or trackName:lower() == "master" or trackName:lower() == "main")
          local isStandaloneChannelPlaceholder = not roleChannel and #childTracks == 0 and standaloneChannelNames[trackName:lower()]
          if isMasterTrack then masterChannel = roleChannel; masterTrackId = child.attr.id
          elseif not isStandaloneChannelPlaceholder then
            local t = {xml=child, id=child.attr.id, name=trackName, depth=depth, channel=roleChannel,
              organizationalOnly=(not roleChannel and #childTracks > 0)}
            tracksById[t.id] = t; ordered[#ordered + 1] = t
            if #childTracks > 0 then depth = depth + 1; walkTracks({children=childTracks}); depth = depth - 1 end
          end
        end
      end
    end
    walkTracks(structure)
    -- Some DAWs serialize mixer buses and FX channels as standalone Channel
    -- nodes instead of wrapping them in Track elements.
    for _, child in ipairs(structure.children or {}) do
      if child.tag == "Channel" then
        local role = child.attr.role or "regular"
        if role == "master" then
          masterChannel, masterTrackId = child, child.attr.id
        elseif child.attr.id then
          local data = {xml={attr=child.attr, children={}}, id=child.attr.id, name=child.attr.name or "Bus", depth=0, channel=child, standaloneChannel=true}
          tracksById[data.id] = data
          ordered[#ordered + 1] = data
        end
      end
    end
    local function resolveLaneTimeUnits(node, inheritedUnit)
      local unit = inheritedUnit
      if node.tag == "Lanes" then
        unit = node.attr.timeUnit or inheritedUnit or "beats"
        node._resolvedTimeUnit = unit
      end
      for _, child in ipairs(node.children or {}) do resolveLaneTimeUnits(child,unit) end
    end
    resolveLaneTimeUnits(arrangement,"beats")
    local laneMap = {}
    for _, lane in ipairs(xmlAll(arrangement, "Lanes")) do
      local id = lane.attr.track
      if id and (tracksById[id] or id == masterTrackId) then
        laneMap[id] = laneMap[id] or {}
        lane._importLaneIndex = #laneMap[id]
        laneMap[id][#laneMap[id] + 1] = lane
      end
    end
    -- All archive entries are resolved before changing the open project.
    local clipRecords, midiRecords = {}, {}
    for _, tr in ipairs(ordered) do
      for _, lane in ipairs(laneMap[tr.id] or {}) do
        local function collectMidi(node, topClip)
          if node.tag == "Clip" and not topClip then topClip = node end
          if node.tag == "Notes" then
            local notes = {}
            for _, note in ipairs(xmlChildren(node,"Note")) do
              notes[#notes + 1] = {time=attrNumber(note,"time",0), duration=attrNumber(note,"duration",0.25), key=attrNumber(note,"key",60), velocity=math.floor(attrNumber(note,"vel",1)*127+0.5), channel=attrNumber(note,"channel",0)}
            end
            if #notes > 0 then midiRecords[#midiRecords + 1] = {track=tr, laneIndex=lane._importLaneIndex or 0, beat=attrNumber(topClip,"time",0), timeUnit=lane._resolvedTimeUnit or lane.attr.timeUnit or "beats", duration=attrNumber(topClip,"duration",0), name=topClip.attr.name or tr.name, notes=notes} end
          end
          for _, child in ipairs(node.children or {}) do collectMidi(child,topClip) end
        end
        collectMidi(lane,nil)
        local function visitClips(node, topClip)
          if node.tag == "Clip" and not topClip then topClip = node end
          if node.tag == "Audio" or node.tag == "Video" then
            local fileNode = xmlFind(node,"File")
            if fileNode and fileNode.attr.path then
              local rel = fileNode.attr.path:gsub("/", pathSep)
              if not safeArchivePath(rel) then error("The archive contains an unsafe media path") end
              local source = joinPath(unpackDir, rel)
              if reaper.file_exists(source) then
                local shownName = topClip and topClip.attr.name or basename(source)
                local warpData, warps = xmlFind(topClip,"Warps"), {}
                local clipContents = xmlFind(topClip,"Clips")
                local contentClip = xmlChildren(clipContents,"Clip")[1]
                local duration = attrNumber(topClip,"duration",0)
                local durationSeconds
                local playStart = attrNumber(topClip,"playStart",nil)
                local playStop = attrNumber(topClip,"playStop",nil)
                if duration <= 0 and playStart ~= nil and playStop ~= nil and playStop > playStart and topClip.attr.contentTimeUnit == "seconds" then
                  durationSeconds = playStop - playStart
                end
                local warpUnit = (warpData and warpData.attr.timeUnit) or (clipContents and clipContents.attr.timeUnit) or
                  (contentClip and contentClip.attr.contentTimeUnit) or topClip.attr.contentTimeUnit or "beats"
                for _, warp in ipairs(xmlChildren(warpData,"Warp")) do
                  warps[#warps + 1] = {beat=attrNumber(warp,"time",0), source=attrNumber(warp,"contentTime",0)}
                end
                clipRecords[#clipRecords + 1] = {track=tr, laneIndex=lane._importLaneIndex or 0, source=source, mediaType=node.tag:lower(), algorithm=node.attr.algorithm, name=shownName, beat=attrNumber(topClip,"time",0), timeUnit=lane._resolvedTimeUnit or lane.attr.timeUnit or "beats", duration=duration, durationSeconds=durationSeconds, playStart=playStart, playStop=playStop, playUnit=topClip.attr.contentTimeUnit, warpUnit=warpUnit, muted=topClip and topClip.attr.enable == "false", fadeIn=attrNumber(topClip,"fadeInTime",0), fadeOut=attrNumber(topClip,"fadeOutTime",0), fadeUnit=topClip and topClip.attr.fadeTimeUnit or "beats", loop=topClip and topClip.attr.loopEnd ~= nil, loopStart=attrNumber(topClip,"loopStart",nil), loopEnd=attrNumber(topClip,"loopEnd",nil), warps=warps}
              elseif rel:match("^audio[/\\]") or rel:match("^video[/\\]") then error("Media file is missing from the archive: " .. rel) end
            end
          end
          for _, child in ipairs(node.children or {}) do visitClips(child,topClip) end
        end
        visitClips(lane,nil)
      end
    end
    local tempoPoints, signaturePoints = {}, {}
    for _, point in ipairs(xmlAll(arrangement, "TempoAutomation")) do
      local pointUnit = point.attr.timeUnit or (point.attr.unit == "seconds" and "seconds") or "beats"
      for _, child in ipairs(xmlAll(point, "RealPoint")) do tempoPoints[#tempoPoints + 1] = {time=attrNumber(child,"time",0), timeUnit=pointUnit, bpm=attrNumber(child,"value",120), linear=child.attr.interpolation == "linear"} end
    end
    for _, point in ipairs(xmlAll(arrangement, "TimeSignatureAutomation")) do
      local pointUnit = point.attr.timeUnit or (point.attr.unit == "seconds" and "seconds") or "beats"
      for _, child in ipairs(xmlAll(point, "TimeSignaturePoint")) do
        local numeratorPoint, denominatorPoint = attrNumber(child,"numerator",0), attrNumber(child,"denominator",0)
        if numeratorPoint > 0 and denominatorPoint > 0 then signaturePoints[#signaturePoints + 1] = {time=attrNumber(child,"time",0), timeUnit=pointUnit, numerator=numeratorPoint, denominator=denominatorPoint} end
      end
    end
    local transport = xmlFind(project, "Transport")
    local tempoNode = transport and xmlFind(transport,"Tempo")
    local sigNode = transport and xmlFind(transport,"TimeSignature")
    local baseTempo = attrNumber(tempoNode,"value",120)
    local numerator, denominator = attrNumber(sigNode,"numerator",4), attrNumber(sigNode,"denominator",4)
    local tempoEvents = {}
    local function getTempoEvent(time, timeUnit)
      for _, event in ipairs(tempoEvents) do if event.timeUnit == timeUnit and math.abs(event.time - time) < 0.0000001 then return event end end
      local event = {time=time, timeUnit=timeUnit}
      tempoEvents[#tempoEvents + 1] = event
      return event
    end
    for _, point in ipairs(tempoPoints) do
      local event = getTempoEvent(point.time,point.timeUnit)
      event.bpm, event.linear = point.bpm, point.linear
    end
    for _, point in ipairs(signaturePoints) do
      local event = getTempoEvent(point.time,point.timeUnit)
      event.numerator, event.denominator = point.numerator, point.denominator
    end
    table.sort(tempoEvents, function(a,b)
      if a.timeUnit == b.timeUnit then return a.time < b.time end
      if a.time <= 0 or b.time <= 0 then return a.time < b.time end
      return a.timeUnit == "seconds"
    end)
    log("Import tempo map: " .. #tempoPoints .. " tempo points; " .. #signaturePoints .. " time-signature points")
    local regions = {}
    for _, mark in ipairs(xmlAll(arrangement,"Marker")) do regions[#regions + 1] = {beat=attrNumber(mark,"time",0), name=mark.attr.name or "Marker"} end
    -- REAPER's undo block keeps the replacement as one reversible operation.
    reaper.Undo_BeginBlock2(proj); reaper.PreventUIRefresh(1)
    local autoCrossfadeState = reaper.GetToggleCommandStateEx(0, 40041)
    if autoCrossfadeState == 1 then reaper.Main_OnCommand(40041, 0) end
    local editOk, editError = xpcall(function()
    for i = reaper.CountTracks(proj)-1, 0, -1 do reaper.DeleteTrack(reaper.GetTrack(proj,i)) end
    for i = reaper.CountProjectMarkers(proj)-1, 0, -1 do
      local rv, isRegion, pos, rgnEnd, name, idx = reaper.EnumProjectMarkers3(proj,i)
      if rv then reaper.DeleteProjectMarker(proj, idx, isRegion) end
    end
    for i = reaper.CountTempoTimeSigMarkers(proj)-1, 0, -1 do reaper.DeleteTempoTimeSigMarker(proj,i) end
    if not reaper.SetTempoTimeSigMarker(proj,-1,0,0,0,baseTempo,numerator,denominator,false) then
      log("REAPER rejected the DAWproject base tempo and time signature")
    end
    local currentTempo, currentNumerator, currentDenominator = baseTempo, numerator, denominator
    for _, p in ipairs(tempoEvents) do
      if p.bpm then currentTempo = p.bpm end
      if p.numerator then currentNumerator, currentDenominator = p.numerator, p.denominator end
      local linear = p.linear or false
      if p.time <= 0 then
        if not reaper.SetTempoTimeSigMarker(proj,0,0,0,0,currentTempo,currentNumerator,currentDenominator,linear) then
          log("REAPER rejected the tempo map point at beat 0")
        end
      else
        local timePosition = p.timeUnit == "seconds" and p.time or reaper.TimeMap2_QNToTime(proj,p.time)
        if not reaper.SetTempoTimeSigMarker(proj,-1,timePosition,-1,-1,currentTempo,p.numerator or 0,p.denominator or 0,linear) then
          log("REAPER rejected the tempo map point at " .. tostring(p.time) .. " " .. p.timeUnit)
        end
      end
    end
    local made, channelTracks, automationIDs, pluginAutomationTargets = {}, {}, {}, {}
    local masterTrack = reaper.GetMasterTrack(proj)
    if #tempoPoints > 0 and reaper.GetTrackEnvelopeByName and reaper.GetSetEnvelopeInfo_String then
      local tempoEnvelope = reaper.GetTrackEnvelopeByName(masterTrack,"Tempo map")
      if tempoEnvelope then reaper.GetSetEnvelopeInfo_String(tempoEnvelope,"ACTIVE","1",true) end
    end
    if masterChannel and masterChannel.attr.id then channelTracks[masterChannel.attr.id] = masterTrack end
    if masterChannel then
      local vol, pan, mute = xmlFind(masterChannel,"Volume"), xmlFind(masterChannel,"Pan"), xmlFind(masterChannel,"Mute")
      automationIDs[masterTrackId] = {}
      if vol and vol.attr.id then automationIDs[masterTrackId][vol.attr.id] = "Volume" end
      if pan and pan.attr.id then automationIDs[masterTrackId][pan.attr.id] = "Pan" end
      if mute and mute.attr.id then automationIDs[masterTrackId][mute.attr.id] = "Mute" end
      if vol then reaper.SetMediaTrackInfo_Value(masterTrack,"D_VOL",attrNumber(vol,"value",1)) end
      if pan then reaper.SetMediaTrackInfo_Value(masterTrack,"D_PAN",attrNumber(pan,"value",0.5)*2-1) end
      if mute then reaper.SetMediaTrackInfo_Value(masterTrack,"B_MUTE",attrBool(mute,"value") and 1 or 0) end
    end
    for _, data in ipairs(ordered) do
      local insertAt = reaper.CountTracks(proj)
      reaper.InsertTrackAtIndex(insertAt, true)
      local tr = reaper.GetTrack(proj, insertAt)
      if not tr then error("REAPER could not create track: " .. data.name) end
      made[data.id] = tr
      reaper.GetSetMediaTrackInfo_String(tr,"P_NAME",data.name,true)
      if data.xml.attr.color then reaper.SetTrackColor(tr, xmlColor(data.xml.attr.color)) end
      local channel = data.channel
      if channel then
        if channel.attr.id then channelTracks[channel.attr.id] = tr end
        local vol, pan, mute = xmlFind(channel,"Volume"), xmlFind(channel,"Pan"), xmlFind(channel,"Mute")
        automationIDs[data.id] = {}
        if vol and vol.attr.id then automationIDs[data.id][vol.attr.id] = "Volume" end
        if pan and pan.attr.id then automationIDs[data.id][pan.attr.id] = "Pan" end
        if mute and mute.attr.id then automationIDs[data.id][mute.attr.id] = "Mute" end
        if vol then reaper.SetMediaTrackInfo_Value(tr,"D_VOL",attrNumber(vol,"value",1)) end
        if pan then reaper.SetMediaTrackInfo_Value(tr,"D_PAN",attrNumber(pan,"value",0.5)*2-1) end
        if mute then reaper.SetMediaTrackInfo_Value(tr,"B_MUTE",attrBool(mute,"value") and 1 or 0) end
        if channel.attr.solo == "true" then reaper.SetMediaTrackInfo_Value(tr,"I_SOLO",1) end
      end
    end
    for i, data in ipairs(ordered) do
      local nextDepth = ordered[i+1] and ordered[i+1].depth or 0
      local delta = nextDepth - data.depth
      reaper.SetMediaTrackInfo_Value(made[data.id],"I_FOLDERDEPTH",delta > 0 and 1 or (delta < 0 and delta or 0))
    end
    local laneCounts = {}
    for _, data in ipairs(ordered) do
      local count = #(laneMap[data.id] or {})
      laneCounts[data.id] = count
      if count > 1 then
        local tr = made[data.id]
        reaper.SetMediaTrackInfo_Value(tr,"I_FREEMODE",2)
        reaper.SetMediaTrackInfo_Value(tr,"I_NUMFIXEDLANES",count)
        if reaper.UpdateTimeline then reaper.UpdateTimeline() end
      end
    end
    pluginImportCounts = {loaded=0, missing=0, failed=0}
    for _, data in ipairs(ordered) do importChannelPlugins(made[data.id], data.channel, unpackDir, data.name, pluginAutomationTargets) end
    if masterChannel then importChannelPlugins(masterTrack, masterChannel, unpackDir, "Master", pluginAutomationTargets) end
    local archiveName = basename(archive):gsub("%.[^%.]+$", "")
    if archiveName == "" then archiveName = "DAWproject" end
    local projectFolder = reaper.GetProjectPathEx(proj)
    if not projectFolder or projectFolder == "" then projectFolder = parentPath(archive) end
    local destRoot = joinPath(projectFolder, archiveName .. "_Media")
    reaper.RecursiveCreateDirectory(destRoot,0)
    local copiedMedia = {}
    for _, clip in ipairs(clipRecords) do
      local dest = copiedMedia[clip.source]
      if not dest then
        local mediaName = safeName(basename(clip.source))
        dest = joinPath(destRoot, mediaName)
        local suffix = 1
        while reaper.file_exists(dest) do
          dest = joinPath(destRoot, tostring(suffix) .. "_" .. mediaName)
          suffix = suffix + 1
        end
        copyFile(clip.source,dest)
        copiedMedia[clip.source] = dest
      end
      local tr = made[clip.track.id]
      local clipBeat = clip.timeUnit == "seconds" and reaper.TimeMap2_timeToQN(proj,clip.beat) or clip.beat
      local startTime = clip.timeUnit == "seconds" and clip.beat or reaper.TimeMap2_QNToTime(proj,clipBeat)
      local oldCursor = reaper.GetCursorPositionEx(proj); reaper.SetEditCurPos2(proj,startTime,false,false)
        reaper.SelectAllMediaItems(proj,false); reaper.SetOnlyTrackSelected(tr); reaper.InsertMedia(dest,0)
      local item = reaper.GetSelectedMediaItem(proj,0)
      if item then
        reaper.SetMediaItemInfo_Value(item,"C_BEATATTACHMODE",0)
        reaper.SetMediaItemInfo_Value(item,"C_AUTOSTRETCH",0)
        if (laneCounts[clip.track.id] or 0) > 1 then reaper.SetMediaItemInfo_Value(item,"I_FIXEDLANE",clip.laneIndex or 0) end
        reaper.SetMediaItemInfo_Value(item,"D_POSITION",startTime)
        if clip.duration > 0 then
          local itemLength = clip.timeUnit == "seconds" and clip.duration or (reaper.TimeMap2_QNToTime(proj,clipBeat+clip.duration)-startTime)
          reaper.SetMediaItemInfo_Value(item,"D_LENGTH",itemLength)
        elseif clip.durationSeconds and clip.durationSeconds > 0 then
          reaper.SetMediaItemInfo_Value(item,"D_LENGTH",clip.durationSeconds)
        end
        if clip.muted then reaper.SetMediaItemInfo_Value(item,"B_MUTE",1) end
        if clip.loop then reaper.SetMediaItemInfo_Value(item,"B_LOOPSRC",1) end
        if clip.fadeIn > 0 then
          local fadeInSeconds = clip.fadeUnit == "seconds" and clip.fadeIn or (reaper.TimeMap2_QNToTime(proj,clipBeat+clip.fadeIn)-startTime)
          reaper.SetMediaItemInfo_Value(item,"D_FADEINLEN",fadeInSeconds)
        end
        if clip.fadeOut > 0 and (clip.duration > 0 or clip.durationSeconds) then
          local fadeOutSeconds = clip.fadeOut
          if clip.fadeUnit ~= "seconds" then
            if clip.duration > 0 then
              local endBeat = clip.timeUnit == "seconds" and reaper.TimeMap2_timeToQN(proj,startTime+clip.duration) or (clipBeat + clip.duration)
              fadeOutSeconds = reaper.TimeMap2_QNToTime(proj,endBeat)-reaper.TimeMap2_QNToTime(proj,math.max(clipBeat,endBeat-clip.fadeOut))
            else
              local itemLength = reaper.GetMediaItemInfo_Value(item,"D_LENGTH")
              local endBeat = reaper.TimeMap2_timeToQN(proj,startTime+itemLength)
              fadeOutSeconds = reaper.TimeMap2_QNToTime(proj,endBeat)-reaper.TimeMap2_QNToTime(proj,math.max(clipBeat,endBeat-clip.fadeOut))
            end
          end
          reaper.SetMediaItemInfo_Value(item,"D_FADEOUTLEN",fadeOutSeconds)
        end
        local take = reaper.GetActiveTake(item)
        if take then
          reaper.GetSetMediaItemTakeInfo_String(take,"P_NAME",clip.name,true)
          local autoStretchMarkers = reaper.GetTakeNumStretchMarkers and reaper.GetTakeNumStretchMarkers(take) or 0
          if autoStretchMarkers > 0 and reaper.DeleteTakeStretchMarkers then
            reaper.DeleteTakeStretchMarkers(take,0,autoStretchMarkers)
          end
          table.sort(clip.warps, function(a, b) return a.beat < b.beat end)
          local itemLength = reaper.GetMediaItemInfo_Value(item,"D_LENGTH")
          local hasPlaybackRange = clip.playStart ~= nil and clip.warpUnit == "seconds" and clip.playUnit == "seconds"
          local selectionStart = hasPlaybackRange and clip.playStart or 0
          local selectionStop = hasPlaybackRange and (clip.playStop or (selectionStart + itemLength)) or itemLength
          local warpSpeed = 1
          local function sourceAt(warpTime)
            local count = #clip.warps
            if count == 0 then return warpTime end
            if count == 1 then return clip.warps[1].source + (warpTime-clip.warps[1].beat) end
            local left, right = clip.warps[1], clip.warps[2]
            if warpTime >= clip.warps[count].beat then
              left, right = clip.warps[count-1], clip.warps[count]
            else
              for wi = 1, count-1 do
                if warpTime <= clip.warps[wi+1].beat then left, right = clip.warps[wi], clip.warps[wi+1]; break end
              end
            end
            local span = right.beat-left.beat
            if math.abs(span) < 0.0000001 then return left.source end
            return left.source + (warpTime-left.beat)*(right.source-left.source)/span
          end
          local function warpBaseRate()
            if #clip.warps < 2 then return nil end
            local firstWarp, lastWarp = clip.warps[1], clip.warps[#clip.warps]
            local warpStartTime, warpEndTime
            if clip.warpUnit == "seconds" then
              warpStartTime, warpEndTime = firstWarp.beat, lastWarp.beat
            else
              warpStartTime = reaper.TimeMap2_QNToTime(proj,clipBeat + firstWarp.beat)
              warpEndTime = reaper.TimeMap2_QNToTime(proj,clipBeat + lastWarp.beat)
            end
            local spanTime = warpEndTime - warpStartTime
            local spanSource = lastWarp.source - firstWarp.source
            if spanTime > 0.000001 and spanSource > 0.000001 then return spanSource / spanTime end
            return nil
          end
          local initialSource
          if hasPlaybackRange then
            initialSource = sourceAt(selectionStart)
          else
            initialSource = clip.warps[1] and clip.warps[1].beat <= 0.0000001 and clip.warps[1].source
            if initialSource == nil then initialSource = clip.playStart end
          end
          if initialSource and initialSource >= 0 then
            reaper.SetMediaItemTakeInfo_Value(take,"D_STARTOFFS",initialSource)
          end
          if hasPlaybackRange and #clip.warps > 0 then
            local rate = clip.loop and warpBaseRate() or (sourceAt(selectionStop)-sourceAt(selectionStart))/itemLength
            if rate > 0.000001 then
              warpSpeed = rate
              reaper.SetMediaItemTakeInfo_Value(take,"D_PLAYRATE",rate)
              if clip.algorithm == "stretch" then reaper.SetMediaItemTakeInfo_Value(take,"B_PPITCH",1) end
            end
          elseif #clip.warps >= 2 then
            local rate = warpBaseRate()
            if rate and rate > 0.000001 then
              warpSpeed = rate
              reaper.SetMediaItemTakeInfo_Value(take,"D_PLAYRATE",rate)
              if clip.algorithm == "stretch" then reaper.SetMediaItemTakeInfo_Value(take,"B_PPITCH",1) end
            end
          end
          for wi = 2, #clip.warps-1 do
            local warp = clip.warps[wi]
            local markerTime
            if hasPlaybackRange then
              if warp.beat > selectionStart and warp.beat < selectionStop and selectionStop > selectionStart then
                markerTime = (warp.beat-selectionStart) * itemLength / (selectionStop-selectionStart)
              end
            else
              markerTime = clip.warpUnit == "seconds" and warp.beat or (reaper.TimeMap2_QNToTime(proj,clipBeat+warp.beat)-startTime)
            end
            if markerTime then markerTime = markerTime * warpSpeed end
            local markerSource = warp.source
            if markerTime and markerTime > 0 and (markerTime < itemLength or warpSpeed > 1.000001) then
              reaper.SetTakeStretchMarker(take,-1,markerTime,markerSource)
            end
          end
        end
      end
      reaper.SetEditCurPos2(proj,oldCursor,false,false)
    end
    for _, clip in ipairs(midiRecords) do
      local startTime = clip.timeUnit == "seconds" and clip.beat or reaper.TimeMap2_QNToTime(proj,clip.beat)
      local startBeat = clip.timeUnit == "seconds" and reaper.TimeMap2_timeToQN(proj,startTime) or clip.beat
      local endTime
      if clip.duration > 0 then
        endTime = clip.timeUnit == "seconds" and (startTime + clip.duration) or reaper.TimeMap2_QNToTime(proj,clip.beat + clip.duration)
      else
        endTime = reaper.TimeMap2_QNToTime(proj,startBeat + 1)
      end
      local item = reaper.CreateNewMIDIItemInProj(made[clip.track.id],startTime,endTime,false)
      if item then
        if clip.timeUnit == "seconds" then reaper.SetMediaItemInfo_Value(item,"C_BEATATTACHMODE",0) end
        if (laneCounts[clip.track.id] or 0) > 1 then reaper.SetMediaItemInfo_Value(item,"I_FIXEDLANE",clip.laneIndex or 0) end
        local take = reaper.GetActiveTake(item)
        if take then
          reaper.GetSetMediaItemTakeInfo_String(take,"P_NAME",clip.name,true)
          for _, note in ipairs(clip.notes) do
            local n0 = reaper.TimeMap2_QNToTime(proj,startBeat + note.time)
            local n1 = reaper.TimeMap2_QNToTime(proj,startBeat + note.time + math.max(note.duration,0.001))
            reaper.MIDI_InsertNote(take,false,false,reaper.MIDI_GetPPQPosFromProjTime(take,n0),reaper.MIDI_GetPPQPosFromProjTime(take,n1),math.max(0,math.min(15,note.channel)),math.max(0,math.min(127,note.key)),math.max(1,math.min(127,note.velocity)),true)
          end
          reaper.MIDI_Sort(take)
        end
      end
    end
    for _, data in ipairs(ordered) do
      local channel = data.channel
      local sends = channel and xmlFind(channel,"Sends")
      for _, send in ipairs(xmlChildren(sends,"Send")) do
        local dest = channelTracks[send.attr.destination]
        local from = made[data.id]
        if dest and from then
          local sendIndex = reaper.CreateTrackSend(from,dest)
          local vol, pan, enable = xmlFind(send,"Volume"), xmlFind(send,"Pan"), xmlFind(send,"Enable")
          if sendIndex >= 0 then
            if vol then reaper.SetTrackSendInfo_Value(from,0,sendIndex,"D_VOL",attrNumber(vol,"value",1)) end
            if pan then reaper.SetTrackSendInfo_Value(from,0,sendIndex,"D_PAN",attrNumber(pan,"value",0.5)*2-1) end
            if enable then reaper.SetTrackSendInfo_Value(from,0,sendIndex,"B_MUTE",attrBool(enable,"value") and 0 or 1) end
            if send.attr.type == "pre" then reaper.SetTrackSendInfo_Value(from,0,sendIndex,"I_SENDMODE",1) end
          end
        end
      end
    end
    local parentChannelFor, folderStack = {}, {}
    for i, data in ipairs(ordered) do
      while #folderStack > data.depth do folderStack[#folderStack] = nil end
      local parent = folderStack[#folderStack]
      parentChannelFor[data.id] = parent and parent.channel and parent.channel.attr.id or nil
      local nextData = ordered[i + 1]
      if nextData and nextData.depth > data.depth then folderStack[#folderStack + 1] = data end
    end
    for _, data in ipairs(ordered) do
      local channel = data.channel
      local destinationId = channel and channel.attr.destination
      local from = made[data.id]
      local dest = destinationId and channelTracks[destinationId]
      -- An arrangement-only folder has no mixer channel of its own. Do not
      -- infer a mixer output for it from its children or folder hierarchy.
      if from and not data.organizationalOnly and channel and dest and dest ~= masterTrack and dest ~= from and destinationId ~= parentChannelFor[data.id] then
        local sendIndex = reaper.CreateTrackSend(from, dest)
        if sendIndex >= 0 then
          reaper.SetMediaTrackInfo_Value(from, "B_MAINSEND", 0)
          reaper.SetTrackSendInfo_Value(from, 0, sendIndex, "I_SENDMODE", 0)
          log("Imported channel output: " .. data.name .. " -> " .. tostring(destinationId))
        end
      end
    end
    local function getOrCreateTrackEnvelope(tr, kind)
      local env = reaper.GetTrackEnvelopeByName(tr, kind)
      if env then return env end
      local command = kind == "Volume" and 40406 or (kind == "Pan" and 40407 or 40408)
      local selected = {}
      for i = 0, reaper.CountSelectedTracks2(proj, true) - 1 do selected[#selected + 1] = reaper.GetSelectedTrack2(proj, i, true) end
      reaper.SetOnlyTrackSelected(tr)
      reaper.Main_OnCommand(command, 0)
      for i = 0, reaper.CountSelectedTracks2(proj, true) - 1 do reaper.SetTrackSelected(reaper.GetSelectedTrack2(proj, i, true), false) end
      for _, old in ipairs(selected) do if old then reaper.SetTrackSelected(old, true) end end
      return reaper.GetTrackEnvelopeByName(tr, kind)
    end
    local function applyAutomationLane(tr, trackId, lane)
      local envs = {}
      for _, points in ipairs(xmlAll(lane,"Points")) do
        local pointTimeUnit = (points.attr and points.attr.timeUnit) or (lane.attr and lane.attr.timeUnit) or "beats"
        local function pointTimeToSeconds(point)
          local position = attrNumber(point, "time", 0)
          return pointTimeUnit == "seconds" and position or reaper.TimeMap2_QNToTime(proj, position)
        end
        local target = xmlFind(points,"Target")
        local parameterId = target and target.attr.parameter
        if #(points.children or {}) > 1 then
          local kind = parameterId and automationIDs[trackId] and automationIDs[trackId][parameterId]
          local env = kind and (envs[kind] or getOrCreateTrackEnvelope(tr,kind))
          if kind then envs[kind] = env end
          local pluginTarget = parameterId and pluginAutomationTargets[parameterId]
          if env then
            for _, point in ipairs(points.children or {}) do
              if point.tag ~= "Target" then
                local value = attrNumber(point,"value",0)
                local atTime = pointTimeToSeconds(point)
                if kind == "Pan" then value = value * 2 - 1 end
                if kind == "Mute" then value = (point.attr.value == "true" or value >= 0.5) and 1 or 0 end
                if kind == "Volume" and reaper.ScaleToEnvelopeMode then value = reaper.ScaleToEnvelopeMode(reaper.GetEnvelopeScalingMode(env), value) end
                local shape = point.attr.interpolation == "hold" and 1 or 0
                reaper.InsertEnvelopePoint(env,atTime,value,shape,0,false,true)
              end
            end
            reaper.Envelope_SortPoints(env)
          elseif pluginTarget and pluginTarget.type == "fx" then
            local fxEnv = reaper.GetFXEnvelope(pluginTarget.track, pluginTarget.fxIndex, pluginTarget.paramIndex, true)
            if fxEnv then
              for _, point in ipairs(points.children or {}) do
                if point.tag ~= "Target" then
                  reaper.InsertEnvelopePoint(fxEnv, pointTimeToSeconds(point), attrNumber(point,"value",0), point.attr.interpolation == "hold" and 1 or 0, 0, false, true)
                end
              end
              reaper.Envelope_SortPoints(fxEnv)
            else log("Could not create plug-in automation envelope for parameter " .. tostring(parameterId)) end
          end
        end
      end
    end
    for _, data in ipairs(ordered) do
      local tr = made[data.id]
      for _, lane in ipairs(laneMap[data.id] or {}) do
        applyAutomationLane(tr, data.id, lane)
      end
    end
    for _, lane in ipairs(laneMap[masterTrackId] or {}) do applyAutomationLane(masterTrack, masterTrackId, lane) end
    for _, marker in ipairs(regions) do reaper.AddProjectMarker2(proj,false,reaper.TimeMap2_QNToTime(proj,marker.beat),0,marker.name,-1,0) end
    reaper.SetTrackSelected(reaper.GetMasterTrack(proj),false)
    end, debug.traceback)
    if autoCrossfadeState == 1 and reaper.GetToggleCommandStateEx(0, 40041) == 0 then
      reaper.Main_OnCommand(40041, 0)
    end
    reaper.PreventUIRefresh(-1); reaper.UpdateArrange(); reaper.Undo_EndBlock2(proj,"Import DAWproject",-1)
    if not editOk then error(editError) end
    reaper.ExecProcess(isWindows and ('cmd.exe /c rmdir /s /q ' .. winarg(unpackDir)) or ('/bin/rm -rf ' .. posixarg(unpackDir)),0)
    local pluginNote = "Plug-ins restored: " .. tostring(pluginImportCounts.loaded) .. "; unavailable: " .. tostring(pluginImportCounts.missing) .. "; state not restored: " .. tostring(pluginImportCounts.failed)
    return #ordered, #clipRecords + #midiRecords, pluginNote
  end, debug.traceback)
  if closeWaitNotice then gfx.quit() end
  if not ok then log("IMPORT FAILED:\r\n" .. tostring(importedTracks)); showErrorNotice("Import")
  else
    setProjectPathState("last_import_path", nativePath(archivePath))
    log(tostring(notes))
    msg("Import complete\nTracks: " .. tostring(importedTracks) .. "\nEvents: " .. tostring(importedEvents))
  end
end
local function startExport(outputPath, closeWaitNotice)
  local success, packagedTracks, packagedEvents = xpcall(function() return run(outputPath) end, debug.traceback)
  if closeWaitNotice then gfx.quit() end
  if not success then
    log("EXPORT FAILED:\r\n" .. tostring(packagedTracks))
    showErrorNotice("Export")
  elseif packagedTracks then
    local savedPath = nativePath(outputPath or "")
    if savedPath ~= "" and not savedPath:lower():match("%.dawproject$") then savedPath = savedPath .. ".dawproject" end
    if savedPath ~= "" then setProjectPathState("last_export_path", savedPath) end
    msg("Export complete\nTracks packaged: " .. tostring(packagedTracks) .. "\nEvents packaged: " .. tostring(packagedEvents or 0))
  end
end
local function displayScaleFactor()
  local scale = math.max(1, tonumber(gfx.ext_retina) or 1)
  if reaper.ThemeLayout_GetLayout then
    local ok, raw = reaper.ThemeLayout_GetLayout("global", -3)
    local dpi = ok and tonumber(raw) or nil
    if dpi and dpi >= 256 then scale = math.max(scale, dpi / 256) end
  end
  return scale
end
local function gfxIsMac()
  local osName = (reaper.GetOS() or ""):upper()
  return osName:find("OSX", 1, true) ~= nil or osName:find("MAC", 1, true) ~= nil
end
local function initHiDPIWaitWindow(width, height)
  gfx.ext_retina = 1
  gfx.init("DAWproject for REAPER", width, height, 0)
  local requestedScale = displayScaleFactor()
  if not gfxIsMac() and requestedScale > 1.01 then
    gfx.quit()
    gfx.ext_retina = 1
    gfx.init("DAWproject for REAPER", math.floor(width * requestedScale + 0.5), math.floor(height * requestedScale + 0.5), 0)
  end
  local drawScale = math.min(gfx.w / width, gfx.h / height)
  drawScale = math.max(1, drawScale)
  return drawScale, gfx.w, gfx.h
end
local function showExportWait(outputPath)
  local width, height = 480, 142
  local scale, canvasW, canvasH = initHiDPIWaitWindow(width, height)
  gfx.set(19/255, 19/255, 19/255, 1); gfx.rect(0, 0, canvasW, canvasH, 1)
  gfx.set(197/255, 160/255, 89/255, 1); gfx.rect(0, 0, 4 * scale, canvasH, 1)
  gfx.set(245/255, 245/255, 245/255, 1); gfx.setfont(1, "Arial", math.floor(20 * scale + 0.5), "b")
  local title = "Exporting project..."
  gfx.x, gfx.y = (canvasW - gfx.measurestr(title)) / 2, 38 * scale; gfx.drawstr(title)
  gfx.set(165/255, 165/255, 165/255, 1); gfx.setfont(2, "Arial", math.floor(14 * scale + 0.5))
  local detail = "Please wait while the DAWproject file is being created."
  gfx.x, gfx.y = (canvasW - gfx.measurestr(detail)) / 2, 79 * scale; gfx.drawstr(detail)
  gfx.update()
  reaper.defer(function() startExport(outputPath, true) end)
end
local function showImportWait(archivePath)
  local width, height = 480, 142
  local scale, canvasW, canvasH = initHiDPIWaitWindow(width, height)
  gfx.set(19/255, 19/255, 19/255, 1); gfx.rect(0, 0, canvasW, canvasH, 1)
  gfx.set(197/255, 160/255, 89/255, 1); gfx.rect(0, 0, 4 * scale, canvasH, 1)
  gfx.set(245/255, 245/255, 245/255, 1); gfx.setfont(1, "Arial", math.floor(20 * scale + 0.5), "b")
  local title = "Importing project..."
  gfx.x, gfx.y = (canvasW - gfx.measurestr(title)) / 2, 38 * scale; gfx.drawstr(title)
  gfx.set(165/255, 165/255, 165/255, 1); gfx.setfont(2, "Arial", math.floor(14 * scale + 0.5))
  local detail = "Please wait while the DAWproject file is being imported."
  gfx.x, gfx.y = (canvasW - gfx.measurestr(detail)) / 2, 79 * scale; gfx.drawstr(detail)
  gfx.update()
  reaper.defer(function() startImport(archivePath, true) end)
end

local outputPath = getProjectPathState("last_export_path")
local importPath = getProjectPathState("last_import_path")
local selectAll = false
local editingImport = false
local pathFocused = false
local dialogOpen = true
local aboutOpen = false
local previousMouseDown = false
local windowWidth, windowHeight = 866, 287
local uiScale, uiOffsetX, uiOffsetY = 1, 0, 0
local lastWindowW, lastWindowH = windowWidth, windowHeight
local logoHandle, logoWidth, logoHeight = -1, 0, 0
local embeddedLogoBase64 = [[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]]
local logoAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function decodeBase64(data)
  data = data:gsub("%s", "")
  local out, acc, bits = {}, 0, 0
  for i = 1, #data do
    local ch = data:sub(i, i)
    if ch ~= "=" then
      local value = logoAlphabet:find(ch, 1, true)
      if value then
        acc = (acc << 6) | (value - 1)
        bits = bits + 6
        if bits >= 8 then
          bits = bits - 8
          out[#out + 1] = string.char((acc >> bits) & 0xFF)
          acc = acc & ((1 << bits) - 1)
        end
      end
    end
  end
  return table.concat(out)
end
local logoTempPath = joinPath(logDir, "REAPER_DAWproject_logo_" .. tostring(math.floor(reaper.time_precise() * 1000000)) .. ".png")
local logoFile = io.open(logoTempPath, "wb")
if logoFile then
  local logoWritten = pcall(function() logoFile:write(decodeBase64(embeddedLogoBase64)) end)
  logoFile:close()
  if logoWritten then
    logoHandle = gfx.loadimg(1, logoTempPath)
    if logoHandle >= 0 then logoWidth, logoHeight = gfx.getimgdim(1) end
  end
  os.remove(logoTempPath)
end
gfx.ext_retina = 1
gfx.init("DAWproject for REAPER", windowWidth, windowHeight, 0)
local requestedWindowScale = displayScaleFactor()
local reportedWindowScale = math.min(gfx.w / windowWidth, gfx.h / windowHeight)
if requestedWindowScale > reportedWindowScale + 0.01 then
  gfx.init("", math.floor(windowWidth * requestedWindowScale + 0.5), math.floor(windowHeight * requestedWindowScale + 0.5))
end
lastWindowW, lastWindowH = gfx.w, gfx.h
gfx.setfont(1, "Arial", 16)

local function setColor(r, g, b, a) gfx.set(r / 255, g / 255, b / 255, a or 1) end
local function uiX(x) return uiOffsetX + x * uiScale end
local function uiY(y) return uiOffsetY + y * uiScale end
local function uiFont(index, family, size, flags)
  gfx.setfont(index, family, math.max(8, math.floor(size * uiScale + 0.5)), flags)
end
local function uiPixel(value) return math.floor(value + 0.5) end
local function uiRoundRect(x, y, w, h, radius, fill)
  gfx.roundrect(uiPixel(uiX(x)), uiPixel(uiY(y)), uiPixel(w * uiScale), uiPixel(h * uiScale), math.max(1, uiPixel(radius * uiScale)), fill)
end
local function fillRoundRect(x, y, w, h, radius, backgroundR, backgroundG, backgroundB)
  radius = math.min(radius, w / 2, h / 2)
  local sx, sy, sw, sh = uiPixel(uiX(x)), uiPixel(uiY(y)), uiPixel(w * uiScale), uiPixel(h * uiScale)
  local sr = math.min(math.max(1, uiPixel(radius * uiScale)), math.floor(sw / 2), math.floor(sh / 2))
  local fillR, fillG, fillB, fillA = gfx.r, gfx.g, gfx.b, gfx.a
  backgroundR, backgroundG, backgroundB = backgroundR or 19, backgroundG or 19, backgroundB or 19
  -- Cut square corners to the actual backdrop, then paint antialiased circles
  -- back into them. The untouched rectangle and circles form a clean union.
  gfx.rect(sx, sy, sw, sh, 1)
  setColor(backgroundR, backgroundG, backgroundB)
  gfx.rect(sx, sy, sr, sr, 1); gfx.rect(sx + sw - sr, sy, sr, sr, 1)
  gfx.rect(sx, sy + sh - sr, sr, sr, 1); gfx.rect(sx + sw - sr, sy + sh - sr, sr, sr, 1)
  setColor(fillR * 255, fillG * 255, fillB * 255, fillA)
  gfx.circle(sx + sr, sy + sr, sr, 1, 1)
  gfx.circle(sx + sw - sr, sy + sr, sr, 1, 1)
  gfx.circle(sx + sr, sy + sh - sr, sr, 1, 1)
  gfx.circle(sx + sw - sr, sy + sh - sr, sr, 1, 1)
end
local function drawLogo(x, y, w, h)
  if logoHandle < 0 or logoWidth <= 0 or logoHeight <= 0 then return end
  local scale = math.min(w / logoWidth, h / logoHeight)
  local dw, dh = logoWidth * scale, logoHeight * scale
  gfx.mode = 0
  gfx.blit(logoHandle, 1, 0, 0, 0, logoWidth, logoHeight,
           uiX(x + (w - dw) / 2), uiY(y + (h - dh) / 2), dw * uiScale, dh * uiScale)
end
local function drawButton(x, y, w, h, label, primary, hover, disabled)
  local radius = 6
  if disabled then
    setColor(19, 19, 19); fillRoundRect(x, y, w, h, radius)
    setColor(83, 83, 83); uiRoundRect(x, y, w, h, radius, 1)
    setColor(83, 83, 83); uiFont(2, "Arial", 16)
  elseif primary then
    setColor(hover and 218 or 197, hover and 179 or 160, hover and 105 or 89); fillRoundRect(x, y, w, h, radius)
    setColor(hover and 218 or 197, hover and 179 or 160, hover and 105 or 89); uiRoundRect(x, y, w, h, radius, 1)
    setColor(24, 24, 24); uiFont(2, "Arial", 16, "b")
  else
    setColor(hover and 76 or 54, hover and 76 or 54, hover and 76 or 54); fillRoundRect(x, y, w, h, radius)
    setColor(hover and 76 or 54, hover and 76 or 54, hover and 76 or 54); uiRoundRect(x, y, w, h, radius, 1)
    setColor(238, 239, 242); uiFont(2, "Arial", 16)
  end
  local tw = gfx.measurestr(label)
  gfx.x, gfx.y = uiX(x + (w - tw / uiScale) / 2), uiY(y + (h - gfx.texth / uiScale) / 2)
  gfx.drawstr(label)
end
local function drawAboutDialog(w, h)
  gfx.set(0, 0, 0, 0.62); gfx.rect(0, 0, gfx.w, gfx.h, 1)
  local panelW, panelH = 390, 229
  local x, y = (w - panelW) / 2, (h - panelH) / 2
  setColor(25, 25, 25); fillRoundRect(x, y, panelW, panelH, 7, 7, 7, 7)
  setColor(197, 160, 89); uiRoundRect(x, y, panelW, panelH, 7, 1)
  local closeX, closeY, closeSize = x + panelW - 34, y + 10, 24
  local mouseX, mouseY = (gfx.mouse_x - uiOffsetX) / uiScale, (gfx.mouse_y - uiOffsetY) / uiScale
  local closeHover = mouseX >= closeX and mouseX <= closeX + closeSize and mouseY >= closeY and mouseY <= closeY + closeSize
  setColor(closeHover and 197 or 165, closeHover and 160 or 165, closeHover and 89 or 165)
  gfx.line(uiPixel(uiX(closeX + 7)), uiPixel(uiY(closeY + 7)), uiPixel(uiX(closeX + 17)), uiPixel(uiY(closeY + 17)), 1)
  gfx.line(uiPixel(uiX(closeX + 17)), uiPixel(uiY(closeY + 7)), uiPixel(uiX(closeX + 7)), uiPixel(uiY(closeY + 17)), 1)
  setColor(238, 238, 238); uiFont(3, "Arial", 20, "b")
  local title = "© 2026 Reach the Knob"
  gfx.x, gfx.y = uiX(x + (panelW - gfx.measurestr(title) / uiScale) / 2), uiY(y + 28); gfx.drawstr(title)
  setColor(165, 165, 165); uiFont(3, "Arial", 15)
  local credit = "Developed and designed by Alex Gurev"
  gfx.x, gfx.y = uiX(x + (panelW - gfx.measurestr(credit) / uiScale) / 2), uiY(y + 63); gfx.drawstr(credit)
  local logLabel = "Enable logging"
  local logBox, logGap = 13, 9
  local logTextW, logRowH = gfx.measurestr(logLabel) / uiScale, gfx.texth / uiScale
  local logTotalW = logBox + logGap + logTextW
  local logX, logY = x + (panelW - logTotalW) / 2, y + 93
  local boxX = uiPixel(uiX(logX))
  local boxY = uiPixel(uiY(logY + (logRowH - logBox) / 2))
  local boxSize = math.max(1, uiPixel(logBox * uiScale))
  setColor(125, 125, 125); gfx.rect(boxX, boxY, boxSize, boxSize, 0)
  if loggingEnabled then
    local inset = math.min(math.max(1, uiPixel(2 * uiScale)), math.floor((boxSize - 1) / 2))
    setColor(197, 160, 89); gfx.rect(boxX + inset, boxY + inset, boxSize - inset * 2, boxSize - inset * 2, 1)
  end
  setColor(165, 165, 165); gfx.x, gfx.y = uiX(logX + logBox + logGap), uiY(logY); gfx.drawstr(logLabel)
  setColor(197, 160, 89)
  local email = "alex.v.gurev@gmail.com"
  local emailW = gfx.measurestr(email) / uiScale
  local emailX = x + (panelW - emailW) / 2
  gfx.x, gfx.y = uiX(emailX), uiY(y + 123); gfx.drawstr(email)
  setColor(165, 165, 165); uiFont(3, "Arial", 15)
  local version = "Version 1.1"
  gfx.x, gfx.y = uiX(x + (panelW - gfx.measurestr(version) / uiScale) / 2), uiY(y + 183); gfx.drawstr(version)
  setColor(197, 160, 89); uiFont(3, "Arial", 15, "u")
  local youtube, donation = "YouTube", "Donation"
  local youtubeW, donationW = gfx.measurestr(youtube), gfx.measurestr(donation)
  local linkGap, totalW = 34, (youtubeW + donationW) / uiScale + 34
  local linkY = y + 153
  local youtubeX = x + (panelW - totalW) / 2
  local donationX = youtubeX + youtubeW / uiScale + linkGap
  gfx.x, gfx.y = uiX(youtubeX), uiY(linkY); gfx.drawstr(youtube)
  gfx.x, gfx.y = uiX(donationX), uiY(linkY); gfx.drawstr(donation)
  return x, y, panelW, panelH, youtubeX, linkY, youtubeW / uiScale, donationX, donationW / uiScale,
    closeX, closeY, closeSize, emailX, y + 123, emailW, logX, logY, logTotalW, logRowH
end

local function drawOutputDialog()
  if not dialogOpen then return end
  local key, unicode = gfx.getchar()
  if key < 0 then dialogOpen = false; gfx.quit(); return end
  while key > 0 do
    if key == 27 then
      if aboutOpen then aboutOpen = false else dialogOpen = false; gfx.quit(); return end
    elseif key == 13 and not aboutOpen then
      dialogOpen = false; gfx.quit(); if editingImport then showImportWait(importPath) else showExportWait(outputPath) end; return
    elseif aboutOpen then
    elseif key == 1 and pathFocused then
      selectAll = true
    elseif key == 22 and pathFocused and reaper.CF_GetClipboard then
      local clip = reaper.CF_GetClipboard()
      if clip and clip ~= "" then if editingImport then importPath = clip else outputPath = clip; overwriteApprovedPath = nil end; selectAll = false end
    elseif (key == 8 or key == 127) and pathFocused then
      local current = editingImport and importPath or outputPath
      if selectAll then current = ""; selectAll = false
      elseif #current > 0 then current = current:sub(1, utf8PrevByte(current, #current + 1) - 1) end
      if editingImport then importPath = current else outputPath = current; overwriteApprovedPath = nil end
    elseif pathFocused then
      local codepoint = unicode or 0
      if codepoint == 0 then
        if key >= 0x75000000 then codepoint = key & 0x00FFFFFF
        elseif key >= 32 and key < 0x110000 then codepoint = key end
      end
      if codepoint >= 32 then
        local current = editingImport and importPath or outputPath
        if selectAll then current = ""; selectAll = false end
        local ok, character = pcall(utf8.char, codepoint)
        if ok then current = current .. character end
        if editingImport then importPath = current else outputPath = current; overwriteApprovedPath = nil end
      end
    end
    key, unicode = gfx.getchar()
  end

  -- Keep the floating window at the designed aspect ratio. gfx.init with an
  -- empty title resizes the already-open gfx window without reopening it.
  local observedW, observedH = gfx.w, gfx.h
  local targetAspect = windowWidth / windowHeight
  if observedW > 0 and observedH > 0 and (observedW ~= lastWindowW or observedH ~= lastWindowH) and
     math.abs(observedW / observedH - targetAspect) > 0.006 then
    local widthChange = math.abs(observedW - lastWindowW) / windowWidth
    local heightChange = math.abs(observedH - lastWindowH) / windowHeight
    local targetW, targetH
    if widthChange >= heightChange then
      targetW = math.max(600, observedW)
      targetH = math.floor(targetW / targetAspect + 0.5)
    else
      targetH = math.max(190, observedH)
      targetW = math.floor(targetH * targetAspect + 0.5)
    end
    gfx.init("", targetW, targetH)
  end
  lastWindowW, lastWindowH = gfx.w, gfx.h

  local pixelW, pixelH = gfx.w, gfx.h
  uiScale = math.min(pixelW / windowWidth, pixelH / windowHeight)
  uiOffsetX, uiOffsetY = (pixelW - windowWidth * uiScale) / 2, (pixelH - windowHeight * uiScale) / 2
  local w, h = windowWidth, windowHeight
  setColor(19, 19, 19); gfx.rect(0, 0, pixelW, pixelH, 1)
  setColor(197, 160, 89); gfx.rect(uiX(0), uiY(0), 4 * uiScale, h * uiScale, 1)
  local logoX, logoY, logoW, logoH = 34, 12, 78, 78
  local titleX, titleY = 142, 30
  setColor(245, 245, 245); uiFont(1, "Arial", 25, "b")
  local titleHeight = gfx.texth / uiScale
  gfx.x, gfx.y = uiX(titleX), uiY(titleY); gfx.drawstr("DAWproject for REAPER")
  local subtitleY = titleY + titleHeight + 4
  setColor(105, 105, 105); uiFont(1, "Arial", 15)
  gfx.x, gfx.y = uiX(titleX), uiY(subtitleY); gfx.drawstr("Import a DAWproject or export the current REAPER project")
  local subtitleHeight = gfx.texth / uiScale
  drawLogo(logoX, logoY, logoW, logoH)

  local fieldX, fieldH = 34, 40
  local buttonW, browseW, gap, rightPad = 130, 130, 12, 30
  local actionX = w - rightPad - buttonW
  local browseX = actionX - gap - browseW
  local fieldW = browseX - gap - fieldX
  local importRowY = subtitleY + subtitleHeight + 55
  local exportRowY = h - 30 - fieldH
  local aboutPanel, youtubeLink, donationLink, aboutClose, emailLink, aboutLogToggle
  if aboutOpen then
    local ax, ay, aw, ah, yx, ly, yw, dx, dw, cx, cy, cs, ex, ey, ew, tx, ty, tw, th = drawAboutDialog(w, h)
    aboutPanel = {ax, ay, aw, ah}; youtubeLink = {yx, ly, yw, 20}; donationLink = {dx, ly, dw, 20}
    aboutClose = {cx, cy, cs, cs}
    emailLink = {ex, ey, ew, 20}
    aboutLogToggle = {tx, ty, tw, th}
  else

  local function drawFileRow(label, path, y, isImport)
    setColor(197, 160, 89); uiFont(1, "Arial", 15, "b")
    gfx.x, gfx.y = uiX(34), uiY(y - 25); gfx.drawstr(label)
    local fieldY = y
    setColor(21, 21, 21); fillRoundRect(fieldX, fieldY, fieldW, fieldH, 6)
    if selectAll and editingImport == isImport then setColor(60, 52, 36); fillRoundRect(fieldX + 2, fieldY + 2, fieldW - 4, fieldH - 4, 5, 21, 21, 21) end
    setColor(197, 160, 89, 0.9); uiRoundRect(fieldX, fieldY, fieldW, fieldH, 6, 1)
    local shown, availableTextWidth = path, fieldW - 24
    setColor(197, 197, 197); uiFont(1, "Arial", 15)
    while #shown > 0 and gfx.measurestr(shown) > availableTextWidth * uiScale do shown = shown:sub(utf8NextByte(shown, 1)) end
    if shown ~= path then shown = "…" .. shown end
    local textY = uiY(fieldY) + (fieldH * uiScale - gfx.texth) / 2 + uiScale
    gfx.x, gfx.y = uiX(fieldX + 12), textY; gfx.drawstr(shown, 0, uiX(fieldX + fieldW - 8), uiY(fieldY + fieldH))
    local caretX = gfx.x
    if pathFocused and editingImport == isImport and math.floor(reaper.time_precise() * 2) % 2 == 0 then
      setColor(220, 220, 220); gfx.line(math.min(caretX + uiScale, uiX(fieldX + fieldW - 7)), uiY(fieldY + 9), math.min(caretX + uiScale, uiX(fieldX + fieldW - 7)), uiY(fieldY + fieldH - 9))
    end
    local logicalMouseX = (gfx.mouse_x - uiOffsetX) / uiScale
    local logicalMouseY = (gfx.mouse_y - uiOffsetY) / uiScale
    local browseHover = logicalMouseX >= browseX and logicalMouseX <= browseX + browseW and logicalMouseY >= fieldY and logicalMouseY <= fieldY + fieldH
    local actionHover = logicalMouseX >= actionX and logicalMouseX <= actionX + buttonW and logicalMouseY >= fieldY and logicalMouseY <= fieldY + fieldH
    local hasPath = path:gsub("%s", "") ~= ""
    drawButton(browseX, fieldY, browseW, fieldH, "Browse…", false, browseHover)
    drawButton(actionX, fieldY, buttonW, fieldH, isImport and "Import" or "Export", true, actionHover, not hasPath)
  end
  drawFileRow("DAWproject file to import:", importPath, importRowY, true)
  drawFileRow("Output DAWproject file:", outputPath, exportRowY, false)
  end
  if aboutOpen then
    local hoverX, hoverY = (gfx.mouse_x - uiOffsetX) / uiScale, (gfx.mouse_y - uiOffsetY) / uiScale
    local function inside(link)
      return link and hoverX >= link[1] and hoverX <= link[1] + link[3] and hoverY >= link[2] and hoverY <= link[2] + link[4]
    end
    if inside(emailLink) or inside(youtubeLink) or inside(donationLink) or inside(aboutLogToggle) then gfx.setcursor(32649, "hand")
    else gfx.setcursor(32512, "arrow") end
  else
    gfx.setcursor(32512, "arrow")
  end
  gfx.update()

  local mouseDown = (gfx.mouse_cap & 1) ~= 0
  if mouseDown and not previousMouseDown then
    local mx, my = (gfx.mouse_x - uiOffsetX) / uiScale, (gfx.mouse_y - uiOffsetY) / uiScale
    if aboutOpen then
      if aboutClose and mx >= aboutClose[1] and mx <= aboutClose[1] + aboutClose[3] and my >= aboutClose[2] and my <= aboutClose[2] + aboutClose[4] then
        aboutOpen = false
      elseif aboutLogToggle and mx >= aboutLogToggle[1] and mx <= aboutLogToggle[1] + aboutLogToggle[3] and my >= aboutLogToggle[2] and my <= aboutLogToggle[2] + aboutLogToggle[4] then
        setLoggingEnabled(not loggingEnabled)
      elseif emailLink and mx >= emailLink[1] and mx <= emailLink[1] + emailLink[3] and my >= emailLink[2] and my <= emailLink[2] + emailLink[4] then
        openExternalURL("mailto:alex.v.gurev@gmail.com")
      elseif youtubeLink and mx >= youtubeLink[1] and mx <= youtubeLink[1] + youtubeLink[3] and my >= youtubeLink[2] and my <= youtubeLink[2] + youtubeLink[4] then
        openExternalURL("https://www.youtube.com/@reachtheknob")
      elseif donationLink and mx >= donationLink[1] and mx <= donationLink[1] + donationLink[3] and my >= donationLink[2] and my <= donationLink[2] + donationLink[4] then
        openExternalURL("https://boosty.to/alex_hius")
      elseif not aboutPanel or mx < aboutPanel[1] or mx > aboutPanel[1] + aboutPanel[3] or my < aboutPanel[2] or my > aboutPanel[2] + aboutPanel[4] then
        aboutOpen = false
      end
    elseif mx >= logoX and mx <= logoX + logoW and my >= logoY and my <= logoY + logoH then
      aboutOpen = true
    elseif my >= importRowY and my <= importRowY + fieldH and mx >= browseX and mx <= browseX + browseW then
      editingImport = true; pathFocused = true
      local ok, chosen = reaper.GetUserFileName(1, "Choose DAWproject to import", importPath, "DAWproject files|*.dawproject|All files|*.*")
      if ok and chosen and chosen ~= "" then importPath = chosen; selectAll = false end
    elseif my >= exportRowY and my <= exportRowY + fieldH and mx >= browseX and mx <= browseX + browseW then
      editingImport = false; pathFocused = true
      overwriteApprovedPath = nil
      local ok, chosen = reaper.GetUserFileName(0, "Choose DAWproject output", outputPath, "DAWproject files|*.dawproject|All files|*.*")
      if ok and chosen and chosen ~= "" then
        outputPath = chosen; selectAll = false
        local approvedCandidate = nativePath(chosen)
        if not approvedCandidate:lower():match("%.dawproject$") then approvedCandidate = approvedCandidate .. ".dawproject" end
        if reaper.file_exists(approvedCandidate) then overwriteApprovedPath = approvedCandidate end
      end
    elseif my >= importRowY and my <= importRowY + fieldH and mx >= actionX and mx <= actionX + buttonW and importPath:gsub("%s", "") ~= "" then
      dialogOpen = false; gfx.quit(); showImportWait(importPath); return
    elseif my >= exportRowY and my <= exportRowY + fieldH and mx >= actionX and mx <= actionX + buttonW and outputPath:gsub("%s", "") ~= "" then
      dialogOpen = false; gfx.quit(); showExportWait(outputPath); return
    elseif mx >= fieldX and mx <= fieldX + fieldW and my >= importRowY and my <= importRowY + fieldH then
      editingImport = true; pathFocused = true; selectAll = false
    elseif mx >= fieldX and mx <= fieldX + fieldW and my >= exportRowY and my <= exportRowY + fieldH then
      editingImport = false; pathFocused = true; selectAll = false
    end
  end
  previousMouseDown = mouseDown
  reaper.defer(drawOutputDialog)
end

drawOutputDialog()
