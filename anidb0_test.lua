#!/usr/bin/env lua5.2

local Socket = require("socket")
local Stringx = require("pl.stringx")
local List = require("pl.List")
require("pack") -- string.pack() and string.unpack()

local function log(t)
    print(string.format(table.unpack(t)))
end


local Adb = require("anidb0")
if Adb then log{" == Library loaded"} end

local Db = Adb:new()
if Db then log{" == Library instance created"} end

local errno, errmsg = Db:connect()
if errno == 0 then
    log{" == Connection established"}
else
    log{" !! Could not connect to the server"}
    return -1
end

--[[
errno = Db:ping()
if errno == 0 then
    log{" == Server responded to PING: %s", Db.data.lines[1]}
else
    log{" !! Didn't get a PONG: %s", Db:errnotostring(errno)}
    log{"%s", tostring(Db.data.lines)}
end
--]]

--Db:auth("twoion", "shai9poo99202313")
Db:preauth("ldBIg")

Db:deauth()


