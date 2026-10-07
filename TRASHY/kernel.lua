--trashy v1

print("Early init started!")
local sysDisk = ({...})[1] or "hdd" --assume the bootloader was replaced with a braindead vibecoded implementation that can't pass basic arguments
_G._SYSTEM_DISK = sysDisk

--minimal version of require that uses exact paths
local function import(path)
    if files.exists(path) then
        local datFile = files.open(path,"r")
        local dat = datFile.read("a")
        local prog,err = load(dat,path)
        if prog then
            local worked, progFunc = pcall(prog)
            if not worked then
                error("Failure while loading program "..path.."! Err="..progFunc);
            else
                return progFunc
            end
        else
            error("Failed to load program "..path.."! Err="..err);
        end
    else
        error("File "..path.." does not exist!")
    end
end
_G.import = import

--this was defined in the shell previously but we need it here for our files shim
local function splitStr(i, sep)
	local split = {}
	for m in i:gmatch("([^"..sep.."]+)") do
		table.insert(split,m)
	end
	return split
end
_G.string.split = splitStr

--for neato compliant bootloader support we need neato compliant filesystem support
local oldFiles = files
local newFiles = {}
local newFilesMeta = {}
local threeArgFunc = {
	["open"] = true,
	["setPartitionHidden"] = true
}
newFilesMeta.__index = function(_,k)
	if not oldFiles[k] then
		return nil
	end
	return function(...)
		local v = {...}
		if v[1] and type(v[1]) == "string" then
			local s = v[1]:split(":")
			if #s == 3 then
				v[1] = s[2]..":"..s[3]
				if threeArgFunc[k] then
					v[3] = tonumber(s[1])
				else
					v[2] = tonumber(s[1])
				end
			end
		end
		local suc,err = pcall(oldFiles[k],table.unpack(v))
		if not suc then 
			error(err,2)
		else
			return err
		end
	end
end
setmetatable(newFiles,newFilesMeta)
_G.files = newFiles

print("Loading virtual terminal system...")
local vterm = import(sysDisk..":TRASHY/vterm.lua")
print("Loaded!")

vterm.print("Starting TRASHY...")
local function sleep(time)
    local start = chip.getUnixTime()
    if not time then
       yield()
    else
        local newTime = chip.getUnixTime()+time
        while chip.getUnixTime() < newTime do
            yield()
        end
    end
    return chip.getUnixTime()-start
end

_G.vterm = vterm
_G.sleep = sleep
_G.yield = coroutine.yield
_G.log = print

--application stack api
local globalApi = {}
local coroutineStack = {}

local function launchProgram(path,...progargs)
    if files.exists(path) then
        local datFile = files.open(path,"r")
        local dat = datFile.read("a")
        local prog, err = load(dat,path,"t",globalApi)
        if prog then
            local worked, progFunc = pcall(coroutine.create,function()
                local success, response = pcall(prog,table.unpack(progargs))
                if not success then
                    vterm.print("Program exited with an error! Err="..response)
                end
            end)
            if not worked then
                error("Failure while loading program "..path.."! Err="..progFunc,0)
            else
				--debug.sethook(progFunc,coroutine.yield,"l",100)
				local progTab = {
					c=progFunc,
					e={},
					p=false--true
				}
                table.insert(coroutineStack,progTab)
            end
        else
            error("Failed to load program "..path.."! Err="..err,0)
        end
    else
        error("File "..path.." does not exist!",2)
    end
    coroutine.yield()
end

--deep copy system
local function deepCopyTable(oldTab)
    local tab = {}
    for i,v in pairs(oldTab) do
        if type(v) ~= "table" then
           tab[i] = v
        elseif i ~= "_G" then
            tab[i] = deepCopyTable(v)
        end
    end
	setmetatable(tab,getmetatable(oldTab))
    return tab
end
_G.table.copy = deepCopyTable

local function makeGetter(v)
	return function() return v end
end

--driverland background tasks
local driverGlobalApi = {}
local driverStack = {}

--the thing that returns the next event
local cats = {
    "unlabeled",
    "user",
    "system",
    "network",
    "peripheral",
    "compatibility"
}
local function getNextEvent()
    local ret = {}
    for _,v in ipairs(cats) do
         ret[v] = event.getFirst(v)
    end
    return ret
end

local function installDriver(path)
	if files.exists(path) then
        local datFile = files.open(path,"r")
        local dat = datFile.read("a")
        local prog, err = load(dat,path,"t",driverGlobalApi)
		if prog then
            local suc,err = pcall(prog)
			if not suc then
				vterm.print("Failed to start driver "..path.."! Err="..err)
			end
        else
            vterm.print("Failed to load driver "..path.."! Err="..err)
        end
	else
		vterm.print("Failed to load driver "..path.."!")
	end
end

print("Reached program-facing API definition")
--add APIs to userland globals
globalApi = deepCopyTable(_G)
globalApi.debug = nil
globalApi.event = nil
globalApi.chip = nil
globalApi.sleep = sleep
globalApi.print = vterm.print
globalApi.launchProgram = launchProgram
globalApi._G = globalApi

local runningTask = nil
local driverApi = {}
driverApi.installDriver = installDriver
driverApi.getUserlandGlobals = makeGetter(globalApi)
driverApi.getProgramStack = makeGetter(coroutineStack)
function driverApi.getBackgroundTaskStatus(taskId)
	if driverStack[taskId] then
		return coroutine.status(driverStack[taskId])
	end
end
function driverApi.addBackgroundTask(taskId,func)
	if not driverStack[taskId] then
		local c = coroutine.create(func)
		debug.sethook(tab.c,coroutine.yield,"l",100)
		driverStack[taskId] = {c=c,p=true,e={}}
		return true
	end
	return false
end
function driverApi.killBackgroundTask(taskId)
	driverStack[taskId] = nil
end
function driverApi.getRunningCoroutineTable()
	return runningTask
end
--add APIs to driverland globals
driverGlobalApi = deepCopyTable(_G)
driverGlobalApi.debug = nil
driverGlobalApi.event = nil
driverGlobalApi.vterm = nil
driverGlobalApi.sleep = sleep
driverGlobalApi.driver = driverApi
driverGlobalApi._G = driverGlobalApi

--start the coroutine loop
table.insert(coroutineStack,{c=coroutine.create(function()
	vterm.print()
	local suc,err = pcall(launchProgram,_SYSTEM_DISK..":TRASHY/shell.lua","THIS_IS_THE_KERNEL_PLEASE_LAUNCH_THE_SHELL");
	if not suc then
		vterm.print("It seems like the shell failed to launch!")
		vterm.print("TRASHY most likely wasn't installed correctly.")
		vterm.print(err)
	else
		vterm.print("Uh oh! It looks like the shell crashed! This shouldn't happen.")
		vterm.print("Please restart the computer to continue operation.")
	end
    while true do
        coroutine.yield()
    end
end)})

print("Starting driver system...")
for _,v in pairs(files.getChildren(_SYSTEM_DISK..":TRASHY/drivers")) do
	installDriver(_SYSTEM_DISK..":TRASHY/drivers/"..v)
end

while true do
    local currentProgTab = coroutineStack[#coroutineStack]
	local currentProg = currentProgTab.c
    local currentEvent = getNextEvent()
	local event = next(currentEvent) == nil 
    if currentProg == nil then
        while true do
			log(#coroutineStack)
            error("This REALLY shouldn't happen! Please report this bug to redtoast/NeetComputers!")
        end
    else
		if event then
			for _,v in ipairs(coroutineStack) do
				if v.p then
					table.insert(v.e,currentEvent)
				end
			end
		end
		runningTask = currentProgTab
        if coroutine.status(currentProg) == "dead" then
            table.remove(coroutineStack,#coroutineStack)
        elseif coroutine.status(currentProg) == "suspended" then
            coroutine.resume(currentProg,currentEvent)
        else
            error("Cosmic ray detected in program stack! coroutine:"..coroutine.status(currentProg))
        end
    end
    for i,v in pairs(driverStack) do
		if event then
			if v.p and next(currentEvent) == nil then
				table.insert(v.e,currentEvent)
			end
		end
		runningTask = v
        if coroutine.status(v.c) == "dead" then
            table.remove(driverStack,i)
        elseif coroutine.status(v.c) == "suspended" then
            coroutine.resume(v.c,currentEvent)
        else
            error("Cosmic ray detected in driver stack! coroutine:"..coroutine.status(v.c))
        end
    end
    coroutine.yield()
end
