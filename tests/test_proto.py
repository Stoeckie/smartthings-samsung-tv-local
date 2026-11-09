"""Pure protocol helpers: base64, websocket frames, SOAP, wake-on-LAN, channel keys."""
import base64
from run_lua import runtime, req


def test_b64_and_path():
    lua = runtime()
    p = req(lua, "tv_proto")
    for s in [b"", b"a", b"ab", b"abc", b"SmartThings Hub", bytes(range(256))]:
        assert p.b64(s) == base64.b64encode(s)
    assert p.ws_path(None) == b"/api/v2/channels/samsung.remote.control?name=U21hcnRUaGluZ3MgSHVi"
    assert p.ws_path(b"12 34").endswith(b"&token=12%2034")


def test_frames():
    lua = runtime()
    p = req(lua, "tv_proto")
    for n in [0, 5, 125, 126, 300, 70000]:
        payload = bytes((i * 7) % 256 for i in range(n))
        fr = p.ws_frame(payload, 1, b"\x01\x02\x03\x04")
        assert fr[0] == 0x81 and fr[1] & 0x80
        # unmask like a server would
        lua.globals().FR = fr
        op, data = lua.execute(b'''local p = require("tv_proto"); local pos = 1
          return p.ws_read(function(n) local s = FR:sub(pos, pos + n - 1); pos = pos + n; return s end)''')
        assert op == 1 and data == payload
    # unmasked server frame with 16 bit length
    srv = b"\x81\x7e" + (200).to_bytes(2, "big") + b"x" * 200
    lua.globals().FR = srv
    op, data = lua.execute(b'''local p = require("tv_proto"); local pos = 1
      return p.ws_read(function(n) local s = FR:sub(pos, pos + n - 1); pos = pos + n; return s end)''')
    assert op == 1 and data == b"x" * 200


def test_soap_wol_keys():
    lua = runtime()
    p = req(lua, "tv_proto")
    h, body = p.soap(b"SetVolume", b"<DesiredVolume>12</DesiredVolume>")
    assert b"<u:SetVolume" in body and b"<DesiredVolume>12</DesiredVolume>" in body
    assert h[b"SOAPACTION"] == b'"urn:schemas-upnp-org:service:RenderingControl:1#SetVolume"'
    assert p.xml_value(b"<a><CurrentVolume> 38 </CurrentVolume></a>", b"CurrentVolume") == b"38"
    pkt = p.wol_packet(b"AA:BB:CC:DD:EE:FF")
    assert pkt == b"\xff" * 6 + bytes.fromhex("aabbccddeeff") * 16
    assert p.wol_packet(b"auto") is None
    assert p.broadcast_for(b"192.168.1.20") == b"192.168.1.255"
    keys = p.channel_keys(b"12")
    assert [keys[i] for i in range(1, 4)] == [b"KEY_1", b"KEY_2", b"KEY_ENTER"]
    assert p.channel_keys(b"x1") is None
    assert p.key_message(b"KEY_POWER").startswith(b'{"method":"ms.remote.control"')


def test_power():
    lua = runtime()
    p = req(lua, "tv_proto")
    j = lua.execute(b'return require("st.json")')
    assert p.power(None) == b"off"
    assert p.power(j.decode(b'{"device":{"PowerState":"on"}}')) == b"on"
    assert p.power(j.decode(b'{"device":{"PowerState":"standby"}}')) == b"standby"
    assert p.power(j.decode(b'{"device":{}}')) == b"on"


def test_scan_in_batches():
    """The /24 scan keeps at most 32 sockets open at once and still tries every address."""
    lua = runtime()
    found, peak, tried = lua.execute(b'''
      local OPEN, PEAK, TRIED, NOW, QUEUE = 0, 0, 0, 0, {}
      package.loaded["cosock"] = { spawn = function(f) QUEUE[#QUEUE + 1] = coroutine.create(f) end }
      package.loaded["cosock.ssl"] = {}
      package.loaded["log"] = { info = function() end, warn = function() end, error = function() end, debug = function() end }
      package.loaded["cosock.socket"] = {
        gettime = function() return NOW end,
        sleep = function(t)   -- run the workers: each connect yields once (a pending connection)
          NOW = NOW + t
          for _, co in ipairs(QUEUE) do if coroutine.status(co) == "suspended" then assert(coroutine.resume(co)) end end
        end,
        tcp = function()
          OPEN = OPEN + 1; PEAK = math.max(PEAK, OPEN)
          return { settimeout = function() end, close = function() OPEN = OPEN - 1 end,
                   connect = function(_, ip) TRIED = TRIED + 1; coroutine.yield(); return ip == "10.0.0.27" end }
        end }
      package.loaded["tv_api"] = nil
      local api = require("tv_api")
      local f = api.scan("10.0.0")
      return f, PEAK, TRIED''')
    assert peak <= 32 and tried == 254
    assert list(found.values()) == [b"10.0.0.27"]
