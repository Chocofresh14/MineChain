local net = require("net/modem")
local proto = require("net/protocol")
local block = require("types/block")
local fs = require("filesystem")
local serialization = require("serialization")
local computer = require("computer")

local M = {}

-- Config

local cfg = assert(loadfile("/etc/minechain/config.lua"))()
local PORT = cfg.PORT or 43
local DIFFICULTY = cfg.DIFFICULTY or 3
local CHAIN_PATH = "/etc/minechain/chain.dat"
local BLOCKS_DIR = "/etc/minechain/blocks"

-- Shared State (injecté depuis node/main)
-- sync.lua ne stocke pas la chaine lui-meme,
-- il travaille sur la reference passee par node/main

local _chain = nil   -- reference vers la chaine locale { block, block, ... }
local _peers = nil   -- reference vers la table des peers connus

local CHUNK_SIZE = 5 -- blocs par paquet reseau

function M.init(chainRef, peersRef)
  _chain = chainRef
  _peers = peersRef
end

-- Persistance

-- Sauvegarde les block sur le disque dans des fichiers différents
local function saveBlock(block)
  local dir = fs.path(BLOCKS_DIR)
  if not fs.exists(dir) then fs.makeDirectory(dir) end
  
  local filename = tostring(block.index) .. ".dat"
  local path = BLOCKS_DIR .. "/" .. filename
  local f = assert(io.open(path, "w"))
  f:write(serialization.serialize(block))
  f:close()
end

-- Sauvegarde la chaine sur le disque
function M.save()
  saveBlock(_chain[#_chain])
end

-- Sauvegarde les blocks et les met dans une chain
function saveChain(blocks)
  if not fs.exists(BLOCKS_DIR) then
    fs.makeDirectory(BLOCKS_DIR)
  end
  for _, block in ipairs(blocks) do
    M.saveBlock(block)
  end
end

-- Charge la chaine depuis le disque
-- Retourne true si une chaine existante a ete trouvee
function M.load()
  if not fs.exists(BLOCKS_DIR) then
    -- Premiere fois : on part du genesis
    table.insert(_chain, block.genesis())
    saveBlock(block.genesis())
    print("[sync] Aucune chaine locale, demarrage depuis le genesis.")
    return false
  end

  local maxIndex = -1
  for file in fs.list(BLOCKS_DIR) do
    local idx = tonumber(file:match("^(%d+)%.dat$"))
    if idx and idx > maxIndex then
      maxIndex = idx
    end
  end

  if maxIndex < 0 then
    table.insert(_chain, block.genesis())
    saveBlock(block.genesis())
    print("[sync] Aucun bloc sur disque, demarrage depuis le genesis.")
    return false
  end

  -- Charge les blocs dans l'ordre
  local missing = false
  for i = 0, maxIndex do
    local path = BLOCKS_DIR .. "/" .. i .. ".dat"

    if not fs.exists(path) then
      print(string.format("[sync] Fichier manquant : bloc #%d", i))
      missing = true
      break
    end

    local f   = assert(io.open(path, "r"))
    local raw = f:read("*a")
    f:close()

    local ok, b = pcall(serialization.unserialize, raw)
    if not ok or type(b) ~= "table" then
      print(string.format("[sync] Bloc #%d corrompu", i))
      missing = true
      break
    end

    table.insert(_chain, b)
  end

  if missing then
    -- Repart du genesis si la chaine est incomplete
    while #_chain > 0 do table.remove(_chain) end
    table.insert(_chain, block.genesis())
    saveBlock(block.genesis())
    print("[sync] Chaine incomplete, repartir du genesis.")
    return false
  end

  -- Validation de l'enchainement
  for i = 2, #_chain do
    if _chain[i].prev_hash ~= _chain[i-1].hash then
      print(string.format("[sync] Chaine cassee au bloc #%d", _chain[i].index))
      while #_chain > 0 do table.remove(_chain) end
      table.insert(_chain, block.genesis())
      return false
    end
  end

  print(string.format("[sync] Chaine chargee : %d blocs.", #_chain))
  return true
end

-- Helpers

local function lastBlock()
  return _chain[#_chain]
end

local function peerList()
  local list = {}
  for addr, _ in pairs(_peers) do
    table.insert(list, addr)
  end
  return list
end

-- Envoie une requete a un peer et attend sa reponse avec timeout
-- Retourne : msgType, data  ou  nil si timeout/erreur
local function request(peerAddr, msgType, payload, expectedType, timeout)
  timeout = timeout or 5
  net.send(peerAddr, PORT, msgType, payload)

  local deadline = computer.uptime() + timeout

  while computer.uptime() < deadline do
    local remaining = deadline - computer.uptime()
    if remaining <= 0 then break end

    local remoteAddr, rType, rData = net.receive(PORT, math.min(1, remaining))

    if remoteAddr == peerAddr and rType == expectedType then
      return rData
    end
    -- message non attendu : on ignore et on reboucle (il est bufferise par net.receive)
  end

  return nil
end

-- Synchronisation au demarrage

-- Telecharge et adopte la chaine d'un peer si elle est plus longue et valide
function M.syncFromPeer(peerAddr)
  print("[sync] Synchronisation depuis " .. peerAddr .. "...")

  local newChain  = {}
  local fromIndex = 0

  -- Telecharge la chaîne bloc par bloc en petits paquets
  while true do
    local data = request(
      peerAddr,
      proto.MSG.GET_CHAIN,
      { from_index = fromIndex, count = CHUNK_SIZE },
      proto.MSG.CHAIN,
      10
    )

    -- Plus rien a recevoir ou timeout
    if not data or type(data.blocks) ~= "table" or #data.blocks == 0 then
      if fromIndex == 0 then
        print("[sync] Aucune chaine reçue de " .. peerAddr)
        return false
      end
      break
    end

    for _, b in ipairs(data.blocks) do
      table.insert(newChain, b)
    end

    -- Moins que CHUNK_SIZE blocs reçus = fin de chaine
    if #data.blocks < CHUNK_SIZE then break end

    fromIndex = fromIndex + #data.blocks
    print(string.format("[sync] Reçu %d blocs...", #newChain))
  end

  if #newChain == 0 then return false end

  -- Valide la chaine complete reçue
  local valid, err, badIndex = block.validateChain(newChain, DIFFICULTY)
  if not valid then
    print(string.format("[sync] Chaine invalide (bloc #%d : %s)",
      badIndex or 0, err))
    return false
  end

  -- N'adopte que si plus longue
  if #newChain <= #_chain then
    print("[sync] Notre chaine est deja a jour.")
    return false
  end

  while #_chain > 0 do table.remove(_chain) end
  for _, b in ipairs(newChain) do
    table.insert(_chain, b)
  end

  saveChain(newChain)
  print(string.format("[sync] Chaine adoptee : %d blocs.", #_chain))
  return true
end

-- Point d'entree : synchronisation complete au demarrage
function M.syncOnStart()
  if #peerList() == 0 then
    print("[sync] Aucun peer connu, on reste sur la chaine locale.")
    return
  end

  -- Attend passivement les LAST_BLOCK qui arrivent en reponse aux JOIN
  -- (announceTopeers declenche des LAST_BLOCK automatiquement)
  -- ET envoie GET_LAST explicitement a chaque peer
  local bestPeer  = nil
  local bestIndex = lastBlock().index

  -- Envoie GET_LAST a tous les peers connus
  for _, peerAddr in ipairs(peerList()) do
    net.send(peerAddr, PORT, proto.MSG.GET_LAST, proto.getLast())
  end

  -- Ecoute pendant 10s tous les LAST_BLOCK qui arrivent
  -- (reponses aux JOIN + reponses aux GET_LAST)
  local deadline = computer.uptime() + 10
  while computer.uptime() < deadline do
    local remoteAddr, rType, rData = net.receive(PORT, 1)

    if remoteAddr and rType == proto.MSG.LAST_BLOCK then
      if rData and rData.block and type(rData.block.index) == "number" then
        print(string.format("[sync] Peer %s : bloc #%d",
          remoteAddr, rData.block.index))
        if rData.block.index > bestIndex then
          bestIndex = rData.block.index
          bestPeer  = remoteAddr
        end
      end
    end
  end

  if not bestPeer then
    print("[sync] Notre chaine est a jour (bloc #" .. lastBlock().index .. ").")
    return
  end

  print(string.format(
    "[sync] Peer plus avance : bloc #%d vs notre #%d.",
    bestIndex, lastBlock().index
  ))

  M.syncFromPeer(bestPeer)
end

-- ─── Reception d'un nouveau bloc ───────────────────────────────────────────

-- Appele par node/main quand un NEW_BLOCK est reçu
-- remoteAddr : peer qui a envoye le bloc
-- newBlock : le bloc reçu
-- Retourne : true si le bloc a ete adopte
function M.onNewBlock(remoteAddr, newBlock)
  -- Deja dans notre chaine ?
  if newBlock.index <= lastBlock().index then
    return false -- on ignore, pas nouveau
  end

  -- Bloc suivant attendu : on peut l'ajouter directement
  if newBlock.index == lastBlock().index + 1 then
    local ok, err = block.validate(newBlock, lastBlock(), DIFFICULTY)
    if not ok then
      print("[sync] Bloc #" .. newBlock.index .. " invalide : " .. err)
      return false
    end

    table.insert(_chain, newBlock)
    M.save()
    print(string.format("[sync] Bloc #%d ajoute. (mineur: %s)",
      newBlock.index, newBlock.miner))
    return true
  end

  -- Gap detecte (index > last + 1) : on est en retard, resync
  print(string.format(
    "[sync] Gap detecte : notre #%d, reçu #%d. Resync depuis %s...",
    lastBlock().index, newBlock.index, remoteAddr
  ))
  return false, remoteAddr
end

-- Reponse aux requêtes des autres nodes

-- Repond à GET_LAST
function M.onGetLast(remoteAddr)
  net.send(remoteAddr, PORT, proto.MSG.LAST_BLOCK, proto.lastBlock(lastBlock()))
end

-- Repond à GET_CHAIN
-- data.from_index : index depuis lequel le peer veut la chaîne
function M.onGetChain(remoteAddr, data)
  local fromIndex = (data and data.from_index) or 0
  local maxCount  = (data and data.count) or CHUNK_SIZE
  local subset    = {}

  for _, b in ipairs(_chain) do
    if b.index >= fromIndex then
      table.insert(subset, b)
      if #subset >= maxCount then break end
    end
  end

  net.send(remoteAddr, PORT, proto.MSG.CHAIN, proto.chain(subset))
end

return M
