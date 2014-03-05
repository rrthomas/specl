-- Specification testing framework.
-- Written by Gary V. Vaughan, 2013
--
-- Copyright (c) 2013-2014 Gary V. Vaughan
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 3, or (at your option)
-- any later version.
--
-- This program is distributed in the hope that it will be useful, but
-- WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
-- General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; see the file COPYING.  If not, write to the
-- Free Software Foundation, Fifth Floor, 51 Franklin Street, Boston,
-- MA 02111-1301, USA.


local matchers   = require "specl.matchers"
local std        = require "specl.std"
local util       = require "specl.util"


from std.string import slurp, split


--[[ ================================= ]]--
--[[ Compatibility between 5.1 and 5.2 ]]--
--[[ ================================= ]]--


-- From http://lua-users.org/lists/lua-l/2010-06/msg00313.html
setfenv = setfenv or function(f, t)
  local name
  local up = 0
  repeat
    up = up + 1
    name = debug.getupvalue (f, up)
  until name == '_ENV' or name == nil
  if name then
    debug.upvaluejoin (f, up, function () return name end, 1)
    debug.setupvalue (f, up, t)
  end
  return f
end


loadstring = loadstring or function (chunk, chunkname)
  return load (chunk, chunkname)
end



--[[ ================= ]]--
--[[ Helper Functions. ]]--
--[[ ================= ]]--


-- Append non-nil ARG to HOLDER.accumulated.
-- If ARG is a table, values for all keys in ARG are accumulated in
-- equivalent HOLDER keys.
-- Used to collect output from formatter calls, to be saved for footer.
local function accumulator (self, arg)
  if arg ~= nil then
    if type (arg) == "table" then
      self.accumulated = self.accumulated or {}
      for k, v in pairs (arg) do
        self.accumulated[k] = (self.accumulated[k] or "") .. tostring(v)
      end
    else
      self.accumulated = (self.accumulated or "") .. arg
    end
  end
end


-- Access to core functions that we override to run within nested
-- function environments.
local core = {
  load       = load,
  loadfile   = loadfile,
  loadstring = loadstring,
  require    = require,
}


-- Intercept functions that normally execute in the global environment,
-- and run them in the example block environment to capture side-effects
-- correctly.
local function initenv (state, env)
  -- Don't let _G (or _ENV) assignments leak into outer tables.
  rawset (env, "_G", env)
  if env._ENV then rawset (env, "_ENV", env) end

  for _, intercept in pairs { "load", "loadfile", "loadstring" } do
    env[intercept] = function (...)
      local fn = core[intercept] (...)
      return function ()
        setfenv (fn, env)
        return fn ()
      end
    end
  end

  -- For a not-yet-{pre,}loaded module, try to find it on `package.path`
  -- and load it with `loadstring`, so that any symbols that leak out
  -- (the side effects) are cached, and then copied into the example
  -- block environment, for this and subsequent examples that load it.
  env.require = function (m)
    local errmsg, import, loaded, loadfn

    -- We can have a spec_helper.lua in each spec directory, so don't
    -- cache the side effects of a random one!
    if m ~= "spec_helper" then
      loaded, loadfn = package.loaded[m], package.preload[m]
      import = state.sidefx[m]
    end

    if import == nil then
      -- Not preloaded, so search package.path.
      if loadfn == nil then
        std.package.mappath (env.package.path, function (path)
          local filename = path:gsub ("%?", (m:gsub ("%.", "/")))
          local s = slurp (filename)
          if s ~= nil then
            loadfn, errmsg = loadstring (s, filename)
	    return "break"
          end
        end)
      end
      if errmsg ~= nil then return error (errmsg) end

      -- Capture side effects.
      if loadfn ~= nil then
        import = setmetatable ({}, {__index = env})
        setfenv (loadfn, import)
        loaded = loadfn ()
      end
    end

    -- Import side effects into example block environment.
    for name, value in pairs (import or {}) do
      env[name] = value
    end

    -- A map of module name to global symbol side effects.
    -- We keep track of these so that they can be injected into an
    -- execution environment that requires a module.
    state.sidefx[m] = import
    package.loaded[m] = package.loaded[m] or loaded or nil

    -- Use the system require if loadstring failed (e.g. C module).
    if loadfn == nil then
      local save = std.table.clone (package)
      -- temporarily use environment search paths
      package.path, package.cpath = env.package.path, env.package.cpath

      setfenv (core.require, env)
      package.loaded[m] = core.require (m)

      package.path, package.cpath = save.path, save.cpath
    end

    return package.loaded[m]
  end
end



--[[ ============= ]]--
--[[ Spec' Runner. ]]--
--[[ ============= ]]--


local run_examples, run_contexts, run


-- Run each of EXAMPLES under ENV in order.
function run_examples (state, examples, descriptions, env)
  local formatter = state.opts.formatter

  local block = function (example, blockenv)
    local fenv   = util.cow (blockenv)
    fenv.expect  = matchers.expect
    fenv.pending = matchers.pending

    initenv (state, fenv)

    if examples.before ~= nil then
      setfenv (examples.before.example, fenv)
      examples.before.example ()
    end

    -- There is only one, otherwise we can't maintain example order.
    local description, definition = next (example)

    local keepgoing = true
    if definition.example then
      local filters = state.spec.filters

      -- An example, execute it in a clean new sub-environment; as long
      -- as there are no filters, or the filters for the source line of
      -- this definition is true.

      if filters == nil or filters[definition.line] == true then
        table.insert (descriptions, description)

        matchers.init ()

        setfenv (definition.example, fenv)
        definition.example ()

        local status = std.table.merge ({
          filename = state.spec.filename,
	  line     = definition.line,
        }, matchers.status ())
	formatter:accumulator (formatter.expectations (status, descriptions, state.opts))

        table.remove (descriptions)

        if state.opts.fail_fast then
          for _, expectation in ipairs (status.expectations) do
            if expectation.status == false then keepgoing = false end
          end
        end
      end

    else
      -- A nested context, revert back to run_contexts.
      if run_contexts (state, example, descriptions, fenv) == false then
        keepgoing = false
      end
    end

    if examples.after ~= nil then
      setfenv (examples.after.example, fenv)
      examples.after.example ()
    end

    -- Now after's have executed, return false for --fail-fast.
    if keepgoing == false then return false end
  end

  for _, example in ipairs (examples) do
    -- Also, run every block in a sub-environment, so that before() and
    -- after() calls from one block don't affect any other.
    local fenv = util.cow (env)
    setfenv (block, fenv)

    -- Return false immediately for --fail-fast.
    if block (example, fenv) == false then
      return false
    end
  end
end


-- Run each of CONTEXTS under ENV in order.
function run_contexts (state, contexts, descriptions, env)
  local formatter = state.opts.formatter
  for description, examples in pairs (contexts) do
    table.insert (descriptions, description)
    formatter:accumulator (formatter.spec (descriptions, state.opts))
    local status = run_examples (state, examples, descriptions, env)
    table.remove (descriptions)

    -- Return false immediately for a failed expectation if --fail-fast
    -- was given.
    if status == false then return false end
  end
end


-- Run `specs` from `state`.
function run (state)
  local formatter = state.opts.formatter

  state.sidefx = {}
  formatter.accumulator = accumulator -- so we can pass self with ':'

  -- Run compiled specs, in order.
  formatter:accumulator (formatter.header (matchers.stats, state.opts))
  for _, spec in ipairs (state.specs) do
    state.spec = spec

    -- Return false immediately for a failed expectation if --fail-fast
    -- was given.
    if run_examples (state, spec.examples, {}, state.sandbox) == false then
      break
    end
  end

  formatter.footer (matchers.stats, formatter.accumulated, state.opts)
  return matchers.stats.fail ~= 0 and 1 or 0
end



--[[ ----------------- ]]--
--[[ Public Interface. ]]--
--[[ ----------------- ]]--

local M = {
  run       = run,
}


return M