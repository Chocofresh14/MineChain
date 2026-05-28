local component = require("component")
local sha256 = require("crypto/sha256")

local M = {}

local function data()
  assert(component.isAvailable("data"), "Data Card introuvable !")
  return component.data
end

-- Convertit une string binaire en hexadecimal lisible
local function toHex(bin)
  -- Garde-fou explicite pour avoir un message d'erreur utile
  if bin == nil then
    error("Data Card sha256 a retourne nil, input trop grand ?")
  end
  return (bin:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

-- SHA-256 retourne une string hex (ex: "a3f2b1...")
M.sha256 = sha256.sha256

-- SHA-256 binaire (usage interne pour signer)
M.sha256raw = sha256.sha256raw

-- Encode en base64 (utile pour serialiser des binaires)
function M.encode64(input) return data().encode64(input) end

-- Decode depuis base64
function M.decode64(input) return data().decode64(input) end

return M