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

local function toHex(bin)
  return (bin:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

function M.sha256(input)
  assert(type(input) == "string", "sha256: string attendue")
  return toHex(data().sha256(input))
end

function M.sha256raw(input)
  assert(type(input) == "string", "sha256raw: string attendue")
  return data().sha256(input)
end

function M.encode64(input)
  return data().encode64(input)
end

function M.decode64(input)
  return data().decode64(input)
end

return M
