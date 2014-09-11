#!/usr/bin/env lua5.2

-- AniDB.net HTTP API client library

local posix = require 'posix'
local http = require 'socket.http'
local zlib = require 'zlib'
local stringx = require 'pl.stringx'
local pretty = require 'pl.pretty'
local list = require 'pl.List'
local api = setmetatable({
  _VERSION = "0.0",
  _AUTHOR = "Jens Oliver John",
  _HOMEPAGE = "https://github.com/2ion/lua-anidb",
  _LICENSE = "GPL3",
  _CATALOG = "http://anidb.net/api/anime-titles.dat.gz"
}, {
  __index = api,
  __call = function (self) 
    print(string.format("AniDB.net HTTP API client library\nVersion: %s", self._VERSION))
    return self
  end
})

local function ifnot(v)
  if v then return v
  else return {} end
end

local function dump_table(t, file)
  local h = io.open(file, "w")
  h:write(pretty.write(t, "", true))
  h:close()
  return true
end


function api:log(...)
  print("anidb.api.http: "..string.format(...))
end

function api:init(cachedir)
  if not self:init_home(cachedir or os.getenv("HOME").."/.anidb-http-api") then
    return false
  end
  if not self:init_catalog() then
    return false
  end
  return true
end

function api:init_home(catalog_dir)
  assert(catalog_dir)
  self.catalog_dir = catalog_dir
  if not posix.access(self.catalog_dir) then
    posix.mkdir(self.catalog_dir)
    if not posix.access(self.catalog_dir) then
      self:log("Could not create catalog directory.")
      return false
    end
  end
  self.catalog_file = self.catalog_dir.."/anime-titles.dat.gz"
  self.catalog_data = self.catalog_dir.."/catalog.lua"
  return true
end

function api:init_catalog()
  self.catalog = {}
  if not posix.access(self.catalog_file) then
    print("NOT PRESENT")
    os.exit(0)
    local b, s = http.request(self._CATALOG)
    if not b then
      self:log("init_catalog: cannot retrieve catalog.")
      return false
    end
    local f = io.open(self.catalog_file, "w")
    if f:write(b) then
      f:close()
    else
      self:log("init_catalog: failed to write catalog file")
      return false
    end
  end
  self:parse_csv_catalog()
end

function api:read_zipfile(file)
  if not posix.access(file) then
    return nil
  end
  local h = io.open(file, "r")
  local zd = h:read("*a")
  h:close()
  return zlib.inflate()(zd)
end

function api:parse_csv_catalog()
  local function titletype2string(type)
    if      type==1 then return "primary"
    elseif  type==2 then return "synonyms"
    elseif  type==3 then return "shorttitles"
    elseif  type==4 then return "official"
    end
  end
  local function new_lng()
    return {
      synonyms = {},
      shorttitles = {}
    }
  end
  self.catalog = {}
  local d = self:read_zipfile(self.catalog_file)
  local lines = stringx.splitlines(d)
  lines = list.slice(lines, 4, -1)
  lines:foreach(function (line)
      local csv = stringx.split(line, '|')
      local aid = tonumber(csv[1])
      local type = titletype2string(tonumber(csv[2]))
      local lng = csv[3]
      local title = csv[4]
      if not self.catalog[aid] then
        self.catalog[aid] = {}
      end
      if not self.catalog[aid][lng] then
        self.catalog[aid][lng] = new_lng()
      end
      local prefix = self.catalog[aid][lng]
      if type=="primary" then
        prefix.primary = title
      elseif type=="synonyms" then
        table.insert(prefix.synonyms, title)
      elseif type=="shorttitles" then
        table.insert(prefix.shorttitles, title)
      elseif type=="official" then
        prefix.official = title
      end
    end)
  dump_table(self.catalog, self.catalog_data)
  return true
end

return api
