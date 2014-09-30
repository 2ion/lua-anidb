#!/usr/bin/env lua5.2

-- AniDB.net HTTP API client library
-- Copyright (C) 2014 Jens Oliver John
-- Licensed under the GNU General Public License v3 or later.
-- See the file LICENSE for details.

local posix = require 'posix'
local http = require 'socket.http'
local zlib = require 'zlib'
local stringx = require 'pl.stringx'
local file = require 'pl.file'
local pretty = require 'pl.pretty'
local list = require 'pl.List'
local api = setmetatable({
  _VERSION = "0.0",
  _AUTHOR = "Jens Oliver John",
  _HOMEPAGE = "https://github.com/2ion/lua-anidb",
  _LICENSE = "GPL3",
  _CATALOG = "http://anidb.net/api/anime-titles.dat.gz",
  _ANIDB_CLIENT = "lua-anidb-http",
  _ANIDB_CLIENTVER = "0",
  _ANIDB_PROTOVER = "1",
  _DEBUG = false,
  _FORCE_CATALOG_REPARSE = false
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

local function get_lastmod_timediff(file)
  if not posix.access(file) then
    return false
  end
  local mtime_s = posix.stat(file).mtime
  local now_s = posix.clock_gettime("realtime")
  return (now_s-mtime_s)
end

local function tokenize(s)
  local tl = stringx.split(s, ' ')
  local T = list.new()
  for i=1,#tl do
    table.insert(T, tl[i])
    local stem = tl[i]
    for j=i+1,#tl do
      stem = stem .. " " .. tl[j]
      table.insert(T, stem)
    end
  end
  return T
end

function api:log(...)
  if self._DEBUG then
    print("anidb.api.http: "..string.format(...))
  end
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
  self.catalog_index_data = self.catalog_dir.."/catalog_index.lua"
  self.catalog_hash_data = self.catalog_dir.."/catalog_hasht.lua"
  return true
end

function api:init_catalog()
  self.catalog = {}
  local do_reparse = false
  local function exit_cleanup()
    posix.unlink(self.catalog_file)
    return false
  end
  if not posix.access(self.catalog_file) or 
    (posix.access(self.catalog_file) and
      get_lastmod_timediff(self.catalog_file)>=86400) then self:log("init_catalog: Requesting a new catalog")
    do_reparse = true
    local b, s = http.request(self._CATALOG)
    if not b then self:log("init_catalog: could not retrieve catalog")
      return exit_cleanup()
    end
    local f = io.open(self.catalog_file, "w")
    if f:write(b) then
      f:close()
    else self:log("init_catalog: failed to write catalog file")
      return exit_cleanup()
    end
  end
  if do_reparse or self._FORCE_CATALOG_REPARSE then self:log("init_catalog: Parsing catalog")
    self:parse_csv_catalog()
  else self:log("init_catalog: Loading cached data")
    self.catalog = pretty.read(file.read(self.catalog_data))
    self.catalog_index = pretty.read(file.read(self.catalog_index_data))
    self.catalog_hash_table = pretty.read(file.read(self.catalog_hash_data))
    if not self.catalog then
      error("FATAL: init_catalog: catalog cache file is not a valid table: " .. self.catalog_data)
    end
    if not self.catalog_index then
      error("FATAL: init_catalog: catalog index cache file is not a valid table: " .. self.catalog_index_data)
    end
  end
  return true
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
  self.catalog_index = {}
  self.catalog_hash_table = {}
  local d = self:read_zipfile(self.catalog_file)
  local lines = stringx.splitlines(d)
  lines = list.slice(lines, 4, -1)
  lines:foreach(function (line)
      local csv = stringx.split(line, '|')
      local aid = tonumber(csv[1])
      local type = titletype2string(tonumber(csv[2]))
      local lng, title = csv[3], csv[4]
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
      -- index
      self.catalog_index[title] = aid
      -- hash table
      local tlist = tokenize(title)
      tlist:foreach(function (token)
        if not self.catalog_hash_table[token] then
          self.catalog_hash_table[token] = {}
        end
        table.insert(self.catalog_hash_table[token], aid)
      end)
    end)
  dump_table(self.catalog, self.catalog_data)
  dump_table(self.catalog_index, self.catalog_index_data)
  dump_table(self.catalog_hash_table, self.catalog_hash_data)
  return true
end

function api:search(expr, min_word_count)
  if not self.catalog or not self.catalog_index then
    return false
  end
  local mwc = tonumber(min_word_count) or 0
  local ii = self.catalog_index[expr]
  if ii then return {ii} end
  local r = {}
  local tl = tokenize(expr, tklen)
  if mwc > 0 then
    tl = tl:filter(function (t)
      if stringx.count(t, " ") < mwc then
        return false
      else
        return true
      end
    end)
  end
  tl:foreach(function (token)
    local bucket = self.catalog_hash_table[token]
    if bucket then
      for _,aid in pairs(bucket) do
        table.insert(r, aid)
      end
    end
  end)
  return r
end

return api
