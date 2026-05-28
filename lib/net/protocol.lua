local M = {}

M.PORT_SEED = 42 -- seed nodes
M.PORT_NODE = 43 -- nodes blockchain
M.PORT_PING = 44 -- keep-alive

M.MSG = {

  -- Seed
  -- Envoye par un node qui rejoint le reseau
  -- data: { address: string }  (son adresse modem)
  JOIN = "JOIN",

  -- Envoye par un node qui quitte proprement
  -- data: {}
  LEAVE = "LEAVE",

  -- Demande la liste des peers connus
  -- data: {}
  LIST = "LIST",

  -- Reponse a LIST ou JOIN
  -- data: { peers: string[] }  (liste d'adresses modem)
  PEERS = "PEERS",

  -- Envoye par le seed aux nodes existants quand un nouveau node rejoint
  -- Permet a tous les nodes d'etre notifies sans attendre le refresh
  -- data: { address: string }
  NEW_PEER = "NEW_PEER",

  -- Keep-alive
  -- Verifie qu'un node est toujours en vie
  -- data: {}
  PING = "PING",

  -- Reponse au PING
  -- data: {}
  PONG = "PONG",

  -- Blockchain
  -- Diffuse un nouveau bloc mine
  -- data: { block: Block }
  NEW_BLOCK = "NEW_BLOCK",

  -- Diffuse une nouvelle transaction
  -- data: { transaction: Transaction }
  NEW_TX = "NEW_TX",

  -- Demande tout ou partie de la chaine
  -- data: { from_index: number }
  GET_CHAIN = "GET_CHAIN",

  -- Reponse a GET_CHAIN
  -- data: { blocks: Block[] }
  CHAIN = "CHAIN",

  -- Demande le dernier bloc connu (pour savoir si on est a jour)
  -- data: {}
  GET_LAST = "GET_LAST",

  -- Reponse a GET_LAST
  -- data: { block: Block }
  LAST_BLOCK = "LAST_BLOCK",
}

-- Constructeurs de messages
-- Helpers pour construire les payloads proprement
-- et eviter les erreurs de typage entre les programmes

function M.join(myAddress)
  return { address = myAddress }
end

function M.peers(peerList)
  return { peers = peerList }
end

function M.ping()
  return {}
end

function M.newBlock(block)
  return { block = block }
end

function M.newTx(transaction, publicKey)
  return {
    transaction = transaction,
    public_key  = publicKey
  }
end

function M.getChain(fromIndex)
  return { from_index = fromIndex or 0 }
end

function M.chain(blocks)
  return { blocks = blocks }
end

function M.getLast()
  return {}
end

function M.lastBlock(block)
  return { block = block }
end

-- Validation basique des messages recus
-- Verifie qu'un message a les champs attendus
-- Retourne true ou false, erreur

local required = {
  [M.MSG.JOIN] = { "address" },
  [M.MSG.PEERS] = { "peers" },
  [M.MSG.NEW_BLOCK] = { "block" },
  [M.MSG.NEW_TX] = { "transaction" },
  [M.MSG.GET_CHAIN] = { "from_index" },
  [M.MSG.CHAIN] = { "blocks" },
  [M.MSG.LAST_BLOCK] = { "block" },
}

function M.validate(msgType, data)
  local fields = required[msgType]
  if not fields then return true end

  for _, field in ipairs(fields) do
    if data[field] == nil then
      return false, "Champ manquant : " .. field .. " dans " .. msgType
    end
  end
  return true
end

return M
