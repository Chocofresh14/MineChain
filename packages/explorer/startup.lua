local path = "/minechain/main.lua"

if require("filesystem").exists(path) then
	dofile(path)
else
	print("[MineChain Explorer] Fichier introuvable : " .. path)
	print("Vérifiez que install.lua a bien été exécuté.")
end
