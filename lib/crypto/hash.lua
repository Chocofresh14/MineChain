local component = require("component")

local M = {}
local _data = nil

local function data()
  if not _data then
    assert(component.isAvailable("data"), "Data Card introuvable !")
    _data = component.data
  end
  return _data
end

-- Convertit une string binaire en hexadecimal lisible
local function toHex(bin)
  return (bin:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

-- SHA-256 retourne une string hex (ex: "a3f2b1...")
function M.sha256(input)
  assert(type(input) == "string", "sha256: string attendue")
  return toHex(data().sha256(input))
end

-- SHA-256 binaire (usage interne pour signer)
function M.sha256raw(input)
  assert(type(input) == "string", "sha256raw: string attendue")
  return data().sha256(input)
end

-- Encode en base64 (utile pour serialiser des binaires)
function M.encode64(input)
  return data().encode64(input)
end

-- Decode depuis base64
function M.decode64(input)
  return data().decode64(input)
end

return M
