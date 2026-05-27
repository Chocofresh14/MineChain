--  Dépendances :
--    lib/net/modem.lua        -> modem.open(port), modem.send(addr, port, msg), modem.broadcast(port, msg)
--    lib/net/protocol.lua     -> protocol.PORTS, protocol.wrap(type, payload), protocol.unwrap(raw)


local modem    = dofile("/minechain/lib/net/modem.lua")
local protocol = dofile("/minechain/lib/net/protocol.lua")

local NODE_FILE = "/minechain/wallet/node.cfg"
local node = nil

local function input(label)
  io.write(label .. " ")
  return io.read()
end

local function query_node(msg_type, payload)
  if not node then
    print("Erreur : aucun node configuré.")
    return nil
  end
  local port = protocol.PORTS.explorer
  modem.open(port)
  modem.send(node, protocol.PORTS.node, protocol.wrap(msg_type, payload))

  local ev, _, _, _, _, raw = event.pull(5, "modem_message")
  if not ev then
    print("Erreur : timeout, node injoignable.")
    return nil
  end
  return protocol.unwrap(raw)
end

local function load_node()
  local fs = require("filesystem")
  if fs.exists(NODE_FILE) then
    local f = io.open(NODE_FILE, "r")
    node = f:read("*a")
    f:close()
    print("Node : " .. node)
  end
end


local function show_chain_info()
  local resp = query_node("GET_INFO", {})
  if not resp or resp.type ~= "INFO" then return end

  local info = resp.payload
  print("Hauteur       : " .. info.height)
  print("Dernier hash  : " .. info.last_hash)
  print("Difficulté    : " .. info.difficulty)
  print("Peers         : " .. info.peer_count)
  print("Tx en mempool : " .. info.mempool_size)
end

local function show_last_blocks()
  local count = tonumber(input("Combien de blocs ? (ex: 5)")) or 5
  local resp = query_node("GET_LAST_BLOCKS", { count = count })
  if not resp or resp.type ~= "BLOCKS" then return end

  for _, b in ipairs(resp.payload.blocks) do
    print("---")
    print("Hauteur : " .. b.height)
    print("Hash    : " .. b.hash)
    print("Mineur  : " .. b.miner)
    print("Tx      : " .. #b.transactions)
    print("Nonce   : " .. b.nonce)
  end
end

local function show_block()
  local h = input("Hauteur du bloc :")
  local resp = query_node("GET_BLOCK", { height = tonumber(h) })
  if not resp or resp.type ~= "BLOCK" then return end

  local b = resp.payload.block
  print("Hauteur     : " .. b.height)
  print("Hash        : " .. b.hash)
  print("Hash préc.  : " .. b.prev_hash)
  print("Mineur      : " .. b.miner)
  print("Nonce       : " .. b.nonce)
  print("Timestamp   : " .. b.timestamp)
  print("Transactions: " .. #b.transactions)

  if #b.transactions > 0 then
    local ans = input("Afficher les transactions ? (o/n)")
    if ans == "o" then
      for i, tx in ipairs(b.transactions) do
        print("  [" .. i .. "] " .. tx.from .. " -> " .. tx.to .. "  " .. tx.amount .. " MC")
      end
    end
  end
end

local function show_tx()
  local hash = input("Hash de la transaction :")
  local resp = query_node("GET_TX", { hash = hash })
  if not resp or resp.type ~= "TX" then return end

  local tx = resp.payload.tx
  print("Hash    : " .. tx.hash)
  print("De      : " .. tx.from)
  print("Vers    : " .. tx.to)
  print("Montant : " .. tx.amount .. " MC")
  print("Nonce   : " .. tx.nonce)
  print("Bloc    : " .. (tx.block_height or "mempool"))
end

local function config_node()
  local addr = input("Adresse modem du node :")
  node = addr
  local fs = require("filesystem")
  if not fs.exists("/minechain/wallet") then
    fs.makeDirectory("/minechain/wallet")
  end
  local f = io.open(NODE_FILE, "w")
  f:write(addr)
  f:close()
  print("Node sauvegardé.")
end


local menu = {
  { label = "Infos de la chaîne",        fn = show_chain_info  },
  { label = "Derniers blocs",            fn = show_last_blocks },
  { label = "Détails d'un bloc",         fn = show_block       },
  { label = "Détails d'une transaction", fn = show_tx          },
  { label = "Configurer le node",        fn = config_node      },
  { label = "Quitter",                   fn = nil              },
}

load_node()

while true do
  print("\n ———MineChain Explorer——— ")
  for i, item in ipairs(menu) do
    print(i .. ". " .. item.label)
  end

  local choice = tonumber(input(">"))
  if not choice or not menu[choice] then
    print("Choix invalide.")
  elseif not menu[choice].fn then
    print("Au revoir.")
    break
  else
    print("")
    menu[choice].fn()
  end
end