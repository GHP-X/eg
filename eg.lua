-- SafeSkin v6.4b — Client-Side Skinchanger for Rivals
-- Cosmetics (skins, wraps, charms, finishers) for owned weapons
-- Swallows equip/favorite remotes, passes everything else through

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

-- Wait for game to load
if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(1)

-- Wait for character
if not LocalPlayer.Character then
    LocalPlayer.CharacterAdded:Wait()
end
task.wait(0.5)

-- Find essential folders
local PlayerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
if not PlayerScripts then return end
local Controllers = PlayerScripts:FindFirstChild("Controllers")
if not Controllers then return end
local Modules = ReplicatedStorage:FindFirstChild("Modules")
if not Modules then return end

-- Helper to find child with timeout
local function findChild(parent, name, timeout)
    local count = 0
    while not parent:FindFirstChild(name) and count < timeout do
        task.wait(0.5)
        count = count + 1
    end
    return parent:FindFirstChild(name)
end

-- Load required modules
local CosmeticLibrary = findChild(Modules, "CosmeticLibrary", 10)
local ItemLibrary = findChild(Modules, "ItemLibrary", 10)
local PlayerDataController = findChild(Controllers, "PlayerDataController", 10)

if not CosmeticLibrary or not ItemLibrary or not PlayerDataController then return end

local CosmeticLib = require(CosmeticLibrary)
local ItemLib = require(ItemLibrary)
local PlayerData = require(PlayerDataController)
local EnumLib = Modules:FindFirstChild("EnumLibrary") and require(Modules:FindFirstChild("EnumLibrary"))

if not CosmeticLib or not ItemLib or not PlayerData then return end

-- ============================================================
-- STATE
-- ============================================================
local equipped = {}           -- equipped[weapon][slot] = item
local favorites = {}          -- favorites[slot][id] = true
local currentItemName         -- for item creation context (Wrap.new)
local viewedPlayer            -- player being viewed in profile
local currentFinisherName     -- last used finisher

-- Build cosmetic inventory with real entries for pairs() iteration
local cosmeticInventoryProxy = {}
pcall(function()
    if CosmeticLib.Cosmetics then
        for name, _ in pairs(CosmeticLib.Cosmetics) do
            cosmeticInventoryProxy[name] = true
        end
    end
end)

-- Create cosmetic item from library data
local function createCosmeticItem(name, slot, options)
    if not CosmeticLib.Cosmetics then return nil end
    local data = CosmeticLib.Cosmetics[name]
    if not data then return nil end

    local item = {}
    for k, v in pairs(data) do item[k] = v end
    item.Name = name
    item.Type = item.Type or slot
    item.Seed = math.random(1, 1000000)

    if EnumLib then
        pcall(function()
            local enum = EnumLib:ToEnum(name)
            if enum then
                item.Enum = enum
                item.ObjectID = enum
            end
        end)
    end

    if options then
        if options.inverted then item.Inverted = true end
        if options.favoritesOnly then item.OnlyUseFavorites = true end
    end
    return item
end

-- ============================================================
-- CONFIG PERSISTENCE
-- ============================================================
local CONFIG_FOLDER = "GHP"
local CONFIG_FILE = CONFIG_FOLDER .. "/skins_v6.json"

local function saveConfig()
    if not writefile then return end
    task.spawn(function()
        pcall(function()
            local data = { equipped = {}, favorites = favorites }
            for weapon, items in pairs(equipped) do
                data.equipped[weapon] = {}
                for slot, item in pairs(items) do
                    if item and item.Name then
                        data.equipped[weapon][slot] = {
                            name = item.Name,
                            seed = item.Seed,
                            inverted = item.Inverted
                        }
                    end
                end
            end
            if isfolder and not isfolder(CONFIG_FOLDER) then pcall(makefolder, CONFIG_FOLDER) end
            writefile(CONFIG_FILE, HttpService:JSONEncode(data))
        end)
    end)
end

local function loadConfig()
    if not readfile or not isfile then return end
    -- Try v6 first, fall back to older configs
    local path
    for _, f in ipairs({CONFIG_FILE, CONFIG_FOLDER .. "/skins_v4.json", CONFIG_FOLDER .. "/skins_v3.json"}) do
        if isfile(f) then path = f; break end
    end
    if not path then return end
    pcall(function()
        local data = HttpService:JSONDecode(readfile(path))
        favorites = data.favorites or {}
        if data.equipped then
            for weapon, items in pairs(data.equipped) do
                equipped[weapon] = {}
                for slot, info in pairs(items) do
                    local item = createCosmeticItem(info.name, slot, { inverted = info.inverted })
                    if item then
                        item.Seed = info.seed
                        equipped[weapon][slot] = item
                    end
                end
            end
        end
    end)
end

-- ============================================================
-- OWNERSHIP SPOOFING
-- Hook ALL ownership-related methods on CosmeticLib and ItemLib.
-- ============================================================
CosmeticLib.OwnsCosmeticNormally = function() return true end
CosmeticLib.OwnsCosmeticUniversally = function() return true end
CosmeticLib.OwnsCosmeticForWeapon = function() return true end

local originalOwnsCosmetic = CosmeticLib.OwnsCosmetic
CosmeticLib.OwnsCosmetic = function(self, cosmetic, weapon, ...)
    if weapon and type(weapon) == "string" and weapon:find("MISSING_") then
        return originalOwnsCosmetic(self, cosmetic, weapon, ...)
    end
    return true
end

-- Dynamically hook any remaining ownership/availability methods on CosmeticLib and ItemLib
pcall(function()
    for k, v in pairs(CosmeticLib) do
        if type(v) == "function" and type(k) == "string" then
            local lk = k:lower()
            if (lk:find("owns") or lk:find("has") or lk:find("available") or lk:find("unlocked") or lk:find("purchased")) 
               and k ~= "OwnsCosmetic" then
                CosmeticLib[k] = function() return true end
            end
        end
    end
    for k, v in pairs(ItemLib) do
        if type(v) == "function" and type(k) == "string" then
            local lk = k:lower()
            if lk:find("owns") or lk:find("has") or lk:find("available") or lk:find("unlocked") or lk:find("purchased") then
                ItemLib[k] = function() return true end
            end
        end
    end
end)

-- ============================================================
-- PLAYERDATA HOOKS
-- ============================================================
local originalGet = PlayerData.Get
PlayerData.Get = function(self, key)
    local result = originalGet(self, key)

    if key == "FavoritedCosmetics" then
        local favs = result or {}
        for slot, ids in pairs(favorites) do
            favs[slot] = favs[slot] or {}
            for id, _ in pairs(ids) do
                favs[slot][id] = true
            end
        end
        return favs
    end

    if key == "CosmeticInventory" then
        return cosmeticInventoryProxy
    end

    return result
end

local originalGetWeaponData = PlayerData.GetWeaponData
PlayerData.GetWeaponData = function(self, weapon)
    local data = originalGetWeaponData(self, weapon)
    if data and equipped[weapon] then
        for slot, item in pairs(equipped[weapon]) do
            data[slot] = item
        end
    end
    return data
end

-- ============================================================
-- VIEWMODEL IMAGE OVERRIDE
-- ============================================================
local originalGetViewModelImage = ItemLib.GetViewModelImageFromWeaponData
ItemLib.GetViewModelImageFromWeaponData = function(self, weaponData, ...)
    if not weaponData then return originalGetViewModelImage(self, weaponData, ...) end
    local weaponName = weaponData.Name
    local useSkin = (weaponData.Skin and equipped[weaponName] and weaponData.Skin == equipped[weaponName].Skin) or
                    (viewedPlayer == LocalPlayer and equipped[weaponName] and equipped[weaponName].Skin)
    if useSkin and equipped[weaponName] and equipped[weaponName].Skin then
        local skin = self.ViewModels[equipped[weaponName].Skin.Name]
        if skin then return skin.ImageHighResolution or skin.Image end
    end
    return originalGetViewModelImage(self, weaponData, ...)
end

-- ============================================================
-- FIGHTERCONTROLLER (for finisher tracking)
-- ============================================================
local FighterController
task.spawn(function()
    task.wait(1)
    local fighterCtrl = Controllers:FindFirstChild("FighterController")
    if fighterCtrl then
        pcall(function() FighterController = require(fighterCtrl) end)
    end
end)

-- ============================================================
-- REMOTE HOOKS via hookmetamethod(__namecall)
-- PERF: checkcaller() + table lookup = minimal overhead on hot path.
-- 99.9% of calls hit the first two checks and return instantly.
-- ============================================================
task.spawn(function()
    task.wait(0.5)
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotes then return end

    local dataRemote = remotes:FindFirstChild("Data")
    local replication = remotes:FindFirstChild("Replication")
    local equipRemote = dataRemote and dataRemote:FindFirstChild("EquipCosmetic")
    local favoriteRemote = dataRemote and dataRemote:FindFirstChild("FavoriteCosmetic")
    local useItemRemote = replication and replication:FindFirstChild("Fighter")
        and replication.Fighter:FindFirstChild("UseItem")

    if not hookmetamethod then
        warn("[SafeSkin] hookmetamethod not available")
        return
    end

    -- Table-based dispatch: O(1) lookup instead of chained if-else
    local TARGET_METHODS = { FireServer = true, InvokeServer = true }
    local remoteHandlers = {}

    if equipRemote then
        remoteHandlers[equipRemote] = function(method, ...)
            local args = { ... }
            local weapon, slot, cosmetic = args[1], args[2], args[3]
            local options = args[4] or {}

            equipped[weapon] = equipped[weapon] or {}
            if not cosmetic or cosmetic == "None" or cosmetic == "" then
                equipped[weapon][slot] = nil
                if not next(equipped[weapon]) then equipped[weapon] = nil end
            else
                local item = createCosmeticItem(cosmetic, slot, {
                    inverted = options.IsInverted,
                    favoritesOnly = options.OnlyUseFavorites
                })
                if item then equipped[weapon][slot] = item end
            end

            task.spawn(function()
                task.wait(0.1)
                pcall(function() PlayerData.CurrentData:Replicate("WeaponInventory") end)
                saveConfig()
            end)

            if method == "InvokeServer" then return true end
            return
        end
    end

    if favoriteRemote then
        remoteHandlers[favoriteRemote] = function(method, ...)
            local args = { ... }
            favorites[args[1]] = favorites[args[1]] or {}
            favorites[args[1]][args[2]] = args[3] or nil
            saveConfig()
            if method == "InvokeServer" then return true end
            return
        end
    end

    local wrapClosure = newcclosure or newclosure or function(f) return f end
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", wrapClosure(function(self, ...)
        -- FAST PATH: skip calls from our own exploit environment
        if checkcaller and checkcaller() then
            return oldNamecall(self, ...)
        end

        -- FAST PATH: only care about FireServer/InvokeServer (1 table lookup)
        local method = getnamecallmethod()
        if not TARGET_METHODS[method] then
            return oldNamecall(self, ...)
        end

        -- Check if this remote has a handler (1 table lookup)
        local handler = remoteHandlers[self]
        if handler then
            return handler(method, ...)
        end

        -- UseItem — track finisher then pass through
        if self == useItemRemote and FighterController then
            local args = { ... }
            task.spawn(function()
                pcall(function()
                    local fighter = FighterController:GetFighter(LocalPlayer)
                    if fighter and fighter.Items then
                        for _, item in pairs(fighter.Items) do
                            if item:Get("ObjectID") == args[1] then
                                currentFinisherName = item.Name
                                break
                            end
                        end
                    end
                end)
            end)
        end

        return oldNamecall(self, ...)
    end))
end)

-- ============================================================
-- CLIENT VISUAL HOOKS
-- ============================================================

-- ClientItem._CreateViewModel (injects skin + wrap + charm)
task.spawn(function()
    task.wait(1)
    pcall(function()
        local clientItemModule = PlayerScripts.Modules.ClientReplicatedClasses.ClientFighter.ClientItem
        local ClientItem = require(clientItemModule)
        if ClientItem._CreateViewModel then
            local oldCreate = ClientItem._CreateViewModel
            ClientItem._CreateViewModel = function(self, data)
                local itemName = self.Name
                local player = self.ClientFighter and self.ClientFighter.Player
                currentItemName = (player == LocalPlayer and itemName) or nil

                if player == LocalPlayer and equipped[itemName] and data then
                    pcall(function()
                        local DataEnum = self:ToEnum("Data")
                        if data[DataEnum] then
                            local skinData = equipped[itemName]
                            if skinData.Skin then
                                data[DataEnum][self:ToEnum("Skin")] = skinData.Skin
                                data[DataEnum][self:ToEnum("Name")] = skinData.Skin.Name
                            end
                            if skinData.Wrap then
                                data[DataEnum][self:ToEnum("Wrap")] = skinData.Wrap
                            end
                            if skinData.Charm then
                                data[DataEnum][self:ToEnum("Charm")] = skinData.Charm
                            end
                        elseif data.Data then
                            local skinData = equipped[itemName]
                            if skinData.Skin then
                                data.Data.Skin = skinData.Skin
                                data.Data.Name = skinData.Skin.Name
                            end
                            if skinData.Wrap then data.Data.Wrap = skinData.Wrap end
                            if skinData.Charm then data.Data.Charm = skinData.Charm end
                        end
                    end)
                end

                local result = oldCreate(self, data)
                currentItemName = nil
                return result
            end
        end
    end)
end)

-- ClientItemWrap (injects wrap + charm)
task.spawn(function()
    task.wait(2)
    pcall(function()
        local wrapModule = PlayerScripts.Modules.ClientReplicatedClasses.ClientFighter.ClientItem:FindFirstChild("ClientItemWrap")
        if wrapModule then
            local Wrap = require(wrapModule)
            if Wrap.GetWrap then
                local oldGetWrap = Wrap.GetWrap
                Wrap.GetWrap = function(item)
                    local itemName = item.ClientItem and item.ClientItem.Name
                    local player = item.ClientItem and item.ClientItem.ClientFighter and item.ClientItem.ClientFighter.Player
                    if itemName and player == LocalPlayer and equipped[itemName] and equipped[itemName].Wrap then
                        return equipped[itemName].Wrap
                    end
                    return oldGetWrap(item)
                end
            end

            -- Cache ReplicatedClass enums ONCE (avoid re-requiring in hot path)
            local RepClass, DataE, SkinE, WrapE, CharmE
            pcall(function()
                RepClass = require(ReplicatedStorage.Modules.ReplicatedClass)
                DataE = RepClass:ToEnum("Data")
                SkinE = RepClass:ToEnum("Skin")
                WrapE = RepClass:ToEnum("Wrap")
                CharmE = RepClass:ToEnum("Charm")
            end)

            local oldNew = Wrap.new
            Wrap.new = function(data, item)
                local player = item.ClientFighter and item.ClientFighter.Player
                local itemName = currentItemName or item.Name

                if player == LocalPlayer and equipped[itemName] and DataE then
                    pcall(function()
                        data[DataE] = data[DataE] or {}
                        local skinData = equipped[itemName]
                        if skinData.Skin then data[DataE][SkinE] = skinData.Skin end
                        if skinData.Wrap then data[DataE][WrapE] = skinData.Wrap end
                        if skinData.Charm then data[DataE][CharmE] = skinData.Charm end
                    end)
                end

                local obj = oldNew(data, item)

                if player == LocalPlayer and equipped[itemName] and equipped[itemName].Wrap and obj._UpdateWrap then
                    task.spawn(function()
                        obj:_UpdateWrap()
                        task.wait(0.1)
                        if not obj._destroyed then obj:_UpdateWrap() end
                    end)
                end
                return obj
            end
        end
    end)
end)

-- ViewProfile.Fetch (track viewed player for image override)
task.spawn(function()
    task.wait(1)
    pcall(function()
        local ViewProfile = require(PlayerScripts.Modules.Pages.ViewProfile)
        if ViewProfile and ViewProfile.Fetch then
            local oldFetch = ViewProfile.Fetch
            ViewProfile.Fetch = function(self, player)
                viewedPlayer = player
                return oldFetch(self, player)
            end
        end
    end)
end)

-- ClientEntity.ReplicateFromServer (finisher injection)
task.spawn(function()
    task.wait(2)
    pcall(function()
        local ClientEntity = require(PlayerScripts.Modules.ClientReplicatedClasses.ClientEntity)
        if ClientEntity.ReplicateFromServer then
            local oldReplicate = ClientEntity.ReplicateFromServer
            ClientEntity.ReplicateFromServer = function(self, method, ...)
                if method == "FinisherEffect" then
                    local args = { ... }
                    local player = args[3]

                    if type(player) == "userdata" and EnumLib and EnumLib.FromEnum then
                        pcall(function() player = EnumLib:FromEnum(player) end)
                    end

                    if (tostring(player) == LocalPlayer.Name or tostring(player):lower() == LocalPlayer.Name:lower()) and
                       currentFinisherName and equipped[currentFinisherName] and equipped[currentFinisherName].Finisher then
                        local finisher = equipped[currentFinisherName].Finisher
                        local finisherEnum = finisher.Enum
                        if not finisherEnum and EnumLib then
                            pcall(function() finisherEnum = EnumLib:ToEnum(finisher.Name) end)
                        end
                        if finisherEnum then
                            args[1] = finisherEnum
                            return oldReplicate(self, method, unpack(args))
                        end
                    end
                end
                return oldReplicate(self, method, ...)
            end
        end
    end)
end)

-- Load saved config
loadConfig()

print("[GHP v6.4b] Loaded: Skinchanger ready")
