-- This files holds code for scanning the filesystem to build the tree.

local vim = vim
local renderer = require("neo-tree.ui.renderer")
local utils = require("neo-tree.utils")
local scan = require('plenary.scandir')
local filter_external = require("neo-tree.sources.filesystem.lib.filter_external")
local Job = require("plenary.job")

local M = {}

local function sort_items(a, b)
  if a.type == b.type then
    return a.path < b.path
  else
    return a.type < b.type
  end
end

local function deep_sort(tbl)
  table.sort(tbl, sort_items)
  for _, item in pairs(tbl) do
    if item.type == 'directory' then
      deep_sort(item.children)
    end
  end
end


local create_item, set_parents

function create_item(context, path, _type)
  local parent_path, name = utils.split_path(path)
  if _type == nil then
    local stat = vim.loop.fs_stat(path)
    _type = stat and stat.type or 'unknown'
  end
  local item = {
    id = path,
    name = name,
    parent_path = parent_path,
    path = path,
    type = _type,
  }
  if item.type == 'link' then
    item.is_link = true
    item.link_to = vim.loop.fs_realpath(path)
    if item.link_to ~= nil then
        item.type = vim.loop.fs_stat(item.link_to).type
    end
  end
  if item.type == 'directory' then
    item.children = {}
    item.loaded = false
    context.folders[path] = item
    if context.state.search_pattern then
      table.insert(context.state.default_expanded_nodes, item.id)
    end
  else
    item.ext = item.name:match("%.(%w+)$")
  end
  set_parents(context, item)
  return item
end

-- function to set (or create) parent folder
function set_parents(context, item)
  -- we can get duplicate items if we navigate up with open folders
  -- this is probably hacky, but it works
  if context.existing_items[item.id] then
    return
  end
  if not item.parent_path then
    return
  end
  local parent = context.folders[item.parent_path]
  if parent == nil then
    local success
    success, parent = pcall(create_item, context, item.parent_path, 'directory')
    if not success then
      print("error creating item for ", item.parent_path)
    end
    context.folders[parent.id] = parent
    set_parents(context, parent)
  end
  table.insert(parent.children, item)
  context.existing_items[item.id] = true
end


-- this is the actual work of collecting items
-- at least if we are not searching...
local function do_scan(context, path_to_scan)
  local state = context.state
  local paths_to_load = context.paths_to_load
  local folders = context.folders

  scan.scan_dir_async(path_to_scan, {
    hidden = state.show_hidden or false,
    respect_gitignore = state.respect_gitignore or false,
    search_pattern = state.search_pattern or nil,
    add_dirs = true,
    depth = 1,
    on_insert = function(path, _type)
      local success, item = pcall(create_item, context, path, _type)
      if not success then
        print("error creating item for ", path)
      end
    end,
    on_exit = vim.schedule_wrap(function()
      local scanned_folder = folders[path_to_scan]
      if scanned_folder then
        scanned_folder.loaded = true
      end
      -- check to see if there are more folders to load
      local next_path = nil
      while #paths_to_load > 0 and not next_path do
        next_path = table.remove(paths_to_load)
        -- ensure that the path is still valid
        local success, result = pcall(vim.loop.fs_stat, next_path)
        if success and result then
          -- ensure that it is not already loaded
          local existing = folders[next_path]
          if existing and existing.loaded then
            next_path = nil
          end
        else
          -- if the path doesn't exist, skip it
          next_path = nil
        end
      end

      if next_path then
        do_scan(context, next_path)
      else
        context.job_complete()
      end
    end)
  })
end

M.get_items_async = function(state, parent_id, path_to_reveal, callback)
  local context = {
    state = state,
    folders = {},
    existing_items = {},
  }

  -- Create root folder
  local root = create_item(context, parent_id or state.path, 'directory')
  root.name = vim.fn.fnamemodify(root.path, ':~')
  root.loaded = true
  root.search_pattern = state.search_pattern
  context.folders[root.path] = root
  state.default_expanded_nodes = { state.path }

  context.job_complete = function()
    deep_sort(root.children)
    if parent_id then
      -- lazy loading a child folder
      renderer.show_nodes(root.children, state, parent_id)
    else
      -- full render of the tree
      state.before_render(state)
      renderer.show_nodes({ root }, state)
    end
    if callback then
      callback()
    end
  end

  if state.search_pattern then
    -- Use the external command because the plenary search is slow
    filter_external.find_files({
      filters = state.filters,
      find_command = state.find_command,
      limit = state.search_limit or 50,
      path = root.path,
      term = state.search_pattern,
      on_insert = function(err, path)
        if err and #err > 0 then
          print(err, path)
        else
          create_item(context, path)
        end
      end,
      on_exit = vim.schedule_wrap(context.job_complete)
    })
  else
    -- In the case of a refresh or navigating up, we need to make sure that all
    -- open folders are loaded.
    local path = parent_id or state.path
    context.paths_to_load = {}
    if parent_id == nil then
      if state.tree then
        context.paths_to_load = renderer.get_expanded_nodes(state.tree)
      end
      if path_to_reveal then
        -- be sure to load all of the folders leading up to the path to reveal
        local path_to_reveal_parts = utils.split(path_to_reveal, utils.path_separator)
        table.remove(path_to_reveal_parts) -- remove the file name
        -- add all parent folders to the list of paths to load
        utils.reduce(path_to_reveal_parts, "", function(acc, part)
          local current_path = acc .. utils.path_separator .. part
          if #current_path > #path then -- within current root
            table.insert(context.paths_to_load, current_path)
            table.insert(state.default_expanded_nodes, current_path)
          end
          return current_path
        end)
        context.paths_to_load = utils.unique(context.paths_to_load)
      end
    end
    do_scan(context, parent_id or state.path)
  end
end

return M