-- SmartThings Edge driver: Samsung TV (Tizen, 2016 and later) over the LAN, no cloud.
-- Power state from :8001/api/v2/, volume and mute over UPnP (:9197), keys over the remote control websocket (:8002).
-- The pairing token the TV gives after "Allow" stays in a device field on the hub; nothing secret in code.
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local cosock = require "cosock"
local log = require "log"
local api = require "tv_api"
local proto = require "tv_proto"

local BUILD = "2026-11-08a"
local PAIR_EVERY = 120
local PAIR_TRIES = 5
local REDISCOVER_EVERY = 300

local switch = capabilities.switch
local volume = capabilities.audioVolume
local mute = capabilities.audioMute
local input = capabilities.mediaInputSource
local tvsource = capabilities["silvervalley08660.tvInput"]
local emit_sources -- defined below, used by the poll
local channel = capabilities.tvChannel

local state = {}   -- device.id -> { timer, busy, pairing, tries, asked_at, misses, rediscovered_at }
local pending = {} -- device_network_id -> { ip, mac } from discovery, picked up in init

local function clean(s) return (tostring(s or ""):gsub("%s", "")) end

local function dni_for(info, ip)
  local mac = proto.clean_mac(((info or {}).device or {}).wifiMac)
  return "samsungtv-" .. (mac or tostring(ip):gsub("%.", "-"))
end

local function settings(dev)
  local p = dev.preferences or {}
  local host = clean(p.ipAddress)
  if host == "" or host == "auto" then host = dev:get_field("ip") or "" end
  local mac = proto.clean_mac(p.macAddress) or dev:get_field("mac")
  return host, mac
end

-- Sound through a soundbar or receiver (HDMI ARC/eARC): the TV's own (UPnP) volume does nothing there, so
-- volume and mute go as remote control keys, which the TV passes on over HDMI-CEC.
local function external_sound(dev)
  return tostring((dev.preferences or {}).soundOutput or "tv") == "external"
end

-- With external sound the volume shown is our own count (the soundbar can not be read): keep it persisted.
local function shown_volume(dev)
  local v = tonumber((dev:get_field("ext_volume")))
  if v then return v end
  local ok, st = pcall(function() return dev:get_latest_state("main", "audioVolume", "volume") end)
  return ok and tonumber(st) or tonumber((dev:get_field("last_volume")))
end

local function emit(dev, key, value, event)
  if dev:get_field("last_" .. key) == value then return end
  local ok, err = pcall(function() dev:emit_event(event) end)
  if ok then dev:set_field("last_" .. key, value) else log.warn("[tv] emit " .. key .. ": " .. tostring(err)) end
end

local function save_token(dev, tok)
  if tok and tok ~= "" and tok ~= dev:get_field("token") then
    dev:set_field("token", tok, { persist = true })
    log.info("[tv] " .. tostring(dev.label) .. ": paired with the TV")
  end
end

local function send_keys(dev, keys, wait, gap)
  local host = settings(dev)
  if host == "" then log.warn("[tv] " .. tostring(dev.label) .. ": no IP address yet"); return false end
  local tok, err = api.keys(host, dev:get_field("token"), keys, wait or 30, gap)
  if not tok then
    log.warn("[tv] " .. tostring(dev.label) .. " " .. table.concat(keys, ",") .. ": " .. tostring(err))
    return false
  end
  save_token(dev, tok)
  local seen = api.events or {}
  log.info(string.format("[tv] %s: sent %s%s", tostring(dev.label), table.concat(keys, ","),
    #seen > 0 and (", TV answered: " .. table.concat(seen, "; "):sub(1, 200)) or ""))
  return true
end

local function is_tv(info)
  return type(info) == "table" and tostring(((info.device or {}).type) or ""):lower():find("tv", 1, true) ~= nil
end

local function candidates(timeout, allow_scan)
  local ips = api.ssdp(timeout)
  if #ips == 0 and allow_scan then
    ips = api.scan()
    log.info("[tv] SSDP found nothing, network scan found " .. #ips .. " address(es) with port 8001 open")
  end
  return ips
end

local function rediscover(dev, st, allow_scan)
  if os.time() - (st.rediscovered_at or 0) < REDISCOVER_EVERY then return end
  st.rediscovered_at = os.time()
  for _, ip in ipairs(candidates(4, allow_scan)) do
    local info = api.info(ip)
    if is_tv(info) and (dni_for(info, ip) == dev.device_network_id or dev.device_network_id == "samsungtv-manual") then
      if ip ~= dev:get_field("ip") then log.info("[tv] " .. tostring(dev.label) .. ": found at " .. ip) end
      dev:set_field("ip", ip, { persist = true })
      return ip
    end
  end
end

local function pair(dev, st)
  if st.pairing then return end
  st.pairing, st.asked_at, st.tries = true, os.time(), (st.tries or 0) + 1
  log.info("[tv] " .. tostring(dev.label) .. ": asking the TV for access, choose Allow on the TV screen")
  cosock.spawn(function()
    local ok, err = pcall(send_keys, dev, {}, 45)
    if not ok then log.warn("[tv] pairing: " .. tostring(err)) end
    st.pairing = false
  end, "tv-pair")
end

local function poll_once(dev, st)
  local host, mac = settings(dev)
  local auto = clean((dev.preferences or {}).ipAddress)
  auto = auto == "" or auto == "auto"
  if host == "" and auto then host = rediscover(dev, st, true) or "" end
  if host == "" then
    if not st.warned then
      st.warned = true
      log.warn("[tv] " .. tostring(dev.label) .. ": TV not found (is it on?), set its IP address in the settings")
    end
    emit(dev, "switch", "off", switch.switch.off())
    return
  end
  local info = api.info(host)
  if not info then
    st.misses = (st.misses or 0) + 1
    emit(dev, "switch", "off", switch.switch.off())
    if auto and st.misses >= 3 then rediscover(dev, st) end
    return
  end
  st.misses, st.warned = 0, false
  local year = proto.model_year(info)
  if year and dev:get_field("tv_year") ~= year then
    dev:set_field("tv_year", year, { persist = true })
    dev:set_field("sources_emitted", nil)
    emit_sources(dev)
  end
  local d = info.device or {}
  if not mac and proto.clean_mac(d.wifiMac) then dev:set_field("mac", proto.clean_mac(d.wifiMac), { persist = true }) end
  if not st.listed then
    st.listed = true
    log.info(string.format("[tv] %s: %s %s at %s, power %s, %s network, wake-on-LAN MAC %s, %s", tostring(dev.label),
      tostring(d.modelName), tostring(d.name), host, proto.power(info), tostring(d.networkType),
      tostring(mac or proto.clean_mac(d.wifiMac)), dev:get_field("token") and "paired" or "not paired yet"))
  end
  local power = proto.power(info)
  emit(dev, "switch", power == "on" and "on" or "off", power == "on" and switch.switch.on() or switch.switch.off())
  if power ~= "on" then return end
  if not external_sound(dev) then
    local vol = tonumber(proto.xml_value(api.soap(host, "GetVolume") or "", "CurrentVolume"))
    if vol then emit(dev, "volume", vol, volume.volume(vol)) end
    local m = proto.xml_value(api.soap(host, "GetMute") or "", "CurrentMute")
    if m then emit(dev, "mute", m, m == "1" and mute.mute.muted() or mute.mute.unmuted()) end
  end
  if not dev:get_field("token") and (st.tries or 0) < PAIR_TRIES
      and (os.time() - (st.asked_at or 0) >= PAIR_EVERY or st.pair_now) then
    st.pair_now = false
    pair(dev, st)
  end
end

local function poll(dev)
  local st = state[dev.id]
  if not st or st.busy then return end
  st.busy = true
  local ok, err = pcall(poll_once, dev, st)
  st.busy = false
  if not ok then log.error("[tv] poll error: " .. tostring(err)) end
end

local function soon(dev)
  dev.thread:call_with_delay(2, function() poll(dev) end)
  dev.thread:call_with_delay(7, function() poll(dev) end)
end

local function schedule(dev)
  local st = state[dev.id]
  if st.timer then pcall(function() dev.thread:cancel_timer(st.timer) end) end
  local interval = tonumber((dev.preferences or {}).pollInterval) or 10
  st.timer = dev.thread:call_on_schedule(interval, function() poll(dev) end, "tv-poll")
  dev.thread:call_with_delay(2, function() poll(dev) end)
end

local function is_on(dev)
  local host = settings(dev)
  return host ~= "" and proto.power(api.info(host)) == "on"
end

local function turn_on(_, dev)
  local host, mac = settings(dev)
  if host == "" then return end
  local info = api.info(host)
  if proto.power(info) == "on" then emit(dev, "switch", "on", switch.switch.on()); return end
  if mac then api.wol(mac, host) else log.warn("[tv] " .. tostring(dev.label) .. ": no MAC address, wake-on-LAN skipped") end
  if info then
    -- network standby: the TV answers; give wake-on-LAN a moment, then the power key
    cosock.socket.sleep(3)
    if not is_on(dev) then send_keys(dev, { "KEY_POWER" }, 10) end
  end
  soon(dev)
end

local function turn_off(_, dev)
  if is_on(dev) then send_keys(dev, { "KEY_POWER" }) end
  emit(dev, "switch", "off", switch.switch.off())
  soon(dev)
end

local MAX_VOLUME_KEYS = 50

local function set_volume(_, dev, cmd)
  local v = math.max(0, math.min(100, math.floor((tonumber(cmd.args.volume) or 0) + 0.5)))
  local host = settings(dev)
  if external_sound(dev) then
    -- the soundbar volume can not be read: step from the last value shown
    local cur = shown_volume(dev) or v
    local keys = proto.volume_keys(cur, v, MAX_VOLUME_KEYS)
    if #keys == 0 or send_keys(dev, keys, nil, 0.15) then
      dev:set_field("ext_volume", v, { persist = true })
      emit(dev, "volume", v, volume.volume(v))
    end
    return
  end
  if api.soap(host, "SetVolume", "<DesiredVolume>" .. v .. "</DesiredVolume>") then
    emit(dev, "volume", v, volume.volume(v))
  else
    log.warn("[tv] " .. tostring(dev.label) .. ": volume not accepted (TV off?)")
  end
end

local function step_volume(dev, up)
  local ok = send_keys(dev, { up and "KEY_VOLUP" or "KEY_VOLDOWN" })
  if ok and external_sound(dev) then
    local cur = shown_volume(dev)
    if cur then
      local v = math.max(0, math.min(100, cur + (up and 1 or -1)))
      dev:set_field("ext_volume", v, { persist = true })
      emit(dev, "volume", v, volume.volume(v))
    end
  end
  soon(dev)
end

local function set_mute(dev, on)
  local host = settings(dev)
  if external_sound(dev) then
    -- KEY_MUTE toggles: only send it when the state shown differs
    if (dev:get_field("last_mute") == "1") == on then return end
    if send_keys(dev, { "KEY_MUTE" }) then
      emit(dev, "mute", on and "1" or "0", on and mute.mute.muted() or mute.mute.unmuted())
    end
    return
  end
  if api.soap(host, "SetMute", "<DesiredMute>" .. (on and 1 or 0) .. "</DesiredMute>") then
    emit(dev, "mute", on and "1" or "0", on and mute.mute.muted() or mute.mute.unmuted())
  else
    log.warn("[tv] " .. tostring(dev.label) .. ": mute not accepted (TV off?)")
  end
end

local function set_input(_, dev, cmd)
  local src = tostring(cmd.args.mode or "")
  local key = proto.INPUTS[src]
  if not key then log.warn("[tv] unknown input " .. src); return end
  local p = dev.preferences or {}
  local keys = { key }
  local method = tostring(p.inputMethod or "auto")
  if method == "auto" then
    -- TVs from 2021 on ignore the HDMI1..4 keys
    method = (tonumber((dev:get_field("tv_year"))) or 0) >= 2021 and "menu" or "direct"
  end
  if method == "menu" then
    -- newer TVs ignore KEY_HDMI1..4: pick the tile in the Source menu instead
    local pos = proto.menu_positions(p.menuPositions or "digitalTv=1,HDMI1=3,HDMI2=4,HDMI3=5,HDMI4=6")[src]
    if not pos then log.warn("[tv] " .. src .. " has no position in the Source menu setting"); return end
    keys = proto.menu_keys(pos, tonumber(p.menuColumns) or 2)
  end
  if send_keys(dev, keys, nil, 0.15) then
    dev:set_field("input", src, { persist = true })
    emit(dev, "input", src, input.inputSource(src))
  end
end

local function set_channel(_, dev, cmd)
  -- a key sequence instead of a number ("KEY_SOURCE+800+KEY_RIGHT"): sent as remote keys, e.g. from a routine
  local seq = tostring(cmd.args.tvChannel or ""):upper():find("KEY_", 1, true) and proto.key_sequence(cmd.args.tvChannel)
  if seq then send_keys(dev, seq); return end
  local keys = proto.channel_keys(cmd.args.tvChannel)
  if not keys then log.warn("[tv] channel must be a number: " .. tostring(cmd.args.tvChannel)); return end
  if send_keys(dev, keys) then emit(dev, "channel", tostring(cmd.args.tvChannel), channel.tvChannel(tostring(cmd.args.tvChannel))) end
end

local function send_keypad(_, dev, cmd)
  local key = proto.KEYPAD[tostring(cmd.args.keyCode or "")]
  if not key then log.warn("[tv] unknown key " .. tostring(cmd.args.keyCode)); return end
  send_keys(dev, { key })
end

-- Sources by name (setting "Sources"): the Source menu tile or a key sequence per name.
local function source_list(dev)
  local s = clean((dev.preferences or {}).sources) == "" and "auto" or tostring((dev.preferences or {}).sources)
  if s == "auto" then
    s = (tonumber((dev:get_field("tv_year"))) or 0) >= 2021 and proto.DEFAULT_SOURCES_MENU or proto.DEFAULT_SOURCES_KEYS
  end
  return proto.sources(s)
end

emit_sources = function(dev)
  local names = {}
  for _, e in ipairs(source_list(dev)) do names[#names + 1] = e.name end
  local key = table.concat(names, "|")
  if dev:get_field("sources_emitted") == key then return end
  local ok = pcall(function() dev:emit_event(tvsource.supportedSources(names, { visibility = { displayed = false } })) end)
  if ok then dev:set_field("sources_emitted", key) end
  if not dev:get_field("source") and names[1] then
    pcall(function() dev:emit_event(tvsource.source(names[1], { visibility = { displayed = false } })) end)
  end
end

local function set_source(_, dev, cmd)
  local want = tostring(cmd.args.source or "")
  for _, e in ipairs(source_list(dev)) do
    if e.name == want then
      local keys = e.keys or proto.menu_keys(e.pos, tonumber((dev.preferences or {}).menuColumns) or 2)
      if send_keys(dev, keys, nil, 0.15) then
        dev:set_field("source", want, { persist = true })
        pcall(function() dev:emit_event(tvsource.source(want)) end)
      end
      return
    end
  end
  log.warn("[tv] unknown source " .. want)
end

local function handle_refresh(_, dev)
  local st = state[dev.id]
  if not st then return end
  st.listed, st.tries, st.pair_now, st.rediscovered_at = false, 0, true, 0
  for k in pairs({ switch = 1, volume = 1, mute = 1 }) do dev:set_field("last_" .. k, nil) end
  poll(dev)
end

local function device_init(_, dev)
  state[dev.id] = state[dev.id] or {}
  local p = pending[dev.device_network_id or ""]
  if p then
    pending[dev.device_network_id] = nil
    if p.ip then dev:set_field("ip", p.ip, { persist = true }) end
    if p.mac then dev:set_field("mac", p.mac, { persist = true }) end
  end
  dev:online()
  dev:set_field("sources_emitted", nil)
  emit_sources(dev)
  if dev:get_field("source") then
    pcall(function() dev:emit_event(tvsource.source(dev:get_field("source"), { visibility = { displayed = false } })) end)
  end
  pcall(function() dev:emit_event(capabilities.keypadInput.supportedKeyCodes(proto.KEYPAD_LIST, { visibility = { displayed = false } })) end)
  -- The app greys out a control whose attribute never had a value ("has not updated all status data"). The TV
  -- does not report its channel over the LAN, so start with "-".
  emit(dev, "channel", dev:get_field("last_channel") or "-", channel.tvChannel(dev:get_field("last_channel") or "-",
    { visibility = { displayed = false } }))
  pcall(function() dev:emit_event(channel.tvChannelName("", { visibility = { displayed = false } })) end)
  schedule(dev)
end

local function info_changed(_, dev, _event, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  if clean(old.ipAddress) ~= clean((dev.preferences or {}).ipAddress) then dev:set_field("ip", nil, { persist = true }) end
  state[dev.id] = state[dev.id] or {}
  state[dev.id].listed = false
  emit_sources(dev)
  schedule(dev)
end

local function device_removed(_, dev)
  local st = state[dev.id]
  if st and st.timer then pcall(function() dev.thread:cancel_timer(st.timer) end) end
  state[dev.id] = nil
end

local function discovery(driver, _opts, _should_continue)
  local known = {}
  for _, d in ipairs(driver:get_devices()) do known[d.device_network_id or ""] = d end
  local found = 0
  for _, ip in ipairs(candidates(5, true)) do
    local info = api.info(ip)
    local d = (info or {}).device or {}
    if is_tv(info) then
      found = found + 1
      local dni = dni_for(info, ip)
      if known[dni] then
        known[dni]:set_field("ip", ip, { persist = true })
      else
        local label = tostring(d.name or "Samsung TV"):gsub("^%[TV%]%s*", "")
        log.info("[tv] discovery: " .. label .. " (" .. tostring(d.modelName) .. ") at " .. ip)
        pending[dni] = { ip = ip, mac = proto.clean_mac(d.wifiMac) }
        driver:try_create_device({ type = "LAN", device_network_id = dni, label = label, profile = "samsung-tv",
          manufacturer = "Samsung", model = tostring(d.modelName or "Samsung TV"), vendor_provided_label = label })
      end
    end
  end
  if found == 0 and next(known) == nil then
    log.info("[tv] discovery: no TV answered, adding one to set up by IP address")
    driver:try_create_device({ type = "LAN", device_network_id = "samsungtv-manual", label = "Samsung TV",
      profile = "samsung-tv", manufacturer = "Samsung", model = "Samsung TV", vendor_provided_label = "Samsung TV" })
  end
end

local driver = Driver("samsung-tv-local", {
  discovery = discovery,
  lifecycle_handlers = { init = device_init, added = device_init, infoChanged = info_changed, removed = device_removed },
  capability_handlers = {
    [capabilities.refresh.ID] = { [capabilities.refresh.commands.refresh.NAME] = handle_refresh },
    [switch.ID] = { [switch.commands.on.NAME] = turn_on, [switch.commands.off.NAME] = turn_off },
    [volume.ID] = {
      [volume.commands.setVolume.NAME] = set_volume,
      [volume.commands.volumeUp.NAME] = function(_, dev) step_volume(dev, true) end,
      [volume.commands.volumeDown.NAME] = function(_, dev) step_volume(dev, false) end,
    },
    [mute.ID] = {
      [mute.commands.mute.NAME] = function(_, dev) set_mute(dev, true) end,
      [mute.commands.unmute.NAME] = function(_, dev) set_mute(dev, false) end,
      [mute.commands.setMute.NAME] = function(_, dev, cmd) set_mute(dev, cmd.args.state == "muted") end,
    },
    [input.ID] = { [input.commands.setInputSource.NAME] = set_input },
    [tvsource.ID] = {
      [tvsource.commands.setSource.NAME] = set_source,
      [tvsource.commands.openMenu.NAME] = function(_, dev) send_keys(dev, { "KEY_SOURCE" }) end,
    },
    [capabilities.keypadInput.ID] = { [capabilities.keypadInput.commands.sendKey.NAME] = send_keypad },

    [channel.ID] = {
      [channel.commands.channelUp.NAME] = function(_, dev) send_keys(dev, { "KEY_CHUP" }) end,
      [channel.commands.channelDown.NAME] = function(_, dev) send_keys(dev, { "KEY_CHDOWN" }) end,
      [channel.commands.setTvChannel.NAME] = set_channel,
    },
  },
})

log.info("[tv] Samsung TV (local) driver starting, build " .. BUILD)
driver:run()
