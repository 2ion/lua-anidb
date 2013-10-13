#!/usr/bin/luajit

local socket = require("socket")
local stringx = require("pl.stringx")
local list = require("pl.List")

local function _(x, ...)
    for n, arg in ipairs{...} do
        if x == arg then
            return true
        end
    end
    return false
end

local AniDB = {
    server = "udp.anidb.net",
    port = "9000",
    timeout = 5,
    client = "anidb-lua/0",
    localport = 0,
    
    error = {
        SOCKET          = 0x0,
        EXEC_RECEIVING  = 0x1
    }
}

function AniDB:errorstr(errno)
    for k,v in pairs(self.error) do
        if v == errno then
            return k
        end
    end
    return ""
end

function AniDB.new()
    local o = {}
    setmetatable(o, { __index = AniDB })
    return o
end

function AniDB:set_error_handler(func)
    if type(func) ~= "function" then
        return nil
    end
    self.errh = func
    return true
end

function AniDB:log(t)
    print(string.format(unpack(t)))
end

function AniDB:connect(username, password)
    local err, tmp

    self.username = username
    self.password = password
    print(self.server, self.port)

    self.sock, err = socket.udp()

    if not self.sock then
        return nil, self.error.SOCKET
    end

    self.sock:settimeout(self.timeout)

    tmp, err = self.sock:setsockname("*", self.localport)
    if not tmp then
        self.sock = nil
        return nil, self.error.SOCKET
    end

    tmp, err = self.sock:setpeername(self.server, self.port)
    if not tmp then
        self.sock = nil
        return nil, self.error.SOCKET
    end

    self.is_connected = true

    return true
end

function AniDB:disconnect()
    if self.sock then
        self.sock:close()
        self.sock = nil
    end
end

function AniDB:ping()
    if not self.is_connected then
        return nil
    end
    local v, errno = self:exec("PING")
    if not v then
        return nil
    end
    return true
end

function AniDB:exec(cmd, pairlist, retries)
    local cmd = cmd
    local err = nil
    local rc, r = 0, (retries and (retries + 2) or 2)
    local v = {}

    if pairlist then
        for _,v in ipairs(pairlist) do
            if _ > 1 then
                d = d .. string.format("&%s=%s", v[1], v[2])
            else
                d = d .. string.format("%s=%s", v[1], v[2])
            end
        end
    end

    self.sock:send(d)

    while rc < r do
        d, err = self.sock:receive(8192)
        if err and err == "timeout" then
            rc = rc + 1
            self:log{ "exec(): Retrying after timeout" }
        elseif err then
            return nil, self.error.EXEC_RECEIVING
        else
            break
        end
    end

    v.lines = stringx.splitlines(d)
    v.code = stringx.split(v.lines[1], " ", 2)
    v.text, v.code = v.code[2], tonumber(v.code[1])
    list.remove(v.lines, 1)

    return v
end

return AniDB
