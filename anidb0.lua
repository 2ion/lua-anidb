#!/usr/bin/env lua5.2

-- anidb client library
-- Copyright (C) 2013 Jens Oliver John
-- Licensed under the GNU General Public License v3 or later.
-- See the file LICENSE for details.

local Socket = require("socket")
local Stringx = require("pl.stringx")
local List = require("pl.List")
require("pack") -- string.pack() and string.unpack()

local Pkg = {
    error = {},
    amask = {},
    session = {},

    quiet = false,
    client = "luanidb",
    clientver = "0",
    protover = "3",
    server = "api.anidb.net",
    port = 9000,
    timeout = 15,
    retries = 1,
    string_encoding = "UTF-8",
    default_amask = "b2f0e0fc000000"
}

--- Enumerate the values in an environment, and assign them
-- values 2^x so that they can be used as bitmasks. Creates a subtable
-- _vv in G with the reversed mapping (enum_value -> key)
-- @param G table, environment
-- @param t table, array of strings
-- @param nullshift the power of x to begin the enumeration with
-- (defaults to 1)
local function enum(G, t, nullshift)
    local idx = nullshift or 1
    G._vv = {}
    for _,v in ipairs(t) do
        G[v] = bit32.lshift(1, idx)
        G._vv[G[v]] = v
        idx = idx + 1
    end
end

--- Like enum(), but doesn't generate the G._vv
-- @see enum
-- @param G table, environment
-- @param t table, array of strings
-- @param nullshift the power of x to begin the enumeration with
-- (defaults to 1)

local function enum_bytes(G, t, nullshift)
    local idx = nullshift or 1
    for _,v in ipairs(t) do
        G[v] = bit32.lshift(1, idx)
        idx = idx + 1
    end
end

--- Reverse an array
-- @param l list
-- @return reversed list
local function reverse_list(l)
    local results = {}
    for i=#l, 1, -1 do
    	results[#results+1] = l[i];
    end
    return results
end

--- Check if the value x is equal to a value among the vargs
-- @param x value
-- @param ... vargs
-- @return true if there is a matching value, false if not
local function onein(x, ...)
    for n, arg in ipairs{...} do
        if x == arg then
            return true
        end
    end
    return false
end

--- Create a new instance of the library
-- @return library object
function Pkg:new()
    local o = {}
    setmetatable(o, { __index = self })
    return o
end

--- Log to stderr if logging is enabled
-- @param t table in printf() format ("<format string>", ...)
-- @see enable_logging()
function Pkg:log(t)
    if not self.quiet then
        io.stderr:write(string.format(table.unpack(t)).."\n")
    end
end

--- Construct a querystring from the arguments passed in t. Appends the
-- session key &s=$sessionkey
-- @param t table of kv-pairs
-- @return query string in the form a=b&c=d and so on
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
        if #t == 0 then
            str = str .. string.format("s=%s", self.session.key)
        else
            str = str .. string.format("&s=%s", self.session.key)
        end
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

-- FIXME: not necessary, the OS does this
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

function Pkg:preauth(sessionkey)
    if not self:is_connected() then
        return self.error.NOT_CONNECTED
    end
    self.session.key = sessionkey
    self.session.is_loggedin = true
    return 0
end

function Pkg:auth(username, password)
    local errno = 0

    if not username or not password then
        return self.error.TOO_FEW_ARGUMENTS
    end

    if not self:is_connected() then
        return self.error.NOT_CONNECTED
    end

    if self:is_loggedin() then
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
        self.session.key = self.data.headfields[2]
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

function Pkg:deauth()
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
        errno = bit32.bor(errno, self:deauth())
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
    
    return v
end

function Pkg:anime_by_name(name, amask)
    if not self:is_authenticated() then
        return self.error.NOT_AUTHENTICATED
    end

    local anime = {}
    local amask = amask or self:decode_amask(self.default_amask)

    local errno = self:send("ANIME", {
        aname = name,
        amask = self:encode_amask(amask)
    })

    if errno ~= 0 then
        return errno
    end

    if self.data.code == 330 then
        return self.error.NO_SUCH_ANIME, nil
    elseif self.data.code ~= 230 then
        return self.error.UNKNOWN_RESPONSE
    end

    for i=1,#amask do
        anime[amask[i].fieldname] = self.data.tailfields[i]
    end

    return 0, anime
end

function Pkg:anime_by_aid(aid, amask)
    if not self:is_authenticated() then
        return self.error.NOT_AUTHENTICATED
    end

    local anime = {}
    local amask = amask or self:decode_amask(self.default_amask)

    local errno = self:send("ANIME", {
        aid = aid,
        amask = self:encode_amask(amask)
    })

    if errno ~= 0 then
        return errno
    end

    if self.data.code == 330 then
        return self.error.NO_SUCH_ANIME
    elseif self.data.code ~= 230 then
        return self.error.UNKNOWN_RESPONSE
    end

    for i=1,#amask do
        anime[amask[i].fieldname] = self.data.tailfields[i]
    end

    return 0, anime
end

function Pkg:anime_description(aid)
    if not self:is_authenticated() then
        return self.error.NOT_AUTHENTICATED
    end

    local description = ""
    local aid = aid
    local part = 0

    local errno = self:send("ANIMEDESC", {
        aid = aid,
        part = part
    })

    if errno ~= 0 then
        return errno
    end

    if self.data.code == 330 then
        return self.error.NO_SUCH_ANIME
    elseif self.data.code == 333 then
        return self.error.NO_SUCH_DESCRIPTION
    elseif self.data.code ~= 233 then
        return self.error.UNKNOWN_RESPONSE
    end

    description = description .. self.data.tailfields[3]

    if tonumber(self.data.tailfields[2]) > 0 then
        for part=1,tonumber(self.data.tailfields[2]) do
            errno = self:send("ANIMEDESC", {
                aid = aid,
                part = part
            })
            if errno ~= 0 then
                description = description .. self.data.tailfields[3]
            end
        end
    end

    return 0, description
end

function Pkg:encode_amask(flags)
    local mask = { 0, 0, 0, 0, 0, 0, 0 }
    for _,flag in ipairs(flags) do
        local b = flag.byte
        mask[b] = bit32.bor(mask[b], flag.mask)
    end
    for i,_ in ipairs(mask) do
        mask[i] = string.format("%02x", mask[i])
    end
    return table.concat(mask)
end

--- decode the hexstring form of an amask to an array of flags as
-- accepted by anime_by_name() and anime_by_id()
-- @param hexstring an encoded amask
-- @return an array of flags
function Pkg:decode_amask(hexstring)
    local hexstring = hexstring
    local mask = {}
    local flags = { {}, {}, {}, {}, {}, {}, {} }
    local amask = {}

    -- don't accept incomplete bytes
    if (#hexstring % 2) == 1 then
        return self.error.INVALID_HEXSTRING
    end

    -- pad zeros for missing bytes
    for i=1,(14-#hexstring)/2 do
        hexstring = hexstring .. "00"
    end

    for byte in hexstring:gmatch("..") do
        table.insert(mask, tonumber(byte, 16))
    end

    for i,byte in ipairs(mask) do
        for flag,flagmask in pairs(self.amask[i]) do
            if bit32.band(byte, flagmask) == flagmask then
                table.insert(flags[i], self.amask[flag])
            end
        end
    end

    for _,t in ipairs(flags) do
        -- sort for correct bit order => correct value order
        table.sort(t, function (a,b)
            if a.mask > b.mask then
                return true
            else
                return false
            end
        end)
        for __, flag in ipairs(t) do
            table.insert(amask, flag)
        end
    end

    return amask
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

function Pkg:enable_logging(flag)
    self.quiet = flag and false or true
end

-- .DATA

enum(Pkg.error, {
    "SOCKET",
    "NOT_CONNECTED",
    "NOT_AUTHENTICATED",
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
    "UNKNOWN_RESPONSE",
    "INVALID_HEXSTRING",
    "NO_SUCH_ANIME",
    "NO_SUCH_DESCRIPTION"
})

-- AMASK

for b=1,7 do
    Pkg.amask[b] = {}
end

enum_bytes(Pkg.amask[1], {
    "CATEGORY_WEIGHT_LIST",
    "CATEGORY_LIST",
    "RELATED_AID_TYPE",
    "RELATED_AID_LIST",
    "TYPE",
    "YEAR",
    "DATEFLAGS",                
    "AID"
}, 0)

enum_bytes(Pkg.amask[2], {
    "RETIRED1", -- retired
    "RETIRED2",
    "NAME_SYNONYM_LIST",
    "NAME_SHORTS_LIST",
    "NAME_OTHER",
    "NAME_ENGLISH",
    "NAME_KANJI",
    "NAME_ROMAJI",
}, 0)

enum_bytes(Pkg.amask[3], {
    "CATEGORY_ID_LIST",
    "PICNAME",
    "URL",
    "END_DATE",
    "AIR_DATE",
    "SPECIAL_EP_COUNT",
    "HIGHEST_EP_NUMBER",
    "EPISODES"
}, 0)

enum_bytes(Pkg.amask[4], {
    "18PLUS",
    "AWARD_LIST",
    "REVIEW_COUNT",
    "AVERAGE_REVIEW_RATING",
    "TEMP_VOTE_COUNT",
    "TEMP_RATING",
    "VOTE_COUNT",
    "RATING"
}, 0)

enum_bytes(Pkg.amask[5], {
    "DATE_RECORD_UPDATED",
    "UNUSED1",
    "UNUSED2",
    "UNUSED3",
    "ANIME_NFO_ID",
    "ALLCINEMA_ID",
    "ANN_ID",
    "ANIMEPLANET_ID"
}, 0)

enum_bytes(Pkg.amask[6], {
    "UNUSED1",
    "UNUSED2",
    "UNUSED3",
    "UNUSED4",
    "MAIN_CREATOR_NAME_LIST",
    "MAIN_CREATOR_ID_LIST",
    "CREATOR_ID_LIST",
    "CREATOR",
    "CHARACTER_ID_LIST"
}, 0)

enum_bytes(Pkg.amask[7], {
    "UNUSED1",
    "UNUSED2",
    "UNUSED3",
    "PARODY_COUNT",
    "TRAILER_COUNT",
    "OTHER_COUNT",
    "CREDITS_COUNT",
    "SPECIALS_COUNT"
}, 0)

for byteidx,byte in ipairs(Pkg.amask) do
    for option,bitmask in pairs(byte) do
        Pkg.amask[option] = { byte = byteidx, mask = bitmask, fieldname = tostring(option) }
    end
end

return Pkg
