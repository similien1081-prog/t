-- ActionRegistry.lua
local ActionRegistry = {}
ActionRegistry.__index = ActionRegistry

local registeredActions = {}

-- Load all action modules from a folder
function ActionRegistry.Initialize(actionsFolder)
	if not actionsFolder or not actionsFolder:IsA("Folder") then
		warn("[ActionRegistry] Invalid actions folder provided")
		return
	end

	local loadedCount = 0
	local failedCount = 0

	for _, moduleScript in ipairs(actionsFolder:GetChildren()) do
		if moduleScript:IsA("ModuleScript") then
			local success, actionModule = pcall(require, moduleScript)

			if success and type(actionModule) == "table" then
				-- Validate action module structure
				if actionModule.ActionName and type(actionModule.ActionName) == "string" 
					and actionModule.Execute and type(actionModule.Execute) == "function" then

					registeredActions[actionModule.ActionName] = {
						Execute = actionModule.Execute,
						ValidatePermission = actionModule.ValidatePermission, -- Optional
						Cooldown = actionModule.Cooldown or 0.5, -- Default 500ms
						RequiresAlive = actionModule.RequiresAlive ~= false, -- Default true
						ModuleName = moduleScript.Name
					}

					loadedCount = loadedCount + 1
					print(("[ActionRegistry] Loaded: %s (%s)"):format(actionModule.ActionName, moduleScript.Name))
				else
					warn(("[ActionRegistry] Invalid structure in module: %s"):format(moduleScript.Name))
					failedCount = failedCount + 1
				end
			else
				warn(("[ActionRegistry] Failed to load module: %s - %s"):format(moduleScript.Name, tostring(actionModule)))
				failedCount = failedCount + 1
			end
		end
	end

	print(("[ActionRegistry] Initialization complete: %d loaded, %d failed"):format(loadedCount, failedCount))
end

-- Execute an action
function ActionRegistry.ExecuteAction(actionName, player, root)
	local action = registeredActions[actionName]

	if not action then
		warn(("[ActionRegistry] No handler found for action: %s"):format(actionName))
		return false
	end

	-- Execute in protected call
	local success, result = pcall(action.Execute, player, root)

	if not success then
		warn(("[ActionRegistry] Action '%s' failed: %s"):format(actionName, tostring(result)))
		return false
	end

	return true
end

-- Check if action exists
function ActionRegistry.ActionExists(actionName)
	return registeredActions[actionName] ~= nil
end

-- Get action metadata
function ActionRegistry.GetActionData(actionName)
	return registeredActions[actionName]
end

-- Register action at runtime (for dynamic actions)
function ActionRegistry.RegisterAction(actionName, actionData)
	if type(actionName) ~= "string" or type(actionData) ~= "table" then
		warn("[ActionRegistry] Invalid registration parameters")
		return false
	end

	if not actionData.Execute or type(actionData.Execute) ~= "function" then
		warn("[ActionRegistry] Action must have Execute function")
		return false
	end

	registeredActions[actionName] = {
		Execute = actionData.Execute,
		ValidatePermission = actionData.ValidatePermission,
		Cooldown = actionData.Cooldown or 0.5,
		RequiresAlive = actionData.RequiresAlive ~= false,
		ModuleName = "Runtime"
	}

	print(("[ActionRegistry] Registered runtime action: %s"):format(actionName))
	return true
end

-- Get all registered actions (for debugging)
function ActionRegistry.GetAllActions()
	local actions = {}
	for name, _ in pairs(registeredActions) do
		table.insert(actions, name)
	end
	return actions
end

return ActionRegistry
