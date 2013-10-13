#!/usr/bin/luajit

local anidb = require("anidb")
local list = require("pl.List")

local db = anidb.new()

local v, errno = db:connect("twoion", "password")

print(v, db:errorstr(errno))

print("PING", db:ping())

db:disconnect()

