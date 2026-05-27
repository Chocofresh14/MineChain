local component = require("component")
local serialization = require("serialization")
local fs = require("filesystem")
local hash = require("crypto/hash")

local M = {}
local _data = nil

local function data()
  if not _data then
    assert(component.isAvailable("data"), "Data Card introuvable !")
    _data = component.data
  end
  return _data
end

-- Derive une adresse depuis une cle publique
-- Format : 40 premiers caracteres hex du sha256(cle serialisee)
-- Similaire au principe d'une adresse Ethereum
local function deriveAddress(pubKey)
  local h = hash.sha256(pubKey.serialize())
  return h:sub(1, 40)
end

-- Genere une nouvelle paire de cles
-- Retourne : { public, private, address }
function M.generate()
  local pub, priv = data().generateKeyPair(256)
  return {
    public  = pub,
    private = priv,
    address = deriveAddress(pub)
  }
end

-- Derive l'adresse depuis une cle publique existante
function M.addressFrom(pubKey)
  return deriveAddress(pubKey)
end

-- Sauvegarde les cles sur le disque OC
-- path : dossier de destination (ex: "/etc/minechain/wallet/")
function M.save(keys, path)
  if not fs.exists(path) then
    fs.makeDirectory(path)
  end

  local function write(filename, content)
    local f = assert(io.open(path .. filename, "wb"))
    f:write(content)
    f:close()
  end

  write("key.pub", serialization.serialize(keys.public.serialize()))
  write("key.priv", serialization.serialize(keys.private.serialize()))
  write("address", keys.address)

  print("Cles sauvegardees dans : " .. path)
end

-- Charge les cles depuis le disque
-- Retourne : keys ou nil, erreur
function M.load(path)
  local function read(filename)
    local f = io.open(path .. filename, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
  end

  local pubRaw  = read("key.pub")
  local privRaw = read("key.priv")
  local address = read("address")

  if not pubRaw or not privRaw then
    return nil, "Cles introuvables dans : " .. path
  end

  local pub  = data().deserializeKey(serialization.unserialize(pubRaw), "ec-public")
  local priv = data().deserializeKey(serialization.unserialize(privRaw), "ec-private")

  return {
    public  = pub,
    private = priv,
    address = address
  }
end

-- Verifie si des cles existent deja dans le dossier
function M.exists(path)
  return fs.exists(path .. "key.pub")
      and fs.exists(path .. "key.priv")
      and fs.exists(path .. "address")
end

return M
