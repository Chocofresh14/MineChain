local hash = require("crypto/hash")
local sign = require("crypto/sign")

local M = {}

-- Serialisation

-- Serialise les champs signables d'une transaction (ordre fixe, deterministe)
-- On exclut "id" et "signature" (pas signes, logique)
function M.serialize(tx)
  return "amount=" .. string.format("%d", tx.amount)
      .. ",from=" .. tostring(tx.from)
      .. ",timestamp=" .. string.format("%d", tx.timestamp)
      .. ",to=" .. tostring(tx.to)
end

-- ID de transaction

-- Calcule l'identifiant unique d'une transaction (hash de son contenu)
function M.computeId(tx)
  return hash.sha256(M.serialize(tx) .. tostring(tx.signature or ""))
end

-- Creation

-- Cree une transaction normale (non signee, a signer avant envoi)
-- from : adresse de l'emetteur
-- to : adresse du destinataire
-- amount : montant (nombre entier positif)
function M.new(from, to, amount)
  assert(type(from) == "string", "tx.new: from doit etre une string")
  assert(type(to) == "string", "tx.new: to doit etre une string")
  assert(type(amount) == "number" and amount > 0, "tx.new: amount doit etre un nombre positif")

  local tx = {
    from = from,
    to = to,
    amount = amount,
    timestamp = math.floor(os.time()),
    signature = nil, -- a remplir par le wallet avant envoi
    id = nil,        -- calcule apres signature
  }
  return tx
end

-- Cree une transaction coinbase (recompense de minage, pas de signature)
-- to : adresse du mineur
-- amount : récompense
function M.coinbase(to, amount)
  assert(type(to) == "string", "tx.coinbase: to doit etre une string")
  assert(type(amount) == "number" and amount > 0, "tx.coinbase: amount invalide")

  local tx = {
    from = "coinbase", -- emetteur spécial, pas de signature
    to = to,
    amount = amount,
    timestamp = math.floor(os.time()),
    signature = "coinbase", -- valeur sentinelle reconnue par validate
  }
  tx.id = M.computeId(tx)
  return tx
end

-- Attache une signature a une transaction et calcule son ID final
-- Appele par le wallet apres signature
function M.attach(tx, signature)
  assert(type(signature) == "string", "tx.attach: signature doit etre une string")
  tx.signature = signature
  tx.id = M.computeId(tx)
  return tx
end

-- Validation

-- Valide la structure d'une transaction
-- Retourne : true ou false, message d'erreur
function M.validate(tx)
  -- Champs presents
  if tx.from == nil
      or tx.to == nil
      or tx.amount == nil
      or tx.timestamp == nil
      or tx.signature == nil
      or tx.id == nil
  then
    return false, "Champs manquants"
  end

  -- Montant positif
  if type(tx.amount) ~= "number" or tx.amount <= 0 then
    return false, "Montant invalide : " .. tostring(tx.amount)
  end

  -- Pas d'auto-envoi
  if tx.from == tx.to then
    return false, "L'emetteur et le destinataire sont identiques"
  end

  -- ID coherent
  local expectedId = M.computeId(tx)
  if tx.id ~= expectedId then
    print("[tx] ID recu    : " .. tostring(tx.id))
    print("[tx] ID calcule : " .. tostring(expectedId))
    print("[tx] serialize  : " .. M.serialize(tx))
    print("[tx] signature  : " .. tostring(tx.signature))
    return false, "ID de transaction invalide"
  end

  -- Coinbase : pas de verification de signature
  if tx.from == "coinbase" then
    return true
  end

  return true
end

-- Valide la cryptographie d'une transaction
-- Appelee par le NODE lors de la reception d'un NEW_TX
-- publicKey : userdata (cle publique EC, recue avec la transaction)
-- Retourne : true ou false, message d'erreur
function M.verifySignature(tx, publicKey)
  assert(publicKey ~= nil, "verifySignature: cle publique requise")

  if tx.from == "coinbase" then
    return true -- coinbase, pas de signature a verifier
  end

  local msg = M.serialize(tx)
  local ok  = sign.verify(msg, publicKey, tx.signature)

  if not ok then
    return false, "Signature invalide"
  end
  return true
end

-- Helpers

local INITIAL_BALANCE = 1000 -- solde de depart pour les tests

-- Calcule le solde d'une adresse depuis une liste de blocs
function M.balanceOf(address, blocks)
  local balance = INITIAL_BALANCE
  for _, block in ipairs(blocks) do
    for _, tx in ipairs(block.transactions or {}) do
      if tx.to == address then balance = balance + tx.amount end
      if tx.from == address then balance = balance - tx.amount end
    end
  end
  return balance
end

-- Verifie qu'une adresse a assez de fonds pour une transaction
function M.hasFunds(tx, blocks)
  local balance = M.balanceOf(tx.from, blocks)
  return balance >= tx.amount,
      string.format("Fonds insuffisants : %d disponible, %d demande", balance, tx.amount)
end

return M
