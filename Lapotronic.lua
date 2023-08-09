-- Power Monitor script for GregTech batteries
-- Author: CAHCAHbl4
-- Idea: aka_zaratustra
-- Fixed: Quetz4l
-- Modified: Semash
-- Version: 1.6.0
-- License: MIT

-- The script supports plenty of GT energy storage in any combination.
-- https://i.imgur.com/qnzr4OT.gif

-- Setup: place OpenComputers Adapter next to Battery Buffer or multiblock controller
--        and connect to the computer with cables.

local displayMods = {
	Cycle = 1, -- Cycle betweem values on a single screen.
	Grid = 2, -- Show batteries in grid.
	Summary = 3 -- Display only summary information of all batteries.
}

local settings = {
	screenRefreshInterval = 0.2, -- In seconds. Supports values down to 0.05.
	batteryPollInterval = 1, -- In seconds. Doesn't make sense to set lower than 1.
	listSize = 20, -- The size of the historical data. 20 * 1(batteryPollInterval) = 20 seconds of history.
	useMedian = false, -- If enabled script will use median instead of average to calculate In/Out.
	displayMode = displayMods.Grid, -- See mods description.
	toggleInterval = 5, -- Interval in seconds to toggle between batteries in Cycle mode. Supports only integer values.
	debug = false -- Enable Debug mode
}

local batteryNames = {
	["cee19723-4a5e-4003-bf64-cb10ec2bb4ee"] = "LSC" -- Here you can provide names of your batteries by their addresses. Address can be full guid or first few symbols.
}

local palette = {
	w = 0xFFFFFF, -- white
	bk = 0x000000, -- black
	r = 0xCC0000, -- red
	g = 0x009200, -- green
	b = 0x0000C0, -- blue
	y = 0xFFDB00 -- yellow
}

local template = {
	columnCount = 3, -- Number of columns to display in Grid mode
	space = 1, -- Spacing in Grid mode
	width = 32,
	background = palette.bk,
	foreground = palette.w,
	chargebar = {
		levels = {
			green = {start = 80, color = palette.g},
			yellow = {start = 40, color = palette.y},
			red = {start = 0, color = palette.r}
		},
		background = palette.b,
		symbol = palette.w,
		arrows = 5
	},
	lines = {
		"$name$: $percent:s,%.2f$%  $stored:si,EU$",
		"In: &g;$input:si,EU/t$&w; Out: &r;$output:si,EU/t$",
		"          ?charge>=0|&g;|&r;?$charge:si,EU/t$",
		"#chargebar#",
		"?percent>=99.9|         &g;Fully charged|?" ..
			"?percent==0|     &r;Completely discharged|?" ..
				"?(percent<99.9 and charge>0)|Time to full:  &g;$left:t,2$|?" ..
					"?(percent<99.9 and charge<0)|Time to empty:  &r;$left:t,2$|?" ..
						"?(percent<99.9 and charge==0)|             Idle|?"
	}
}

-- Template description
-- $<value>:<formatter,arg1,arg2,...>$ - Render value using formatter. Formatter can be ommited.
--                                       Default formater is string.
--
-- Available values:
-- * name - Name of the battery.
-- * currentNum - Current battery number.
-- * totalNum - Total number of batteries.
-- * stored - Amount of total EU stored.
-- * capacity - Amount of maximum EU can be stored.
-- * percent - Current level of EU stored.
-- * input - Current total input in EU/t.
-- * output - Current total ouptut in EU/t.
-- * charge - Absolute value of current charge rate in EU/t.
--
-- Available formatters:
-- * s - String formatter. Arguments - [format:string]
-- * si - SI (System International) formatter. Arguments - [unit:string], [format:string]
-- * t - Time span formatter. Arguments - [parts:number]
--
-- &<color:palette or RGB>; - Change foreground color.
-- &&<color:palette or RGB>; - Change background color.
-- ?<condition>|<true>|<false>? - Evaluate condition and insert value based on that.

-----------------------------------------------------------
local event = require("event")
local computer = require("computer")
local component = require("component")
local thread = require("thread")
local gpu = component.gpu

function split(string, delimiter)
	local splitted = {}
	for match in string:gmatch("([^" .. delimiter .. "]+)") do
		table.insert(splitted, match)
	end
	return splitted
end

----------------------------------------------------------------------
local formatters = {
	s = function(value, format)
		format = (format and format or "%.2f")

		return string.format(format, value)
	end,
	si = function(value, unit, format)
		format = (format and format or "%.2f")
		local incPrefixes = {"k", "M", "G", "T", "P", "E", "Z", "Y"}
		local decPrefixes = {"m", "μ", "n", "p", "f", "a", "z", "y"}

		local prefix = ""
		local scaled = value

		if value ~= 0 then
			local degree = math.floor(math.log(math.abs(value), 10) / 3)
			scaled = value * 1000 ^ -degree
			if degree > 0 then
				prefix = incPrefixes[degree]
			elseif degree < 0 then
				prefix = decPrefixes[-degree]
			end
		end

		return string.format(format, scaled) .. " " .. prefix .. (unit and unit or "")
	end,
	t = function(secs, parts)
		parts = (parts and parts or 4)

		local units = {"d", "hr", "min", "sec"}
		local result = {}
		for i, v in ipairs({86400, 3600, 60}) do
			if secs >= v then
				result[i] = math.floor(secs / v)
				secs = secs % v
			end
		end
		result[4] = secs

		local resultString = ""
		local i = 1
		while parts ~= 0 and i ~= 5 do
			if result[i] and result[i] > 0 then
				if i > 1 then
					resultString = resultString .. " "
				end
				resultString = resultString .. result[i] .. " " .. units[i]
				parts = parts - 1
			end
			i = i + 1
		end
		return resultString
	end
}

----------------------------------------------------------------------
local widgets = {
	chargebar = function(template)
		local state = {}
		state.template = template
		state.center = math.ceil(template.width / 2)
		state.tick = 1

		local getChar = function(charge, tick, i)
			local char, start, charging
			if charge > 0 then
				start = state.center - math.ceil(template.chargebar.arrows / 2)
				char = ">"
				charging = true
			elseif charge < 0 then
				start = state.center + math.ceil(template.chargebar.arrows / 2)
				char = "<"
				charging = false
			else
				return " "
			end

			if not charging and (i >= start - tick) and (i < start) then
				return char
			elseif charging and (i <= start + tick) and (i > start) then
				return char
			end
			return " "
		end

		local getAlertLevel = function(percent)
			local currentLevel, lastStart = nil, 0

			for level, config in pairs(template.chargebar.levels) do
				if not currentLevel then
					currentLevel = level
				end

				if config.start >= lastStart and percent >= config.start then
					currentLevel = level
					lastStart = config.start
				end
			end

			return currentLevel
		end

		return function(values)
			local level = math.ceil(template.width * (values.percent / 100))
			local maxDepth = gpu.maxDepth()

			local result
			local alertLevel = getAlertLevel(values.percent)

			if maxDepth == 1 then
				result = "&&0xFFFFFF;&0x000000;"
			else
				result = "&" .. template.chargebar.symbol .. ";&&" .. template.chargebar.levels[alertLevel].color .. ";"
			end

			for i = 1, template.width do
				if i > level then
					if maxDepth == 1 then
						result = result .. "&&0x000000;&0xFFFFFF;"
					else
						result = result .. "&&" .. template.chargebar.background .. ";"
					end
				end
				result = result .. getChar(values.charge, state.tick, i)
			end

			if state.tick == template.chargebar.arrows then
				state.tick = 1
			else
				state.tick = state.tick + 1
			end

			return result
		end
	end
}

----------------------------------------------------------------------
List = {}
function List.new(size)
	local obj = {}
	local list = {}
	local count = 0

	function obj.push(value)
		if count == 0 then
			list[1] = value
			count = count + 1
		elseif #list < size then
			list[#list + 1] = value
			count = count + 1
		else
			for i = 1, #list do
				if i < size then
					list[i] = list[i + 1]
				else
					list[i] = value
				end
			end
		end
	end

	function obj.average()
		if count == 0 then
			return 0
		end

		local result = 0
		for _, v in ipairs(list) do
			if type(v) == "number" then
				result = result + v
			end
		end
		return result / count
	end

	function obj.median()
		if count == 0 then
			return 0
		end

		local temp = {}

		for _, v in ipairs(list) do
			if type(v) == "number" then
				table.insert(temp, v)
			end
		end

		table.sort(temp)

		if math.fmod(#temp, 2) == 0 then
			return (temp[#temp / 2] + temp[(#temp / 2) + 1]) / 2
		else
			return temp[math.ceil(#temp / 2)]
		end
	end

	return obj
end

----------------------------------------------------------------------
SensorProxyDecorator = {}
function SensorProxyDecorator.new(proxy)
	function proxy.getSensorValue(c)
		local info = proxy.getSensorInformation()
		local line = info[c.line]
		local match = line:match(c.pattern)
		local cleaned = match:gsub("%D", "")
		local result = tonumber(cleaned)
		return result
	end

	return proxy
end

----------------------------------------------------------------------
GenericGTBlock = {}
function GenericGTBlock.new(proxy, name)
	local obj = {}

	obj.name = name or "Unknown"
	obj.proxy = proxy
	obj.inputHistory = List.new(settings.listSize)
	obj.outputHistory = List.new(settings.listSize)

	function obj.runMonitoring()
		while true do
			obj.inputHistory.push(obj.proxy.getEUInputAverage())
			obj.outputHistory.push(obj.proxy.getEUOutputAverage())
			os.sleep(settings.batteryPollInterval)
		end
	end

	function obj.getStored()
		return obj.proxy.getEUStored()
	end

	function obj.getCapacity()
		return obj.proxy.getEUMaxStored()
	end

	function obj.getInput()
		if settings.useMedian then
			return obj.inputHistory.median()
		else
			return obj.inputHistory.average()
		end
	end

	function obj.getOutput()
		if settings.useMedian then
			return obj.outputHistory.median()
		else
			return obj.outputHistory.average()
		end
	end

	return obj
end
----------------------------------------------------------------------
Lapotronic = {}
function Lapotronic.new(proxy, name)
	local obj = GenericGTBlock.new(proxy, name)

	local config = {
		-- "§a1 199 934§r EU / §e1 232 768§r EU"
		STORED = {line = 2, pattern = "§.(.+)§.+/.+$"},
		CAPACITY = {line = 3, pattern = "^.+/.+§.(.+)§.+$"},
		-- "32 768 EU/t"
		INPUT = {line = 7, pattern = "^(.+)%sEU/t$"},
		OUTPUT = {line = 8, pattern = "^(.+)%sEU/t$"}
	}

	function obj.runMonitoring()
		while true do
			obj.inputHistory.push(obj.proxy.getSensorValue(config.INPUT))
			obj.outputHistory.push(obj.proxy.getSensorValue(config.OUTPUT))
			os.sleep(settings.batteryPollInterval)
		end
	end

	function obj.getStored()
		return obj.proxy.getSensorValue(config.STORED)
	end

	function obj.getCapacity()
		return obj.proxy.getSensorValue(config.CAPACITY)
	end

	return obj
end
----------------------------------------------------------------------
BatBuffer = {}
function BatBuffer.new(proxy, name)
	local obj = GenericGTBlock.new(proxy, name)

	local config = {
		-- "§a1 199 934§r EU / §e1 232 768§r EU"
		STORED = {line = 3, pattern = "§.(.+)§.+/.+$"},
		CAPACITY = {line = 3, pattern = "^.+/.+§.(.+)§.+$"},
		-- "32 768 EU/t"
		INPUT = {line = 5, pattern = "^(.+)%sEU/t$"},
		OUTPUT = {line = 7, pattern = "^(.+)%sEU/t$"}
	}

	function obj.runMonitoring()
		while true do
			obj.inputHistory.push(obj.proxy.getSensorValue(config.INPUT))
			obj.outputHistory.push(obj.proxy.getSensorValue(config.OUTPUT))
			os.sleep(settings.batteryPollInterval)
		end
	end

	function obj.getStored()
		return obj.proxy.getSensorValue(config.STORED)
	end

	function obj.getCapacity()
		return obj.proxy.getSensorValue(config.CAPACITY)
	end

	return obj
end

----------------------------------------------------------------------
Substation = {}
function Substation.new(proxy, name)
	local obj = GenericGTBlock.new(proxy, name)

	local config = {
		-- "Stored EU: §a1 275 992 701§r"
		STORED = {line = 3, pattern = "^.+§.(.+)§.+$"},
		CAPACITY = {line = 4, pattern = "^.+§.(.+)§.+$"},
		-- "Total Input: §91 352 912 896§r EU",
		TOTAL_INPUT = {line = 12, pattern = "^.+§.(.+)§.+$"},
		TOTAL_OUTPUT = {line = 13, pattern = "^.+§.(.+)§.+$"},
		TOTAL_COSTS = {line = 14, pattern = "^.+§.(.+)§.+$"}
	}
	local lastTotalInput = 0
	local lastTotalOutput = 0

	function obj:runMonitoring()
		while true do
			local currentTotalInput = obj.proxy.getSensorValue(config.TOTAL_INPUT)
			local currentTotalOutput = obj.proxy.getSensorValue(config.TOTAL_OUTPUT)
			local currentTotalCosts = obj.proxy.getSensorValue(config.TOTAL_COSTS)

			local currentInput = (currentTotalInput - lastTotalInput) / (settings.batteryPollInterval * 20)
			local currentOutput =
				(currentTotalOutput + currentTotalCosts - lastTotalOutput) / (settings.batteryPollInterval * 20)

			if lastTotalInput ~= 0 then
				obj.inputHistory.push(currentInput)
				obj.outputHistory.push(currentOutput)
			end

			lastTotalInput = currentTotalInput
			lastTotalOutput = currentTotalOutput + currentTotalCosts
			os.sleep(settings.batteryPollInterval)
		end
	end

	function obj.getStored()
		return obj.proxy.getSensorValue(config.STORED)
	end

	function obj.getCapacity()
		return obj.proxy.getSensorValue(config.CAPACITY)
	end

	return obj
end

----------------------------------------------------------------------
LESU = {}
function LESU.new(proxy, name)
	local obj = GenericGTBlock.new(proxy, name)

	local baseGetCapacity = obj.getCapacity
	function obj.getCapacity()
		return baseGetCapacity() / 2
	end

	return obj
end

----------------------------------------------------------------------
MFSU = {}
function MFSU.new(proxy, name)
	local obj = GenericGTBlock.new(proxy, name)
	local lastStored

	function obj.runMonitoring()
		while true do
			local currentStored = obj.proxy.getStored()

			if lastStored then
				if currentStored > lastStored then
					obj.inputHistory.push((currentStored - lastStored) / (settings.batteryPollInterval * 20))
					obj.outputHistory.push(0)
				elseif currentStored < lastStored then
					obj.inputHistory.push(0)
					obj.outputHistory.push((lastStored - currentStored) / (settings.batteryPollInterval * 20))
				else
					obj.inputHistory.push(0)
					obj.outputHistory.push(0)
				end
			end

			lastStored = currentStored
			os.sleep(settings.batteryPollInterval)
		end
	end

	function obj.getStored()
		return obj.proxy.getStored()
	end

	function obj.getCapacity()
		return obj.proxy.getCapacity()
	end

	return obj
end

----------------------------------------------------------------------
ScreenController = {}
function ScreenController.new(num)
	local obj = {}
	local width, height = template.width, #template.lines

	if not settings.debug then
		if (settings.displayMode == displayMods.Grid) then
			local displayW, displayH = 0, 0
			if num <= template.columnCount then
				displayW = num * width + (num - 1) * template.space
			else
				displayW = template.columnCount * width + (template.columnCount - 1) * template.space
			end
			displayH =
				math.ceil(num / template.columnCount) * height + (math.ceil(num / template.columnCount) - 1) * template.space
			gpu.setResolution(displayW, displayH)
		else
			gpu.setResolution(width, height)
		end
	end

	local _widgets = {}
	for n = 1, num do
		_widgets[n] = {}
		for k, widget in pairs(widgets) do
			_widgets[n][k] = widget(template)
		end
	end

	function obj.evaluateConditions(line, values)
		return string.gsub(
			line,
			"?(.-)?",
			function(pattern)
				local condition, left, right = pattern:match("^(.*)|(.*)|(.*)$")
				local f = ""
				for key, value in pairs(values) do
					f = f .. "local " .. key .. "="
					if type(value) == "string" then
						f = f .. "'" .. value .. "'\n"
					else
						f = f .. value .. "\n"
					end
				end
				f = f .. "return " .. condition
				f = load(f)
				if f then
					local result = f()
					return result and left or right
				end
			end
		)
	end

	function obj.evaluateValues(line, values)
		return string.gsub(
			line,
			"%$(.-)%$",
			function(pattern)
				local formatter
				local variable, args = pattern:match("^(.+):(.+)$")
				if not variable then
					variable = pattern
					formatter = "s"
					args = {"%s"}
				else
					args = split(args, ",")
					formatter = args[1]
					table.remove(args, 1)
				end

				if formatter then
					return formatters[formatter](values[variable], table.unpack(args))
				end
				return values[variable]
			end
		)
	end

	function obj.evaluateWidgets(line, values, n)
		return string.gsub(
			line,
			"#(.-)#",
			function(pattern)
				local name, args = pattern:match("^(.+):(.+)$")

				if not name then
					name = pattern
					args = {}
				else
					args = split(args, ",")
				end

				if _widgets[n][name] then
					return _widgets[n][name](values, args)
				end
			end
		)
	end

	function obj.render(values)
		for n, battery in ipairs(values.batteries) do
			local buffer = gpu.allocateBuffer(width, height)
			gpu.setActiveBuffer(buffer)
			local i = 1
			for _, line in pairs(template.lines) do
				gpu.setBackground(template.background)
				gpu.setForeground(template.foreground)

				local rendered = obj.evaluateConditions(line, battery)
				rendered = obj.evaluateValues(rendered, battery)
				rendered = obj.evaluateWidgets(rendered, battery, n)

				local j, k = 1, 1

				while j <= #rendered do
					local c = rendered:sub(j, j)
					if c == "&" then
						local cstr = ""
						local bg = false

						if rendered:sub(j + 1, j + 1) == "&" then
							bg = true
							j = j + 1
						end

						repeat
							j = j + 1
							local next = rendered:sub(j, j)
							if next ~= ";" then
								cstr = cstr .. next
							end
						until next == ";"
						local color

						if palette[cstr] then
							color = palette[cstr]
						else
							local hex = tonumber(cstr)
							if hex then
								color = hex
							end
						end

						if color then
							if bg then
								gpu.setBackground(color)
							else
								gpu.setForeground(color)
							end
						end

						j = j + 1
					else
						gpu.set(k, i, c)
						k = k + 1
						j = j + 1
					end
				end
				i = i + 1
			end
			local rn = n - 1
			gpu.bitblt(
				0,
				rn % template.columnCount * width + 1 + rn % template.columnCount * template.space,
				math.floor(rn / template.columnCount) * height + 1 + math.floor(rn / template.columnCount) * template.space,
				width,
				height,
				buffer,
				1,
				1
			)
		end
		gpu.freeAllBuffers()
	end

	function obj.resetScreen()
		if not settings.debug then
			local w, h = gpu.maxResolution()
			gpu.freeAllBuffers()
			gpu.setResolution(w, h)
			gpu.fill(1, 1, w, h, " ")
		end
	end

	return obj
end
----------------------------------------------------------------------

function GetName(address, prefix)
	for k, v in pairs(batteryNames) do
		if string.sub(address, 1, string.len(k)) == k then
			return v
		end
	end
	return prefix .. "@" .. string.sub(address, 1, 4)
end

----------------------------------------------------------------------
function Main()
	local lastUptime = computer.uptime()
	local lastToggle = lastUptime
	local num = 1

	local batteries = {}
	local i = 1
	for address, type in component.list() do
		local proxy = SensorProxyDecorator.new(component.proxy(address))
		if type == "gt_machine" then
			local info = proxy.getSensorInformation()
			if string.find(info[1], "substation") then
				batteries[i] = Substation.new(proxy, GetName(address, "PSS"))
				i = i + 1
			elseif string.find(info[1], "Progress") then
				batteries[i] = LESU.new(proxy, GetName(address, "L.E.S.U."))
				i = i + 1
			elseif string.find(info[1], "Operational Data") then
				batteries[i] = Lapotronic.new(proxy, GetName(address, "Lapotronic"))
				i = i + 1
			end
		elseif type == "gt_batterybuffer" then
			batteries[i] = BatBuffer.new(proxy, GetName(address, "BBuffer"))
			i = i + 1
		elseif type == "mfsu" then
			batteries[i] = MFSU.new(proxy, GetName(address, "MFSU"))
			i = i + 1
		end
	end

	if #batteries == 0 then
		print("Can't find any Battery Buffer or Power Sub-Station. Check your cables and adapters.")
		return -1
	end

	for _, battery in ipairs(batteries) do
		thread.create(
			function()
				battery:runMonitoring()
			end
		):detach()
	end

	local screen = ScreenController.new(#batteries)

	repeat
		local currentUptime = computer.uptime()

		if #batteries > 1 then
			if currentUptime - lastToggle > settings.toggleInterval then
				if num + 1 > #batteries then
					num = 1
				else
					num = num + 1
				end
				lastToggle = currentUptime
			end
		end

		local values = {
			batteries = {},
			currentNum = num,
			totalNum = #batteries
		}

		if settings.displayMode == displayMods.Summary then
			local data = {
				stored = 0,
				capacity = 0,
				input = 0,
				output = 0
			}
			for _, battery in ipairs(batteries) do
				data.stored = data.stored + battery.getStored()
				data.capacity = data.capacity + battery.getCapacity()
				data.input = data.input + battery.getInput()
				data.output = data.output + battery.getOutput()
			end
			data.name = "Summary"
			table.insert(values.batteries, data)
		elseif settings.displayMode == displayMods.Cycle then
			local data = {}
			data.stored = batteries[num].getStored()
			data.capacity = batteries[num].getCapacity()
			data.input = batteries[num].getInput()
			data.output = batteries[num].getOutput()
			data.name = batteries[num].name
			table.insert(values.batteries, data)
		elseif settings.displayMode == displayMods.Grid then
			for _, battery in ipairs(batteries) do
				local data = {}
				data.stored = battery.getStored()
				data.capacity = battery.getCapacity()
				data.input = battery.getInput()
				data.output = battery.getOutput()
				data.name = battery.name
				table.insert(values.batteries, data)
			end
		end

		for _, battery in ipairs(values.batteries) do
			battery.percent = battery.stored / battery.capacity * 100
			battery.charge = battery.input - battery.output

			if battery.charge > 0 then
				battery.left = (battery.capacity - battery.stored) / battery.charge
			elseif battery.charge < 0 then
				battery.left = battery.stored / -battery.charge
			else
				battery.left = 0
			end
			battery.left = math.floor(battery.left / 20)
		end

		screen.render(values)

		lastUptime = currentUptime
	until event.pull(settings.screenRefreshInterval, "interrupted")
	screen.resetScreen()
end

Main()
