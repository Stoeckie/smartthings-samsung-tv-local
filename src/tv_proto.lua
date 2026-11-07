-- Pure helpers for the Samsung TV local protocols (no sockets): base64, websocket frames, UPnP SOAP, wake-on-LAN.
local M = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.b64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local t = {}
    for k = 3, 0, -1 do
      local idx = (n >> (6 * k)) & 63
      t[#t + 1] = B64:sub(idx + 1, idx + 1)
    end
    if not b then t[3], t[4] = "=", "=" elseif not c then t[4] = "=" end
    out[#out + 1] = table.concat(t)
  end
  return table.concat(out)
end

function M.urlencode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(ch) return string.format("%%%02X", ch:byte()) end))
end

M.CLIENT_NAME = "SmartThings Hub"

--- Path of the remote control channel; the token (after pairing) lets the TV skip the "Allow" question.
function M.ws_path(token)
  local p = "/api/v2/channels/samsung.remote.control?name=" .. M.urlencode(M.b64(M.CLIENT_NAME))
  if token and token ~= "" then p = p .. "&token=" .. M.urlencode(token) end
  return p
end

function M.ws_upgrade(host, port, path, key)
  return table.concat({
    "GET " .. path .. " HTTP/1.1",
    "Host: " .. host .. ":" .. port,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
    "User-Agent: smartthings-edge-samsung-tv-local",
  }, "\r\n") .. "\r\n\r\n"
end

--- Client frame (always masked, RFC 6455). opcode 1 = text, 8 = close, 10 = pong.
function M.ws_frame(payload, opcode, mask)
  opcode = opcode or 1
  mask = mask or string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255))
  local n = #payload
  local head
  if n < 126 then
    head = string.char(0x80 | opcode, 0x80 | n)
  elseif n < 65536 then
    head = string.char(0x80 | opcode, 0x80 | 126) .. string.pack(">I2", n)
  else
    head = string.char(0x80 | opcode, 0x80 | 127) .. string.pack(">I8", n)
  end
  local m = { mask:byte(1, 4) }
  local out = {}
  for i = 1, n do out[i] = string.char(payload:byte(i) ~ m[(i - 1) % 4 + 1]) end
  return head .. mask .. table.concat(out)
end

--- Read one frame with recv(n) -> bytes or nil, err. Returns opcode, payload or nil, err.
function M.ws_read(recv)
  local h, err = recv(2)
  if not h then return nil, err end
  local b1, b2 = h:byte(1, 2)
  local opcode, masked, n = b1 & 0x0f, (b2 & 0x80) ~= 0, b2 & 0x7f
  if n == 126 then
    local x; x, err = recv(2); if not x then return nil, err end
    n = string.unpack(">I2", x)
  elseif n == 127 then
    local x; x, err = recv(8); if not x then return nil, err end
    n = string.unpack(">I8", x)
  end
  local mask
  if masked then mask, err = recv(4); if not mask then return nil, err end end
  local data = ""
  if n > 0 then data, err = recv(n); if not data then return nil, err end end
  if mask then
    local m = { mask:byte(1, 4) }
    local out = {}
    for i = 1, #data do out[i] = string.char(data:byte(i) ~ m[(i - 1) % 4 + 1]) end
    data = table.concat(out)
  end
  return opcode, data
end

function M.key_message(key)
  return string.format('{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"%s",'
    .. '"Option":"false","TypeOfRemote":"SendRemoteKey"}}', key)
end

M.RC = "/upnp/control/RenderingControl1"

function M.soap(action, args)
  local body = '<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    .. 's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
    .. '<u:' .. action .. ' xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID>'
    .. '<Channel>Master</Channel>' .. (args or "") .. '</u:' .. action .. '></s:Body></s:Envelope>'
  local headers = {
    ["Content-Type"] = 'text/xml; charset="utf-8"',
    ["SOAPACTION"] = '"urn:schemas-upnp-org:service:RenderingControl:1#' .. action .. '"',
  }
  return headers, body
end

function M.xml_value(xml, tag)
  return (tostring(xml or ""):match("<" .. tag .. ">%s*(.-)%s*</" .. tag .. ">"))
end

function M.clean_mac(mac)
  local hex = tostring(mac or ""):gsub("[^%x]", ""):lower()
  if #hex ~= 12 then return nil end
  return hex
end

function M.wol_packet(mac)
  local hex = M.clean_mac(mac)
  if not hex then return nil end
  local raw = hex:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)
  return string.rep("\255", 6) .. string.rep(raw, 16)
end

--- Directed broadcast for a /24 network (the usual home LAN).
function M.broadcast_for(ip)
  local a, b, c = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
  if a then return a .. "." .. b .. "." .. c .. ".255" end
end

M.INPUTS = { HDMI1 = "KEY_HDMI1", HDMI2 = "KEY_HDMI2", HDMI3 = "KEY_HDMI3", HDMI4 = "KEY_HDMI4", digitalTv = "KEY_DTV" }
M.INPUT_LIST = { "HDMI1", "HDMI2", "HDMI3", "HDMI4", "digitalTv" }

--- Keys for a channel number: digits then enter.
function M.channel_keys(ch)
  local s = tostring(ch or ""):gsub("%s", "")
  if not s:match("^%d+$") or #s > 5 then return nil end
  local keys = {}
  for d in s:gmatch("%d") do keys[#keys + 1] = "KEY_" .. d end
  keys[#keys + 1] = "KEY_ENTER"
  return keys
end

--- Volume keys to go from `from` to `to` (at most `max` keys).
function M.volume_keys(from, to, max)
  local d = math.floor((tonumber(to) or 0) - (tonumber(from) or 0) + 0.5)
  local n = math.min(math.abs(d), max or 50)
  local keys = {}
  for i = 1, n do keys[i] = d > 0 and "KEY_VOLUP" or "KEY_VOLDOWN" end
  return keys
end

--- Key sequence "KEY_SOURCE+800+KEY_RIGHT+KEY_ENTER": keys and pauses in ms. Returns a list or nil.
function M.key_sequence(s)
  s = tostring(s or ""):gsub("%s", "")
  if s == "" or #s > 300 then return nil end
  local out = {}
  for part in s:gmatch("[^+]+") do
    local ms = tonumber(part)
    if ms then
      if ms < 0 or ms > 5000 then return nil end
      out[#out + 1] = ms
    else
      local k = M.valid_key(part)
      if not k then return nil end
      out[#out + 1] = k
    end
    if #out > 30 then return nil end
  end
  if #out == 0 then return nil end
  return out
end

--- Model year from /api/v2/ device.model ("23_OSCP_8K_T09" -> 2023), or nil.
function M.model_year(info)
  local m = type(info) == "table" and type(info.device) == "table" and tostring(info.device.model or "") or ""
  local yy = tonumber(m:match("^(%d%d)_"))
  if yy then return 2000 + yy end
end

M.DEFAULT_SOURCES_MENU = "TV=1,HDMI 1=3,HDMI 2=4,HDMI 3=5,HDMI 4=6"
M.DEFAULT_SOURCES_KEYS = "TV=KEY_TV,HDMI 1=KEY_HDMI1,HDMI 2=KEY_HDMI2,HDMI 3=KEY_HDMI3,HDMI 4=KEY_HDMI4"

--- Source list "Tv=1,PC=3,Sonos Beam=KEY_HDMI3": name = tile number in the Source menu, or a key sequence.
--- Returns an ordered list of { name, pos } / { name, keys }.
function M.sources(s)
  local out = {}
  for part in tostring(s or ""):gmatch("[^,]+") do
    local name, val = part:match("^%s*(.-)%s*=%s*(.-)%s*$")
    if name and name ~= "" and #name <= 40 and #out < 20 then
      local n = tonumber(val)
      if n and n >= 1 and n <= 30 and n == math.floor(n) then
        out[#out + 1] = { name = name, pos = n }
      else
        local keys = M.key_sequence(val)
        if keys then out[#out + 1] = { name = name, keys = keys } end
      end
    end
  end
  return out
end

--- Positions in the Source menu, "digitalTv=1,HDMI1=3" -> { digitalTv = 1, HDMI1 = 3 }.
function M.menu_positions(s)
  local out = {}
  for name, pos in tostring(s or ""):gmatch("([%w]+)%s*=%s*(%d+)") do
    local n = tonumber(pos)
    if M.INPUTS[name] and n and n >= 1 and n <= 20 then out[name] = n end
  end
  return out
end

--- Keys to pick tile `pos` (1 = top left, reading order) in the Source menu grid of `cols` columns:
--- open the menu, go to the top left corner (extra presses stop at the edge), then down and right, OK.
function M.menu_keys(pos, cols, open_ms)
  cols = cols or 2
  local keys = { "KEY_SOURCE", open_ms or 1500 }
  for _ = 1, 4 do keys[#keys + 1] = "KEY_UP" end
  for _ = 1, cols do keys[#keys + 1] = "KEY_LEFT" end
  local row, col = (pos - 1) // cols, (pos - 1) % cols
  for _ = 1, row do keys[#keys + 1] = "KEY_DOWN" end
  for _ = 1, col do keys[#keys + 1] = "KEY_RIGHT" end
  keys[#keys + 1] = 300
  keys[#keys + 1] = "KEY_ENTER"
  return keys
end

-- keypadInput key codes -> remote keys
M.KEYPAD = { UP = "KEY_UP", DOWN = "KEY_DOWN", LEFT = "KEY_LEFT", RIGHT = "KEY_RIGHT", SELECT = "KEY_ENTER",
  BACK = "KEY_RETURN", EXIT = "KEY_EXIT", MENU = "KEY_MENU", SETTINGS = "KEY_MENU", HOME = "KEY_HOME" }
for i = 0, 9 do M.KEYPAD["NUMBER" .. i] = "KEY_" .. i end
M.KEYPAD_LIST = { "UP", "DOWN", "LEFT", "RIGHT", "SELECT", "BACK", "EXIT", "MENU", "SETTINGS", "HOME" }

function M.valid_key(k)
  k = tostring(k or ""):upper()
  if k:match("^KEY_[%w_]+$") then return k end
end

--- Power from the /api/v2/ answer: "on", "standby" (network standby, answers but screen off) or "off".
function M.power(info)
  if type(info) ~= "table" then return "off" end
  local dev = info.device or {}
  local ps = tostring(dev.PowerState or "on"):lower()
  return ps == "on" and "on" or "standby"
end

return M
