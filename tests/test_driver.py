"""Driver flow with mocked SmartThings and a fake TV: discovery, power, volume, pairing, keys."""
from run_lua import runtime

HARNESS = r'''
-- events shaped like the hub's ({ capability = { ID }, attribute = { NAME }, value = { value } }), plus path/arg
local function capmock(path, segs)
  segs = segs or { "cap" }
  return setmetatable({}, {
    __index = function(t, k)
      if k == "NAME" then return segs[#segs] end
      local s = {}
      for i, x in ipairs(segs) do s[i] = x end
      s[#s + 1] = k
      local v = capmock(path .. "." .. k, s); rawset(t, k, v); return v end,
    __call = function(_, a, b)
      local val = a
      if type(val) ~= "table" then val = { value = segs[4] or a } end
      return { path = path, arg = a, capability = { ID = segs[2] }, attribute = { NAME = segs[3] }, value = val,
               visibility = b and b.visibility } end })
end
local caps = capmock("cap")
for _, id in ipairs({ "switch", "audioVolume", "audioMute", "mediaInputSource", "tvChannel", "refresh", "keypadInput", "momentary" }) do caps[id].ID = id end
caps["silvervalley08660.tvInput"].ID = "silvervalley08660.tvInput"
caps["silvervalley08660.tvSourceMenu"].ID = "silvervalley08660.tvSourceMenu"
for _, id in ipairs({}) do caps[id].ID = id end
package.loaded["st.capabilities"] = caps
package.loaded["st.driver"] = function(name, tmpl) DRIVER = tmpl; return { run = function() end } end
LOGS = {}
package.loaded["log"] = { info = function(m) LOGS[#LOGS + 1] = m end, warn = function(m) LOGS[#LOGS + 1] = "W " .. m end,
                          error = function(m) LOGS[#LOGS + 1] = "E " .. m end, debug = function() end }
SPAWNED = {}
package.loaded["cosock"] = { spawn = function(f) SPAWNED[#SPAWNED + 1] = f end, socket = { sleep = function() end } }
package.loaded["cosock.socket"] = {}; package.loaded["cosock.ssl"] = {}
TV = { power = "on", volume = 38, mute = "0", token = "tok1", allowed = true }
CALLS = {}
package.loaded["tv_api"] = {
  ssdp = function() return SSDP or { "192.168.1.27" } end,
  scan = function() return SCAN or {} end,
  info = function(ip)
    if TV.power == "off" or ip ~= "192.168.1.27" then return nil end
    return { device = { type = "Samsung SmartTV", name = "[TV] Samsung Q65", modelName = "QE65", PowerState = TV.power,
      model = TV.model,
      wifiMac = "AA:BB:CC:DD:EE:FF" } } end,
  soap = function(ip, action, args)
    CALLS[#CALLS + 1] = action .. (args or "")
    if TV.power ~= "on" then return nil end
    if action == "GetVolume" then return "<CurrentVolume>" .. TV.volume .. "</CurrentVolume>" end
    if action == "GetMute" then return "<CurrentMute>" .. TV.mute .. "</CurrentMute>" end
    return "<ok/>" end,
  keys = function(ip, token, keys, wait)
    CALLS[#CALLS + 1] = "keys:" .. tostring(token) .. ":" .. table.concat(keys, ",")
    if not TV.allowed then return nil, "refused" end
    if keys[1] == "KEY_POWER" then TV.power = TV.power == "on" and "standby" or "on" end
    return TV.token end,
  wol = function(mac, ip) CALLS[#CALLS + 1] = "wol:" .. mac .. "@" .. ip; TV.power = "on"; return true end,
}
DEVICES = {}
local function mkdev(o)
  o.fields = {}; o.events = {}; o.status = "offline"; o.preferences = o.preferences or {}
  o.thread = { call_on_schedule = function(_, _, f) POLLFN = f; return 1 end, call_with_delay = function(_, d, f, name)
    if name == "tv-first-poll" then FIRST = { d = d, f = f } end end, cancel_timer = function() end }
  function o:get_field(k) if self.fields[k] == nil then return end return self.fields[k] end  -- like the hub: nothing at all
  function o:set_field(k, v) self.fields[k] = v end
  function o:emit_event(e) self.events[e.path] = e.arg == nil and true or e.arg; self.events.n = (self.events.n or 0) + 1 end
  function o:online() self.status = "online" end
  function o:offline() self.status = "offline" end
  DEVICES[#DEVICES + 1] = o
  return o
end
DRV = { get_devices = function() return DEVICES end,
        try_create_device = function(_, o) local d = mkdev({ id = o.device_network_id, label = o.label,
          device_network_id = o.device_network_id, preferences = { ipAddress = "auto", macAddress = "auto" } })
          DRIVER.lifecycle_handlers.added(DRV, d) end }
'''


def setup():
    lua = runtime()
    lua.execute(HARNESS.encode())
    lua.execute(b'require("init")')
    lua.execute(b'DRIVER.discovery(DRV, {}, function() return true end); DEV = DEVICES[1]')
    lua.execute(b'FIRST.f()')   # the random first delay has passed: the schedule starts
    return lua


def ev(lua, name):
    return lua.eval(f'DEV.events["{name}"]'.encode())


def test_discovery_and_poll():
    lua = setup()
    g = lua.globals()
    assert g.DEV.label == b"Samsung Q65" and g.DEV.device_network_id == b"samsungtv-aabbccddeeff"
    assert g.DEV.fields[b"ip"] == b"192.168.1.27" and g.DEV.fields[b"mac"] == b"aabbccddeeff"
    lua.execute(b'DRIVER.capability_handlers.refresh.refresh(DRV, DEV)')
    assert ev(lua, "cap.switch.switch.on") is True
    assert ev(lua, "cap.audioVolume.volume") == 38
    assert ev(lua, "cap.audioMute.mute.unmuted") is True
    # not paired: pairing was started in the background
    assert len(g.SPAWNED) == 1
    lua.execute(b'SPAWNED[1]()')
    assert g.DEV.fields[b"token"] == b"tok1"
    # second discovery does not create another device
    lua.execute(b'DRIVER.discovery(DRV, {}, function() return true end)')
    assert len(g.DEVICES) == 1
    # no repeated events when nothing changes
    n = g.DEV.events.n
    lua.execute(b'POLLFN()')
    assert g.DEV.events.n == n


def test_commands():
    lua = setup()
    g = lua.globals()
    lua.execute(b'DEV.fields.token = "tok1"')
    lua.execute(b'DRIVER.capability_handlers.audioVolume.setVolume(DRV, DEV, { args = { volume = 20.4 } })')
    assert g.CALLS[len(g.CALLS)] == b"SetVolume<DesiredVolume>20</DesiredVolume>"
    assert ev(lua, "cap.audioVolume.volume") == 20
    lua.execute(b'DRIVER.capability_handlers.audioMute.setMute(DRV, DEV, { args = { state = "muted" } })')
    assert g.CALLS[len(g.CALLS)] == b"SetMute<DesiredMute>1</DesiredMute>"
    lua.execute(b'DRIVER.capability_handlers.mediaInputSource.setInputSource(DRV, DEV, { args = { mode = "HDMI2" } })')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_HDMI2" and ev(lua, "cap.mediaInputSource.inputSource") == b"HDMI2"
    lua.execute(b'DRIVER.capability_handlers.tvChannel.setTvChannel(DRV, DEV, { args = { tvChannel = "101" } })')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_1,KEY_0,KEY_1,KEY_ENTER"
    lua.execute(b'DRIVER.capability_handlers.switch.off(DRV, DEV)')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_POWER" and g.TV.power == b"standby"
    # on from network standby: wake-on-LAN first, no power key when that already woke it
    lua.execute(b'DRIVER.capability_handlers.switch.on(DRV, DEV)')
    assert g.CALLS[len(g.CALLS)] == b"wol:aabbccddeeff@192.168.1.27" and g.TV.power == b"on"
    # deep off: only wake-on-LAN
    lua.execute(b'TV.power = "off"; DRIVER.capability_handlers.switch.on(DRV, DEV)')
    assert g.CALLS[len(g.CALLS)] == b"wol:aabbccddeeff@192.168.1.27"


def test_tv_off_and_refused():
    lua = setup()
    g = lua.globals()
    n = len(g.SPAWNED)   # the first poll (setup) may already have asked for pairing
    lua.execute(b'TV.power = "off"; DRIVER.capability_handlers.refresh.refresh(DRV, DEV)')
    assert ev(lua, "cap.switch.switch.off") is True and len(g.SPAWNED) == n
    lua.execute(b'TV.power = "on"; TV.allowed = false; DRIVER.capability_handlers.refresh.refresh(DRV, DEV); SPAWNED[#SPAWNED]()')
    assert g.DEV.fields[b"token"] is None
    assert any(b"refused" in (m or b"") for m in g.LOGS.values())


def test_manual_ip():
    lua = setup()
    g = lua.globals()
    lua.execute(b'''DEV.preferences.ipAddress = "192.168.1.99"
      DRIVER.lifecycle_handlers.infoChanged(DRV, DEV, "x", { old_st_store = { preferences = { ipAddress = "auto" } } })''')
    assert g.DEV.fields[b"ip"] is None


def test_manual_then_scan():
    lua = runtime()
    lua.execute(HARNESS.encode())
    lua.execute(b'require("init")')
    lua.execute(b'SSDP = {}; DRIVER.discovery(DRV, {}, function() return true end); DEV = DEVICES[1]')
    g = lua.globals()
    assert g.DEV.device_network_id == b"samsungtv-manual"
    lua.execute(b'SCAN = { "192.168.1.5", "192.168.1.27" }; DRIVER.capability_handlers.refresh.refresh(DRV, DEV)')
    assert g.DEV.fields[b"ip"] == b"192.168.1.27"
    assert ev(lua, "cap.switch.switch.on") is True


def test_initial_input_and_channel():
    """The app greys out controls whose attribute never had a value: input and channel start with a value."""
    lua = setup()
    assert ev(lua, "cap.tvChannel.tvChannel") == b"-"


def test_soundbar_volume_by_keys():
    """Sound over HDMI ARC (soundbar): volume and mute as remote keys, the TV's own volume is not polled."""
    lua = setup()
    g = lua.globals()
    lua.execute(b'DEV.fields.token = "tok1"; DEV.preferences.soundOutput = "external"')
    lua.execute(b'DEV.get_latest_state = function() return 38 end')   # value the app shows
    lua.execute(b'TV.volume = 10; CALLS = {}; POLLFN()')
    assert not any(c.startswith(b"GetVolume") for c in g.CALLS.values())
    lua.execute(b'DRIVER.capability_handlers.audioVolume.setVolume(DRV, DEV, { args = { volume = 41 } })')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_VOLUP,KEY_VOLUP,KEY_VOLUP"
    assert ev(lua, "cap.audioVolume.volume") == 41
    lua.execute(b'DRIVER.capability_handlers.audioVolume.volumeDown(DRV, DEV)')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_VOLDOWN" and ev(lua, "cap.audioVolume.volume") == 40
    lua.execute(b'DRIVER.capability_handlers.audioMute.setMute(DRV, DEV, { args = { state = "muted" } })')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_MUTE"
    n = len(g.CALLS)
    lua.execute(b'DRIVER.capability_handlers.audioMute.mute(DRV, DEV)')   # already muted: no toggle
    assert len(g.CALLS) == n


def test_key_sequence_and_keypad():
    lua = setup()
    g = lua.globals()
    lua.execute(b'DEV.fields.token = "tok1"')
    lua.execute(b'DRIVER.capability_handlers.tvChannel.setTvChannel(DRV, DEV, { args = { tvChannel = "key_source+800+KEY_RIGHT" } })')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_SOURCE,800,KEY_RIGHT"
    lua.execute(b'DRIVER.capability_handlers.keypadInput.sendKey(DRV, DEV, { args = { keyCode = "LEFT" } })')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_LEFT"
    n = len(g.CALLS)
    lua.execute(b'DRIVER.capability_handlers.tvChannel.setTvChannel(DRV, DEV, { args = { tvChannel = "KEY_X;rm" } })')
    assert len(g.CALLS) == n   # invalid: nothing sent


def test_input_by_source_menu():
    lua = setup()
    g = lua.globals()
    lua.execute(b'DEV.fields.token = "tok1"; DEV.preferences.inputMethod = "menu"')
    lua.execute(b'DRIVER.capability_handlers.mediaInputSource.setInputSource(DRV, DEV, { args = { mode = "HDMI1" } })')
    assert g.CALLS[len(g.CALLS)] == (b"keys:tok1:KEY_SOURCE,1500,KEY_UP,KEY_UP,KEY_UP,KEY_UP,KEY_LEFT,KEY_LEFT,"
                                     b"KEY_DOWN,300,KEY_ENTER")
    assert ev(lua, "cap.mediaInputSource.inputSource") == b"HDMI1"
    lua.execute(b'DEV.preferences.menuPositions = "HDMI1=4"')
    lua.execute(b'DRIVER.capability_handlers.mediaInputSource.setInputSource(DRV, DEV, { args = { mode = "HDMI1" } })')
    assert g.CALLS[len(g.CALLS)].endswith(b"KEY_LEFT,KEY_LEFT,KEY_DOWN,KEY_RIGHT,300,KEY_ENTER")


def test_input_auto_by_model_year():
    lua = setup()
    g = lua.globals()
    lua.execute(b'DEV.fields.token = "tok1"; TV.model = "23_OSCP_8K_T09"')
    lua.execute(b'DRIVER.capability_handlers.refresh.refresh(DRV, DEV)')
    lua.execute(b'DRIVER.capability_handlers.mediaInputSource.setInputSource(DRV, DEV, { args = { mode = "HDMI1" } })')
    assert g.CALLS[len(g.CALLS)].startswith(b"keys:tok1:KEY_SOURCE,1500")
    lua.execute(b'DEV.fields.tv_year = 2019')
    lua.execute(b'DRIVER.capability_handlers.mediaInputSource.setInputSource(DRV, DEV, { args = { mode = "HDMI1" } })')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_HDMI1"


def test_source_button():
    lua = setup()
    g = lua.globals()
    lua.execute(b'DEV.fields.token = "tok1"')
    lua.execute(b'DRIVER.capability_handlers["silvervalley08660.tvInput"].openMenu(DRV, DEV, { args = {} })')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_SOURCE"
    lua.execute(b'DRIVER.capability_handlers["silvervalley08660.tvSourceMenu"].openMenu(DRV, DEV, { args = {} })')
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_SOURCE"
    assert lua.eval(b'DEV.events["cap.silvervalley08660.tvSourceMenu.menu"]') in (b"open", b"closed")


def sev(lua, attr):
    return lua.eval(f'DEV.events["cap.silvervalley08660.tvInput.{attr}"]'.encode())


def test_sources_by_name():
    lua = setup()
    g = lua.globals()
    lua.execute(b'DEV.fields.token = "tok1"; TV.model = "23_OSCP_8K_T09"')
    lua.execute(b'DRIVER.capability_handlers.refresh.refresh(DRV, DEV)')
    names = sev(lua, "supportedSources")
    assert [names[i] for i in range(1, len(names) + 1)] == [b"TV", b"HDMI 1", b"HDMI 2", b"HDMI 3", b"HDMI 4"]
    lua.execute(b'DEV.preferences.sources = "Tv=1, PC=3 ,Sonos Beam=KEY_HDMI3,bad=x;y"')
    lua.execute(b'DRIVER.lifecycle_handlers.infoChanged(DRV, DEV, "infoChanged", { old_st_store = { preferences = { ipAddress = "auto" } } })')
    names = sev(lua, "supportedSources")
    assert [names[i] for i in range(1, len(names) + 1)] == [b"Tv", b"PC", b"Sonos Beam"]
    H = b'DRIVER.capability_handlers["silvervalley08660.tvInput"].setSource(DRV, DEV, { args = { source = "%s" } })'
    lua.execute(H % b"PC")
    assert g.CALLS[len(g.CALLS)] == (b"keys:tok1:KEY_SOURCE,1500,KEY_UP,KEY_UP,KEY_UP,KEY_UP,KEY_LEFT,KEY_LEFT,"
                                     b"KEY_DOWN,300,KEY_ENTER")
    assert sev(lua, "source") == b"PC"
    lua.execute(H % b"Sonos Beam")
    assert g.CALLS[len(g.CALLS)] == b"keys:tok1:KEY_HDMI3"
    n = len(g.CALLS)
    lua.execute(H % b"Sonos Beam")   # list opened and closed without a choice: the shown source again
    assert len(g.CALLS) == n


def test_first_poll_random_delay():
    """The schedule starts after a random delay of 1..interval s, so TVs do not poll in lockstep."""
    lua = setup()
    g = lua.globals()
    assert 1 <= g.FIRST.d <= 10
    lua.execute(b'DEV.preferences.pollInterval = 60; FIRST = nil; DRIVER.lifecycle_handlers.infoChanged(DRV, DEV, {}, { preferences = {} })')
    assert g.FIRST is not None and 1 <= g.FIRST.d <= 60


def test_soundbar_mute_after_restart():
    """External sound: last_mute is persisted; when it is gone (Refresh, restart) the app's state decides."""
    lua = setup()
    g = lua.globals()
    lua.execute(b'DEV.fields.token = "tok1"; DEV.preferences.soundOutput = "external"')
    lua.execute(b'PERSIST = {}; local sf = DEV.set_field; DEV.set_field = function(self, k, v, o) PERSIST[k] = o and o.persist; sf(self, k, v) end')
    lua.execute(b'DRIVER.capability_handlers.audioMute.setMute(DRV, DEV, { args = { state = "muted" } })')
    assert g.DEV.fields[b"last_mute"] == b"1" and g.PERSIST[b"last_mute"] is True
    # restart / Refresh: the field is gone, the app shows muted -> Unmute must send the key
    lua.execute(b'DEV.fields.last_mute = nil; DEV.get_latest_state = function(_, c, cap, a) if a == "mute" then return "muted" end end')
    lua.execute(b'CALLS = {}; DRIVER.capability_handlers.audioMute.setMute(DRV, DEV, { args = { state = "unmuted" } })')
    assert g.CALLS[1] == b"keys:tok1:KEY_MUTE" and g.DEV.fields[b"last_mute"] == b"0"
    lua.execute(b'CALLS = {}; DRIVER.capability_handlers.audioMute.unmute(DRV, DEV)')   # already unmuted
    assert len(g.CALLS) == 0


def test_standard_inputs_for_routines():
    """Routines show no choices for the own Source list: the standard input list is emitted at init."""
    lua = setup()
    names = lua.eval(b'DEV.events["cap.mediaInputSource.supportedInputSources"]')
    assert names is not None
    assert [names[i] for i in range(1, 6)] == [b"digitalTv", b"HDMI1", b"HDMI2", b"HDMI3", b"HDMI4"]
