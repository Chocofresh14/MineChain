-- Usage : wget https://forgejo.ton-domaine.tld/user/repo/raw/branch/main/install.lua
--         lua install.lua

local component = require("component")
local filesystem = require("filesystem")
local term = require("term")
local os = require("os")
local serialization = require("serialization")

local REPO_BASE = "https://git.oteria.fr/tiago.ferreira-lourenco/minechain/-/raw/main"

local gpu = component.isAvailable("gpu") and component.gpu or nil

local colors = {
  white  = 0xFFFFFF,
  gray   = 0x888888,
  green  = 0x00FF00,
  red    = 0xFF4444,
  yellow = 0xFFCC00,
  cyan   = 0x00CCFF,
  black  = 0x000000,
}

local function setColor(fg, bg)
  if gpu then
    if fg then gpu.setForeground(fg) end
    if bg then gpu.setBackground(bg or colors.black) end
  end
end

local function printColor(text, color)
  setColor(color or colors.white)
  print(text)
  setColor(colors.white)
end

assert(component.isAvailable("internet"), "Carte internet introuvable ! Impossible de telecharger les fichiers.")
local internet = component.internet

local function fetch(url)
  local handle, err = internet.request(url)
  if not handle then
    error("Requete impossible : " .. tostring(err))
  end

  local deadline = os.time() + 10
  while not handle.finishConnect() do
    if os.time() > deadline then
      handle.close()
      error("Timeout : " .. url)
    end
    os.sleep(0.5)
  end

  local code, msg = handle.response()
  if code ~= 200 then
    handle.close()
    error(string.format("HTTP %d : %s", code, tostring(msg)))
  end

  local content = ""
  for chunk in handle.read do
    content = content .. chunk
  end
  handle.close()

  return content
end

local function download(repoPath, localPath)
  io.write("  Telechargement " .. localPath .. " ... ")

  local dir = filesystem.path(localPath)
  if not filesystem.exists(dir) then
    filesystem.makeDirectory(dir)
  end

  local ok, result = pcall(fetch, REPO_BASE .. "/" .. repoPath)
  if not ok then
    setColor(colors.red)
    print("ERREUR : " .. result)
    setColor(colors.white)
    return false
  end

  local file = io.open(localPath, "w")
  if not file then
    setColor(colors.red)
    print("ERREUR : impossible d'ecrire " .. localPath)
    setColor(colors.white)
    return false
  end

  file:write(result)
  file:close()

  setColor(colors.green)
  print("OK")
  setColor(colors.white)

  return true
end

local function downloadAll(files)
  local allOk = true
  for _, entry in ipairs(files) do
    local ok = download(entry[1], entry[2])
    if not ok then allOk = false end
  end
  return allOk
end

local function writeConfig(cfg)
  local dir = "/etc/minechain"
  if not filesystem.exists(dir) then
    filesystem.makeDirectory(dir)
  end

  local file = assert(io.open("/etc/minechain/config.lua", "w"))
  file:write("-- Configuration generee par install.lua\n")
  file:write("-- Ne pas modifier manuellement\n\n")
  file:write("return {\n")

  for k, v in pairs(cfg) do
    if type(v) == "string" then
      file:write(string.format('  %-20s = "%s",\n', k, v))
    elseif type(v) == "boolean" then
      file:write(string.format('  %-20s = %s,\n', k, tostring(v)))
    elseif type(v) == "number" then
      file:write(string.format('  %-20s = %d,\n', k, v))
    elseif type(v) == "table" then
      file:write(string.format('  %-20s = %s,\n', k, serialization.serialize(v)))
    end
  end

  file:write("}\n")
  file:close()

  setColor(colors.green)
  print("  /etc/minechain/config.lua")
  setColor(colors.white)
end

local function ask(question, default)
  setColor(colors.cyan)
  if default then
    io.write(question .. " [" .. tostring(default) .. "] : ")
  else
    io.write(question .. " : ")
  end
  setColor(colors.white)

  local input = io.read()
  if input == nil or input == "" then
    return default
  end
  return input
end

local function askBool(question, default)
  local defaultStr = default and "o" or "n"
  local raw = ask(question .. " (o/n)", defaultStr)
  return (raw == "o" or raw == "oui" or raw == "y" or raw == "yes")
end

local function menu(title, options)
  setColor(colors.yellow)
  print("\n" .. title)
  setColor(colors.white)

  for i, opt in ipairs(options) do
    print(string.format("  %d. %s", i, opt.label))
  end

  while true do
    local raw = ask("Choix", nil)
    local n   = tonumber(raw)
    if n and options[n] then
      return options[n].key
    end
    setColor(colors.red)
    print("  Choix invalide, reessaie (1-" .. #options .. ")")
    setColor(colors.white)
  end
end

local COMMON_FILES = {
  { "lib/crypto/sha256.lua",     "/lib/crypto/sha256.lua" },
  { "lib/crypto/hash.lua",       "/lib/crypto/hash.lua" },
  { "lib/crypto/keypair.lua",    "/lib/crypto/keypair.lua" },
  { "lib/crypto/sign.lua",       "/lib/crypto/sign.lua" },
  { "lib/types/block.lua",       "/lib/types/block.lua" },
  { "lib/types/transaction.lua", "/lib/types/transaction.lua" },
  { "lib/net/modem.lua",         "/lib/net/modem.lua" },
  { "lib/net/protocol.lua",      "/lib/net/protocol.lua" },
  { "seeds.lua",                 "/etc/minechain/seeds.lua" },
}

local PACKAGES = {}

PACKAGES["seed"] = {
  label = "Seed - Annuaire reseau",
  files = {
    { "packages/seed/main.lua",    "/minechain/main.lua" },
    { "packages/seed/startup.lua", "/startup.lua" },
  },
  configure = function()
    print("")
    printColor("Configuration du Seed Node :", colors.yellow)

    local port = tonumber(ask("Port d'ecoute", 42))

    return {
      PACKAGE = "seed",
      PORT    = port,
    }
  end,
  info = {
    "- Toujours allume si possible",
    "- Notez l'adresse modem affichee au demarrage",
    "- Ajoutez-la dans seeds.lua du depot",
  }
}

PACKAGES["node"] = {
  label = "Node - Noeud blockchain",
  files = {
    { "packages/node/main.lua",    "/minechain/main.lua" },
    { "packages/node/sync.lua",    "/lib/node/sync.lua" },
    { "packages/node/miner.lua",   "/lib/node/miner.lua" },
    { "packages/node/mempool.lua", "/lib/node/mempool.lua" },
    { "packages/node/startup.lua", "/startup.lua" },
  },
  configure = function()
    print("")
    printColor("Configuration du Node :", colors.yellow)

    local port   = tonumber(ask("Port d'ecoute", 43))
    local mining = askBool("Activer le mining ?", false)
    local diff   = 3
    local wallet = ""

    if mining then
      diff = tonumber(ask("Difficulte PoW (zeros requis en tete de hash)", 3))
      wallet = ask("Adresse wallet pour recevoir les recompenses")

      while wallet == "" or wallet == nil do
        printColor("  L'adresse wallet est obligatoire pour miner.", colors.red)
        wallet = ask("Adresse wallet")
      end
    end

    return {
      PACKAGE = "node",
      PORT = port,
      MINING = mining,
      DIFFICULTY = diff,
      WALLET_ADDRESS = wallet,
    }
  end,
  info = {
    "- Demarre et se synchronise automatiquement",
    "- Le mining peut etre active/desactive dans la config",
  }
}

PACKAGES["wallet"] = {
  label = "Wallet - Portefeuille",
  files = {
    { "packages/wallet/main.lua",    "/minechain/main.lua" },
    { "packages/wallet/startup.lua", "/startup.lua" },
  },
  configure = function()
    print("")
    printColor("Configuration du Wallet :", colors.yellow)

    local port    = tonumber(ask("Port reseau", 43))
    local genKeys = askBool("Generer une nouvelle paire de cles maintenant ?", true)

    return {
      PACKAGE      = "wallet",
      PORT         = port,
      KEY_PATH     = "/etc/minechain/wallet/",
      GENERATE_KEY = genKeys,
    }
  end,
  info = {
    "- Requiert une Data Card Tier 3 pour la crypto",
    "- Les cles sont stockees dans /etc/minechain/wallet/",
    "- Ne partagez jamais key.priv !",
  }
}

PACKAGES["explorer"] = {
  label = "Explorer - Explorateur de blocs",
  files = {
    { "packages/explorer/main.lua",     "/minechain/main.lua" },
    { "packages/explorer/renderer.lua", "/minechain/renderer.lua" },
    { "packages/explorer/startup.lua",  "/startup.lua" },
  },
  configure = function()
    print("")
    printColor("Configuration de l'Explorer :", colors.yellow)

    local port = tonumber(ask("Port reseau des nodes", 43))

    return {
      PACKAGE = "explorer",
      PORT    = port,
    }
  end,
  info = {
    "- Requiert un GPU et un grand ecran pour le rendu",
    "- Se connecte automatiquement a un node via les seeds",
    "- Mode lecture seule, ne participe pas au reseau",
  }
}

local function printBanner()
  term.clear()
  setColor(colors.cyan)
  print("╔══════════════════════════════════════════╗")
  print("║         MineChain - Installateur         ║")
  print("╚══════════════════════════════════════════╝")
  setColor(colors.gray)
  print("  Depot : " .. REPO_BASE)
  setColor(colors.white)
  print("")
end

printBanner()

local choice = menu("Que souhaitez-vous installer ?", {
  { key = "seed",     label = PACKAGES["seed"].label },
  { key = "node",     label = PACKAGES["node"].label },
  { key = "wallet",   label = PACKAGES["wallet"].label },
  { key = "explorer", label = PACKAGES["explorer"].label },
})

local pkg = PACKAGES[choice]

print("")
printColor("Package selectionne : " .. pkg.label, colors.yellow)
print("")
local confirmed = askBool("Confirmer l'installation ?", true)
if not confirmed then
  printColor("Installation annulee.", colors.red)
  return
end

print("")
printColor("[ 1/3 ] Telechargement des libs communes...", colors.cyan)
local ok = downloadAll(COMMON_FILES)
if not ok then
  printColor("\nErreur lors du telechargement des libs. Verifiez la connexion.", colors.red)
  return
end

print("")
printColor("[ 2/3 ] Telechargement du package " .. pkg.label .. "...", colors.cyan)
ok = downloadAll(pkg.files)
if not ok then
  printColor("\nErreur lors du telechargement du package.", colors.red)
  return
end

print("")
printColor("[ 3/3 ] Configuration...", colors.cyan)
local cfg = pkg.configure()
writeConfig(cfg)

print("")
setColor(colors.green)
print("╔══════════════════════════════════════════╗")
print("║         Installation terminee !          ║")
print("╚══════════════════════════════════════════╝")
setColor(colors.white)
print("")
printColor("Package   : " .. pkg.label, colors.yellow)
printColor("Config    : /etc/minechain/config.lua", colors.gray)
printColor("Programme : /minechain/main.lua", colors.gray)
printColor("Démarrage : /startup.lua", colors.gray)

if #pkg.info > 0 then
  print("")
  printColor("Notes :", colors.yellow)
  for _, line in ipairs(pkg.info) do
    printColor(line, colors.gray)
  end
end

print("")
printColor("Redemarre le PC pour lancer automatiquement.", colors.cyan)
printColor("Ou lance manuellement : lua /minechain/main.lua", colors.gray)
print("")
