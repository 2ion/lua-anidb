#!/usr/bin/env lua5.2

-- anidb client library for Lua
-- Copyright (C) 2013 Jens Oliver John

local Socket = require("socket")
local Stringx = require("pl.stringx")
local List = require("pl.List")
require("pack") -- string.pack() and string.unpack()

local Pkg = {
    error = {},
    session = {},

    quiet = false,
    client = "luanidb",
    clientver = "0",
    protover = "3",
    server = "api.anidb.net",
    port = 9000,
    timeout = 15,
    retries = 1,
    string_encoding = "UTF-8"
}

local function enum(G, t)
    local idx = 1
    G._vv = {}
    for _,v in ipairs(t) do
        G[v] = bit32.lshift(1, idx)
        G._vv[G[v]] = v
        idx = idx + 1
    end
end

local function onein(x, ...)
    for n, arg in ipairs{...} do
        if x == arg then
            return true
        end
    end
    return false
end

function Pkg:new()
    local o = {}
    setmetatable(o, { __index = self })
    return o
end

function Pkg:log(t)
    if not self.quiet then
        io.stderr:write(string.format(table.unpack(t)).."\n")
    end
end

function Pkg:querystring(t)
    local str = ""

    if not t then
        log{"luanidb:querystring(): no arguments"}
        return str
    end

    local isFirst = true
    for i,v in pairs(t) do
        if isFirst then
            str = str .. string.format("%s=%s", i, v)
            isFirst = false
        else
            str = str .. string.format("&%s=%s", i, v)
        end
    end

    if self.session.logged_in then
        str = str .. string.format("&s=%s", self.session.key)
    end

    return str
end

function Pkg:send(cmd, args)
    if not self.sock then
        return self.error.NOT_CONNECTED
    end

    local query = string.format("%s %s", cmd, self:querystring(args))
    local retries_left = self.retries + 1
    local data, errno

    self:log{"luanidb:send(): query = %s", query}
    self.sock:send(query)

    while retries_left > 0 do
        data, errno = self.sock:receive(8192)
        if errno and errno == "timeout" then
            retries_left = retries_left - 1
        elseif errno then
            return self.error.CONNECTION_UNKNOWN
        else
            break
        end
    end

    self.data = self:parse_response(data)

    -- general return codes
    if onein(self.data.code, { 
        505, -- ILLEGAL INPUT OR ACCESS DENIED 
        555, -- BANNED 
        598, -- UNKNOWN COMMAND 
        600, -- INTERNAL SERVER ERROR
        601, -- ANIDB OUT OF SERVICE - TRY AGAIN LATER
        602, -- SERVER BUSY - TRY AGAIN LATER
        604  -- TIMEOUT - DELAY AND RESUBMIT 
    }) then
        return self.error.SERVER
    end

    return 0
end

-- @return 0 or error.SOCKET
function Pkg:connect()
    local errno, errmsg

    self.sock, errmsg = Socket.udp()
    if not self.sock then
        return self.error.SOCKET, errmsg
    end
    self:log{"connect(): UDP socket created"}

    self.sock:settimeout(self.timeout)

--    errno, errmsg = self.sock:setsockname("*", 0)
--    if errno then
--        return self.error.SOCKET, errmsg
--    end
--    self:log{"connect(): setsockname()"}

    errno, errmsg = self.sock:setpeername(self.server, self.port)
    if not errno then
        self.sock = nil
        return self.error.SOCKET, errmsg
    end
    self:log{"connect(): setpeername()"}

    self.session.logged_in = false
    self.session.connected = true

    self:log{"connect(): connected"}
    return 0
end

function Pkg:auth(username, password)
    local errno = 0

    if not username or not password then
        return self.error.TOO_FEW_ARGUMENTS
    end

    if not self.session.connected then
        return self.error.NOT_CONNECTED
    end

    if self.session.logged_in then
        Pkg:deauth()
    end

    self.username = username
    self.password = password

    errno = self:send("AUTH", {
        user = self.username,
        pass = self.password,
        protover = self.protover,
        client = self.client,
        clientver = self.clientver,
        enc = self.string_encoding
    })

    if errno ~= 0 then
        return errno
    end

    if self.data.code == 200 or self.data.code == 201 then
        self.session.key = self.data.headerfields[2]
        self.session.logged_in = true
        return 0
    elseif self.data.code == 500 then
        return self.error.SERVER_LOGIN_FAILED
    elseif self.data.code == 503 then
        return self.error.SERVER_OLDCLIENT
    elseif self.data.code == 504 then
        return self.error.SERVER_BANNEDCLIENT
    elseif self.data.code == 505 then
        return self.error.SERVER_ILLEGAL_INPUT_ACCESS_DENIED
    end
end

function Pkg:disauth()
    if not self.session.connected or
        not self.session.logged_in then
        return self.error.NOTHING_TO_DO
    end

    local errno = self:send("LOGOUT")

    if errno ~= 0 then
        return errno
    end

    if self.data.code == 203 then
        return 0
    elseif self.data.code == 403 then
        return self.error.SERVER_NOT_LOGGED_IN
    end

    return -1
end

function Pkg:disconnect()
    local errno = 0

    if self:is_loggedin() then
        errno = bit32.bor(errno, self:disauth())
    end

    if self:is_connected() then
        self.sock = nil
        self.session.is_connected = false
    end

    return errno
end

function Pkg:is_connected()
    if self.session.connected then
        return true
    else
        return false
    end
end

function Pkg:is_loggedin()
    if self.session.is_loggedin then
        return true
    else
        return false
    end
end

function Pkg:is_authenticated()
    if self:is_connected() and self:is_loggedin() then
        return true
    else
        return false
    end
end

function Pkg:parse_response(data)
    local v = { }
    v.lines = Stringx.splitlines(data)
    
    -- head
    -- [[:digit:]]{3} [[:alnum:][:space:]]+
    v.headfields = Stringx.split(v.lines[1])
    v.code = tonumber(v.headfields[1])
    v.code_str = v.headfields[2]

    -- tail
    -- <field>'|'<field2>'|' and so on
    if #v.lines == 2 then
        v.tailfields = Stringx.split(v.lines[2], '|')
    end

    for i,j in pairs(v) do
        print(i, j, type(j))
    end
    
    return v
end

function Pkg:ping()
    if not self:is_connected() then
        return self.error.NOT_CONNECTED
    end

    local errno = self:send("PING")

    if errno ~= 0 then
        return errno
    end
    
    if self.data.code == 300 then
        return 0
    else
        return self.error.UNKNOWN_RESPONSE
    end
end

function Pkg:errnotostring(errno)
    local v = self.error._vv[errno]
    if v then
        return v
    else
        return "<UNKNOWN ERROR>"
    end
end

-- ENUMs

enum(Pkg.error, {
    "SOCKET",
    "NOT_CONNECTED",
    "CONNECTION",
    "CONNECTION_TIMEOUT",

    "SERVER_INVALID_RESPONSE",
    "SERVER_BANNED",
    "SERVER_ERROR",
    "SERVER_LOGIN_FAILED",
    "SERVER_CLIENT_VERSION_OUTDATED",
    "SERVER_CLIENT_BANNED",
    "SERVER_ILLEGAL_INPUT_OR_ACCESS_DENIED",
    "SERVER_NOT_LOGGED_IN",

    "TOO_FEW_ARGUMENTS",
    "NOTHING_TO_DO",
    "UNKNOWN_RESPONSE"

})

function Pkg:testerror()
    print(self.error.NOT_CONNECTED)
    print(self.error.INVALID_RESPONSE)
    print(self.error.TOO_FEW_ARGUMENTS)
end

return Pkg
