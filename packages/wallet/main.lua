--  Dépendances :
--    lib/crypto/keypair.lua   -> keypair.generate(), keypair.load(), keypair.save()
--    lib/crypto/sign.lua      -> sign.sign(privkey, data), sign.verify(pubkey, data, sig)
--    lib/crypto/sha256.lua    -> sha256.hash(str)
--    lib/types/transaction.lua-> transaction.new(from, to, amount, nonce), transaction.serialize()
--    lib/net/modem.lua        -> modem.open(port), modem.send(addr, port, msg), modem.broadcast(port, msg)
--    lib/net/protocol.lua     -> protocol.PORTS, protocol.wrap(type, payload), protocol.unwrap(raw)


local fs     = require("filesystem")
local serial = require("serialization")

local keypair = dofile("crypto/keypair.lua")
local sha256  = dofile("crypto/sha256.lua")
local sign    = dofile("crypto/sign.lua")
local TxLib   = dofile("types/transaction.lua")
local modem   = dofile("net/modem.lua")
local protocol= dofile("net/protocol.lua")

local KEY_FILE  = "/minechain/keys.dat"
local NODE_FILE = "/minechain/node.cfg"

local wallet = {
  pubkey  = nil,
  privkey = nil,
  address = nil,
  node    = nil,
  nonce   = 0,
}


local function input(label)
  io.write(label .. " ")
  return io.read()
end

local function derive_address(pub)
  return sha256.hash(pub):sub(1, 40)
end

local function load_persisted()
  if fs.exists(KEY_FILE) then
    local f = io.open(KEY_FILE, "r")
    local data = serial.unserialize(f:read("*a"))
    f:close()
    if data and data.pub then
      wallet.pubkey  = data.pub
      wallet.privkey = data.priv
      wallet.address = derive_address(data.pub)
      print("Clés chargées automatiquement.")
    end
  end
  if fs.exists(NODE_FILE) then
    local f = io.open(NODE_FILE, "r")
    wallet.node = f:read("*a")
    f:close()
    print("Node : " .. wallet.node)
  end
end

local function save_keys()
  if not fs.exists("/minechain/wallet") then
    fs.makeDirectory("/minechain/wallet")
  end
  local f = io.open(KEY_FILE, "w")
  f:write(serial.serialize({ pub = wallet.pubkey, priv = wallet.privkey }))
  f:close()
  print("Clés sauvegardées.")
end

local function query_node(msg_type, payload)
  if not wallet.node then
    print("Erreur : aucun node configuré.")
    return nil
  end
  local port = protocol.PORTS.wallet
  modem.open(port)
  modem.send(wallet.node, protocol.PORTS.node, protocol.wrap(msg_type, payload))

  local ev, _, _, _, _, raw = event.pull(5, "modem_message")
  if not ev then
    print("Erreur : timeout, node injoignable.")
    return nil
  end
  return protocol.unwrap(raw)
end


local function generate_keys()
  wallet.pubkey, wallet.privkey = keypair.generate()
  wallet.address = derive_address(wallet.pubkey)
  wallet.nonce   = 0
  print("Adresse : " .. wallet.address)
  local ans = input("Sauvegarder ? (o/n)")
  if ans == "o" then save_keys() end
end

local function load_keys()
  if not fs.exists(KEY_FILE) then
    print("Aucun fichier trouvé : " .. KEY_FILE)
    return
  end
  local f = io.open(KEY_FILE, "r")
  local data = serial.unserialize(f:read("*a"))
  f:close()
  wallet.pubkey  = data.pub
  wallet.privkey = data.priv
  wallet.address = derive_address(data.pub)
  wallet.nonce   = 0
  print("Adresse : " .. wallet.address)
end

local function show_balance()
  if not wallet.address then print("Aucune clé chargée.") return end
  local resp = query_node("GET_BALANCE", { address = wallet.address })
  if resp and resp.type == "BALANCE" then
    print("Solde : " .. resp.payload.balance .. " MC")
    wallet.nonce = resp.payload.nonce or wallet.nonce
  end
end

local function send_tx()
  if not wallet.address or not wallet.privkey then
    print("Aucune clé chargée.") return
  end
  local to     = input("Destinataire :")
  local amount = tonumber(input("Montant (MC) :"))
  if not amount or amount <= 0 then print("Montant invalide.") return end

  local nonce = wallet.nonce + 1
  local tx    = TxLib.new(wallet.address, to, amount, nonce)
  tx:set_signature(sign.sign(wallet.privkey, tx:serialize()))

  print("De      : " .. wallet.address)
  print("Vers    : " .. to)
  print("Montant : " .. amount .. " MC")
  local ans = input("Confirmer ? (o/n)")
  if ans ~= "o" then print("Annulé.") return end

  local resp = query_node("BROADCAST_TX", { tx = tx:to_table() })
  if resp and resp.type == "TX_ACCEPTED" then
    wallet.nonce = nonce
    print("Transaction acceptée ! Hash : " .. (resp.payload.hash or "?"))
  elseif resp and resp.type == "TX_REJECTED" then
    print("Transaction rejetée : " .. (resp.payload.reason or "?"))
  end
end

local function config_node()
  local addr = input("Adresse modem du node :")
  wallet.node = addr
  if not fs.exists("/minechain/wallet") then
    fs.makeDirectory("/minechain/wallet")
  end
  local f = io.open(NODE_FILE, "w")
  f:write(addr)
  f:close()
  print("Node sauvegardé.")
end

local function show_info()
  if not wallet.address then print("Aucune clé chargée.") return end
  print("Adresse : " .. wallet.address)
  print("Nonce   : " .. wallet.nonce)
  print("Node    : " .. (wallet.node or "non configuré"))
end


local menu = {
  { label = "Générer une paire de clés",  fn = generate_keys },
  { label = "Charger les clés du disque", fn = load_keys     },
  { label = "Afficher le solde",          fn = show_balance  },
  { label = "Envoyer une transaction",    fn = send_tx       },
  { label = "Configurer le node",         fn = config_node   },
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