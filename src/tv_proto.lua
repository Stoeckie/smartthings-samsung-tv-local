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
