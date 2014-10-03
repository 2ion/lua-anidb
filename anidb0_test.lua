#!/usr/bin/env lua5.2

local Socket = require("socket")
local Stringx = require("pl.stringx")
local List = require("pl.List")
local Getopt = require("getopt")

local USERNAME, PASSWORD, REMAIN_LOGGEDIN

local function usage()
    print([[anidb0_test [option]
-u username
-p password
-r remain logged in

-a anime-title  query anime by title
-A aid          query anime by aid
-D aid          query anime description by aid]])
end

local function go_assign(t, n, v) v = t[n] end
local function mka(n, v) return function (t) go_assign(t, n, v) end end

local noop = Getopt{
    { a={"u","username"}, g=1, f=mka(1, USERNAME)  },
    { a={"p","password"}, g=1, f=mka(1, PASSWORD)  }
}

print(USERNAME, PASSWORD)




