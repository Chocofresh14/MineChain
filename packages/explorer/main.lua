local fs = require("filesystem")
local computer = require("computer")
local modem = require("net/modem")
local protocol = require("net/protocol")

local CONFIG_FILE = "/etc/minechain/config.lua"
local SEEDS_FILE = "/etc/minechain/seeds.lua"
local NODE_FILE = "/etc/minechain/explorer/node.cfg"

local explorer = {
  node = nil,
  port = protocol.PORT_NODE,
}

local function input(label)
  io.write(label .. " ")
  return io.read()
end

local function trim(value)
  if not value then
    return nil
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end

  local content = file:read("*a")
  file:close()
  return content
end

local function read_table_file(path)
  local loader = loadfile(path)
  if not loader then
    return nil
  end

  local ok, value = pcall(loader)
  if not ok or type(value) ~= "table" then
    return nil
  end

  return value
end

local function ensure_storage()
  local dir = "/etc/minechain/explorer"
  if not fs.exists(dir) then
    fs.makeDirectory(dir)
  end
end

local function save_node()
  if not explorer.node or explorer.node == "" then
    return
  end

  ensure_storage()
  local file = assert(io.open(NODE_FILE, "w"))
  file:write(explorer.node)
  file:close()
end

local function load_config()
  local loader = loadfile(CONFIG_FILE)
  if not loader then
    return
  end

  local ok, cfg = pcall(loader)
  if not ok or type(cfg) ~= "table" then
    return
  end

  explorer.port = tonumber(cfg.PORT) or explorer.port
end

local function load_persisted()
  local savedNode = trim(read_file(NODE_FILE))
  if savedNode and savedNode ~= "" then
    explorer.node = savedNode
    print("Node : " .. explorer.node)
  end
end

local function load_seeds()
  return read_table_file(SEEDS_FILE) or {}
end

local function ensure_node()
  if explorer.node and explorer.node ~= "" then
    return explorer.node
  end
  return nil
end

local function try_node(candidate)
  modem.send(candidate, explorer.port, protocol.MSG.GET_LAST, protocol.getLast())

  local started_at = computer.uptime()
  while (computer.uptime() - started_at) < 2 do
    local remoteAddr, msgType, data = modem.receive(explorer.port, 1)
    if remoteAddr == candidate and msgType == protocol.MSG.LAST_BLOCK and data and data.block then
      explorer.node = candidate
      save_node()
      print("Node detecte : " .. candidate)
      return candidate
    end
  end

  return nil
end

local function discover_node()
  local seeds = load_seeds()
  if #seeds == 0 then
    print("Erreur : aucun seed configure dans " .. SEEDS_FILE)
    return nil
  end

  local nodeQueue = {}
  local seen = {}

  local function enqueue(address)
    if type(address) == "string" and address ~= "" and not seen[address] then
      seen[address] = true
      table.insert(nodeQueue, address)
    end
  end

  for _, seedAddr in ipairs(seeds) do
    modem.send(seedAddr, protocol.PORT_SEED, protocol.MSG.LIST, protocol.ping())

    local started_at = computer.uptime()
    while (computer.uptime() - started_at) < 3 do
      local remoteAddr, msgType, data = modem.receive(protocol.PORT_SEED, 1)
      if remoteAddr == seedAddr and msgType == protocol.MSG.PEERS and type(data.peers) == "table" then
        for _, candidate in ipairs(data.peers) do
          enqueue(candidate)
        end
        break
      end
    end
  end

  if #nodeQueue == 0 then
    print("Erreur : aucun node connu des seeds.")
    return nil
  end

  for _, candidate in ipairs(nodeQueue) do
    if try_node(candidate) then
      return candidate
    end
  end

  print("Erreur : aucun node joignable.")
  return nil
end

local function query_node(msg_type, payload, expected_type, timeout)
  if not ensure_node() and not discover_node() then
    print("Erreur : aucun node configuré.")
    return nil
  end

  modem.send(explorer.node, explorer.port, msg_type, payload)

  local deadline = computer.uptime() + (timeout or 5)
  while computer.uptime() < deadline do
    local remoteAddr, respType, data = modem.receive(explorer.port, 1)
    if remoteAddr == explorer.node and (not expected_type or respType == expected_type) then
      return respType, data
    end
  end

  print("Erreur : timeout, node injoignable.")
  return nil
end

local function fetch_chain(page_size)
  local blocks = {}
  local from_index = 0
  local count = page_size or 20
  local pages = 0
  local max_pages = 128

  while pages < max_pages do
    local respType, data = query_node(
      protocol.MSG.GET_CHAIN,
      protocol.getChain(from_index, count),
      protocol.MSG.CHAIN,
      5
    )

    if not respType then
      return nil
    end

    if type(data.blocks) ~= "table" then
      print("Erreur : reponse CHAIN invalide.")
      return nil
    end

    if #data.blocks == 0 then
      break
    end

    for _, block in ipairs(data.blocks) do
      table.insert(blocks, block)
    end

    if #data.blocks < count then
      break
    end

    from_index = from_index + #data.blocks
    pages = pages + 1
  end

  return blocks
end

local function find_block(blocks, query)
  local index = tonumber(query)
  if index then
    for _, block in ipairs(blocks) do
      if block.index == index then
        return block
      end
    end
  end

  for _, block in ipairs(blocks) do
    if block.hash == query then
      return block
    end
  end

  return nil
end

local function find_tx(blocks, query)
  for _, block in ipairs(blocks) do
    for _, tx in ipairs(block.transactions or {}) do
      if tx.id == query or tx.hash == query then
        return tx, block
      end
    end
  end

  return nil
end

local function show_chain_info()
  local blocks = fetch_chain(20)
  if not blocks then
    return
  end

  local lastBlock = blocks[#blocks]
  local totalTx = 0
  for _, block in ipairs(blocks) do
    totalTx = totalTx + #(block.transactions or {})
  end

  print("Blocs        : " .. #blocks)
  print("Hauteur      : " .. (lastBlock and lastBlock.index or 0))
  print("Dernier hash : " .. (lastBlock and lastBlock.hash or "inconnu"))
  print("Dernier mineur: " .. (lastBlock and lastBlock.miner or "inconnu"))
  print("Tx totales   : " .. totalTx)
  print("Node         : " .. (explorer.node or "non configure"))
  print("Port         : " .. explorer.port)
end

local function show_last_blocks()
  local count = tonumber(input("Combien de blocs ? (ex: 5)")) or 5
  local blocks = fetch_chain(20)
  if not blocks then
    return
  end

  local startIndex = math.max(1, #blocks - count + 1)
  for i = startIndex, #blocks do
    local block = blocks[i]
    print("---")
    print("Index   : " .. block.index)
    print("Hash    : " .. block.hash)
    print("Mineur  : " .. block.miner)
    print("Tx      : " .. #(block.transactions or {}))
    print("Nonce   : " .. block.nonce)
  end
end

local function show_block()
  local query = trim(input("Index ou hash du bloc :"))
  if not query or query == "" then
    print("Requete invalide.")
    return
  end

  local blocks = fetch_chain(20)
  if not blocks then
    return
  end

  local block = find_block(blocks, query)
  if not block then
    print("Bloc introuvable.")
    return
  end

  print("Index       : " .. block.index)
  print("Hash        : " .. block.hash)
  print("Hash préc.  : " .. block.prev_hash)
  print("Mineur      : " .. block.miner)
  print("Nonce       : " .. block.nonce)
  print("Timestamp   : " .. block.timestamp)
  print("Transactions: " .. #(block.transactions or {}))

  if #(block.transactions or {}) > 0 then
    local ans = input("Afficher les transactions ? (o/n)")
    if ans == "o" then
      for i, tx in ipairs(block.transactions or {}) do
        print("  [" .. i .. "] ID : " .. (tx.id or "sans-id"))
        print("      De : " .. tx.from)
        print("      Vers : " .. tx.to)
        print("      Montant : " .. tx.amount .. " MC")
      end
    end
  end
end

local function show_tx()
  local query = trim(input("ID de la transaction :"))
  if not query or query == "" then
    print("Requete invalide.")
    return
  end

  local blocks = fetch_chain(20)
  if not blocks then
    return
  end

  local tx, block = find_tx(blocks, query)
  if not tx then
    print("Transaction introuvable dans la chaîne.")
    return
  end

  print("ID       : " .. (tx.id or tx.hash or "inconnu"))
  print("De       : " .. tx.from)
  print("Vers     : " .. tx.to)
  print("Montant  : " .. tx.amount .. " MC")
  print("Bloc     : " .. (block and block.index or "mempool"))
  print("Hash bloc: " .. (block and block.hash or "inconnu"))
end

local function config_node()
  local discovered = discover_node()
  if discovered then
    print("Node sauvegarde automatiquement.")
    return
  end

  local addr = trim(input("Adresse modem du node :"))
  if not addr or addr == "" then
    print("Aucune adresse fournie.")
    return
  end

  explorer.node = addr
  save_node()
  print("Node sauvegarde.")
end

local function show_info()
  print("Node    : " .. (explorer.node or "non configure"))
  print("Port    : " .. explorer.port)
  print("Config  : " .. CONFIG_FILE)
  print("Seeds   : " .. SEEDS_FILE)
end

local menu = {
  { label = "Infos de la chaîne",        fn = show_chain_info  },
  { label = "Derniers blocs",            fn = show_last_blocks },
  { label = "Détails d'un bloc",         fn = show_block       },
  { label = "Détails d'une transaction", fn = show_tx          },
  { label = "Détecter le node",          fn = config_node      },
  { label = "Infos de l'explorer",       fn = show_info        },
  { label = "Quitter",                   fn = nil              },
}

load_config()
modem.open(protocol.PORT_SEED)
modem.open(explorer.port)
load_persisted()

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