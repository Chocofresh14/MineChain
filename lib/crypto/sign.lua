local component = require("component")
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

function M.sign(message, privateKey)
  assert(type(message) == "string", "sign: message doit etre une string")
  local h   = hash.sha256raw(message)
  local sig = data().ecdsa(h, privateKey)
  return data().encode64(sig)
end

function M.verify(message, publicKey, signature)
  assert(type(message) == "string", "verify: message doit etre une string")
  assert(type(signature) == "string", "verify: signature doit etre une string")
  local h      = hash.sha256raw(message)
  local sigBin = data().decode64(signature)
  return data().ecdsa(h, publicKey, sigBin)
end

return M
