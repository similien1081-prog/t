local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

-- Initialize Packet
local Packet = require(ReplicatedStorage:WaitForChild("Packet"))

-- Initialize ActionRegistry
local ActionRegistry = require(ReplicatedStorage:WaitForChild("ActionRegistry"))

-- Load all action modules from a folder
-- Create a folder called "Actions" in ReplicatedStorage or ServerScriptService
local actionsFolder = ReplicatedStorage.ActionRegistry:FindFirstChild("Actions") 

if actionsFolder then
	ActionRegistry.Initialize(actionsFolder)
else
	warn("[Server] No Actions folder found! Create one in ReplicatedStorage or ServerScriptService")
end

-- Create packet with proper type definitions
local interactPacket = Packet(
	"Interact",
	Packet.Instance,  -- targetInstance parameter
	Packet.String    -- actionName parameter
)

local MAX_DISTANCE = 20 -- server-side safety distance

-- Memory management
local playerCooldowns = {} -- player -> {action -> lastTime}
local attributeCache = {} -- instance -> {attrs, time}
local CACHE_LIFETIME = 1

-- Get cached attributes
local function getCachedAttributes(instance)
	if not instance then return {} end

	local cached = attributeCache[instance]
	local now = tick()

	if cached and (now - cached.time) < CACHE_LIFETIME then
		return cached.attrs
	end

	local attrs = instance:GetAttributes()
	attributeCache[instance] = {attrs = attrs, time = now}
	return attrs
end

-- Helper functions
local function hasInteractionAttributes(instance)
	if not instance then return false end
	local attrs = getCachedAttributes(instance)
	return attrs.ActionText or attrs.ObjectText or attrs.Action1
end

local function findInteractionsRoot(instance)
	if not instance then return nil end
	local cur = instance
	local depth = 0
	while cur and cur.Parent and depth < 10 do
		if hasInteractionAttributes(cur) then
			return cur
		end
		cur = cur.Parent
		depth = depth + 1
	end
	return nil
end

-- SERVER-SIDE PERMISSION CHECK
local function canPlayerUse(player, root, actionName)
	if not root or not actionName then return false end

	-- First check if action has custom validation
	local actionData = ActionRegistry.GetActionData(actionName)
	if actionData and actionData.ValidatePermission then
		local success, result = pcall(actionData.ValidatePermission, player, root)
		if success and not result then
			return false -- Custom validation failed
		end
	end

	-- Find action index
	local attrs = getCachedAttributes(root)
	local actionIndex = nil
	local i = 1
	while i <= 20 do
		local action = attrs["Action" .. i]
		if not action then break end
		if action == actionName then
			actionIndex = i
			break
		end
		i = i + 1
	end

	if not actionIndex then return false end

	-- Check attribute-based restriction
	local restrictionAttr = "Action" .. actionIndex .. "_Restrict"
	local restriction = attrs[restrictionAttr]

	if not restriction then return true end

	local restrictType, value = restriction:match("^(%w+):(.+)$")
	if not restrictType then return true end

	if restrictType == "team" then
		local playerTeam = player.Team
		if not playerTeam then return false end
		return playerTeam.Name == value

	elseif restrictType == "player" then
		for playerName in value:gmatch("([^,]+)") do
			playerName = playerName:match("^%s*(.-)%s*$")
			if player.Name == playerName then
				return true
			end
		end
		return false

	elseif restrictType == "rank" then
		local groupId, minRank = value:match("^(%d+):(%d+)$")
		if groupId and minRank then
			local success, rank = pcall(function()
				return player:GetRankInGroup(tonumber(groupId))
			end)
			if success then
				return rank >= tonumber(minRank)
			end
		end
		return false
	end

	return false
end

-- Check if player can interact
local function canPlayerInteract(player)
	if not player then return false end

	if player:GetAttribute("Arrested") == true then return false end
	if player:GetAttribute("Cuffed") == true then return false end

	local playerTeam = player.Team
	if playerTeam and (playerTeam.Name == "Arrested" or playerTeam.Name == "Prisoner") then 
		return false 
	end

	local char = player.Character
	if not char then return false end

	local humanoid = char:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end

	return true
end

-- Check action cooldown (now uses action-specific cooldowns)
local function isActionOnCooldown(player, actionName)
	if not playerCooldowns[player] then
		playerCooldowns[player] = {}
	end

	local lastTime = playerCooldowns[player][actionName] or 0
	local now = tick()

	-- Get action-specific cooldown or use default
	local actionData = ActionRegistry.GetActionData(actionName)
	local cooldown = (actionData and actionData.Cooldown) or 0.5

	if now - lastTime < cooldown then
		return true
	end

	playerCooldowns[player][actionName] = now
	return false
end

-- Main packet handler
interactPacket.OnServerEvent:Connect(function(player, targetInstance, actionName)
	-- Input validation
	if not player then return end
	if type(targetInstance) ~= "userdata" or not targetInstance:IsDescendantOf(game) then 
		warn(("[SECURITY] Player %s sent invalid target instance"):format(player.Name))
		return 
	end
	if type(actionName) ~= "string" or #actionName > 100 or #actionName < 1 then 
		warn(("[SECURITY] Player %s sent invalid action name"):format(player.Name))
		return 
	end

	-- Check if player can interact
	if not canPlayerInteract(player) then
		return
	end

	-- Check action cooldown
	if isActionOnCooldown(player, actionName) then
		return
	end

	-- Find interaction root
	local root = findInteractionsRoot(targetInstance)
	if not root then return end

	-- Validate distance
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local targetPos
	if root:IsA("BasePart") then
		targetPos = root.Position
	elseif root:IsA("Model") then
		local primary = root.PrimaryPart or root:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			targetPos = primary.Position
		end
	end

	if not targetPos then return end

	local distance = (hrp.Position - targetPos).Magnitude
	if distance > MAX_DISTANCE then
		if distance > MAX_DISTANCE * 2 then
			warn(("[SECURITY] Player %s attempted interaction from suspicious distance: %.1f"):format(player.Name, distance))
		end
		return
	end

	-- Verify action exists in attributes
	local attrs = getCachedAttributes(root)
	local actionExists = false
	local actionIndex = 1

	while actionIndex <= 20 do
		local action = attrs["Action" .. actionIndex]
		if not action then break end
		if action == actionName then
			actionExists = true
			break
		end
		actionIndex = actionIndex + 1
	end

	if not actionExists then
		warn(("[SECURITY] Player %s attempted non-existent action: %s"):format(player.Name, actionName))
		return
	end

	-- Check if action is registered in ActionRegistry
	if not ActionRegistry.ActionExists(actionName) then
		warn(("[Server] Action '%s' exists in attributes but no handler is registered"):format(actionName))
		return
	end

	-- Permission check
	if not canPlayerUse(player, root, actionName) then
		return
	end

	-- Execute the action via ActionRegistry
	print(("[Server] %s performed action '%s' on %s"):format(player.Name, actionName, root.Name))
	ActionRegistry.ExecuteAction(actionName, player, root)
end)

-- MEMORY MANAGEMENT
Players.PlayerRemoving:Connect(function(player)
	playerCooldowns[player] = nil

	for instance, _ in pairs(attributeCache) do
		if instance:IsDescendantOf(player) then
			attributeCache[instance] = nil
		end
	end
end)

-- Periodic cache cleanup
task.spawn(function()
	while true do
		task.wait(60)
		local now = tick()
		local cleaned = 0

		for instance, data in pairs(attributeCache) do
			if not instance.Parent or (now - data.time) > CACHE_LIFETIME * 10 then
				attributeCache[instance] = nil
				cleaned = cleaned + 1
			end
		end

		if cleaned > 0 then
			print(("[Memory] Cleaned %d expired cache entries"):format(cleaned))
		end
	end
end)

-- Export registry for runtime registration if needed
_G.ActionRegistry = ActionRegistry
print(ActionRegistry)
