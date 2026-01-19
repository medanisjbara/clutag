#!/usr/bin/env lua

local cjson = require "cjson"
local lfs = require "lfs"

-- CONFIG
local HOME = os.getenv("HOME") or "."
local DB_FILE = os.getenv("CLUTAG_DB") or (HOME .. "/.local/state/clutag.json")
local NO_FS = os.getenv("CLUTAG_NO_FS") == "1"

-- util
local function join_path(...)
  local parts = {...}
  return table.concat(parts, "/")
end

local function abspath(p)
  if p:sub(1,1) == "/" then return p end
  if p:sub(1,2) == "~/" then
    return HOME .. p:sub(2)
  end
  return HOME .. "/" .. p
end

local function relpath(p)
  local ap = abspath(p)
  local prefix = HOME .. "/"
  if ap == HOME then return "." end
  if ap:sub(1, #prefix) == prefix then
    return ap:sub(#prefix + 1)
  end
  return ap
end

local function exists(path)
  if NO_FS then return false end
  local attr = lfs.attributes(path)
  return attr ~= nil
end

local function is_dir(path)
  if NO_FS then return false end
  local a = lfs.attributes(path)
  return a and a.mode == "directory"
end

local function is_file(path)
  if NO_FS then return false end
  local a = lfs.attributes(path)
  return a and a.mode == "file"
end

-- Clipboard helper
local function copy_to_clipboard(text)
  local function has_cmd(cmd)
    local ok = os.execute("command -v " .. cmd .. " >/dev/null 2>&1")
    return ok == true or ok == 0
  end

  if has_cmd("xclip") then
    os.execute(string.format("printf %%s %q | xclip -selection clipboard", text))
    return true
  elseif has_cmd("wl-copy") then
    os.execute(string.format("printf %%s %q | wl-copy", text))
    return true
  elseif has_cmd("pbcopy") then
    os.execute(string.format("printf %%s %q | pbcopy", text))
    return true
  else
    print("(No clipboard tool found — path printed instead)")
    print(text)
    return false
  end
end

-- DB load/save
local function load_db()
  local f = io.open(DB_FILE, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  if content == "" then return {} end
  local ok, t = pcall(cjson.decode, content)
  if not ok then
    io.stderr:write("Failed to parse DB JSON, starting with empty DB\n")
    return {}
  end
  return t
end

local function save_db(db)
  local f, err = io.open(DB_FILE, "w")
  if not f then
    io.stderr:write("Failed to write DB file: " .. tostring(err) .. "\n")
    return
  end
  f:write(cjson.encode(db))
  f:close()
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- DB helpers
local function make_entry(path_rel, tag, typ)
  return {
    path = path_rel,
    tag = tag or "unprocessed",
    type = typ or "file",
    created_at = now_iso(),
    updated_at = now_iso()
  }
end

local function db_get(db, rel)
  return db[rel]
end

local function db_set(db, rel, entry)
  entry.updated_at = now_iso()
  db[rel] = entry
end

local function db_remove(db, rel)
  db[rel] = nil
end

-- List children (immediate)
local function list_immediate_children(abs_dir, include_dotfiles)
  local t = {}
  if NO_FS then return t end
  for name in lfs.dir(abs_dir) do
    if name ~= "." and name ~= ".." then
      if not include_dotfiles and name:sub(1,1) == "." then
      else
        table.insert(t, name)
      end
    end
  end
  table.sort(t)
  return t
end

-- Recursively walk descendants
local function collect_descendants(abs_root, include_dotfiles)
  local results = {}
  if NO_FS then return results end
  local function walk(abs_p)
    for name in lfs.dir(abs_p) do
      if name ~= "." and name ~= ".." then
        if not include_dotfiles and name:sub(1,1) == "." then
        else
          local child_abs = abs_p .. "/" .. name
          local child_rel = relpath(child_abs)
          table.insert(results, child_rel)
          if is_dir(child_abs) then walk(child_abs) end
        end
      end
    end
  end
  walk(abs_root)
  return results
end

-- Count processed vs total
local function subtree_counts(db, rel_root)
  local root_prefix = rel_root == "." and "" or (rel_root .. "/")
  local total, processed, review = 0,0,0
  for k,v in pairs(db) do
    if k == rel_root or k:sub(1, #root_prefix) == root_prefix then
      total = total + 1
      if v.tag ~= "unprocessed" and v.tag ~= "review" then processed = processed + 1 end
      if v.tag == "review" then review = review + 1 end
    end
  end
  return processed, total, review
end

-- Depth of relative path
local function path_depth(rel)
  if rel == "." then return 0 end
  local count = 0
  for _ in rel:gmatch("/") do count = count + 1 end
  return count + 1
end

-- UI: Status
local function cmd_status(db, show_review)
  local top = {}
  for k,v in pairs(db) do
    if path_depth(k) == 1 then table.insert(top,k) end
  end
  table.sort(top)
  if #top == 0 then
    print("No top-level entries in DB. Run `clutag init` to populate.")
    return
  end
  for _, rel in ipairs(top) do
    local pcount, tcount, rcount = subtree_counts(db, rel)
    local percent = 0
    if tcount > 0 then percent = math.floor((pcount / tcount)*100 + 0.5) end
    if show_review then
      io.write(string.format("%-30s %3d%% (%d/%d) [%d review]\n", rel, percent, pcount, tcount, rcount))
    else
      io.write(string.format("%-30s %3d%% (%d/%d)\n", rel, percent, pcount, tcount))
    end
  end
end

-- INIT/RESCAN
local function cmd_init(db, include_dotfiles)
  if NO_FS then
    print("CLUTAG_NO_FS=1 set, skipping init/rescan.")
    return
  end

  -- Ensure the root (.) exists in the DB. 
  -- We treat HOME as an inherently "kept" directory to trigger child discovery.
  if not db_get(db, ".") then
    db_set(db, ".", make_entry(".", "keep", "dir"))
    print("Root (.) initialized in database.")
  end

  -- 1. Remove stale non-keep entries, mark missing keep as not-found
  local to_delete = {}
  for k, v in pairs(db) do
    if k ~= "." then -- Never prune the root entry itself
      local abs = abspath(k)
      if not exists(abs) then
        if v.tag == "keep" then
          v.tag = "not-found"
          db_set(db, k, v)
        else
          table.insert(to_delete, k)
        end
      end
    end
  end
  for _, k in ipairs(to_delete) do db_remove(db, k) end

  -- 2. Discovery: For every 'keep' directory, add immediate children if not tracked.
  -- This now includes (.) so new files in HOME are automatically picked up.
  for k, v in pairs(db) do
    if v.tag == "keep" and v.type == "dir" then
      local abs = abspath(k)
      if exists(abs) and is_dir(abs) then
        local children = list_immediate_children(abs, include_dotfiles)
        for _, name in ipairs(children) do
          -- Handle path joining for root (.) vs subdirectories
          local child_rel = (k == ".") and name or (k .. "/" .. name)
          if not db_get(db, child_rel) then
            local child_abs = abspath(child_rel)
            local typ = is_dir(child_abs) and "dir" or "file"
            db_set(db, child_rel, make_entry(child_rel, "unprocessed", typ))
          end
        end
      end
    end
  end

  -- 3. Expand r-keep entries (Recursive Keep)
  for k, v in pairs(db) do
    if v.tag == "r-keep" then
      local abs = abspath(k)
      if exists(abs) and is_dir(abs) then
        local descendants = collect_descendants(abs, include_dotfiles)
        db_set(db, k, make_entry(k, "keep", "dir"))
        for _, child_rel in ipairs(descendants) do
          local child_abs = abspath(child_rel)
          local child_typ = is_dir(child_abs) and "dir" or "file"
          db_set(db, child_rel, make_entry(child_rel, "keep", child_typ))
        end
      else
        db_set(db, k, make_entry(k, "keep", v.type))
      end
    end
  end

  save_db(db)
  print("Rescan complete.")
end

-- Helpers: show DB entry info
local function show_entry(db, rel)
  local e = db_get(db, rel)
  if not e then
    print("No DB entry for:", rel)
    return
  end
  print("Path:", rel)
  print("Type:", e.type)
  print("Tag:", e.tag)
  print("Created:", e.created_at)
  print("Updated:", e.updated_at)
end

local function show_help_review()
  print([[
  Review commands:
  h        Show this help
  c        Copy path  -- copy absolute path to clipboard (non-terminating)
  k        Keep       -- mark entry as keep (recursive or pending)
  r        Review     -- mark as to be reviewed later
  f        Filter     -- mark as filter (children added later locally)
  i        Ignore     -- mark ignore
  d        Delete     -- mark delete
  s        Show info  -- show DB entry info
  n        Next       -- skip this entry
  q        Quit review
  ]])
end

-- Remove descendants from DB
local function remove_descendants(db, rel_root)
  local prefix = rel_root == "." and "" or (rel_root .. "/")
  local to_remove = {}
  for k,_ in pairs(db) do
    if k:sub(1,#prefix) == prefix and k ~= rel_root then
      table.insert(to_remove,k)
    end
  end
  for _, k in ipairs(to_remove) do db_remove(db,k) end
end

-- Review functions
local function recursive_keep(db, rel, include_dotfiles)
  local abs = abspath(rel)
  if NO_FS then
    db_set(db, rel, make_entry(rel, "r-keep", is_dir(abs) and "dir" or "file"))
    return
  end
  if exists(abs) then
    local typ = is_dir(abs) and "dir" or "file"
    db_set(db, rel, make_entry(rel,"keep",typ))
    if typ == "dir" then
      local descendants = collect_descendants(abs, include_dotfiles)
      for _, child_rel in ipairs(descendants) do
        local child_abs = abspath(child_rel)
        local child_typ = is_dir(child_abs) and "dir" or "file"
        db_set(db, child_rel, make_entry(child_rel,"keep",child_typ))
      end
    end
  else
    print("Path does not exist on disk:", rel)
  end
end

local function filter_keep(db, rel, include_dotfiles)
  local abs = abspath(rel)
  if NO_FS then
    db_set(db, rel, make_entry(rel, "filter", "dir"))
    return
  end
  if not exists(abs) then
    print("Path missing:", rel)
    return
  end
  local typ = is_dir(abs) and "dir" or "file"
  db_set(db, rel, make_entry(rel,"keep",typ))
  if typ == "dir" then
    local children = list_immediate_children(abs, include_dotfiles)
    for _, name in ipairs(children) do
      local child_abs = abs .. "/" .. name
      local child_rel = relpath(child_abs)
      if not db_get(db, child_rel) then
        local child_typ = is_dir(child_abs) and "dir" or "file"
        db_set(db, child_rel, make_entry(child_rel,"unprocessed",child_typ))
      end
    end
  end
end

-- Helper: pick a random unprocessed (or review) entry
local function pick_next_random_unprocessed(db, review_mode)
  local candidates = {}
  for k, v in pairs(db) do
    if review_mode then
      if v.tag == "review" then table.insert(candidates, k) end
    else
      if v.tag == "unprocessed" then table.insert(candidates, k) end
    end
  end
  if #candidates == 0 then return nil end
  math.randomseed(os.time() + math.random(1000))
  local pick = candidates[math.random(#candidates)]
  local abs = abspath(pick)
  return pick, abs
end

local function cmd_review(db, target_rel, include_dotfiles)
  if not target_rel then
    print("review requires a path argument.")
    return
  end
  local rel = relpath(target_rel)
  if not db_get(db, rel) then
    local abs = abspath(rel)
    local typ = is_dir(abs) and "dir" or "file"
    db_set(db, rel, make_entry(rel,"unprocessed",typ))
    save_db(db)
  end
  local e = db_get(db, rel)
  if not e then
    print("Failed to add or load entry:", rel)
    return
  end
  print("Reviewing:", rel,"("..(e.tag or "nil")..") -- press h for help.")
  while true do
    io.write("> ")
    local line = io.read()
    if not line then return end
    local cmd = line:match("^%s*(%S+)")
    if not cmd then
    elseif cmd == "h" then show_help_review()
    elseif cmd == "s" then show_entry(db,rel)
    elseif cmd == "c" then
      local abs = abspath(rel)
      local ok = copy_to_clipboard(abs)
      if ok then
        print("Copied to clipboard:", abs)
      end
      -- remain in review mode
    elseif cmd == "q" then
      print("Quitting review for:",rel)
      break
    elseif cmd == "n" then
      print("Skipping:", rel)
      rel, abs = pick_next_random_unprocessed(db, false)
      if not rel then
        print("No more unprocessed entries.")
        break
      end
      print("Next up:", rel)
    elseif cmd == "k" then
      io.write("Keep recursively (y/N)? ")
      local ans = io.read()
      if ans and (ans=="y" or ans=="Y") then
        recursive_keep(db,rel,include_dotfiles)
        save_db(db)
        print("Marked recursively as keep:",rel)
      else
        recursive_keep(db,rel,include_dotfiles)
        save_db(db)
        print("Marked recursively as keep:",rel)
      end
      break
    elseif cmd == "f" then
      filter_keep(db,rel,include_dotfiles)
      save_db(db)
      print("Marked as filter (pending expansion):",rel)
      break
    elseif cmd == "i" or cmd=="d" or cmd=="r" then
      if e.tag == "keep" and e.type=="dir" then
        remove_descendants(db,rel)
      end
      local new_tag = cmd=="i" and "ignore" or cmd=="d" and "delete" or "review"
      db_set(db,rel,make_entry(rel,new_tag,e.type))
      save_db(db)
      print("Tagged",rel,"as",new_tag)
      break
    else
      print("Unknown command (h for help).")
    end
  end
end

local function cmd_shuf(db, include_dotfiles, review_mode)
  local candidates = {}
  for k,v in pairs(db) do
    if review_mode then
      if v.tag=="review" then table.insert(candidates,k) end
    else
      if v.tag=="unprocessed" then table.insert(candidates,k) end
    end
  end
  if #candidates==0 then
    print("No entries to pick.")
    return
  end
  math.randomseed(os.time())
  local pick = candidates[math.random(#candidates)]
  print("Random pick:",pick)
  cmd_review(db,pick,include_dotfiles)
end

local function cmd_next(db, mode, include_dotfiles)
  local candidates = {}
  for k, v in pairs(db) do
    if v.tag == "unprocessed" then table.insert(candidates, k) end
  end

  if #candidates == 0 then print("Clean soul! No unprocessed files.") return end

  table.sort(candidates, function(a, b)
    local da, db_depth = path_depth(a), path_depth(b)
    if da ~= db_depth then
      return da < db_depth -- Strict shallow priority
    end
    return a < b -- Alphabetical tie-breaker
  end)

  local pick = candidates[1]
  print(string.format("[%s MODE] Next item: %s", mode:upper(), pick))
  cmd_review(db, pick, include_dotfiles)
end

-- CLI
local function usage()
  print([[
  clutag.lua COMMAND [ARGS...]
  Commands:
  status [-r]            -- show top-level items (optionally include review)
  init [-d]              -- scan / rescan
  rescan [-d]            -- alias of init
  review [-d] PATH       -- interactive review of PATH
  shuf [-d] [-r]         -- pick random unprocessed (or review with -r)
  next                   -- pick next deep unprocessed
  ]])
end

-- HOME sanity check
local function sanity_check(db)
  if NO_FS then return end
  local total, missing = 0,0
  for k,_ in pairs(db) do
    total = total + 1
    if not exists(abspath(k)) then missing = missing + 1 end
  end
  if total>0 and missing/total>0.8 then
    print("Warning: Most DB entries not found under $HOME. Remote review mode recommended (CLUTAG_NO_FS=1).")
    io.write("Continue anyway? (y/N) ")
    local ans = io.read()
    if not ans or ans:lower()~="y" then os.exit() end
  end
end

-- Entry
local function main()
  local args = {}
  for i=1,#arg do args[i]=arg[i] end
  local cmd = args[1]

  local include_dotfiles, review_mode = false,false
  for i=1,#args do
    if args[i]=="-d" then include_dotfiles=true end
    if args[i]=="-r" then review_mode=true end
  end

  local db = load_db()
  sanity_check(db)

  if cmd=="status" then cmd_status(db,review_mode)
  elseif cmd=="init" or cmd=="rescan" then cmd_init(db,include_dotfiles)
  elseif cmd=="review" then
    local patharg = args[2]
    if not patharg then print("review needs a PATH argument."); return end
    cmd_review(db,patharg,include_dotfiles)
  elseif cmd=="shuf" then cmd_shuf(db,include_dotfiles,review_mode)
  elseif cmd=="next" then cmd_next(db,"shallow",review_mode)
  else usage()
  end
end

main()

-- vim: ft=lua
