local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")

local M = {}

-- Init

assert(component.isAvailable("modem"), "Carte reseau introuvable !")
local _modem = component.modem

-- Buffer par port : les messages recus sur un port non attendu sont stockes ici
local _buffer = {}

local function bufferPush(port, entry)
  if not _buffer[port] then _buffer[port] = {} end
  table.insert(_buffer[port], entry)
end

local function bufferPop(port)
  if _buffer[port] and #_buffer[port] > 0 then
    return table.remove(_buffer[port], 1)
  end
end

-- Ouvre un port d'ecoute
function M.open(port)
  _modem.open(port)
end

-- Ferme un port
function M.close(port)
  _modem.close(port)
end

-- Retourne l'adresse modem de cette machine
function M.address()
  return _modem.address
end

-- Envoi

-- Envoie un message a une adresse precise
-- addr : adresse modem destinataire
-- port : port d'ecoute du destinataire
-- msgType : string (ex: "JOIN", "NEW_BLOCK"...)
-- payload : table Lua (donnees du message)
function M.send(addr, port, msgType, payload)
  assert(type(addr)    == "string", "send: addr doit etre une string")
  assert(type(port)    == "number", "send: port doit etre un number")
  assert(type(msgType) == "string", "send: msgType doit etre une string")

  local msg = serialization.serialize({
    type = msgType,
    data = payload or {}
  })

  _modem.send(addr, port, msg)
end

-- Broadcast sur le reseau local OC (tous les modems sur le meme reseau)
-- port : port d'ecoute
-- msgType : string
-- payload : table
function M.broadcast(port, msgType, payload)
  assert(type(port)    == "number", "broadcast: port doit etre un number")
  assert(type(msgType) == "string", "broadcast: msgType doit etre une string")

  local msg = serialization.serialize({
    type = msgType,
    data = payload or {}
  })

  _modem.broadcast(port, msg)
end

-- Reception

-- Ecoute un message entrant avec timeout
-- port : port a ecouter
-- timeout : secondes max d'attente (defaut: 5)
-- Retourne: remoteAddr, msgType, payload ou nil si timeout
function M.receive(port, timeout)
  timeout = timeout or 5

  local buffered = bufferPop(port)
  if buffered then
    return table.unpack(buffered)
  end

  local deadline = computer.uptime() + timeout

  while computer.uptime() < deadline do
    local remaining = deadline - computer.uptime()
    if remaining <= 0 then break end

    local ev = { event.pull(math.max(remaining, 0.05), "modem_message") }
    if ev[1] ~= "modem_message" then break end

    local _, _, remoteAddr, evPort, _, raw = table.unpack(ev)
    local ok, msg = pcall(serialization.unserialize, raw)

    if not ok or type(msg) ~= "table" or not msg.type then
      -- message malforme, on ignore
    elseif evPort == port then
      -- c'est pour nous
      return remoteAddr, msg.type, msg.data or {}
    else
      -- mauvais port : on bufferise pour plus tard au lieu de jeter
      bufferPush(evPort, { remoteAddr, msg.type, msg.data or {} })
    end
  end

  return nil
end

-- Ecoute en boucle et dispatch vers des handlers
-- port : port a ecouter
-- handlers : table { ["TYPE"] = function(remoteAddr, data) end }
-- timeout : timeout entre chaque ecoute (pour intercaler des taches)
-- onTick : fonction appelee à chaque timeout (optionnel, pour taches periodiques)
function M.listen(port, handlers, timeout, onTick)
  timeout = timeout or 5

  while true do
    local remoteAddr, msgType, data = M.receive(port, timeout)

    if remoteAddr and msgType then
      local handler = handlers[msgType]
      if handler then
        local ok, err = pcall(handler, remoteAddr, data)
        if not ok then
          print("[!] Erreur handler " .. msgType .. " : " .. tostring(err))
        end
      else
        print("[?] Type inconnu : " .. msgType .. " de " .. remoteAddr)
      end
    elseif remoteAddr and not msgType then
      print("[!] Message malforme de : " .. remoteAddr)
    end

    if onTick then
      local ok, err = pcall(onTick)
      if not ok then
        print("[!] Erreur onTick : " .. tostring(err))
      end
    end
  end
end

return M