local serialization = require("serialization")
local hash = require("crypto/hash")

local M = {}

-- Bloc Genesis
-- Premier bloc de la chaine, code en dur.
-- TOUS les nodes doivent avoir exactement le meme.

local GENESIS = {
  index = 0,
  timestamp = 0,
  prev_hash = string.rep("0", 64), -- 64 zeros, rien avant lui
  nonce = 0,
  miner = "genesis",
  transactions = {},
}
-- Le hash du genesis est calcule une fois depuis son contenu fixe
GENESIS.hash = nil -- sera calcule a la premiere demande

-- Serialisation

-- Serialise un bloc en string deterministe pour le hachage
-- On exclut le champ "hash" lui-meme (logique)
function M.serialize(b)
  return serialization.serialize({
    index = b.index,
    timestamp = b.timestamp,
    prev_hash = b.prev_hash,
    nonce = b.nonce,
    miner = b.miner,
    transactions = b.transactions,
  })
end

-- Hachage

-- Calcule le hash d'un bloc (sans son champ hash)
function M.computeHash(b)
  return hash.sha256(M.serialize(b))
end

-- Creation

-- Cree un nouveau bloc candidat (pas encore mine, nonce = 0)
-- index : numero du bloc
-- prev_hash : hash du bloc precedent
-- transactions : liste de transactions a inclure
-- miner : adresse du mineur
function M.new(index, prev_hash, transactions, miner)
  assert(type(index) == "number", "block.new: index doit etre un number")
  assert(type(prev_hash) == "string", "block.new: prev_hash doit etre une string")
  assert(type(miner) == "string", "block.new: miner doit etre une string")

  local b = {
    index = index,
    timestamp = os.time(),
    prev_hash = prev_hash,
    nonce = 0,
    miner = miner,
    transactions = transactions or {},
    hash = "",
  }
  b.hash = M.computeHash(b)
  return b
end

-- Retourne le bloc genesis (singleton, calcule une fois)
function M.genesis()
  if not GENESIS.hash then
    GENESIS.hash = M.computeHash(GENESIS)
  end
  return GENESIS
end

-- Validation

-- Verifie qu'un bloc a bien tous ses champs
local function hasRequiredFields(b)
  return b.index ~= nil
      and b.timestamp ~= nil
      and b.prev_hash ~= nil
      and b.nonce ~= nil
      and b.miner ~= nil
      and b.transactions ~= nil
      and b.hash ~= nil
end

-- Valide un bloc par rapport au bloc precedent
-- Retourne : true ou false, message d'erreur
function M.validate(b, prevBlock, difficulty)
  difficulty = difficulty or 3

  -- Champs presents
  if not hasRequiredFields(b) then
    return false, "Champs manquants dans le bloc #" .. tostring(b.index)
  end

  -- Index coherent
  if b.index ~= prevBlock.index + 1 then
    return false, string.format(
      "Index incoherent : attendu %d, reçu %d",
      prevBlock.index + 1, b.index
    )
  end

  -- Chainage : prev_hash pointe bien sur le bloc precedent
  if b.prev_hash ~= prevBlock.hash then
    return false, "prev_hash ne correspond pas au hash du bloc precedent"
  end

  -- Hash correct (pas altere)
  local expected = M.computeHash(b)
  if b.hash ~= expected then
    return false, "Hash du bloc invalide"
  end

  -- Proof of Work : le hash doit commencer par N zeros
  local prefix = string.rep("0", difficulty)
  if b.hash:sub(1, difficulty) ~= prefix then
    return false, string.format(
      "PoW insuffisant : hash ne commence pas par %d zeros", difficulty
    )
  end

  -- Timestamp raisonnable (pas dans le futur lointain)
  if b.timestamp > os.time() + 60 then
    return false, "Timestamp dans le futur"
  end

  return true
end

-- Valide toute une chaine depuis le genesis
-- Retourne : true  ou  false, message d'erreur, index du bloc fautif
function M.validateChain(blocks, difficulty)
  if #blocks == 0 then
    return false, "Chaine vide", 0
  end

  -- Le premier bloc doit etre le genesis
  local genesis = M.genesis()
  if blocks[1].hash ~= genesis.hash then
    return false, "Le premier bloc n'est pas le genesis", 1
  end

  -- Valide chaque bloc par rapport au precedent
  for i = 2, #blocks do
    local ok, err = M.validate(blocks[i], blocks[i - 1], difficulty)
    if not ok then
      return false, err, i
    end
  end

  return true
end

return M
