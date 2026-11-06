-- Network side for Samsung Tizen TVs (2016 and later) on the LAN:
--   http://tv:8001/api/v2/                      device info and PowerState
--   http://tv:9197/upnp/control/RenderingControl1  volume and mute (UPnP SOAP)
--   wss://tv:8002/api/v2/channels/samsung.remote.control  remote control keys (token after "Allow" on the TV)
--   wake-on-LAN (UDP 9) and SSDP discovery
local socket = require "cosock.socket"
local ssl = require "cosock.ssl"
local json = require "st.json"
local proto = require "tv_proto"

local M = {}
M.TIMEOUT = 4

local function read_head(sock)
  local line, err = sock:receive("*l")
  if not line then return nil, "receive status: " .. tostring(err) end
  local status = tonumber(line:match("^HTTP/%d%.?%d?%s+(%d+)"))
  if not status then return nil, "bad status line" end
  local headers = {}
  while true do
    line, err = sock:receive("*l")
    if not line then return nil, "receive headers: " .. tostring(err) end
    if line == "" then break end
    local k, v = line:match("^([^:]+):%s*(.-)%s*$")
    if k then headers[k:lower()] = v end
  end
  return status, headers
end

local function read_body(sock, headers)
  local parts = {}
  if (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
    while true do
      local line, rerr = sock:receive("*l")
      if not line then return nil, "receive chunk size: " .. tostring(rerr) end
      local size = tonumber(line:match("^%s*(%x+)"), 16)
      if not size then return nil, "bad chunk size" end
      if size == 0 then break end
      local data, cerr = sock:receive(size)
      if not data then return nil, "receive chunk: " .. tostring(cerr) end
      parts[#parts + 1] = data
      sock:receive("*l")
    end
  elseif headers["content-length"] then
    local len = tonumber(headers["content-length"]) or 0
    if len > 0 then
      local data, cerr = sock:receive(len)
      if not data then return nil, "receive body: " .. tostring(cerr) end
      parts[#parts + 1] = data
    end
  else
    local data, _, partial = sock:receive("*a")
    parts[#parts + 1] = data or partial or ""
  end
  return table.concat(parts)
end

--- Plain HTTP request. Returns status, body or nil, err.
function M.http(method, host, port, path, headers, body)
  local sock, err = socket.tcp()
  if not sock then return nil, "tcp: " .. tostring(err) end
  sock:settimeout(M.TIMEOUT)
  local ok, cerr = sock:connect(host, port)
  if not ok then sock:close(); return nil, "connect: " .. tostring(cerr) end
  local lines = { method .. " " .. path .. " HTTP/1.1", "Host: " .. host .. ":" .. port, "Connection: close",
    "User-Agent: smartthings-edge-samsung-tv-local" }
  for k, v in pairs(headers or {}) do lines[#lines + 1] = k .. ": " .. v end
  if body then lines[#lines + 1] = "Content-Length: " .. #body end
  local sent, serr = sock:send(table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or ""))
  if not sent then sock:close(); return nil, "send: " .. tostring(serr) end
  local status, h = read_head(sock)
  if not status then sock:close(); return nil, h end
  local data, berr = read_body(sock, h)
  sock:close()
  if not data then return nil, berr end
  return status, data
end

--- /api/v2/ of the TV, or nil when it does not answer (off or deep standby).
function M.info(host)
  local status, data = M.http("GET", host, 8001, "/api/v2/")
  if status ~= 200 then return nil, data end
  local ok, obj = pcall(json.decode, data)
  if ok and type(obj) == "table" then return obj end
  return nil, "invalid JSON"
end

function M.soap(host, action, args)
  local headers, body = proto.soap(action, args)
  local status, data = M.http("POST", host, 9197, proto.RC, headers, body)
  if status == 200 then return data end
  return nil, status and ("HTTP " .. status) or data
end

--- Open the remote control channel. Waits up to `wait` seconds for the TV (the first time it shows "Allow").
--- Returns conn, token or nil, err.
function M.ws_open(host, token, wait)
  local sock, err = socket.tcp()
  if not sock then return nil, "tcp: " .. tostring(err) end
  sock:settimeout(M.TIMEOUT)
  local ok, cerr = sock:connect(host, 8002)
  if not ok then sock:close(); return nil, "connect: " .. tostring(cerr) end
  -- the TV has a self-signed certificate; LAN only
  local tls, werr = ssl.wrap(sock, { mode = "client", protocol = "any", verify = "none", options = "all" })
  if not tls then sock:close(); return nil, "tls wrap: " .. tostring(werr) end
  local hs, herr = tls:dohandshake()
  if not hs then tls:close(); return nil, "tls handshake: " .. tostring(herr) end
  local raw = {}
  for i = 1, 16 do raw[i] = string.char(math.random(0, 255)) end
  local sent, serr = tls:send(proto.ws_upgrade(host, 8002, proto.ws_path(token), proto.b64(table.concat(raw))))
  if not sent then tls:close(); return nil, "send: " .. tostring(serr) end
  local status, h = read_head(tls)
  if status ~= 101 then tls:close(); return nil, "websocket upgrade: " .. tostring(status or h) end
  local conn = { sock = tls }
  local deadline = socket.gettime() + (wait or 10)
  while true do
    local left = deadline - socket.gettime()
    if left <= 0 then tls:close(); return nil, "no answer from the TV (choose Allow on the TV screen)" end
    tls:settimeout(left)
    local op, data = proto.ws_read(function(n) return tls:receive(n) end)
    if not op then tls:close(); return nil, "TV closed the connection (" .. tostring(data) .. "), Allow not chosen?" end
    if op == 8 then tls:close(); return nil, "TV closed the connection, Allow not chosen?" end
    if op == 9 then tls:send(proto.ws_frame(data, 10)) end
    if op == 1 then
      local okj, ev = pcall(json.decode, data)
      ev = okj and type(ev) == "table" and ev or {}
      if ev.event == "ms.channel.connect" then
        local tok = type(ev.data) == "table" and ev.data.token or nil
        return conn, tok and tostring(tok) or token
      elseif ev.event == "ms.channel.unauthorized" then
        tls:close()
        return nil, "refused by the TV (Settings > General > External Device Manager > Device Connection Manager)"
      end
    end
  end
end

function M.ws_send_key(conn, key)
  return conn.sock:send(proto.ws_frame(proto.key_message(key)))
end

function M.ws_close(conn)
  pcall(function() conn.sock:send(proto.ws_frame("", 8)) end)
  pcall(function() conn.sock:close() end)
end

--- Send keys. Returns token (possibly new) or nil, err.
function M.keys(host, token, keys, wait)
  local conn, tok = M.ws_open(host, token, wait)
  if not conn then return nil, tok end
  for i, k in ipairs(keys) do
    local ok, err = M.ws_send_key(conn, k)
    if not ok then M.ws_close(conn); return nil, "send key: " .. tostring(err) end
    if i < #keys then socket.sleep(0.4) end
  end
  socket.sleep(0.3)
  M.ws_close(conn)
  return tok or ""
end

--- Magic packet to the TV address, the /24 broadcast and the global broadcast (3 times each).
function M.wol(mac, ip)
  local pkt = proto.wol_packet(mac)
  if not pkt then return nil, "no valid MAC address" end
  local udp = socket.udp()
  if not udp then return nil, "udp" end
  pcall(function() udp:setoption("broadcast", true) end)
  local targets = { "255.255.255.255" }
  local bc = proto.broadcast_for(ip)
  if bc then targets[#targets + 1] = bc end
  if ip then targets[#targets + 1] = ip end
  local sent = 0
  for _ = 1, 3 do
    for _, t in ipairs(targets) do
      local ok, res = pcall(function() return udp:sendto(pkt, t, 9) end)
      if ok and res then sent = sent + 1 end
    end
  end
  udp:close()
  return sent > 0
end

local SSDP_ST = "urn:samsung.com:device:RemoteControlReceiver:1"

--- SSDP search for Samsung TVs; returns a list of IP addresses.
function M.ssdp(timeout)
  local udp = socket.udp()
  if not udp then return {} end
  udp:setsockname("*", 0)
  udp:settimeout(1)
  local msg = table.concat({ "M-SEARCH * HTTP/1.1", "HOST: 239.255.255.250:1900", 'MAN: "ssdp:discover"', "MX: 2",
    "ST: " .. SSDP_ST }, "\r\n") .. "\r\n\r\n"
  udp:sendto(msg, "239.255.255.250", 1900)
  local found, seen = {}, {}
  local deadline = socket.gettime() + (timeout or 4)
  while socket.gettime() < deadline do
    local data, ip = udp:receivefrom()
    if data and ip and not seen[ip] and tostring(data):lower():find("samsung", 1, true) then
      seen[ip] = true
      found[#found + 1] = ip
    end
  end
  udp:close()
  return found
end

return M
