local fs     = require("filesystem")
local serial = require("serialization")
local computer = require("computer")

local keypair = require("crypto/keypair")
local sign    = require("crypto/sign")
local TxLib   = require("types/transaction")
local modem   = require("net/modem")
local protocol= require("net/protocol")

local CONFIG_FILE    = "/etc/minechain/config.lua"
local SEEDS_FILE     = "/etc/minechain/seeds.lua"
local DEFAULT_KEYDIR = "/etc/minechain/wallet/"

local wallet = {
  pubkey  = nil,
  privkey = nil,
  address = nil,
  node    = nil,
  port    = protocol.PORT_NODE,
  keydir  = DEFAULT_KEYDIR,
  nodecfg = DEFAULT_KEYDIR .. "node.cfg",
}

local function normalize_dir(path)
  if not path or path == "" then
    return DEFAULT_KEYDIR
  end
  if path:sub(-1) ~= "/" then
    return path .. "/"
  end
  return path
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

  wallet.port = tonumber(cfg.PORT) or wallet.port
  wallet.keydir = normalize_dir(cfg.KEY_PATH)
  wallet.nodecfg = wallet.keydir .. "node.cfg"
end

load_config()

modem.open(protocol.PORT_SEED)
modem.open(wallet.port)

local function input(label)
  io.write(label .. " ")
  return io.read()
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

local function ensure_wallet_dir()
  if not fs.exists(wallet.keydir) then
    fs.makeDirectory(wallet.keydir)
  end
end

local function apply_keys(keys)
  wallet.pubkey = keys.public
  wallet.privkey = keys.private
  wallet.address = keys.address or keypair.addressFrom(keys.public)
end

local function serialize_public_key(pubkey)
  return serial.serialize(pubkey.serialize())
end

local function persist_node()
  ensure_wallet_dir()
  local file = io.open(wallet.nodecfg, "w")
  file:write(wallet.node or "")
  file:close()
end

local function persist_keys()
  ensure_wallet_dir()
  keypair.save({
    public = wallet.pubkey,
    private = wallet.privkey,
    address = wallet.address,
  }, wallet.keydir)
end

local function load_persisted()
  if keypair.exists(wallet.keydir) then
    local keys, err = keypair.load(wallet.keydir)
    if keys then
      apply_keys(keys)
      print("Clés chargées automatiquement.")
    else
      print("Erreur chargement clés : " .. tostring(err))
    end
  end

  local node = read_file(wallet.nodecfg)
  if node and node ~= "" then
    wallet.node = node:gsub("%s+$", "")
    print("Node : " .. wallet.node)
  end
end

local function load_seeds()
  return read_table_file(SEEDS_FILE) or {}
end

local function try_node(candidate)
  print("[try_node] Envoi GET_LAST -> " .. candidate .. " sur port " .. wallet.port)
  modem.send(candidate, wallet.port, protocol.MSG.GET_LAST, protocol.getLast())

  local started_at = computer.uptime()
  while (computer.uptime() - started_at) < 2 do
    local remoteAddr, msgType, respData = modem.receive(wallet.port, 1)
    if remoteAddr then
      print("[try_node] Recu " .. tostring(msgType) .. " de " .. tostring(remoteAddr))
    end
    if remoteAddr == candidate and msgType == protocol.MSG.LAST_BLOCK and respData and respData.block then
      wallet.node = candidate
      ensure_wallet_dir()
      local file = io.open(wallet.nodecfg, "w")
      file:write(candidate)
      file:close()
      print("Node detecte : " .. candidate)
      return candidate
    end
  end

  print("[try_node] Timeout, pas de reponse de " .. candidate)
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

local function fetch_chain(page_size)
  if not wallet.node and not discover_node() then
    print("Erreur : aucun node configuré.")
    return nil
  end

  local blocks = {}
  local from_index = 0
  local timeout = 5
  local count = page_size or 20
  local max_pages = 128
  local pages = 0

  while pages < max_pages do
    modem.send(wallet.node, wallet.port, protocol.MSG.GET_CHAIN, protocol.getChain(from_index, count))

    local response = nil
    local started_at = computer.uptime()
    while (computer.uptime() - started_at) < timeout do
      local remoteAddr, msgType, data = modem.receive(wallet.port, 1)
      if remoteAddr == wallet.node and msgType == protocol.MSG.CHAIN then
        response = data
        break
      end
    end

    if not response then
      print("Erreur : timeout, node injoignable.")
      return nil
    end

    if type(response.blocks) ~= "table" then
      print("Erreur : reponse CHAIN invalide.")
      return nil
    end

    if #response.blocks == 0 then
      break
    end

    local previous_from_index = from_index

    for _, block in ipairs(response.blocks) do
      table.insert(blocks, block)
    end

    if #response.blocks < count then
      break
    end

    from_index = from_index + #response.blocks
    if from_index <= previous_from_index then
      print("Erreur : progression de synchronisation invalide.")
      return nil
    end

    pages = pages + 1
  end

  if pages >= max_pages then
    print("Erreur : trop de pages recues (boucle de sync interrompue).")
    return nil
  end

  return blocks
end

local function query_node(msg_type, payload)
  if not wallet.node and not discover_node() then
    print("Erreur : aucun node configuré.")
    return nil
  end

  modem.send(wallet.node, wallet.port, msg_type, payload)

  local deadline = os.time() + 5
  while os.time() < deadline do
    local remoteAddr, respType, data = modem.receive(wallet.port, 1)
    if remoteAddr == wallet.node then
      return respType, data
    end
  end

  print("Erreur : timeout, node injoignable.")
  return nil
end


local function generate_keys()
  apply_keys(keypair.generate())
  print("Adresse : " .. wallet.address)
  local ans = input("Sauvegarder ? (o/n)")
  if ans == "o" then
    persist_keys()
  end
end

local function load_keys()
  local keys, err = keypair.load(wallet.keydir)
  if not keys then
    print("Aucun fichier trouvé : " .. tostring(err))
    return
  end
  apply_keys(keys)
  print("Adresse : " .. wallet.address)
end

local function show_balance()
  if not wallet.address then
    print("Aucune clé chargée.")
    return
  end

  local blocks = fetch_chain(20)
  if not blocks then
    return
  end

  print("Solde : " .. TxLib.balanceOf(wallet.address, blocks) .. " MC")
end

local function send_tx()
  if not wallet.address or not wallet.privkey or not wallet.pubkey then
    print("Aucune clé chargée.")
    return
  end

  local to     = input("Destinataire :")
  local amount = tonumber(input("Montant (MC) :"))
  if not amount or amount <= 0 then
    print("Montant invalide.")
    return
  end

  local blocks = fetch_chain(20)
  if not blocks then
    return
  end

  local fundsOk, fundsErr = TxLib.hasFunds({ from = wallet.address, amount = amount }, blocks)
  if not fundsOk then
    print(fundsErr)
    return
  end

  local tx = TxLib.new(wallet.address, to, amount)
  local signature = sign.sign(TxLib.serialize(tx), wallet.privkey)
  tx = TxLib.attach(tx, signature)

  print("De      : " .. wallet.address)
  print("Vers    : " .. to)
  print("Montant : " .. amount .. " MC")
  local ans = input("Confirmer ? (o/n)")
  if ans ~= "o" then
    print("Annulé.")
    return
  end

  modem.send(wallet.node, wallet.port, protocol.MSG.NEW_TX, protocol.newTx(tx, serialize_public_key(wallet.pubkey)))
  print("Transaction envoyée au node.")
end

local function config_node()
  if discover_node() then
    print("Node sauvegarde automatiquement.")
  end
end

local function show_info()
  if not wallet.address then
    print("Aucune clé chargée.")
    return
  end
  print("Adresse : " .. wallet.address)
  print("Port    : " .. wallet.port)
  print("Clés    : " .. wallet.keydir)
  print("Node    : " .. (wallet.node or "non configuré"))
end


local menu = {
  { label = "Générer une paire de clés",  fn = generate_keys },
  { label = "Charger les clés du disque", fn = load_keys     },
  { label = "Afficher le solde",          fn = show_balance  },
  { label = "Envoyer une transaction",    fn = send_tx       },
  { label = "Detecter le node",            fn = config_node   },
  { label = "Infos du wallet",            fn = show_info     },
  { label = "Quitter",                    fn = nil           },
}

load_persisted()

while true do
  print("\n ———MineChain Wallet——— ")
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