#!/usr/bin/env lua

-- AniDB.net HTTP API client library
-- Copyright (C) 2014-2015 2ion <dev@2ion.de>

local ansicolors = require 'ansicolors'
local file = require 'pl.file'
local http = require 'socket.http'
local list = require 'pl.List'
local posix = require 'posix'
local pretty = require 'pl.pretty'
local stringx = require 'pl.stringx'
local tablex = require 'pl.tablex'
local url = require 'socket.url'
local xml = require 'pl.xml'
local zlib = require 'zlib'

local api = setmetatable({
  _VERSION = "0.0",
  _AUTHOR = "Jens Oliver John",
  _HOMEPAGE = "https://github.com/2ion/lua-anidb",
  _LICENSE = "GPL3",
  _CATALOG = "http://anidb.net/api/anime-titles.dat.gz",
  _ANSICOLORS = false,
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

--- Write library-internal debug messages to stdout. Does nothing unless
-- the _DEBUG flag has been set.
-- @param ... printf-style format string and optionally arguments
-- @return nothing
function api:log(...)
  if self._DEBUG then
    print("anidb.api.http: "..string.format(...))
  end
end

function api:debug_dump(t)
  pretty.dump(t)
end

--- Initialize the library. This function must be called before any
-- other library function.
-- @param cachedir The working directory to write cache data to.
-- Defaults to ~/.anidb-http-api if empty.
-- @ return true on success, false on failure
function api:init(cachedir)
  if not self:init_home(cachedir or os.getenv("HOME").."/.anidb-http-api") then
    return false
  end
  if not self:init_catalog() then
    return false
  end
  return true
end

--- Ensure that the cache directory exists and set up internal file name
-- variables accordingly. Called by api:init(), do not call directly.
-- @param cachedir The cache directory/data prefix
function api:init_home(cachedir)
  assert(cachedir)
  self.cachedir = cachedir
  if not posix.access(self.cachedir) then
    posix.mkdir(self.cachedir)
    if not posix.access(self.cachedir) then
      self:log("Could not create catalog directory.")
      return false
    end
  end
  self.catalog_file = self.cachedir.."/anime-titles.dat.gz"
  self.catalog_data = self.cachedir.."/catalog.lua.gz"
  self.catalog_index_data = self.cachedir.."/catalog_index.lua.gz"
  self.catalog_hash_data = self.cachedir.."/catalog_hasht.lua.gz"
  self.cache_data = self.cachedir.."/data.lua.gz"
  return true
end

--- Retrieve and process updated AniDB catalog data. By default and
-- honouring the API specifications, a new catalog will be requested
-- only once per day or if the locally stored catalog has been deleted.
-- The maximum age of the locally stored catalog data may be modified by
-- setting the _MAX_CATALOG_AGE variable to a value other than 86400
-- [seconds]. Newly retrieved catalogs will be parsed into Lua data
-- structures and stored locally, compressed in ZIP format. A reparsing
-- of old locally stored catalog data may be triggered by setting
-- _FORCE_CATALOG_REPARSE=true.
-- @return true on success, false on failure
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

--- API exit function that must be called before the main program exits.
-- Upon calling, eventually retrieved data other than catalog data (for
-- example, anime information) will be written to disk for later fast
-- access).
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

--- Parse the catalog data retrieved from AniDB. It shouldn't be
-- necessary to call this function.
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

--- Searches the catalog by anime title and returns a list of anime IDs
-- that match the respective title search. These IDs may be used in
-- api:info() to retrieve anime-specific data. The search function uses
-- a two-step search strategy: In the first step, a hash table created
-- by tokenizing titles is being searched for matches with the also
-- tokenized input string. Tokenizing as of now means to split strings
-- at blank spaces (%s). For example, the search string "Banner of the
-- Stars" would yield a token list { Banner, of, the, Stars } and would
-- thus the match imaginary titles "of the Stars", "of", "of the" or
-- "Banner of". In order to make the search more precise, the required
-- minimum size of compound tokens can be increased, ie. setting
-- $min_word_count to 3 would mean that titles "Banner of the" and "of
-- the Stars" would be valid in the light of the above example, but "of
-- the" would not match anything. In token lists, the order of the
-- tokens as they appear in the individual titles is being preserved. In
-- the second step, a regular string search search is being performed.
-- However, a full string search on all titles will only be performed if
-- the number of results from the hash-based search is less than
-- $fs_threshold. $fs_function specifies the search strategy being used.
-- If the full-text string search produces results that overlap with the
-- results from the hash-based search, duplicate results will be cleaned
-- up.
-- @param expr The search expression, a regular string
-- @param min_word_count The minimum number of words a token to be used
-- in the has table search must contain, defaults to -1 (no limit); 0
-- also does nothing
-- @param fs_threshold The minimum number of results expected from the
-- hash table search. If the number of results is below this threshold,
-- an additional full-text search will commence
-- @param fs_function The string-matching strategy to be used in the
-- full text search. Valid values are "startswith", "endswith" and
-- "count" (from the Penlight stringx library).
-- @return A list of anime IDs (integers) that match the search
-- expression. In the case of an internal error, false is being
-- returned. In the case that there was no match, an empty list is being
-- returned.
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
      self:log("info(): returning cached data for aid %d", aid)
      if self._DEBUG == true then -- filter even processed data
        self.cache[aid].info = self:info_collect(self.cache[aid].info)
      end
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

  self.cache[aid].info = self:info_parse_xml(self.cache[aid].xml)
  if not self.cache[aid].info then
    self:log("info(): Failed to parse the XML: No information available")
  end

  self:log("info(): running info_collect()")
  self.cache[aid].info = self:info_collect(self.cache[aid].info)

  self:log("info(): finished")
  return self.cache[aid].info
end

function api:info_request_url(aid)
  return string.format(self._ANIDB_DATA_REQUEST, url.escape(self._ANIDB_CLIENT),
    url.escape(self._ANIDB_CLIENTVER), url.escape(self._ANIDB_PROTOVER), aid)
end

function api:info_parse_xml(s)
  local function filter_blanks(t)
    return tablex.map(function (tv)
      if type(tv) == "string" and tv == "\n" then
        return nil
      elseif type(tv) == "table" then
        return filter_blanks(tv)
      end
      return tv
    end, t)
  end
  local x = xml.parse(s, false, false)
  x = filter_blanks(x)
  return x
end

function api:info_collect(t)

  local function index(t)
    local i = {}
    tablex.foreachi(t, function (v)
      if i[v.tag] and type(i[v.tag]) == 'table' then
        table.insert(i[v.tag], v)
      elseif i[v.tag] then
        i[v.tag] = { i[v.tag], v }
      else
        i[v.tag] = v
      end
    end)
    return i
  end

  local function collect_ratings(v)
    local i = index(v)
    return {
      permanent = { val = tonumber(i.permanent and i.permanent[1] or 0),  count = tonumber(i.permanent and i.permanent.attr.count or 0) },
      temporary = { val = tonumber(i.temporary and i.temporary[1] or 0),  count = tonumber(i.temporary and i.temporary.attr.count or 0) },
      review    = { val = tonumber(i.review    and i.review[1]    or 0),  count = tonumber(i.review and i.review.attr.count       or 0) }
    }
  end

  local function collect_official_titles(v)
    local i = index(v)
    local r = {}
    if type(i.title) == 'table' then
      tablex.foreach(i.title, function (vv)
        if vv.attr and (vv.attr.type == "official" or vv.attr.type == "main") then
          r[vv.attr["xml:lang"]] = vv[1]
        end
      end)
    end
    return r
  end

  local function collect_similar_anime(v)
    local r = {}
    if not v then return r end
    tablex.foreachi(v, function (vv)
      local k = vv[1]
      r[k] = {
        aid = tonumber(vv.attr.id),
        type = vv.attr.type,
        total_votes = tonumber(vv.attr.total),
        approving_votes = tonumber(vv.attr.approval)
      }
      r[k].approval_rate = r[k].approving_votes/r[k].total_votes
    end)
    return r
  end

  local function collect_episodes(v)
    local r = {}

    tablex.foreachi(v, function (vv)
      local i = index(vv)
      local key = i.epno[1] -- may be alphanumeric

      local function collect_ep_titles(t)
        local s = {}
        s.ja = t[1]
        tablex.foreachi(t, function (e)
          if e.attr then
            s[e.attr["xml:lang"]] = e[1]
          end
        end)
        return s
      end

      r[key] = {
        length = tonumber(i.length[1]),
        titles = collect_ep_titles(i.title),
        airdate = i.airdate and i.airdate[1] or nil
      }
    end)

    return r
  end

  local function collect_description(v)
    local i, j = v:find("Source:", 1, true)
    if i then
      return v:sub(1, i-1)
    end
  end

  local t = t
  local i = index(t)

  t._DATA = {
    type          = i.type[1],
    aid           = tonumber(t.attr.id),
    titles        = collect_official_titles(i.titles),
    similaranime  = collect_similar_anime(i.similaranime),
    episodecount  = tonumber(i.episodecount[1]),
    episodes      = collect_episodes(i.episodes),
    startdate     = i.startdate[1],
    enddate       = i.enddate[1],
    ratings       = collect_ratings(i.ratings),
    image         = "http://img7.anidb.net/pics/anime/"..i.picture[1],
    url           = "http://anidb.net/perl-bin/animedb.pl?show=anime&aid="..t.attr.id,
    description   = collect_description(i.description[1])
  }

  return t
end

function api:pretty(info, lang)
  if not info._DATA then return nil end

  local lang = lang or "ja"
  local c_perm = self:pretty_colorcode_rating(info._DATA.ratings.permanent.val)
  local c_temp = self:pretty_colorcode_rating(info._DATA.ratings.temporary.val)
  local c_review = self:pretty_colorcode_rating(info._DATA.ratings.review.val)

  print(self:pretty_sprint([[
Title         %{bright yellow underline}%s%{reset} (%{blue}%d%{reset})
Type          %s
Episodes      %d
Airtime       %s ~ %s
Rating
  Permanent   ]]..c_perm..[[%.2f%{reset} (%d)
  Temporary   ]]..c_temp..[[%.2f%{reset} (%d)
  Review      ]]..c_review..[[%.2f%{reset} (%d)
Similar anime]],
  self:pretty_find_nonempty_title(info._DATA.titles, lang), info._DATA.aid,
  info._DATA.type,
  info._DATA.episodecount,
  info._DATA.startdate, info._DATA.enddate,
  info._DATA.ratings.permanent.val, info._DATA.ratings.permanent.count,
  info._DATA.ratings.temporary.val, info._DATA.ratings.temporary.count,
  info._DATA.ratings.review.val, info._DATA.ratings.review.count))

  -- Display similar anime

  local sa = {}
  local sa_max_percentage = 0
  for title,v in pairs(info._DATA.similaranime) do
    local p = v.approval_rate * 100
    table.insert(sa, { t = title, approval_percentage = p, data = v })
    if p > sa_max_percentage then
      sa_max_percentage = p
    end
  end
  table.sort(sa, function (a, b) return a.data.approval_rate > b.data.approval_rate end)
  for _,v in ipairs(sa) do
    print(self:pretty_sprint("  "..self:pretty_colorcode_percentage(v.approval_percentage).."%.1f%{reset} %s (%{blue}%d%{reset})", v.approval_percentage, v.t, v.data.aid))
  end

  -- Picture URL
  print(self:pretty_sprint([[
AniDB.net
  URL          %s
  Picture      %s]],
  info._DATA.url,
  info._DATA.image))

  print([[Description]])
  print(string.format("  %s", self:pretty_reflow_text(info._DATA.description)))

  -- Display episodes

  print([[Episodes]])
  self:pretty_episodes(info._DATA.episodes)
end

function api:pretty_find_nonempty_title(t, lang)
  if t[lang] then
    return t[lang]
  elseif t.ja then self:log("find_nonempty_title(): substituting Japanese title: %s", t.ja)
    return t.ja
  else
    for k,v in pairs(t) do
      self:log("find_nonempty_title(): substituting title %s (%s), k, v")
      return v
    end
  end
  return "<empty>" -- not reached
end

function api:pretty_colorcode_percentage(score)
  local p = score<100.0 and " " or ""
  if score>=75.0 then
    return p.."%{green}"
  elseif score>=50.0 then
    return p.."%{yellow}"
  else
    return p.."%{red}"
  end
end

function api:pretty_colorcode_rating(score)
  if score >= 7.5 then
    return "%{green}"
  elseif score >= 5.0 then
    return "%{yellow}"
  else
    return "%{red}"
  end
end

function api:pretty_sprint(s, ...)
  return string.format(ansicolors(s), ...)
end

function api:pretty_reflow_text(s, width)
  local s = s:gsub("\n", " ")
  local width = width or os.getenv("COLUMNS") or 72
  local i = 1
  while i <= #s do
    i = i + width
    local j 
    if s:sub(i, i) ~= " " then
      j = s:find(' ', i+1, true)
    end
    if j then
      s = s:sub(1, j-1) .. "\n  " .. s:sub(j+1, -1)
      i = j + 3
    end
  end
  return s
end

function api:pretty_episodes(episode_table)
  local eps = {}
  local eps_max_idx = 0

  for k,v in pairs(episode_table) do
    table.insert(eps, { i = tonumber(k) or k, title = self:pretty_find_nonempty_title(v.titles, lang), len = v.length })
    if #k > eps_max_idx then
      eps_max_idx = #k
    end
  end

  table.sort(eps, function (a, b)
    if type(a.i) == "number" and type(b.i) == "number" then
      return a.i < b.i
    elseif type(a.i) == "string" and type(b.i) == "string" then
      return a.i < b.i
    elseif type(a.i) == "string" then
      return false
    else
      return true
    end
  end)

  for k,v in ipairs(eps) do
    local function pad(v)
      local v = tostring(v)
      for _=eps_max_idx-#v,0,-1 do
        v = v .. ' '
      end
      return v
    end
    if v.title then
      print(self:pretty_sprint("  %s%s", pad(v.i), v.title))
    end
  end
end

function api:property(info, name)
  if info._DATA[name] then
    return info._DATA[name]
  end
  return nil
end

return api
