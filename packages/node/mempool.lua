local tx = require("types/transaction")

local M = {}

-- State

-- pending[tx.id] = { transaction, public_key }
-- On stocke la cles publique avec la tx pour pouvoir verifier la signature
local pending = {}

-- Add

-- Ajoute une transaction a la mempool
-- transaction : table tx
-- publicKey : userdata cle publique EC (pour verifier la signature)
-- chain : chaine actuelle (pour verifier les fonds)
-- Retourne : true ou false, erreur
function M.add(transaction, publicKey, chain)
  -- Deja dans la mempool ?
  if pending[transaction.id] then
    return false, "Transaction deja en attente"
  end

  -- Validation structurelle
  local ok, err = tx.validate(transaction)
  if not ok then
    return false, "Structure invalide : " .. err
  end

  -- Verification de la signature (sauf coinbase)
  if transaction.from ~= "coinbase" then
    ok, err = tx.verifySignature(transaction, publicKey)
    if not ok then
      return false, "Signature invalide : " .. err
    end
  end

  -- Verification des fonds
  if transaction.from ~= "coinbase" then
    ok, err = tx.hasFunds(transaction, chain)
    if not ok then
      return false, err
    end
  end

  pending[transaction.id] = {
    transaction = transaction,
    public_key = publicKey,
  }

  print(string.format("[mempool] +tx %s (%s -> %s, %d)",
    transaction.id:sub(1, 8) .. "...",
    transaction.from:sub(1, 8) .. "...",
    transaction.to:sub(1, 8) .. "...",
    transaction.amount
  ))

  return true
end

-- Remove

-- Supprime les transactions d'un bloc qui vient d'etre confirme
function M.removeConfirmed(block)
  local removed = 0
  for _, confirmedTx in ipairs(block.transactions or {}) do
    if pending[confirmedTx.id] then
      pending[confirmedTx.id] = nil
      removed = removed + 1
    end
  end

  if removed > 0 then
    print(string.format("[mempool] %d tx confirmee(s), %d en attente.", removed, M.size()))
  end
end

-- Read

-- Retourne les N premieres transactions pour un bloc candidat
-- maxTx : nombre maximum de tx a inclure (defaut: 10)
function M.getPending(maxTx)
  maxTx = maxTx or 10
  local result = {}

  for _, entry in pairs(pending) do
    table.insert(result, entry.transaction)
    if #result >= maxTx then break end
  end

  return result
end

-- Nombre de transactions en attente
function M.size()
  local n = 0
  for _ in pairs(pending) do n = n + 1 end
  return n
end

-- Verifie si la mempool contient une transaction
function M.has(txId)
  return pending[txId] ~= nil
end

return M