local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Wait for Packet module and create packet with matching parameters
local Packet = require(ReplicatedStorage:WaitForChild("Packet"))

-- Create packet with same parameters as server (including rate limit config)
local interactPacket = Packet(
	"Interact",
	Packet.Instance,  -- targetInstance parameter
	Packet.String    -- actionName parameter
)

local INTERACT_TAG = "Interactable"
local MAX_RAY_DISTANCE = 7

-- DYNAMIC RAYCAST THROTTLING
local RAY_THROTTLE_MOVING = 0.035 -- ~28Hz when mouse is moving
local RAY_THROTTLE_IDLE = 0.1 -- 10Hz when mouse is idle
local MOUSE_IDLE_TIME = 0.5 -- Time before considering mouse idle
local lastMouseMoveTime = 0
local mousePosition = Vector2.new(0, 0)
local lastRayTime = 0

-- Use the existing GUI
local Screengui = player:WaitForChild("PlayerGui"):WaitForChild("MouseInteractUI")
local mainFrame = Screengui:WaitForChild("Main")
local actionText = mainFrame:WaitForChild("ActionText")
local objectText = mainFrame:WaitForChild("ObjectText")
local rowsFrame = mainFrame:WaitForChild("Rows")
local RowTemplate = rowsFrame:WaitForChild("RowTemplate")

-- Security: Hide the template from exploiters
RowTemplate.Visible = false
RowTemplate.Name = "RT_" .. game:GetService("HttpService"):GenerateGUID(false):sub(1, 8)

-- Pool for row management
local rowPool = {}
local activeRows = {}

local function getRow()
	if #rowPool > 0 then
		local r = table.remove(rowPool)
		r.Visible = true
		table.insert(activeRows, r)
		return r
	else
		local clone = RowTemplate:Clone()
		clone.Name = "Row_" .. #activeRows
		clone.Visible = true
		clone.Parent = nil
		table.insert(activeRows, clone)
		return clone
	end
end

local function recycleRow(row)
	row.Visible = false
	row.Parent = nil
	local index = table.find(activeRows, row)
	if index then
		table.remove(activeRows, index)
	end
	table.insert(rowPool, row)
end

local function recycleAllRows()
	for i = #activeRows, 1, -1 do
		recycleRow(activeRows[i])
	end
end

-- Raycast whitelist setup
local raycastParams = RaycastParams.new()
raycastParams.IgnoreWater = true
raycastParams.FilterType = Enum.RaycastFilterType.Whitelist
raycastParams.FilterDescendantsInstances = {}

local function rebuildWhitelist()
	local tagged = CollectionService:GetTagged(INTERACT_TAG)
	local parts = {}

	for _, inst in ipairs(tagged) do
		if inst:IsA("BasePart") then
			table.insert(parts, inst)
		elseif inst:IsA("Model") then
			for _, desc in ipairs(inst:GetDescendants()) do
				if desc:IsA("BasePart") then
					table.insert(parts, desc)
				end
			end
		end
	end

	if #parts == 0 then
		raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
		raycastParams.FilterDescendantsInstances = {}
	else
		raycastParams.FilterType = Enum.RaycastFilterType.Whitelist
		raycastParams.FilterDescendantsInstances = parts
	end
end

rebuildWhitelist()
CollectionService:GetInstanceAddedSignal(INTERACT_TAG):Connect(rebuildWhitelist)
CollectionService:GetInstanceRemovedSignal(INTERACT_TAG):Connect(rebuildWhitelist)

-- Find interaction root
local function hasInteractionAttributes(inst)
	if not inst then return false end
	local attrs = inst:GetAttributes()
	return attrs.ActionText or attrs.ObjectText or attrs.Action1
end

local function findInteractRoot(part)
	local cur = part
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

-- State management
local currentTarget = nil
local currentActions = {}
local lastHitInstance = nil
local lastTargetRoot = nil
local playerStatus = "normal"

-- Client-side rate limiting to prevent accidental spam
local lastFireTime = 0
local FIRE_COOLDOWN = 0.1 -- 100ms between fires

-- OPTIMIZED MOUSE TRACKING with movement detection
UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		mousePosition = UserInputService:GetMouseLocation()
		lastMouseMoveTime = tick() -- Track when mouse last moved
	end
end)

-- Monitor player status for UI feedback (simplified)
local function updatePlayerStatus()
	if player:GetAttribute("Cuffed") then
		playerStatus = "cuffed"
	else
		playerStatus = "normal"
	end
end

-- Update status periodically
task.spawn(function()
	while true do
		updatePlayerStatus()
		task.wait(0.5)
	end
end)

-- CLIENT-SIDE PERMISSION CHECK (mirrors server logic)
local function canPlayerUseAction(root, actionName, actionIndex)
	if not root or not actionName then return false end

	local restrictionAttr = "Action" .. actionIndex .. "_Restrict"
	local restriction = root:GetAttribute(restrictionAttr)

	if not restriction then return true end -- No restriction

	-- Parse restriction format
	local restrictType, value = restriction:match("^(%w+):(.+)$")
	if not restrictType then return true end

	if restrictType == "team" then
		local playerTeam = player.Team
		if not playerTeam then return false end
		return playerTeam.Name == value

	elseif restrictType == "player" then
		-- Support comma-separated player names
		for playerName in value:gmatch("([^,]+)") do
			playerName = playerName:match("^%s*(.-)%s*$") -- trim spaces
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

-- Build actions from attributes
local function buildActionsFromAttributes(root)
	if not root then return {} end
	local attrs = root:GetAttributes()
	local actions = {}
	local actionIndex = 1

	while actionIndex <= 20 do
		local action = attrs["Action" .. actionIndex]
		if not action then break end

		-- Check if player can use this specific action
		local canUse = canPlayerUseAction(root, action, actionIndex)

		local actionData = {
			Key = attrs["Action" .. actionIndex .. "_Key"] or "",
			Label = attrs["Action" .. actionIndex .. "_Label"] or action,
			Action = action,
			Index = actionIndex,
			Restricted = not canUse  -- Set based on actual permission check
		}

		table.insert(actions, actionData)
		actionIndex = actionIndex + 1
	end

	return actions
end

-- Update UI
local function showForTarget(root)
	if not root then
		mainFrame.Visible = false
		currentTarget = nil
		currentActions = {}
		recycleAllRows()
		return
	end

	currentTarget = root
	local attrs = root:GetAttributes()

	actionText.Text = attrs.ActionText or root.Name
	currentActions = buildActionsFromAttributes(root)

	-- Update object text based on player status (simplified to 2 states)
	if playerStatus == "cuffed" then
		objectText.Text = "Cuffed"
		objectText.TextColor3 = Color3.new(1, 0.4, 0.4)
		-- Hide all action rows when cuffed
		recycleAllRows()
	else
		-- Player can potentially interact
		if #currentActions == 0 then
			objectText.Text = ""
			objectText.TextColor3 = Color3.new(1, 1, 1)
			recycleAllRows()
		else
			-- Check if ALL actions are restricted
			local allRestricted = true
			local hasAnyActions = false
			for _, action in ipairs(currentActions) do
				hasAnyActions = true
				if not action.Restricted then
					allRestricted = false
					break
				end
			end

			if hasAnyActions and allRestricted then
				objectText.Text = "Access Restricted"
				objectText.TextColor3 = Color3.new(1, 0.7, 0.7)
				-- Don't show action rows if all are restricted
				recycleAllRows()
			else
				objectText.Text = attrs.ObjectText or ""
				objectText.TextColor3 = Color3.new(1, 1, 1)

				-- Clear and populate rows
				recycleAllRows()

				local rowIndex = 0
				for i, action in ipairs(currentActions) do
					if i > 10 then break end

					rowIndex = rowIndex + 1
					local row = getRow()
					row.Parent = rowsFrame
					row.Position = UDim2.new(0, 0, 0, (rowIndex-1) * 28)

					local keyBox = row:FindFirstChild("Key")
					local label = row:FindFirstChild("Label")

					if keyBox then 
						keyBox.Text = action.Key or ""
					end

					if label then 
						label.Text = action.Label or ""
						if action.Restricted then
							label.Text = label.Text .. " (Restricted)"
						end
					end
				end

				-- Adjust frame size based on visible rows
				local visibleRowsCount = rowIndex
				local newHeight = math.min(56 + visibleRowsCount * 28, 300)
				mainFrame.Size = UDim2.new(0, 360, 0, newHeight)
				rowsFrame.Size = UDim2.new(1, -12, 0, visibleRowsCount * 28)
			end
		end
	end

	mainFrame.Visible = true
end

-- Perform raycast logic
local function performRaycast()
	local x, y = mousePosition.X, mousePosition.Y
	if not x or not y then
		if lastTargetRoot then
			lastHitInstance = nil
			lastTargetRoot = nil
			showForTarget(nil)
		end
		return
	end

	-- Adjust for GUI inset
	local GuiService = game:GetService("GuiService")
	local inset = GuiService:GetGuiInset()
	local adjustedY = math.max(0, y - inset.Y)

	-- Cast ray
	local unitRay = camera:ScreenPointToRay(x, adjustedY)
	local rayResult = workspace:Raycast(
		unitRay.Origin, 
		unitRay.Direction * MAX_RAY_DISTANCE, 
		raycastParams
	)

	if rayResult and rayResult.Instance then
		if rayResult.Instance ~= lastHitInstance then
			lastHitInstance = rayResult.Instance
			local root = findInteractRoot(rayResult.Instance)

			if root ~= lastTargetRoot then
				lastTargetRoot = root
				showForTarget(root)
			end
		end
	else
		if lastTargetRoot then
			lastHitInstance = nil
			lastTargetRoot = nil
			showForTarget(nil)
		end
	end
end

-- OPTIMIZED RENDER LOOPS - Separated concerns
-- Use Heartbeat for raycast logic (physics-synced, lower priority than RenderStepped)
RunService.Heartbeat:Connect(function()
	local now = tick()

	-- DYNAMIC THROTTLING based on mouse movement
	local timeSinceMouseMove = now - lastMouseMoveTime
	local isMouseIdle = timeSinceMouseMove > MOUSE_IDLE_TIME
	local currentThrottle = isMouseIdle and RAY_THROTTLE_IDLE or RAY_THROTTLE_MOVING

	-- Check if enough time has passed based on dynamic throttle
	if now - lastRayTime < currentThrottle then
		return
	end
	lastRayTime = now

	-- Perform the raycast
	performRaycast()
end)

-- Use RenderStepped ONLY for UI positioning (visual updates)
RunService.RenderStepped:Connect(function()
	if mainFrame.Visible then
		mainFrame.Position = UDim2.new(0, mousePosition.X + 16, 0, mousePosition.Y + 16)
	end
end)

-- Input handling using Packet's Fire method
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if not currentTarget then return end
	-- Don't process inputs if player is cuffed
	if playerStatus == "cuffed" then return end

	if input.UserInputType == Enum.UserInputType.Keyboard then
		local key = input.KeyCode.Name

		for _, action in ipairs(currentActions) do
			-- Skip restricted actions
			if action.Restricted then continue end

			if action.Key and action.Key:upper() == key:upper() then
				-- Client-side rate limiting
				local now = tick()
				if now - lastFireTime < FIRE_COOLDOWN then
					return -- Too soon since last fire
				end
				lastFireTime = now

				-- Send to server using Packet's Fire method
				interactPacket:Fire(currentTarget, action.Action)

				-- Optional: Visual/audio feedback
				local sound = game.SoundService:FindFirstChild("Click")
				if sound and sound:IsA("Sound") then
					sound:Play()
				end

				break
			end
		end
	end
end)

-- MEMORY CLEANUP on character removal
player.CharacterRemoving:Connect(function()
	showForTarget(nil)
	lastHitInstance = nil
	lastTargetRoot = nil
	currentTarget = nil
	currentActions = {}
	playerStatus = "no_character"

	-- Clear row pool to prevent memory leaks
	recycleAllRows()
	for i = #rowPool, 1, -1 do
		local row = rowPool[i]
		if row then
			row:Destroy()
		end
	end
	rowPool = {}
end)

-- Additional cleanup when player's character is added back
player.CharacterAdded:Connect(function()
	playerStatus = "normal"
	-- Rebuild whitelist in case new interactables were added
	task.wait(0.5) -- Wait for character to load
	rebuildWhitelist()
end)
