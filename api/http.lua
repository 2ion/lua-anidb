#!/usr/bin/env lua5.2

-- AniDB.net HTTP API client library
-- Copyright (C) 2014 Jens Oliver John
-- Licensed under the GNU General Public License v3 or later.
-- See the file LICENSE for details.

local file = require 'pl.file'
local http = require 'socket.http'
local list = require 'pl.List'
local lxp = require 'lxp'
local posix = require 'posix'
local pretty = require 'pl.pretty'
local stringx = require 'pl.stringx'
local url = require 'socket.url'
local zlib = require 'zlib'

local api = setmetatable({
  _VERSION = "0.0",
  _AUTHOR = "Jens Oliver John",
  _HOMEPAGE = "https://github.com/2ion/lua-anidb",
  _LICENSE = "GPL3",
  _CATALOG = "http://anidb.net/api/anime-titles.dat.gz",
  _ANIDB_CLIENT = "httpanidb",
  _ANIDB_CLIENTVER = "0",
  _ANIDB_PROTOVER = "1",
  _ANIDB_DATA_REQUEST = "http://api.anidb.net:9001/httpapi?request=anime&client=%s&clientver=%s&protover=%s&aid=%d",
  _ANIDB_REQUEST_LIMIT = 2,
  _DEBUG = false,
  _FORCE_CATALOG_REPARSE = false,
  _FORCE_REQUESTS = false,
  _MAX_CATALOG_AGE = 86400,
  _MAX_INFO_AGE = 86400
}, {
  __index = api,
  __call = function (self) 
    print(string.format("AniDB.net HTTP API client library\nVersion: %s", self._VERSION))
    return self
  end
})
local XMLElement = {}

local function ifnot(v)
  if v then return v
  else return {} end
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

local function uniq(t)
  local d, r = {}, {}
  for _,e in ipairs(t) do
    if not d[e] then
      table.insert(r, e)
      d[e] = true
    end
  end
  return r
end

local function one_of(v, ...)
  if select('#', ...) == 0 then
    return false
  end
  for _,e in ipairs{...} do
    if e == v then
      return true
    end
  end
  return false
end

local function read_zipfile(f)
  if not posix.access(f) then return nil end
  return zlib.inflate()(file.read(f))
end

local function write_zipfile(f, data)
  local zd = zlib.deflate(zlib.BEST_COMPRESSION)(data, 'finish')
  if not zd then return nil end
  file.write(f, zd)
  return true
end

local function dump_table(t, file)
  return write_zipfile(file, pretty.write(t, "", true))
end

local function read_table(file)
  if not posix.access(file) then return nil end
  return pretty.read(read_zipfile(file))
end

function XMLElement.new(parent, name, attr)
  local o = { children = {}, name = name, attr = attr, parent = parent }
  setmetatable(o, { __index = XMLElement})
  if parent and parent.children then
    table.insert(parent.children, o)
  end
  return o
end

function XMLElement:addchild(e)
  table.insert(self.children, e)
  return self
end

function XMLElement:settext(s)
  self.text = s
  return self
end

function XMLElement:parent(root)
  return self.parent or root
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
  self.catalog_data = self.catalog_dir.."/catalog.lua.gz"
  self.catalog_index_data = self.catalog_dir.."/catalog_index.lua.gz"
  self.catalog_hash_data = self.catalog_dir.."/catalog_hasht.lua.gz"
  self.cache_data = self.catalog_dir.."/data.lua.gz"
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
      get_lastmod_timediff(self.catalog_file)>=self._MAX_CATALOG_AGE) then self:log("init_catalog: Requesting a new catalog")
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
    self.catalog = read_table(self.catalog_data)
    self.catalog_index = read_table(self.catalog_index_data)
    self.catalog_hash_table = read_table(self.catalog_hash_data)
    if not self.catalog then
      error("FATAL: init_catalog: catalog cache file is not a valid table: " .. self.catalog_data)
    end
    if not self.catalog_index then
      error("FATAL: init_catalog: catalog index cache file is not a valid table: " .. self.catalog_index_data)
    end
  end
  self.cache = ifnot(read_table(self.cache_data))
  return true
end

function api:exit()
  local function setfree(ref, file)
    if ref then
      dump_table(ref, file)
    ref = nil
    end
  end
  self.catalog = nil
  self.catalog_index = nil
  self.catalog_hash_table = nil
  setfree(self.cache, self.cache_data)
  return true
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
  local d = read_zipfile(self.catalog_file)
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
      if one_of(type, "primary", "official") then
        prefix[type] = title
      elseif one_of(type, "shorttitles", "synonyms") then
        table.insert(prefix[type], title)
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

function api:search(expr, min_word_count, fs_threshold, fs_function)
  if not self.catalog or not self.catalog_index then
    return false
  end
  local mwc = tonumber(min_word_count) or -1
  local fst = tonumber(fs_threshold) or -1
  local fsf = stringx[fs_function] or stringx.startswith
  local ii = self.catalog_index[expr]
  if ii then return {ii} end
  local r = {}
  local tl = tokenize(expr)
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
  if #r < fst then self:log("search(): commencing full search using method: "..fs_function)
    for title,aid in pairs(self.catalog_index) do
      if fsf(title, expr) then
        table.insert(r, aid)
      end
    end
  end
  return uniq(r)
end

function api:info(aid)
  local now = posix.clock_gettime("realtime")

  if self.cache[aid] then
    if self.cache[aid].info
    and (now-self.cache[aid].reqtime) < self._MAX_INFO_AGE then
      return self.cache[aid].info
    end
  else
    self.cache[aid] = { reqtime = 0, reqcnt = 0 } 
  end

  if (now-self.cache[aid].reqtime) >= 86400 then
    self.cache[aid].reqcnt = 0
  end

  if (not self.cache[aid].xml and self.cache[aid].reqcnt < self._ANIDB_REQUEST_LIMIT)
  or self._FORCE_REQUESTS then self:log("info(): requesting XML for aid "..aid)
    local zd = http.request(self:info_request_url(aid))
    self.cache[aid].xml = zlib.inflate()(zd)
    self.cache[aid].reqtime = now
    self.cache[aid].reqcnt = self.cache[aid].reqcnt + 1
  end

  if not self.cache[aid].xml then self:log("info(): failed to retrieve XML data")
    return nil
  end

  self.cache[aid].info = self:parse_info_xml(self.cache[aid].xml)

  return self.cache[aid].info
end

function api:info_request_url(aid)
  return string.format(self._ANIDB_DATA_REQUEST, url.escape(self._ANIDB_CLIENT),
    url.escape(self._ANIDB_CLIENTVER), url.escape(self._ANIDB_PROTOVER), aid)
end

function api:parse_info_xml(xml)
  local root = XMLElement.new()
  local cur = root
  function lxp_StartElement(p, e, attr)
    cur = XMLElement.new(p, e, attr)
  end
  function lxp_EndElement(p, e)
    cur = cur.parent or root
  end
  function lxp_DefaultExpand(p, s)
    cur.text = s
  end
  local p = lxp.new{
    StartElement = lxp_StartElement,
    EndElement = lxp_EndElement,
    DefaultExpand = lxp_DefaultExpand
  }
  p:setencoding("UTF-8")
  local done = false
  local stat, msg, line, col, pos = p:parse(xml)
  if not stat then
    self:log("parse_info_xml(): XML parser failed: %s @ %d:%d (%d)",
      msg, line, col, pos)
    return nil
  else
    self:log("parse_info_xml(): XML parser finished successfully")
  end
  p:close()
  return root
end

return api
