local net = require("net/modem")
local proto = require("net/protocol")
local block = require("types/block")
local tx = require("types/transaction")
local sync = require("node/sync")
local mempool = require("node/mempool")
local miner = require("node/miner")
local component = require("component")
local event = require("event")
local computer = require("computer")
local serialization = require("serialization")

local cfg = assert(loadfile("/etc/minechain/config.lua"))()
local PORT = cfg.PORT    or 43
local MINING = cfg.MINING  or false

-- Limites de connexions separees
local MAX_PEERS_OUT = cfg.MAX_PEERS_OUT or 4
local MAX_PEERS_IN  = cfg.MAX_PEERS_IN  or 8

local chain = {}
-- peers[addr] = { last_seen, direction = "in"|"out" }
local peers = {}

local _resyncPeer = nil

-- Helpers

local function peerList_main()
  local list = {}
  for addr, _ in pairs(peers) do table.insert(list, addr) end
  return list
end

local function lastBlock()
  return chain[#chain]
end

local function countByDirection(dir)
  local n = 0
  for _, p in pairs(peers) do
    if p.direction == dir then n = n + 1 end
  end
  return n
end

-- Ajoute un peer sortant (on le contacte)
local function addPeerOut(addr)
  if addr == net.address() then return false end
  if peers[addr] then
    peers[addr].last_seen = os.time()
    return true
  end
  if countByDirection("out") >= MAX_PEERS_OUT then
    return false
  end
  peers[addr] = { last_seen = os.time(), direction = "out" }
  return true
end

-- Ajoute un peer entrant (il nous contacte)
local function addPeerIn(addr)
  if addr == net.address() then return false end
  if peers[addr] then
    peers[addr].last_seen = os.time()
    return true
  end
  if countByDirection("in") >= MAX_PEERS_IN then
    print("[main] Max peers entrants atteint, " .. addr .. " refuse.")
    return false
  end
  peers[addr] = { last_seen = os.time(), direction = "in" }
  return true
end

local function broadcast(msgType, payload)
  for addr, _ in pairs(peers) do
    net.send(addr, PORT, msgType, payload)
  end
end

-- Connexion aux seeds

local seeds = {}

local function connectToSeeds()
  local ok, loaded = pcall(function()
    return assert(loadfile("/etc/minechain/seeds.lua"))()
  end)

  if not ok or type(loaded) ~= "table" or #loaded == 0 then
    print("[main] Aucun seed configure.")
    return
  end

  seeds = loaded
  print(string.format("[main] Contacte %d seed(s)...", #seeds))

  for _, seedAddr in ipairs(seeds) do
    net.send(seedAddr, proto.PORT_SEED, proto.MSG.JOIN,
      proto.join(net.address()))
  end

  local deadline = computer.uptime() + 2
  while computer.uptime() < deadline do
    local remoteAddr, msgType, data = net.receive(proto.PORT_SEED, 1)
    if remoteAddr and msgType == proto.MSG.PEERS then
      for _, peerAddr in ipairs(data.peers or {}) do
        addPeerOut(peerAddr)
      end
      break
    end
  end

  print(string.format("[main] %d peer(s) decouvert(s).", countByDirection("out")))
end

local function announceTopeers()
  broadcast(proto.MSG.JOIN, proto.join(net.address()))
end

-- Handlers

local handlers = {}

-- Ping -> Pong
handlers[proto.MSG.PING] = function(remoteAddr, data)
  if peers[remoteAddr] then peers[remoteAddr].last_seen = os.time() end
  net.send(remoteAddr, PORT, proto.MSG.PONG, proto.ping())
end

-- Pong -> refresh last_seen
handlers[proto.MSG.PONG] = function(remoteAddr, data)
  if peers[remoteAddr] then peers[remoteAddr].last_seen = os.time() end
end

-- Quelqu'un nous contacte -> connexion entrante
handlers[proto.MSG.JOIN] = function(remoteAddr, data)
  addPeerIn(remoteAddr)
  net.send(remoteAddr, PORT,
    proto.MSG.LAST_BLOCK, proto.lastBlock(lastBlock()))
end

-- Un peer quitte le reseau
handlers[proto.MSG.LEAVE] = function(remoteAddr, data)
  peers[remoteAddr] = nil
  print("[main] Peer parti : " .. remoteAddr)
end

-- Le seed nous notifie d'un nouveau peer
handlers[proto.MSG.NEW_PEER] = function(remoteAddr, data)
  if not data.address then return end
  if data.address == net.address() then return end
  if peers[data.address] then return end

  print("[main] Nouveau peer via seed : " .. data.address)

  -- On essaie de le contacter (connexion sortante)
  if addPeerOut(data.address) then
    net.send(data.address, PORT, proto.MSG.JOIN,
      proto.join(net.address()))
  end
end

-- Nouveau bloc recu
handlers[proto.MSG.NEW_BLOCK] = function(remoteAddr, data)
  if not proto.validate(proto.MSG.NEW_BLOCK, data) then return end

  local adopted, resyncAddr = sync.onNewBlock(remoteAddr, data.block)
  if adopted then
    -- Nettoie la mempool des tx confirmees
    mempool.removeConfirmed(data.block)

    -- Rebroadcast aux autres peers (on ne rebroadcast pas a l'expediteur)
    for addr, _ in pairs(peers) do
      if addr ~= remoteAddr then
        net.send(addr, PORT, proto.MSG.NEW_BLOCK, proto.newBlock(data.block))
      end
    end

    -- Signale au miner de recommencer sur le nouveau dernier bloc
    if MINING then miner.reset() end

  elseif resyncAddr then
    -- Gap detecte, programmer une resync hors handler
    _resyncPeer = resyncAddr
  end
end

handlers[proto.MSG.LAST_BLOCK] = function(remoteAddr, data)
  if not data.block then return end
  local peerIndex = data.block.index
  local ourIndex  = lastBlock().index
  if peerIndex > ourIndex + 1 then
    print(string.format("[main] Peer plus avance (#%d vs #%d), resync...",
      peerIndex, ourIndex))
    _resyncPeer = remoteAddr
  end
end

-- Nouvelle transaction recue
handlers[proto.MSG.NEW_TX] = function(remoteAddr, data)
  if not data.transaction or not data.public_key then return end

  -- Reconstruit la cle publique depuis sa forme serialisee
  local ok, pubKey = pcall(function()
    return component.data.deserializeKey(serialization.unserialize(data.public_key), "ec-public")
  end)
  if not ok or not pubKey then
    print("[main] Cle publique invalide dans NEW_TX")
    return
  end

  local added, err = mempool.add(data.transaction, pubKey, chain)
  if not added then
    print("[main] TX refusee : " .. tostring(err))
    return
  end

  -- Rebroadcast
  for addr, _ in pairs(peers) do
    if addr ~= remoteAddr then
      net.send(addr, PORT, proto.MSG.NEW_TX, data)
    end
  end
end

-- Reponse aux demandes de sync
handlers[proto.MSG.GET_LAST]  = function(remoteAddr, data)
  print("[main] GET_LAST recu de " .. remoteAddr)
  sync.onGetLast(remoteAddr)
end

handlers[proto.MSG.GET_CHAIN] = function(remoteAddr, data)
  sync.onGetChain(remoteAddr, data)
end

-- Callback miner

-- Appele par miner.lua quand un bloc est trouve
local function onBlockFound(newBlock)
  -- Ajoute à notre chaine
  table.insert(chain, newBlock)
  sync.save()
  mempool.removeConfirmed(newBlock)

  print(string.format("[main] Bloc #%d mine et ajoute.", newBlock.index))

  -- Broadcast aux peers
  broadcast(proto.MSG.NEW_BLOCK, proto.newBlock(newBlock))
end

-- Demarrage

local function leaveSeeds()
  for _, seedAddr in ipairs(seeds) do
    net.send(seedAddr, proto.PORT_SEED, proto.MSG.LEAVE, {})
  end
end

local function start()
  -- Ouvre le port d'ecoute
  net.open(PORT)
  net.open(proto.PORT_SEED)

  print("╔══════════════════════════════════════════╗")
  print("║            Node MineChain                ║")
  print("╠══════════════════════════════════════════╣")
  print("║ Adresse : " .. net.address())
  print("║ Port    : " .. PORT)
  print("║ Mining  : " .. (MINING and "✅ active" or "❌ desactive"))
  print("╚══════════════════════════════════════════╝\n")

  -- Initialise et charge la chaine locale
  sync.init(chain, peers)
  sync.load()

  -- Decouverte du reseau
  connectToSeeds()
  announceTopeers()

  -- Synchronise la chaine avec les peers
  sync.syncOnStart(handlers)

  -- Initialise et demarre le miner si active
  local minerThread = nil
  if MINING then
    if not cfg.WALLET_ADDRESS or cfg.WALLET_ADDRESS == "" then
      print("[main] /!\\ WALLET_ADDRESS manquant, mining desactive.")
    else
      miner.init(lastBlock, cfg.WALLET_ADDRESS, onBlockFound)
      miner.start()
      minerThread = coroutine.create(miner.run)
      print("[main] Miner demarre.")
    end
  end

  -- Notifie les seeds si le programme est interrompu (Ctrl+C / shutdown)
  event.listen("interrupted", function()
    leaveSeeds()
  end)

  -- Boucle principale
  print("[main] En ecoute...\n")

  local lastPing    = computer.uptime()
  local lastRefresh = computer.uptime()
  local lastSyncCheck = computer.uptime()
  local PING_EVERY    = 30 -- ping les peers toutes les 30s
  local REFRESH_EVERY = 60 -- refresh de la liste des peers depuis les seeds
  local SYNC_CHECK_EVERY = 60 -- re-verifie toutes les 60s

  while true do

    -- Ecoute PORT_NODE (blocs, tx, sync)
    local remoteAddr, msgType, data = net.receive(PORT, 0.05)
    if remoteAddr then
      print("[main] Port " .. PORT .. " <- " .. tostring(msgType) .. " de " .. remoteAddr)
    end
    if remoteAddr and msgType then
      local handler = handlers[msgType]
      if handler then
        local ok, err = pcall(handler, remoteAddr, data)
        if not ok then
          print("[main] Erreur handler " .. msgType .. " : " .. tostring(err))
        end
      end
    end

    -- Ecoute PORT_SEED (PEERS au demarrage, NEW_PEER du seed)
    local remoteAddr2, msgType2, data2 = net.receive(proto.PORT_SEED, 0)
    if remoteAddr2 and msgType2 then
      local handler = handlers[msgType2]
      if handler then
        local ok, err = pcall(handler, remoteAddr2, data2)
        if not ok then
          print("[main] Erreur handler seed " .. msgType2 .. " : " .. tostring(err))
        end
      end
    end

    if _resyncPeer then
      local peer  = _resyncPeer
      _resyncPeer = nil
      print("[main] Resync depuis " .. peer .. "...")
      sync.syncFromPeer(peer)
      if MINING then miner.reset() end
    end

    -- Avance le miner d'un pas (batch de nonces)
    if minerThread and coroutine.status(minerThread) == "suspended" then
      local ok, err = coroutine.resume(minerThread)
      if not ok then
        print("[main] Erreur miner : " .. tostring(err))
        minerThread = coroutine.create(miner.run)
      end
    end

    -- Ping periodique des peers pour detecter les morts
    if (computer.uptime() - lastPing) >= PING_EVERY then
      broadcast(proto.MSG.PING, proto.ping())
      lastPing = computer.uptime()
    end

    -- Refresh periodique depuis les seeds (fallback si NEW_PEER rate)
    if (computer.uptime() - lastRefresh) >= REFRESH_EVERY then
      for _, seedAddr in ipairs(seeds) do
        net.send(seedAddr, proto.PORT_SEED, proto.MSG.LIST, {})
      end
      lastRefresh = computer.uptime()
    end
    
    if (computer.uptime() - lastSyncCheck) >= SYNC_CHECK_EVERY then
      lastSyncCheck = computer.uptime()
      -- Envoie juste GET_LAST a tous les peers, sans bloquer
      -- La reponse LAST_BLOCK sera traitee par le handler normal
      for _, peerAddr in ipairs(peerList_main()) do
        net.send(peerAddr, PORT, proto.MSG.GET_LAST, proto.getLast())
      end
    end

    -- Petit sleep pour ne pas saturer le CPU OC
    os.sleep(0)
  end
end

start()