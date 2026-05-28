local block = require("types/block")
local tx = require("types/transaction")
local mempool = require("node/mempool")

local M = {}

-- Config

local cfg = assert(loadfile("/etc/minechain/config.lua"))()
local DIFFICULTY = cfg.DIFFICULTY or 3
local MINING_ADDR = nil -- adresse du mineur, injectee depuis main
local REWARD = 50       -- coins par bloc mine
local BATCH = 100       -- nonces tentes avant chaque yield

-- Prefixe attendu en tete de hash (ex: "000" pour difficulte 3)
local TARGET_PREFIX = string.rep("0", DIFFICULTY)

-- State

local _running = false -- le minage est-il actif ?
local _reset = false   -- flag : un nouveau bloc est arrive, recommencer
local _lastBlock = nil -- reference vers la chaine (injectee depuis main)
local _onFound = nil   -- callback appele quand un bloc est trouve

-- Init

-- Injecte les dependances depuis node/main
-- getLastBlock : fonction qui retourne le dernier bloc de la chaine
-- minerAddress : adresse wallet du mineur (pour la recompense coinbase)
-- onFound : function(block) appelee quand un bloc est mine
function M.init(getLastBlock, minerAddress, onFound)
  _lastBlock  = getLastBlock
  MINING_ADDR = minerAddress
  _onFound    = onFound
end

-- Controle

-- Signale au miner qu'un nouveau bloc est arrive -> recommencer
function M.reset()
  _reset = true
end

function M.start()
  _running = true
end

function M.stop()
  _running = false
end

-- Construction du bloc candidat

local function buildCandidate()
  local prev = _lastBlock()
  local txList = mempool.getPending(10)

  -- Toujours ajouter la coinbase en premier (recompense du mineur)
  local coinbaseTx = tx.coinbase(MINING_ADDR, REWARD)
  table.insert(txList, 1, coinbaseTx)

  return block.new(
    prev.index + 1,
    prev.hash,
    txList,
    MINING_ADDR
  )
end

-- Boucle de minage (coroutine)

-- Cette fonction tourne en coroutine depuis node/main.
-- Elle yield regulierement pour laisser la place aux evenements reseau.

function M.run()
  print("[miner] Demarrage du minage (difficulte " .. DIFFICULTY .. ")...")

  while true do
    -- Attend que le minage soit active
    if not _running then
      coroutine.yield()
    end

    -- Attend qu'il y ait au moins une tx (hors coinbase) OU
    -- qu'un certain temps se soit ecoule depuis le dernier bloc
    local pending = mempool.getPending(1)
    if #pending == 0 then
      coroutine.yield()
    else
      -- Construit un nouveau bloc candidat
      local candidate = buildCandidate()
      local nonce     = 0
      _reset          = false

      print(string.format("[miner] Bloc #%d en cours... (%d tx)",
        candidate.index, #candidate.transactions))

      -- Boucle PoW
      while true do
        -- Un nouveau bloc est arrive depuis le reseau -> on recommence
        if _reset then
          print("[miner] Reset : nouveau bloc reçu, on recommence.")
          break
        end

        -- Tente un batch de nonces avant de yield
        for _ = 1, BATCH do
          candidate.nonce = nonce
          candidate.hash  = block.computeHash(candidate)

          -- Verifie le PoW
          if candidate.hash:sub(1, DIFFICULTY) == TARGET_PREFIX then
            -- Bloc trouve !
            print(string.format(
              "[miner] Bloc #%d mine ! nonce=%d hash=%s",
              candidate.index, nonce, candidate.hash:sub(1, 16) .. "..."
            ))
            if _onFound then _onFound(candidate) end
            _reset = true -- force la reconstruction d'un nouveau candidat
            break
          end

          nonce = nonce + 1
        end

        -- Yield pour laisser la place aux evenements
        coroutine.yield()
      end
    end
  end
end

return M
