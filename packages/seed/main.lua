local net = require("net/modem")
local protocol = require("net/protocol")
local computer = require("computer")

-- Config

local cfg = assert(loadfile("/etc/minechain/config.lua"))()
local PORT = cfg.PORT or protocol.PORT_SEED

-- State

-- peers[adresse_modem] = { last_seen = timestamp }
local peers = {}

local TIMEOUT_PEER = 120 -- secondes sans reponse -> peer mort
local CLEAN_EVERY = 60   -- intervalle de nettoyage

local lastClean = computer.uptime()

-- Helpers

local function peerList()
  local list = {}
  for addr, _ in pairs(peers) do
    table.insert(list, addr)
  end
  return list
end

local function peerCount()
  local n = 0
  for _ in pairs(peers) do n = n + 1 end
  return n
end

local function refreshPeer(addr)
  peers[addr] = { last_seen = computer.uptime() }
end

-- Handlers

local handlers = {}

handlers[protocol.MSG.JOIN] = function(remoteAddr, data)
  local isNew = (peers[remoteAddr] == nil)
  refreshPeer(remoteAddr)

  -- Repond au nouveau avec la liste complete
  net.send(remoteAddr, PORT, protocol.MSG.PEERS, protocol.peers(peerList()))

  if isNew then
    for existingAddr, _ in pairs(peers) do
      if existingAddr ~= remoteAddr then
        net.send(existingAddr, PORT, protocol.MSG.NEW_PEER, { address = remoteAddr })
      end
    end
    print(string.format("[+] Nouveau peer : %s  (total: %d)", remoteAddr, peerCount()))
  end
end

handlers[protocol.MSG.LEAVE] = function(remoteAddr, data)
  if peers[remoteAddr] then
    peers[remoteAddr] = nil
    print(string.format("[-] Peer parti   : %s  (total: %d)", remoteAddr, peerCount()))
  end
end

handlers[protocol.MSG.LIST] = function(remoteAddr, data)
  if peers[remoteAddr] then refreshPeer(remoteAddr) end
  net.send(remoteAddr, PORT, protocol.MSG.PEERS, protocol.peers(peerList()))
end

handlers[protocol.MSG.PING] = function(remoteAddr, data)
  if peers[remoteAddr] then refreshPeer(remoteAddr) end
  net.send(remoteAddr, PORT, protocol.MSG.PONG, protocol.ping())
end

-- Nettoyage periodique

local function cleanDeadPeers()
  local now, removed = computer.uptime(), 0

  for addr, info in pairs(peers) do
    if (now - info.last_seen) > TIMEOUT_PEER then
      peers[addr] = nil
      removed = removed + 1
      print("[x] Timeout : " .. addr)
    end
  end

  if removed > 0 then
    print(string.format("    %d supprime(s). Total : %d", removed, peerCount()))
  end
end

local function onTick()
  if (computer.uptime() - lastClean) >= CLEAN_EVERY then
    cleanDeadPeers()
    lastClean = computer.uptime()
  end
end

-- Demarrage

net.open(PORT)

print("╔══════════════════════════════════════╗")
print("║        Seed Node - MineChain         ║")
print("╠══════════════════════════════════════╣")
print("║ Adresse : " .. net.address())
print("║ Port    : " .. PORT)
print("╚══════════════════════════════════════╝")
print("En attente de connexions...\n")

-- Boucle principale via lib/net
net.listen(PORT, handlers, 5, onTick)
