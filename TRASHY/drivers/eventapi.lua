local globals = driver.getUserlandGlobals()
local vterm = globals.vterm
local event = {}
function event.fetchTop()
	local tab = driver.getRunningCoroutineTable()
	if tab.p then
		return table.remove(tab.e,1) or {}
	else
		return coroutine.yield()
	end
end
function event.clearEvents() 
	local tab = driver.getRunningCoroutineTable()
	if tab.p then
		tab.e = {}
		return true
	end
	return false
end
function event.togglePreempt()
	local tab = driver.getRunningCoroutineTable()
	if tab.p then
		debug.sethook(tab.c,coroutine.yield,"l",100)
		return true
	end
	debug.sethook(tab.c)
	return false
end
function event.isPreempt()
	local tab = driver.getRunningCoroutineTable()
	return tab.p
end

local function input()
    local str = ""
    while true do
        local sizeX,sizeY = vterm.getSize()
        local posX,posY = vterm.getCursorPos()
        local n = event.fetchTop()["user"]
        if n and n[1] == "keyPressed" then
            if n[2] == 13 then
                vterm.print()
                break
            elseif n[2] == 8 then
                if #str ~= 0 then
                    str = str:sub(1,#str-1)
                    posX = posX - 1
                    if posX == 0 then
                        posY = posY - 1
                        posX = sizeX
                    end
                    vterm.setCursorPos(posX,posY)
                    vterm.setChar("",posX,posY)
                end
            else
                if posX > sizeX then
                    posX = 1
                    posY = posY + 1
                    vterm.setCursorPos(posX,posY)
                    if posY > sizeY then
                        vterm.scroll(1)
                    end
                end
                vterm.write(n[3])
                str = str .. n[3]
            end
        end
    end
    return str
end

globals.event = event
globals.input = input
_G.event = event
_G.input = input