--[[
	Reborn Zero - build 0.1
	Features: Tween engine (TweenService / Lerp) + Auto Farm (Quest / Quest + Nearest / Nearest)
	UI: Rayfield (official source by default, see RAYFIELD_URL)

	Written from scratch. Anything marked [ASSUMPTION] depends on Blox Fruits internals
	that could not be verified offline. Use  Debug > "Dump game data"  in-game and send
	the console output (F9) back so the assumptions can be checked or fixed.
]]

local RAYFIELD_URL = "https://sirius.menu/rayfield" -- swap for a reviewed copy in your own repo if you prefer
local BLOX_FRUITS_GAME_ID = 994732206

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local env = (getgenv and getgenv()) or _G
if env.RebornZero and type(env.RebornZero.Stop) == "function" then
	pcall(env.RebornZero.Stop) -- clean re-execute: stop the previous instance first
end

if game.GameId ~= BLOX_FRUITS_GAME_ID then
	warn("[Reborn Zero] This script only supports Blox Fruits.")
	return
end

----------------------------------------------------------------------
-- Services / core references
----------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local VirtualUser = game:GetService("VirtualUser")

local LP = Players.LocalPlayer
local PlayerData = LP:WaitForChild("Data", 15)
local LevelValue = PlayerData and PlayerData:WaitForChild("Level", 15)
local Enemies = Workspace:WaitForChild("Enemies", 15)
if not LevelValue or not Enemies then
	warn("[Reborn Zero] Player data or Workspace.Enemies not found; aborting.")
	return
end

local function log(...)
	print("[Reborn Zero]", ...)
end

local okLib, Rayfield = pcall(function()
	return loadstring(game:HttpGet(RAYFIELD_URL))()
end)
if not okLib or type(Rayfield) ~= "table" then
	warn("[Reborn Zero] Could not load Rayfield:", tostring(Rayfield))
	return
end

local function notify(title, content, duration)
	pcall(function()
		Rayfield:Notify({ Title = title, Content = content, Duration = duration or 4 })
	end)
end

local Config = {
	AutoFarm = false,
	FarmMode = "Quest + Nearest", -- "Quest" | "Quest + Nearest" | "Nearest"
	WeaponType = "Melee", -- matches Tool.ToolTip [ASSUMPTION]: Melee | Sword | Blox Fruit | Gun
	TweenMethod = "TweenService", -- "TweenService" | "Lerp"
	TweenSpeed = 300, -- studs per second
	FarmHeight = 12, -- studs above the mob
	NearbyRadius = 80, -- "Quest + Nearest": fight other mobs inside this radius while quest mobs respawn
}

local State = { Quest = nil, QuestLevel = nil, LastQuestTry = 0, LastClick = 0, Warned = {} }

local function warnOnce(key, message)
	if not State.Warned[key] then
		State.Warned[key] = true
		warn("[Reborn Zero] " .. message)
		notify("Reborn Zero", message, 6)
	end
end

-- Always read the character fresh so a respawn can never leave a stale reference.
local function getRoot()
	local char = LP.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local char = LP.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

----------------------------------------------------------------------
-- Tween engine
----------------------------------------------------------------------
local Tween = { Token = 0, Active = nil }

function Tween.Cancel()
	Tween.Token = Tween.Token + 1
	if Tween.Active then
		pcall(function()
			Tween.Active:Cancel()
		end)
		Tween.Active = nil
	end
end

-- Moves the root part to `target` at a constant speed. Blocks until it arrives or is cancelled.
-- Returns true only if it arrived.
function Tween.To(target, speed)
	local root = getRoot()
	if not root then
		return false
	end

	Tween.Cancel()
	local token = Tween.Token
	speed = math.max(tonumber(speed or Config.TweenSpeed) or 300, 1)

	local distance = (root.Position - target.Position).Magnitude
	if distance < 1 then
		root.CFrame = target
		return true
	end
	local duration = distance / speed

	if Config.TweenMethod == "Lerp" then
		local start = root.CFrame
		local elapsed = 0
		while elapsed < duration do
			if token ~= Tween.Token then
				return false
			end
			local r = getRoot()
			if not r then
				return false
			end
			elapsed = elapsed + RunService.Heartbeat:Wait()
			r.CFrame = start:Lerp(target, math.min(elapsed / duration, 1))
		end
		return token == Tween.Token
	end

	-- TweenService
	local tween = TweenService:Create(root, TweenInfo.new(duration, Enum.EasingStyle.Linear), { CFrame = target })
	Tween.Active = tween
	tween:Play()
	local state = tween.Completed:Wait()
	if Tween.Active == tween then
		Tween.Active = nil
	end
	return state == Enum.PlaybackState.Completed and token == Tween.Token
end

-- Cancels gravity while farming so the character does not drop out of the sky between tweens.
local function setHold(on)
	local root = getRoot()
	if not root then
		return
	end
	local hold = root:FindFirstChild("RZ_Hold")
	if on and not hold then
		hold = Instance.new("BodyVelocity")
		hold.Name = "RZ_Hold"
		hold.MaxForce = Vector3.new(1e9, 1e9, 1e9)
		hold.Velocity = Vector3.new(0, 0, 0)
		hold.Parent = root
	elseif not on and hold then
		hold:Destroy()
	end
end

local noclipConn
local function setNoclip(on)
	if on and not noclipConn then
		noclipConn = RunService.Stepped:Connect(function()
			local char = LP.Character
			if not char then
				return
			end
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end)
	elseif not on and noclipConn then
		noclipConn:Disconnect()
		noclipConn = nil
	end
end

----------------------------------------------------------------------
-- Quest data  [ASSUMPTION] ReplicatedStorage.Quests is a ModuleScript shaped like
--   { QuestName = { [index] = { LevelReq = number, Task = { MobName = count } } } }
----------------------------------------------------------------------
local function seaLevelRange()
	local sea = Workspace:GetAttribute("MAP") -- [ASSUMPTION] "Sea1" | "Sea2" | "Sea3"
	if sea == "Sea1" then
		return 0, 699
	elseif sea == "Sea2" then
		return 700, 1499
	elseif sea == "Sea3" then
		return 1500, math.huge
	end
	return 0, math.huge
end

local function getQuest()
	local level = LevelValue.Value
	if State.QuestLevel == level then
		return State.Quest
	end
	State.QuestLevel = level
	State.Quest = nil

	local module = ReplicatedStorage:FindFirstChild("Quests")
	if not (module and module:IsA("ModuleScript")) then
		warnOnce("noquests", "ReplicatedStorage.Quests not found - run Debug > Dump game data.")
		return nil
	end
	local ok, data = pcall(require, module)
	if not ok or type(data) ~= "table" then
		warnOnce("badquests", "Could not read the Quests module - run Debug > Dump game data.")
		return nil
	end

	local lo, hi = seaLevelRange()
	local best
	for questName, tiers in pairs(data) do
		if type(tiers) == "table" then
			for index, q in pairs(tiers) do
				if type(q) == "table" and type(q.LevelReq) == "number" and type(q.Task) == "table" then
					local total = 0
					for _, count in pairs(q.Task) do
						if type(count) == "number" then
							total = total + count
						end
					end
					-- total >= 2 skips single-target boss quests
					if total >= 2 and q.LevelReq <= level and q.LevelReq >= lo and q.LevelReq <= hi then
						local better = not best
							or q.LevelReq > best.LevelReq
							or (q.LevelReq == best.LevelReq and tostring(questName) < tostring(best.Name))
						if better then
							best = { Name = questName, Index = index, LevelReq = q.LevelReq, Task = q.Task }
						end
					end
				end
			end
		end
	end

	State.Quest = best
	if best then
		log("Quest for level " .. level .. ":", tostring(best.Name), best.Index)
	end
	return best
end

local function taskNames(quest)
	local names = {}
	for mobName in pairs(quest.Task) do
		names[#names + 1] = tostring(mobName)
	end
	return names
end

local function matchesName(name, names)
	for _, key in ipairs(names) do
		if string.find(name, key, 1, true) then
			return true
		end
	end
	return false
end

-- [ASSUMPTION] the quest can be started from anywhere through CommF_ ("quest bypass"), no NPC travel.
local function startQuest(quest)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local commF = remotes and remotes:FindFirstChild("CommF_")
	if not commF then
		warnOnce("nocommf", "Remotes.CommF_ not found - run Debug > Dump game data.")
		return false
	end
	local ok, err = pcall(function()
		return commF:InvokeServer("StartQuest", quest.Name, quest.Index)
	end)
	if not ok then
		warn("[Reborn Zero] StartQuest failed:", tostring(err))
	end
	return ok
end

-- [ASSUMPTION] the quest panel is PlayerGui.Main.Quest and is only visible while a quest is active.
local function hasQuest()
	local gui = LP:FindFirstChild("PlayerGui")
	local main = gui and gui:FindFirstChild("Main")
	local panel = main and main:FindFirstChild("Quest")
	return panel ~= nil and panel.Visible == true
end

----------------------------------------------------------------------
-- Mobs
----------------------------------------------------------------------
local function isAlive(mob)
	local hum = mob:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0 and mob:FindFirstChild("HumanoidRootPart") ~= nil
end

-- names == nil means any mob.
local function nearestMob(names, maxDistance)
	local root = getRoot()
	if not root then
		return nil
	end
	local best, bestDistance = nil, maxDistance or math.huge
	for _, mob in ipairs(Enemies:GetChildren()) do
		if mob:IsA("Model") and isAlive(mob) and (not names or matchesName(mob.Name, names)) then
			local d = (mob.HumanoidRootPart.Position - root.Position).Magnitude
			if d < bestDistance then
				best, bestDistance = mob, d
			end
		end
	end
	return best
end

-- [ASSUMPTION] Workspace._WorldOrigin.EnemySpawns holds spawn parts whose names contain the mob name.
local function findSpawn(names)
	local origin = Workspace:FindFirstChild("_WorldOrigin")
	local folder = origin and origin:FindFirstChild("EnemySpawns")
	local root = getRoot()
	if not folder or not root then
		return nil
	end
	local best, bestDistance
	for _, spawnPart in ipairs(folder:GetChildren()) do
		if spawnPart:IsA("BasePart") and matchesName(spawnPart.Name, names) then
			local d = (spawnPart.Position - root.Position).Magnitude
			if not bestDistance or d < bestDistance then
				best, bestDistance = spawnPart, d
			end
		end
	end
	return best and best.CFrame
end

----------------------------------------------------------------------
-- Combat
----------------------------------------------------------------------
local function equipWeapon()
	local char = LP.Character
	local hum = getHumanoid()
	if not char or not hum then
		return
	end
	local held = char:FindFirstChildOfClass("Tool")
	if held and held.ToolTip == Config.WeaponType then
		return
	end
	local backpack = LP:FindFirstChild("Backpack")
	if not backpack then
		return
	end
	for _, tool in ipairs(backpack:GetChildren()) do
		if tool:IsA("Tool") and tool.ToolTip == Config.WeaponType then
			pcall(function()
				hum:EquipTool(tool)
			end)
			return
		end
	end
end

local function attack()
	local now = os.clock()
	if now - State.LastClick < 0.12 then
		return
	end
	State.LastClick = now
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton1(Vector2.new(1280, 672))
	end)
end

----------------------------------------------------------------------
-- Auto farm
----------------------------------------------------------------------
local function farmStep()
	local root, hum = getRoot(), getHumanoid()
	if not root or not hum or hum.Health <= 0 then
		task.wait(0.5)
		return
	end

	setHold(true)
	equipWeapon()

	local mode = Config.FarmMode
	local quest, names
	if mode ~= "Nearest" then
		quest = getQuest()
		if not quest then
			task.wait(1)
			return
		end
		names = taskNames(quest)
		if not hasQuest() and os.clock() - State.LastQuestTry > 2 then
			State.LastQuestTry = os.clock()
			startQuest(quest)
		end
	end

	local target
	if mode == "Nearest" then
		target = nearestMob(nil)
	else
		target = nearestMob(names)
		if not target and mode == "Quest + Nearest" then
			-- quest mobs are dead or not loaded: keep fighting what is close while they respawn
			target = nearestMob(nil, Config.NearbyRadius)
		end
	end

	if not target then
		-- nothing to fight: travel to where the quest mobs spawn
		local spawnCF = names and findSpawn(names)
		if spawnCF then
			Tween.To(spawnCF + Vector3.new(0, Config.FarmHeight, 0))
		else
			if names then
				warnOnce("nospawn", "No quest mob or spawn found - run Debug > Dump game data.")
			end
			task.wait(0.5)
		end
		return
	end

	local mobPos = target.HumanoidRootPart.Position
	local hover = CFrame.new(mobPos + Vector3.new(0, Config.FarmHeight, 0)) * CFrame.Angles(math.rad(-90), 0, 0)
	if (root.Position - hover.Position).Magnitude > 30 then
		Tween.To(hover) -- far away: travel
	else
		Tween.Cancel() -- close: stay locked above the mob and attack
		root.CFrame = hover
		attack()
	end
end

local runId = 0

local function stopFarm()
	Config.AutoFarm = false
	runId = runId + 1
	Tween.Cancel()
	setHold(false)
	setNoclip(false)
end

local function startFarm()
	stopFarm()
	Config.AutoFarm = true
	local myRun = runId
	setNoclip(true)
	task.spawn(function()
		while Config.AutoFarm and myRun == runId do
			local ok, err = pcall(farmStep)
			if not ok then
				warn("[Reborn Zero] farm error:", tostring(err))
				task.wait(1)
			end
			task.wait()
		end
	end)
end

----------------------------------------------------------------------
-- Debug dump (use this to verify the [ASSUMPTION]s in the real game)
----------------------------------------------------------------------
local function dump()
	log("---------------- dump ----------------")
	log("Level:", LevelValue.Value, "| MAP attribute:", tostring(Workspace:GetAttribute("MAP")))

	local module = ReplicatedStorage:FindFirstChild("Quests")
	log("ReplicatedStorage.Quests:", module and module.ClassName or "NOT FOUND")
	if module and module:IsA("ModuleScript") then
		local ok, data = pcall(require, module)
		if ok and type(data) == "table" then
			local shown = 0
			for name, tiers in pairs(data) do
				if shown >= 6 then
					break
				end
				shown = shown + 1
				local first = type(tiers) == "table" and (tiers[1] or select(2, next(tiers)))
				if type(first) == "table" then
					local parts = {}
					for k, v in pairs(first) do
						parts[#parts + 1] = tostring(k) .. "=" .. (type(v) == "table" and "{table}" or tostring(v))
					end
					log("quest", tostring(name), table.concat(parts, ", "))
					if type(first.Task) == "table" then
						for mob, count in pairs(first.Task) do
							log("   task:", tostring(mob), tostring(count))
						end
					end
				else
					log("quest", tostring(name), typeof(tiers))
				end
			end
		else
			log("require(Quests) failed:", tostring(data))
		end
	end

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	log("Remotes.CommF_:", (remotes and remotes:FindFirstChild("CommF_")) and "found" or "NOT FOUND")

	local origin = Workspace:FindFirstChild("_WorldOrigin")
	local spawns = origin and origin:FindFirstChild("EnemySpawns")
	if spawns then
		local names = {}
		for i, s in ipairs(spawns:GetChildren()) do
			if i > 8 then
				break
			end
			names[#names + 1] = s.Name
		end
		log("EnemySpawns (first 8):", table.concat(names, " | "))
	else
		log("Workspace._WorldOrigin.EnemySpawns: NOT FOUND")
	end

	local mobNames = {}
	for i, m in ipairs(Enemies:GetChildren()) do
		if i > 8 then
			break
		end
		mobNames[#mobNames + 1] = m.Name
	end
	log("Enemies (first 8):", table.concat(mobNames, " | "))

	local main = LP.PlayerGui:FindFirstChild("Main")
	local panel = main and main:FindFirstChild("Quest")
	log("PlayerGui.Main.Quest:", panel and ("found, Visible=" .. tostring(panel.Visible)) or "NOT FOUND")

	local tools = {}
	for _, container in ipairs({ LP:FindFirstChild("Backpack"), LP.Character }) do
		if container then
			for _, t in ipairs(container:GetChildren()) do
				if t:IsA("Tool") then
					tools[#tools + 1] = t.Name .. " (ToolTip=" .. tostring(t.ToolTip) .. ")"
				end
			end
		end
	end
	log("Tools:", table.concat(tools, " | "))
	log("---------------- end dump ----------------")
	notify("Reborn Zero", "Dump printed to the console (F9). Send it back to check the assumptions.", 6)
end

----------------------------------------------------------------------
-- UI (Rayfield)
----------------------------------------------------------------------
local function firstOption(value)
	if type(value) == "table" then
		return value[1]
	end
	return value
end

local Window = Rayfield:CreateWindow({
	Name = "Reborn Zero",
	LoadingTitle = "Reborn Zero",
	LoadingSubtitle = "build 0.1",
	ConfigurationSaving = { Enabled = true, FolderName = "RebornZero", FileName = "Config" },
	KeySystem = false,
})

local FarmTab = Window:CreateTab("Farm", 4483362458)
FarmTab:CreateSection("Auto Farm")

-- No Flag on this toggle on purpose: a saved config must never start farming by itself.
FarmTab:CreateToggle({
	Name = "Auto Farm",
	CurrentValue = false,
	Callback = function(value)
		if value then
			startFarm()
		else
			stopFarm()
		end
	end,
})

FarmTab:CreateDropdown({
	Name = "Farm Mode",
	Options = { "Quest", "Quest + Nearest", "Nearest" },
	CurrentOption = { Config.FarmMode },
	MultipleOptions = false,
	Flag = "RZ_FarmMode",
	Callback = function(option)
		Config.FarmMode = firstOption(option) or Config.FarmMode
	end,
})

FarmTab:CreateDropdown({
	Name = "Weapon Type",
	Options = { "Melee", "Sword", "Blox Fruit", "Gun" },
	CurrentOption = { Config.WeaponType },
	MultipleOptions = false,
	Flag = "RZ_WeaponType",
	Callback = function(option)
		Config.WeaponType = firstOption(option) or Config.WeaponType
	end,
})

FarmTab:CreateSlider({
	Name = "Height Above Mob",
	Range = { 5, 30 },
	Increment = 1,
	Suffix = " studs",
	CurrentValue = Config.FarmHeight,
	Flag = "RZ_FarmHeight",
	Callback = function(value)
		Config.FarmHeight = value
	end,
})

local MoveTab = Window:CreateTab("Movement", 4483362458)
MoveTab:CreateSection("Tween")

MoveTab:CreateDropdown({
	Name = "Tween Method",
	Options = { "TweenService", "Lerp" },
	CurrentOption = { Config.TweenMethod },
	MultipleOptions = false,
	Flag = "RZ_TweenMethod",
	Callback = function(option)
		Config.TweenMethod = firstOption(option) or Config.TweenMethod
	end,
})

MoveTab:CreateSlider({
	Name = "Tween Speed",
	Range = { 100, 500 },
	Increment = 10,
	Suffix = " studs/s",
	CurrentValue = Config.TweenSpeed,
	Flag = "RZ_TweenSpeed",
	Callback = function(value)
		Config.TweenSpeed = value
	end,
})

MoveTab:CreateButton({
	Name = "Test Tween (60 studs forward)",
	Callback = function()
		local root = getRoot()
		if not root then
			return
		end
		task.spawn(function()
			local arrived = Tween.To(root.CFrame * CFrame.new(0, 0, -60))
			notify("Tween test", Config.TweenMethod .. (arrived and ": arrived" or ": cancelled"), 3)
		end)
	end,
})

local DebugTab = Window:CreateTab("Debug", 4483362458)
DebugTab:CreateButton({
	Name = "Dump game data",
	Callback = dump,
})

env.RebornZero = {
	Stop = function()
		stopFarm()
		pcall(function()
			Rayfield:Destroy()
		end)
	end,
}

pcall(function()
	Rayfield:LoadConfiguration()
end)

log("Loaded build 0.1")
