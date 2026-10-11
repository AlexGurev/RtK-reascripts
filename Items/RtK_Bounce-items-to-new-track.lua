-- @description Bounce items to new track
-- @version 1.1
-- @author Reach the Knob
-- @about
--   # Bounce items to new track
--
--   This script renders all selected media items across multiple tracks into a single combined file on a new track below the lowest involved track.
--
--   ### Key Features
--   * **Flexible signal flow:** Options to toggle track FX and take FX on/off.
--   * **Pre-fader rendering:** "Ignore track Vol/Pan" bypasses track volume, pan, mute, and solo states.
--   * **Smart mono:** Allows generating a true 1-channel file.
--   * **Safety First:** The "Delete source tracks" function is a separate undo step. Press undo once to restore tracks, press again to remove the bounce.
--   * **Memory:** The script remembers last used settings (checkbox states).
--   * **Troubleshooting:** Saves detailed operation logs in the relevant project folder.
--
-- @changelog
--   + Added automatic interface scaling based on DPI settings

--------------------------------------------------------------------------------
-- PART 1: CORE LOGIC
--------------------------------------------------------------------------------

local EXT_SECTION = "RenderSelectedItems_Mixdown_Script"
local LOG_SECTION = "RtK_BounceItemsToNewTrack"
local loggingEnabled = reaper.GetExtState(LOG_SECTION, "logging_enabled") == "1"
local logWriteWarningShown = false

local function getProjectLogPath()
    local _, projectFile = reaper.EnumProjects(-1, "", 1024)
    local folder = projectFile and projectFile ~= "" and projectFile:match("^(.*)[/\\][^/\\]+$") or nil
    if not folder or folder == "" then
        if reaper.GetProjectPathEx then
            folder = reaper.GetProjectPathEx(0)
        else
            folder = reaper.GetProjectPath()
        end
        if folder and folder ~= "" then folder = folder:gsub("[/\\]+$", "") else folder = nil end
    end
    if not folder then return nil end
    local sep = package and package.config and package.config:sub(1, 1)
    if not sep or sep == "" then
        sep = reaper.GetOS():match("Win") and "\\" or "/"
    end
    return folder .. sep .. "RtK_Bounce-items-to-new-track.log"
end

local function writeLog(message)
    if not loggingEnabled then return end
    local path = getProjectLogPath()
    if not path then
        if not logWriteWarningShown then reaper.ShowConsoleMsg("Bounce items to new track: save the project to a folder before enabling its log.\n"); logWriteWarningShown = true end
        return
    end
    local file = io.open(path, "ab")
    if file then
        file:write(os.date("[%Y-%m-%d %H:%M:%S] "), tostring(message), "\r\n")
        file:close()
    elseif not logWriteWarningShown then
        reaper.ShowConsoleMsg("Bounce items to new track: could not write the log in the project folder.\n")
        logWriteWarningShown = true
    end
end

local function setLoggingEnabled(enabled)
    enabled = not not enabled
    if loggingEnabled and not enabled then writeLog("Logging disabled") end
    loggingEnabled = enabled
    reaper.SetExtState(LOG_SECTION, "logging_enabled", enabled and "1" or "0", true)
    if enabled then writeLog("Logging enabled") end
end

local function snapshotProjectMixStates()
    local snapshot = {tracks = {}, items = {}, master = nil}
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        snapshot.tracks[track] = {
            mute = reaper.GetMediaTrackInfo_Value(track, "B_MUTE"),
            solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO")
        }
    end
    local master = reaper.GetMasterTrack(0)
    if ValidateTrack(master) then snapshot.master = reaper.GetMediaTrackInfo_Value(master, "B_MUTE") end
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        snapshot.items[item] = reaper.GetMediaItemInfo_Value(item, "B_MUTE")
    end
    return snapshot
end

local function restoreProjectMixStates(snapshot)
    if not snapshot then return end
    for track in pairs(snapshot.tracks) do
        if ValidateTrack(track) and reaper.GetMediaTrackInfo_Value(track, "I_SOLO") ~= 0 then
            reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
        end
    end
    for track, state in pairs(snapshot.tracks) do
        if ValidateTrack(track) then reaper.SetMediaTrackInfo_Value(track, "B_MUTE", state.mute) end
    end
    for item, state in pairs(snapshot.items) do
        if reaper.ValidatePtr(item, "MediaItem*") then reaper.SetMediaItemInfo_Value(item, "B_MUTE", state) end
    end
    for track, state in pairs(snapshot.tracks) do
        if ValidateTrack(track) then reaper.SetMediaTrackInfo_Value(track, "I_SOLO", state.solo) end
    end
    if snapshot.master ~= nil then
        local master = reaper.GetMasterTrack(0)
        if ValidateTrack(master) then reaper.SetMediaTrackInfo_Value(master, "B_MUTE", snapshot.master) end
    end
end

writeLog("Script session started")

function GetInvolvedTracks()
    local tracks = {}
    local item_count = reaper.CountSelectedMediaItems(0)
    if item_count == 0 then return nil end

    local min_start = math.huge
    local max_end = -math.huge
    local max_track_idx = -1
    local bottom_track = nil

    for i = 0, item_count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local track = reaper.GetMediaItem_Track(item)
        local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
        
        local it_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local it_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local it_end = it_start + it_len
        
        if it_start < min_start then min_start = it_start end
        if it_end > max_end then max_end = it_end end

        if track_idx > max_track_idx then
            max_track_idx = track_idx
            bottom_track = track
        end

        tracks[track] = true
    end

    return tracks, min_start, max_end, bottom_track
end

function ValidateTrack(track)
    return track and reaper.ValidatePtr(track, "MediaTrack*")
end

function ProcessRender(enable_track_fx, enable_take_fx, ignore_vol_pan, render_mono, delete_source)
    local selected_items_list = {}
    local item_count = reaper.CountSelectedMediaItems(0)
    for i=0, item_count-1 do
        table.insert(selected_items_list, reaper.GetSelectedMediaItem(0, i))
    end

    local involved_tracks, start_pos, end_pos, bottom_track = GetInvolvedTracks()
    if not involved_tracks then return end

    reaper.PreventUIRefresh(1)
    
    ----------------------------------------------------------------------------
    -- STEP 1: RENDER (Undo Block 1)
    ----------------------------------------------------------------------------
    reaper.Undo_BeginBlock()

    local count_tracks_before = reaper.CountTracks(0)
    
    -- 1. Set Time Selection
    local old_ts_start, old_ts_end = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    reaper.GetSet_LoopTimeRange2(0, true, false, start_pos, end_pos, false)

    -- 2. Store & Change States (FX / Mute)
    local track_fx_states = {} 
    local item_mute_states = {} 
    local take_fx_snapshot = {} 
    local track_mute_states = {}
    local track_solo_states = {}
    local master_mute_state

    if ignore_vol_pan then
        for i = 0, reaper.CountTracks(0) - 1 do
            local track = reaper.GetTrack(0, i)
            local mute = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")
            local solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO")
            track_mute_states[track], track_solo_states[track] = mute, solo
            if mute ~= 0 then reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 0) end
            if solo ~= 0 then reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0) end
        end
        local master = reaper.GetMasterTrack(0)
        if ValidateTrack(master) then
            master_mute_state = reaper.GetMediaTrackInfo_Value(master, "B_MUTE")
            if master_mute_state ~= 0 then reaper.SetMediaTrackInfo_Value(master, "B_MUTE", 0) end
        end
        for _, item in ipairs(selected_items_list) do
            local mute = reaper.GetMediaItemInfo_Value(item, "B_MUTE")
            if mute ~= 0 then
                item_mute_states[item] = mute
                reaper.SetMediaItemInfo_Value(item, "B_MUTE", 0)
            end
        end
    end

    -- A. Disable Take FX
    if not enable_take_fx then
        for _, item in ipairs(selected_items_list) do
            local take = reaper.GetActiveTake(item)
            if take then
                local key = take 
                local fx_count = reaper.TakeFX_GetCount(take)
                if fx_count > 0 then
                    take_fx_snapshot[key] = {}
                    for fx_idx = 0, fx_count - 1 do
                        local is_enabled = reaper.TakeFX_GetEnabled(take, fx_idx)
                        take_fx_snapshot[key][fx_idx] = is_enabled
                        if is_enabled then
                            reaper.TakeFX_SetEnabled(take, fx_idx, false)
                        end
                    end
                end
            end
        end
    end

    -- B. Disable Track FX & Mute Unselected Items
    for track, _ in pairs(involved_tracks) do
        if ValidateTrack(track) then
            if not enable_track_fx then
                track_fx_states[track] = reaper.GetMediaTrackInfo_Value(track, "I_FXEN")
                reaper.SetMediaTrackInfo_Value(track, "I_FXEN", 0) 
            end
            
            local item_cnt = reaper.CountTrackMediaItems(track)
            for i = 0, item_cnt - 1 do
                local item = reaper.GetTrackMediaItem(track, i)
                if not reaper.IsMediaItemSelected(item) then
                    item_mute_states[item] = reaper.GetMediaItemInfo_Value(item, "B_MUTE")
                    reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)
                end
            end
        end
    end

    -- 3. Create Summing Bus
    reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
    local bus_track = reaper.GetTrack(0, reaper.CountTracks(0)-1)
    reaper.GetSetMediaTrackInfo_String(bus_track, "P_NAME", "RENDER_TEMP_BUS", true)

    -- 4. Create Sends
    local send_mode = 0 -- Post-Fader (Default)
    if ignore_vol_pan then send_mode = 3 -- Pre-Fader (Post-FX)
    end

    for track, _ in pairs(involved_tracks) do
        if ValidateTrack(track) then
            local send_idx = reaper.CreateTrackSend(track, bus_track)
            reaper.SetTrackSendInfo_Value(track, 0, send_idx, "I_SENDMODE", send_mode)
            
            -- FIX FOR MONO VOLUME: Force Send to Mono (Sums L+R before Bus)
            if render_mono then
                reaper.SetTrackSendInfo_Value(track, 0, send_idx, "B_MONO", 1)
            end
        end
    end

    -- 5. Render (Always Stereo first)
    reaper.Main_OnCommand(40297, 0) -- Unselect all tracks
    reaper.SetTrackSelected(bus_track, true) 
    reaper.Main_OnCommand(41716, 0) -- Render selected area of tracks to STEREO stem

    -- 6. Cleanup Bus
    if ValidateTrack(bus_track) then
        reaper.DeleteTrack(bus_track)
    end

    -- 7. Process Result
    local result_track = nil
    
    local temp_result_track = reaper.GetSelectedTrack(0, 0)
    if not ValidateTrack(temp_result_track) then 
         temp_result_track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
    end

    if ValidateTrack(temp_result_track) then
        -- Handle Mono Option via Glue
        if render_mono then
            local item = reaper.GetTrackMediaItem(temp_result_track, 0)
            if item then
                local take = reaper.GetActiveTake(item)
                if take then
                    -- Set Channel Mode: 4 = Mono (Downmix)
                    reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", 4)
                    
                    -- Glue (Creates new mono file)
                    reaper.Main_OnCommand(40289, 0) 
                    reaper.SetMediaItemSelected(item, true)
                    reaper.Main_OnCommand(41588, 0)
                    
                    result_track = temp_result_track
                end
            end
        else
            result_track = temp_result_track
        end
    end

    -- 8. Move & Rename Result
    if ValidateTrack(result_track) and ValidateTrack(bottom_track) then
        reaper.SetTrackSelected(result_track, true)
        reaper.GetSetMediaTrackInfo_String(result_track, "P_NAME", "Rendered Mix", true)
        
        local bot_idx = reaper.GetMediaTrackInfo_Value(bottom_track, "IP_TRACKNUMBER")
        reaper.ReorderSelectedTracks(math.floor(bot_idx), 0)
        
        reaper.SetTrackSelected(result_track, false)
    end

    -- 9. Restore State
    reaper.GetSet_LoopTimeRange2(0, true, false, old_ts_start, old_ts_end, false)

    for track, state in pairs(track_fx_states) do
        if ValidateTrack(track) then
            reaper.SetMediaTrackInfo_Value(track, "I_FXEN", state)
        end
    end
    
    for item, state in pairs(item_mute_states) do
        if reaper.ValidatePtr(item, "MediaItem*") then
            reaper.SetMediaItemInfo_Value(item, "B_MUTE", state)
        end
    end

    for track, state in pairs(track_mute_states) do
        if ValidateTrack(track) then reaper.SetMediaTrackInfo_Value(track, "B_MUTE", state) end
    end
    for track, state in pairs(track_solo_states) do
        if ValidateTrack(track) then reaper.SetMediaTrackInfo_Value(track, "I_SOLO", state) end
    end
    if master_mute_state ~= nil then
        local master = reaper.GetMasterTrack(0)
        if ValidateTrack(master) then reaper.SetMediaTrackInfo_Value(master, "B_MUTE", master_mute_state) end
    end

    if not enable_take_fx then
        for _, item in ipairs(selected_items_list) do
            local take = reaper.GetActiveTake(item)
            if take then
                local key = take
                if take_fx_snapshot[key] then
                    for fx_idx, was_enabled in pairs(take_fx_snapshot[key]) do
                        if reaper.ValidatePtr(take, "MediaItem_Take*") then
                            if reaper.TakeFX_GetEnabled(take, fx_idx) ~= was_enabled then
                                reaper.TakeFX_SetEnabled(take, fx_idx, was_enabled)
                            end
                        end
                    end
                end
            end
        end
    end

    reaper.Main_OnCommand(40289, 0) -- Unselect items
    reaper.Main_OnCommand(40297, 0) -- Unselect tracks
    
    if ValidateTrack(result_track) then 
        reaper.SetTrackSelected(result_track, true) 
    end

    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Render Selected Items Mixdown", -1)

    ----------------------------------------------------------------------------
    -- STEP 2: DELETE SOURCE (Undo Block 2)
    ----------------------------------------------------------------------------
    if delete_source then
        reaper.Undo_BeginBlock()
        for track, _ in pairs(involved_tracks) do
            if ValidateTrack(track) then
                reaper.DeleteTrack(track)
            end
        end
        if ValidateTrack(result_track) then 
            reaper.SetTrackSelected(result_track, true) 
        end
        reaper.UpdateArrange()
        reaper.Undo_EndBlock("Delete Source Tracks", -1)
    end

    reaper.PreventUIRefresh(-1)
end

--------------------------------------------------------------------------------
-- PART 2: GUI & PERSISTENCE
--------------------------------------------------------------------------------

local ctx = {
    w = 500, h = 320,
    opt_track = true,
    opt_take = true,
    opt_volpan = false,
    opt_mono = false,
    opt_delete = false,
    last_mouse_cap = 0
}

function LoadSettings()
    local function get_bool(key, default)
        local val = reaper.GetExtState(EXT_SECTION, key)
        if val == "1" then return true
        elseif val == "0" then return false
        else return default end
    end
    ctx.opt_track = get_bool("opt_track", true)
    ctx.opt_take = get_bool("opt_take", true)
    ctx.opt_volpan = get_bool("opt_volpan", false)
    ctx.opt_mono = get_bool("opt_mono", false)
    ctx.opt_delete = get_bool("opt_delete", false)
    local logging = reaper.GetExtState(LOG_SECTION, "logging_enabled")
    if logging == "1" then loggingEnabled = true elseif logging == "0" then loggingEnabled = false end
end

function SaveSettings()
    reaper.SetExtState(EXT_SECTION, "opt_track", ctx.opt_track and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "opt_take", ctx.opt_take and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "opt_volpan", ctx.opt_volpan and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "opt_mono", ctx.opt_mono and "1" or "0", true)
    reaper.SetExtState(EXT_SECTION, "opt_delete", ctx.opt_delete and "1" or "0", true)
    reaper.SetExtState(LOG_SECTION, "logging_enabled", loggingEnabled and "1" or "0", true)
end

local aboutOpen = false
local previousMouseDown = false
local uiScale, uiOffsetX, uiOffsetY = 1, 0, 0
local lastWindowW, lastWindowH = ctx.w, ctx.h
local logoHandle, logoWidth, logoHeight = -1, 0, 0
local embeddedLogoBase64 = [[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]]
local logoAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function decodeEmbeddedLogo(data)
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

local function setColor(r, g, b, a)
    gfx.set(r / 255, g / 255, b / 255, a or 1)
end
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
    gfx.rect(sx, sy, sw, sh, 1)
    setColor(backgroundR, backgroundG, backgroundB)
    gfx.rect(sx, sy, sr, sr, 1); gfx.rect(sx + sw - sr, sy, sr, sr, 1)
    gfx.rect(sx, sy + sh - sr, sr, sr, 1); gfx.rect(sx + sw - sr, sy + sh - sr, sr, sr, 1)
    setColor(fillR * 255, fillG * 255, fillB * 255, fillA)
    gfx.circle(sx + sr, sy + sr, sr, 1, 1); gfx.circle(sx + sw - sr, sy + sr, sr, 1, 1)
    gfx.circle(sx + sr, sy + sh - sr, sr, 1, 1); gfx.circle(sx + sw - sr, sy + sh - sr, sr, 1, 1)
end
local function drawLogo(x, y, w, h)
    if logoHandle < 0 or logoWidth <= 0 or logoHeight <= 0 then return end
    local scale = math.min(w / logoWidth, h / logoHeight)
    local dw, dh = logoWidth * scale, logoHeight * scale
    gfx.mode = 0
    gfx.blit(logoHandle, 1, 0, 0, 0, logoWidth, logoHeight,
        uiX(x + (w - dw) / 2), uiY(y + (h - dh) / 2), dw * uiScale, dh * uiScale)
end
local function drawCheckbox(x, y, label, state)
    local px, py, box = uiPixel(uiX(x)), uiPixel(uiY(y)), math.max(1, uiPixel(16 * uiScale))
    local inset = math.min(math.max(1, uiPixel(3 * uiScale)), math.floor((box - 1) / 2))
    setColor(125, 125, 125); gfx.rect(px, py, box, box, 0)
    if state then
        local inner = box - 2 * inset
        setColor(197, 160, 89); gfx.rect(px + inset, py + inset, inner, inner, 1)
    end
    setColor(238, 238, 238); uiFont(1, "Arial", 15)
    gfx.x, gfx.y = uiX(x + 25), uiY(y + (16 - gfx.texth / uiScale) / 2)
    gfx.drawstr(label)
    local mx, my = (gfx.mouse_x - uiOffsetX) / uiScale, (gfx.mouse_y - uiOffsetY) / uiScale
    if not aboutOpen and mx >= x and mx <= x + 210 and my >= y - 2 and my <= y + 20 and gfx.mouse_cap == 1 and ctx.last_mouse_cap == 0 then
        return not state
    end
    return state
end
local function drawButton(x, y, w, h, label, hover)
    local sx, sy = uiPixel(uiX(x)), uiPixel(uiY(y))
    local sw, sh = uiPixel(w * uiScale), uiPixel(h * uiScale)
    local radius = math.min(math.max(1, uiPixel(7 * uiScale)), math.floor(sw / 2), math.floor(sh / 2))
    local fillR, fillG, fillB = hover and 218 or 197, hover and 179 or 160, hover and 105 or 89
    setColor(fillR, fillG, fillB)
    gfx.rect(sx + radius, sy, sw - radius * 2, sh, 1)
    gfx.rect(sx, sy + radius, sw, sh - radius * 2, 1)
    gfx.circle(sx + radius, sy + radius, radius, 1, 1)
    gfx.circle(sx + sw - radius, sy + radius, radius, 1, 1)
    gfx.circle(sx + radius, sy + sh - radius, radius, 1, 1)
    gfx.circle(sx + sw - radius, sy + sh - radius, radius, 1, 1)
    gfx.roundrect(sx, sy, sw, sh, radius, 0)
    uiFont(2, "Arial", 16, "b")
    setColor(24, 24, 24)
    local tw = gfx.measurestr(label)
    gfx.x, gfx.y = uiX(x + (w - tw / uiScale) / 2), uiY(y + (h - gfx.texth / uiScale) / 2)
    gfx.drawstr(label)
    local mx, my = (gfx.mouse_x - uiOffsetX) / uiScale, (gfx.mouse_y - uiOffsetY) / uiScale
    return mx >= x and mx <= x + w and my >= y and my <= y + h and gfx.mouse_cap == 1 and ctx.last_mouse_cap == 0
end
local function openExternalURL(url)
    if reaper.CF_ShellExecute then return reaper.CF_ShellExecute(url) end
    local osName = reaper.GetOS()
    local command
    if osName:match("Win") then command = 'cmd.exe /d /s /c start "" "' .. url .. '"'
    elseif osName:match("OSX") or osName:match("macOS") then command = 'open "' .. url .. '"'
    elseif osName:match("Linux") then command = 'xdg-open "' .. url .. '"'
    else return false end
    if not reaper.ExecProcess then return false end
    return reaper.ExecProcess(command, -2) ~= nil
end
local function drawAboutDialog()
    gfx.set(0, 0, 0, 0.62); gfx.rect(0, 0, gfx.w, gfx.h, 1)
    local panelW, panelH = 390, 229
    local x, y = (ctx.w - panelW) / 2, (ctx.h - panelH) / 2
    setColor(25, 25, 25); fillRoundRect(x, y, panelW, panelH, 7, 7, 7, 7)
    setColor(197, 160, 89); uiRoundRect(x, y, panelW, panelH, 7, 1)
    local closeX, closeY, closeSize = x + panelW - 34, y + 10, 24
    local mx, my = (gfx.mouse_x - uiOffsetX) / uiScale, (gfx.mouse_y - uiOffsetY) / uiScale
    local closeHover = mx >= closeX and mx <= closeX + closeSize and my >= closeY and my <= closeY + closeSize
    setColor(closeHover and 197 or 165, closeHover and 160 or 165, closeHover and 89 or 165)
    gfx.line(uiPixel(uiX(closeX + 7)), uiPixel(uiY(closeY + 7)), uiPixel(uiX(closeX + 17)), uiPixel(uiY(closeY + 17)), 1)
    gfx.line(uiPixel(uiX(closeX + 17)), uiPixel(uiY(closeY + 7)), uiPixel(uiX(closeX + 7)), uiPixel(uiY(closeY + 17)), 1)
    setColor(238, 238, 238); uiFont(3, "Arial", 20, "b")
    local title = "© 2026 Reach the Knob"
    gfx.x, gfx.y = uiX(x + (panelW - gfx.measurestr(title) / uiScale) / 2), uiY(y + 28); gfx.drawstr(title)
    setColor(165, 165, 165); uiFont(3, "Arial", 15)
    local credit = "Developed and designed by Alex Gurev"
    gfx.x, gfx.y = uiX(x + (panelW - gfx.measurestr(credit) / uiScale) / 2), uiY(y + 63); gfx.drawstr(credit)
    local logLabel, logBox, logGap = "Enable logging", 13, 9
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
    setColor(197, 160, 89); uiFont(3, "Arial", 15, "u")
    local youtube, donation = "YouTube", "Donation"
    local youtubeW, donationW = gfx.measurestr(youtube), gfx.measurestr(donation)
    local linkGap, totalW = 34, (youtubeW + donationW) / uiScale + 34
    local linkY = y + 153
    local youtubeX = x + (panelW - totalW) / 2
    local donationX = youtubeX + youtubeW / uiScale + linkGap
    gfx.x, gfx.y = uiX(youtubeX), uiY(linkY); gfx.drawstr(youtube)
    gfx.x, gfx.y = uiX(donationX), uiY(linkY); gfx.drawstr(donation)
    setColor(165, 165, 165); uiFont(3, "Arial", 15)
    local version = "Version 1.1"
    gfx.x, gfx.y = uiX(x + (panelW - gfx.measurestr(version) / uiScale) / 2), uiY(y + 183); gfx.drawstr(version)
    return {
        panel = {x, y, panelW, panelH}, close = {closeX, closeY, closeSize, closeSize},
        email = {emailX, y + 123, emailW, 20}, youtube = {youtubeX, linkY, youtubeW / uiScale, 20},
        donation = {donationX, linkY, donationW / uiScale, 20},
        logging = {logX, logY, logTotalW, logRowH}
    }
end

local function initLogo()
    local path = reaper.GetResourcePath() .. "/RtK_Bounce_logo_" .. tostring(math.floor(reaper.time_precise() * 1000000)) .. ".png"
    local file = io.open(path, "wb")
    if not file then
        reaper.ShowConsoleMsg("Bounce items to new track: could not create the temporary logo file.\n")
        return
    end
    local ok, err = pcall(function() file:write(decodeEmbeddedLogo(embeddedLogoBase64)) end)
    file:close()
    if ok then
        logoHandle = gfx.loadimg(1, path)
        if logoHandle >= 0 then logoWidth, logoHeight = gfx.getimgdim(1) end
    else
        reaper.ShowConsoleMsg("Bounce items to new track: logo decode failed: " .. tostring(err) .. "\n")
    end
    os.remove(path)
    if logoWidth <= 0 or logoHeight <= 0 then
        reaper.ShowConsoleMsg("Bounce items to new track: REAPER could not load the embedded logo image.\n")
    end
end

local function getDisplayScaleFactor()
    local scale = math.max(1, tonumber(gfx.ext_retina) or 1)
    if reaper.ThemeLayout_GetLayout then
        local ok, raw = reaper.ThemeLayout_GetLayout("global", -3)
        local dpi = ok and tonumber(raw) or nil
        if dpi and dpi >= 256 then scale = math.max(scale, dpi / 256) end
    end
    return scale
end

function InitGUI()
    gfx.ext_retina = 1
    gfx.init("Bounce items to new track", ctx.w, ctx.h)
    local requestedScale = getDisplayScaleFactor()
    local reportedScale = math.min(gfx.w / ctx.w, gfx.h / ctx.h)
    if requestedScale > reportedScale + 0.01 then
        gfx.init("", math.floor(ctx.w * requestedScale + 0.5), math.floor(ctx.h * requestedScale + 0.5))
    end
    lastWindowW, lastWindowH = gfx.w, gfx.h
    gfx.setfont(1, "Arial", 15)
    initLogo()
end

local render_requested = false
function MainLoop()
    local char = gfx.getchar()
    if char < 0 then gfx.quit(); return end
    if char == 27 then
        if aboutOpen then aboutOpen = false else gfx.quit(); return end
    end

    local observedW, observedH = gfx.w, gfx.h
    local targetAspect = ctx.w / ctx.h
    if observedW > 0 and observedH > 0 and (observedW ~= lastWindowW or observedH ~= lastWindowH) and
       math.abs(observedW / observedH - targetAspect) > 0.006 then
        local widthChange = math.abs(observedW - lastWindowW) / ctx.w
        local heightChange = math.abs(observedH - lastWindowH) / ctx.h
        local targetW, targetH
        if widthChange >= heightChange then
            targetW = math.max(ctx.w, observedW)
            targetH = math.floor(targetW / targetAspect + 0.5)
        else
            targetH = math.max(ctx.h, observedH)
            targetW = math.floor(targetH * targetAspect + 0.5)
        end
        gfx.init("", targetW, targetH)
    end
    lastWindowW, lastWindowH = gfx.w, gfx.h
    local pixelW, pixelH = gfx.w, gfx.h
    uiScale = math.min(pixelW / ctx.w, pixelH / ctx.h)
    uiOffsetX, uiOffsetY = (pixelW - ctx.w * uiScale) / 2, (pixelH - ctx.h * uiScale) / 2
    setColor(19, 19, 19); gfx.rect(0, 0, pixelW, pixelH, 1)
    setColor(197, 160, 89); gfx.rect(uiX(0), uiY(0), 4 * uiScale, ctx.h * uiScale, 1)

    local logoX, logoY, logoW, logoH = 34, 12, 78, 78
    drawLogo(logoX, logoY, logoW, logoH)
    setColor(245, 245, 245); uiFont(1, "Arial", 25, "b")
    local titleY = 30
    gfx.x, gfx.y = uiX(142), uiY(titleY); gfx.drawstr("Bounce items to new track")
    local titleHeight = gfx.texth / uiScale
    setColor(115, 115, 115); uiFont(1, "Arial", 15)
    local subtitleY = titleY + titleHeight + 4
    gfx.x, gfx.y = uiX(142), uiY(subtitleY); gfx.drawstr("Render selected items into one combined file")
    local firstOptionY = subtitleY + gfx.texth / uiScale + 30

    ctx.opt_track = drawCheckbox(34, firstOptionY, "Enable track FX", ctx.opt_track)
    ctx.opt_take = drawCheckbox(248, firstOptionY, "Enable take FX", ctx.opt_take)
    ctx.opt_volpan = drawCheckbox(34, firstOptionY + 35, "Ignore track Vol/Pan", ctx.opt_volpan)
    ctx.opt_mono = drawCheckbox(248, firstOptionY + 35, "Bounce to mono", ctx.opt_mono)

    local renderButtonY = ctx.h - 30 - 44
    local deleteY = renderButtonY - 30 - 16
    local dividerY = deleteY - 15
    setColor(61, 61, 61); gfx.line(uiX(34), uiY(dividerY), uiX(ctx.w - 30), uiY(dividerY), 1)
    ctx.opt_delete = drawCheckbox(34, deleteY, "Delete source tracks", ctx.opt_delete)

    local mx, my = (gfx.mouse_x - uiOffsetX) / uiScale, (gfx.mouse_y - uiOffsetY) / uiScale
    local renderHover = mx >= 34 and mx <= ctx.w - 30 and my >= renderButtonY and my <= renderButtonY + 44
    local requestRender = false
    if not aboutOpen then requestRender = drawButton(34, renderButtonY, ctx.w - 64, 44, "Render", renderHover) end

    local aboutHit
    if aboutOpen then aboutHit = drawAboutDialog() end
    if aboutOpen and aboutHit then
        local function inside(rect)
            return rect and mx >= rect[1] and mx <= rect[1] + rect[3] and my >= rect[2] and my <= rect[2] + rect[4]
        end
        if inside(aboutHit.email) or inside(aboutHit.youtube) or inside(aboutHit.donation) or inside(aboutHit.logging) then gfx.setcursor(32649, "hand")
        else gfx.setcursor(32512, "arrow") end
    elseif not aboutOpen and mx >= logoX and mx <= logoX + logoW and my >= logoY and my <= logoY + logoH then
        gfx.setcursor(32649, "hand")
    else
        gfx.setcursor(32512, "arrow")
    end

    gfx.update()
    local mouseDown = (gfx.mouse_cap & 1) ~= 0
    if mouseDown and not previousMouseDown then
        mx, my = (gfx.mouse_x - uiOffsetX) / uiScale, (gfx.mouse_y - uiOffsetY) / uiScale
        if aboutOpen then
            local function inside(rect) return rect and mx >= rect[1] and mx <= rect[1] + rect[3] and my >= rect[2] and my <= rect[2] + rect[4] end
            if inside(aboutHit.close) then aboutOpen = false
            elseif inside(aboutHit.logging) then setLoggingEnabled(not loggingEnabled)
            elseif inside(aboutHit.email) then openExternalURL("mailto:alex.v.gurev@gmail.com")
            elseif inside(aboutHit.youtube) then openExternalURL("https://www.youtube.com/@reachtheknob")
            elseif inside(aboutHit.donation) then openExternalURL("https://boosty.to/alex_hius")
            elseif not inside(aboutHit.panel) then aboutOpen = false end
        elseif mx >= logoX and mx <= logoX + logoW and my >= logoY and my <= logoY + logoH then
            aboutOpen = true
        elseif requestRender then
            if reaper.CountSelectedMediaItems(0) == 0 then
                reaper.ShowMessageBox("Please select items before rendering!", "Error", 0)
            else
                SaveSettings()
                render_requested = true
            end
        end
    end
    previousMouseDown = mouseDown
    ctx.last_mouse_cap = gfx.mouse_cap

    if render_requested then
        render_requested = false
        gfx.update()
        local itemCount = reaper.CountSelectedMediaItems(0)
        writeLog("Render started; selected items: " .. tostring(itemCount) .. "; track FX=" .. tostring(ctx.opt_track) .. "; take FX=" .. tostring(ctx.opt_take) .. "; ignore volume/pan=" .. tostring(ctx.opt_volpan) .. "; mono=" .. tostring(ctx.opt_mono) .. "; delete source tracks=" .. tostring(ctx.opt_delete))
        local mixStateBackup = ctx.opt_volpan and snapshotProjectMixStates() or nil
        local ok, err = xpcall(function()
            ProcessRender(ctx.opt_track, ctx.opt_take, ctx.opt_volpan, ctx.opt_mono, ctx.opt_delete)
        end, debug.traceback)
        restoreProjectMixStates(mixStateBackup)
        if ok then
            writeLog("Render workflow finished")
        else
            writeLog("RENDER FAILED:\r\n" .. tostring(err))
            local path = getProjectLogPath()
            local detail = loggingEnabled and path and ("Details are in the project log:\n" .. path) or "Logging is disabled or unavailable for this project."
            reaper.ShowMessageBox("Render failed.\n" .. detail, "Bounce items to new track", 0)
        end
    end
    reaper.defer(MainLoop)
end

LoadSettings()
InitGUI()
MainLoop()





