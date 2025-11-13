-- SPDX-License-Identifier: MIT
-- Copyright Wes Rupert @wesrupert

---@alias ts_auto_install.Lang string
---@alias ts_auto_install.Bufnr integer
---@alias ts_auto_install.Filetype string

---@alias ts_auto_install.Check
---| boolean
---| table<ts_auto_install.Lang, boolean>
---| fun(bufnr: ts_auto_install.Bufnr, filetype: ts_auto_install.Filetype, lang: ts_auto_install.Lang):boolean

---@alias ts_auto_install.FiletypeCheck
---| boolean
---| table<ts_auto_install.Filetype, boolean>
---| fun(bufnr: ts_auto_install.Bufnr, filetype: ts_auto_install.Filetype, lang: ts_auto_install.Lang):boolean

---@class ts_auto_install.Module
---@field enable ts_auto_install.Check If true, enable the module.
---@field disable? ts_auto_install.Check If false, disable the module.

---@class ts_auto_install.FoldModule : ts_auto_install.Module
---@field start_unfolded? boolean If provided, start with all folds unfolded.

---@class ts_auto_install.SyntaxModule : ts_auto_install.Module
---@field enable ts_auto_install.FiletypeCheck If true, enable additional syntax highlighting.
---@field disable? ts_auto_install.FiletypeCheck If true, disable additional syntax highlighting.

---@class ts_auto_install.Config: ts_auto_install.Module
---@field skip_approval boolean If true, auto-install without prompting.
---@field timeout integer How long to wait on auto install.
---@field fold ts_auto_install.FoldModule
---@field indent ts_auto_install.Module
---@field syntax ts_auto_install.SyntaxModule
---@field additional_syntax_highlighting? table<string> Langs to enable additional syntax highlighting

---@class ts_auto_install.Opts : ts_auto_install.Config
---@field enable? ts_auto_install.Check If true, enable treesitter auto-install.
---@field disable? ts_auto_install.Check If false, disable treesitter auto-install.
---@field skip_approval? boolean If true, auto-install without prompting.
---@field timeout? integer How long to wait on auto install.
---@field fold? ts_auto_install.FoldModule
---@field indent? ts_auto_install.Module
---@field syntax? ts_auto_install.SyntaxModule

local M = {}
local m = {}

---@type ts_auto_install.Config
m.default_config = {
  enable = true,
  disable = false,
  skip_approval = false,
  timeout = 30000,
  fold = { enable = true },
  syntax = { enable = false },
  indent = { enable = false },
}

---Evaluate whether the given module is enabled.
---- A more specific result overrides a more general one.
---- In the case of equal specificity, disabled==true overrides enabled==true.
---@param module ts_auto_install.Module
---@param bufnr ts_auto_install.Bufnr
---@param filetype ts_auto_install.Filetype
---@param lang ts_auto_install.Lang
---@return boolean result
function m.is_module_enabled(module, bufnr, filetype, lang)
  local enable, disable = module.enable, module.disable
  -- Start with nil check as that is the most likely config value.
  if enable == nil then
    if disable ~= nil then
      if disable == false then return true end
      if disable == true then return false end
      if type(disable) == "table" and disable[lang] then return false end
      if type(disable) == "function" and disable(bufnr, filetype, lang) then return false end
    end
    return true
  elseif enable == true or enable == false then
    if disable ~= nil then
      -- Skip: if disable == false then return true end
      if disable == true then return false end
      if type(disable) == "table" and disable[lang] then return false end
      if type(disable) == "function" and disable(bufnr, filetype, lang) then return false end
    end
    return enable
  elseif type(enable) == "table" then
    if disable ~= nil then
      -- Skip: if disable == false then return true end
      -- Skip: if disable == true then return false end
      if type(disable) == "table" and disable[lang] then return false end
      if type(disable) == "function" and disable(bufnr, filetype, lang) then return false end
    end
    return enable[lang] == true
  elseif type(enable) == "function" then
    if disable ~= nil then
      -- Skip: if disable == false then return true end
      -- Skip: if disable == true then return false end
      -- Skip: if type(disable) == "table" and disable[lang] then return false end
      if type(disable) == "function" and disable(bufnr, filetype, lang) then return false end
    end
    return enable(bufnr, filetype, lang) or false
  end
  return true
end

---Get a table from a list of keys.
---@param keys table<string>
---@param value any|fun(key: string):any
---@return table tbl
function m.tbl_from_keys(keys, value)
  local ret = {}
  local fun = type(value) == "function" and value or function () return value end
  for _, k in ipairs(keys) do ret[k] = fun(k) end
  return ret
end

function m.update_cache()
  m.cache = m.cache or {}
  ---@type table<ts_auto_install.Lang, boolean>
  m.cache.available = m.tbl_from_keys(m.treesitter.get_available(), true)
  ---@type table<ts_auto_install.Lang, boolean>
  m.cache.installed = m.tbl_from_keys(m.treesitter.get_installed({ "parsers" }), true)
  ---@type table<ts_auto_install.Lang, boolean>
  m.cache.attempt = m.cache.attempt or m.cache.installed
end

---Clear the auto-install cache.
function M.clear_cache()
  m.update_cache()
  m.cache.attempt = {}
end

---Auto-install grammar for the current lang.
---@param bufnr? ts_auto_install.Bufnr The buffer to install parsers for. Defaults to current buffer.
---@param filetype? ts_auto_install.Filetype The filetype of the buffer. Defaults to current buffer filetype.
---@param lang? string The lang to install. Defaults to the result of |vim.treesitter.language.get_lang|.
---@return ts_auto_install.Lang|nil lang Which language was installed, or nil.
function M.auto_install(bufnr, filetype, lang)
  -- Check if the module is disabled entirely.
  if M.config.enable == false or M.config.disable == true then return nil end

  -- Check if the filetype exists.
  local bn = bufnr or vim.api.nvim_get_current_buf()
  local ft = filetype or vim.bo[bn].filetype
  if not ft or ft == "" then return nil end

  -- Check if grammar can be inferred.
  local parser_lang = lang or vim.treesitter.language.get_lang(ft)
  if not parser_lang then return nil end

  -- Check if the module is enabled for this context.
  if not m.is_module_enabled(M.config, bn, ft, parser_lang) then return nil end

  -- Check if grammar was already auto-installed to short-circuit additional checks.
  local cached_result = m.cache.attempt[parser_lang]
  if cached_result ~= nil then return cached_result and parser_lang or nil end

  -- Check if grammar is available to install.
  -- We'll install it or encounter an error trying; either way don't retry this session.
  m.cache.attempt[parser_lang] = false
  if not m.cache.available[parser_lang] then return nil end

  -- Check if grammar is already installed.
  if m.cache.installed[parser_lang] then
    m.cache.attempt[parser_lang] = true
    m.update_cache()
    return parser_lang
  end

  -- Check if auto-install is approved.
  if not M.config.skip_approval then
    local install_input = vim.fn.input("[TreeSitter] Install grammar for " .. parser_lang .. " (y/N)? ")
    if not install_input:match("[Yy]") then
      vim.notify("Skipping installation of " .. parser_lang .. " grammar for this session.")
      return nil
    end
  end

  -- Install grammar.
  vim.notify("Installing " .. parser_lang .. " grammar...")
  local success, installed = m.treesitter.install({ parser_lang }):pwait(M.config.timeout)
  if not success or not installed then
    vim.notify("Error installing " .. parser_lang .. " grammar.", vim.diagnostic.severity.ERROR)
    return nil
  end

  m.cache.attempt[parser_lang] = true
  m.update_cache()
  vim.notify(parser_lang .. " grammar installed")
  return parser_lang
end

---Run auto-install for all children of the given tree.
---@param bufnr ts_auto_install.Bufnr The buffer to install parsers for
---@param filetype ts_auto_install.Filetype The filetype of the buffer
---@param tree vim.treesitter.LanguageTree|nil The language tree
function m.auto_install_children(bufnr, filetype, tree)
  if not tree then return end

  local function process_injections()
    -- HACK: Nothing exposes the injections table?..grab it directly.
    ---@diagnostic disable-next-line: invisible
    vim.iter(ipairs(tree._injection_query and tree._injection_query._processed_patterns or {}))
      :map(function (_, injection) return injection.directives[1] end)
      :filter(function (directive) return directive[1] == "set!" and directive[2] == "injection.language" end)
      :map(function (directive) return directive[3] end)
      :filter(function (lang) return m.cache.attempt[lang] == nil end)
      :each(function (lang) M.auto_install(bufnr, filetype, lang) end)
  end

  process_injections()
  tree:register_cbs({
    on_changedtree = process_injections,
    ---@param t vim.treesitter.LanguageTree
    on_child_added = function (t)
      for _, child in pairs(t:children()) do M.auto_install_children(bufnr, filetype, child) end
    end,
  }, true)
end

---@param opts? ts_auto_install.Opts
function M.setup(opts)
  -- Check that dependencies are available.
  if vim.fn.executable("tree-sitter") == 0 then
    error("[TSAutoInstall] Unable to start, cannot locate tree-sitter-cli.")
  end
  local treesitter_loaded, treesitter = pcall(require, "nvim-treesitter")
  if not treesitter_loaded then
    error("[TSAutoInstall] Unable to start, nvim-treesitter not found.")
  end
  m.treesitter = treesitter

  -- Initialize plugin.
  ---@type ts_auto_install.Config
  M.config = vim.tbl_deep_extend("force", {}, m.default_config, opts or {})
  m.update_cache()

  if M.config.fold and M.config.fold.start_unfolded then
    vim.o.foldlevelstart = 999
  end

  vim.api.nvim_create_autocmd("FileType", {
    desc = "[TSAutoInstall] auto-install / auto-launch",
    group = vim.api.nvim_create_augroup("TSAutoInstall", { clear = true }),
    callback = function (ev)
      local bufnr, filetype = ev.buf, ev.match
      local lang = M.auto_install(bufnr, filetype)
      if not lang then return end

      if not pcall(vim.treesitter.start, bufnr, lang) then return end
      m.auto_install_children(bufnr, filetype, vim.treesitter.get_parser(bufnr, lang, { error = false }))

      if m.is_module_enabled(M.config.fold, bufnr, filetype, lang) then
        vim.iter(vim.api.nvim_list_wins())
          :filter(function (winnr) return vim.api.nvim_win_get_buf(winnr) == bufnr end)
          :each(function (winnr)
          if M.config.fold.start_unfolded then vim.wo[winnr].foldlevel = 999 end
          vim.wo[winnr].foldmethod = "expr"
          vim.wo[winnr].foldexpr = "v:lua.vim.treesitter.foldexpr()"
        end)
      end

      if m.is_module_enabled(M.config.indent, bufnr, filetype, lang) then
        vim.bo[bufnr].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
      end

      if m.is_module_enabled(M.config.syntax, bufnr, filetype, lang) then
        vim.bo[bufnr].syntax = "on"
      end
    end,
  })
end

return M