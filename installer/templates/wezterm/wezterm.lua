local wezterm = require 'wezterm'
local config = {}
local config_file = assert(wezterm.config_file, 'Load the folder config with --config-file')
local root = config_file:gsub('\\', '/'):match('^(.*)/config/wezterm/[^/]+$')
assert(root and root ~= '', 'WezTerm config must be inside the folder/config/wezterm directory')
local msys2_root
local path_file = io.open(root .. '/config/path/msys2-root.txt', 'r')
if path_file then
  msys2_root = path_file:read('*a'):match('^%s*(.-)%s*$')
  path_file:close()
end
msys2_root = (msys2_root and msys2_root ~= '' and msys2_root or 'install/msys2'):gsub('\\', '/')
if not msys2_root:match('^/') and not msys2_root:match('^%a:/') then
  msys2_root = root .. '/' .. msys2_root
end
config.default_cwd = root
config.term = 'xterm-256color'
config.enable_kitty_graphics = false
config.font_dirs = { root .. '/install/fonts' }
config.font = wezterm.font('Lucida Console')
config.font_size = 10.0
config.keys = {
  {
    key = '+',
    mods = 'CTRL|ALT|SHIFT',
    action = wezterm.action.SpawnTab('CurrentPaneDomain'),
  },
  {
    key = 'LeftArrow',
    mods = 'CTRL|ALT',
    action = wezterm.action.ActivateTabRelative(-1),
  },
  {
    key = 'RightArrow',
    mods = 'CTRL|ALT',
    action = wezterm.action.ActivateTabRelative(1),
  },
}
if wezterm.target_triple:find('windows') then
  local bash = os.getenv('DEVTOOLS_BASH_EXE') or msys2_root .. '/usr/bin/bash.exe'
  bash = bash:gsub('\\', '/')
  config.default_prog = {
    bash,
    '--rcfile', root .. '/config/bash/bashrc', '-i',
  }
  config.set_environment_variables = {
    MSYSTEM = 'UCRT64',
    CHERE_INVOKING = '1',
    MSYS2_PATH_TYPE = 'inherit',
    PD_PLAYGROUND_ROOT = root,
    PD_PLAYGROUND_MSYS2_ROOT = msys2_root,
    DEVTOOLS_BASH_EXE = bash,
    PATH = root .. '/bin;' .. msys2_root .. '/ucrt64/bin;' ..
      msys2_root .. '/usr/bin;' .. (os.getenv('PATH') or ''),
  }
else
  local bash = io.open(root .. '/bin/bash', 'r')
  if bash then
    bash:close()
    config.default_prog = { root .. '/bin/bash', '-i' }
  end
  config.set_environment_variables = {
    PD_PLAYGROUND_ROOT = root,
    PATH = root .. '/bin:' .. (os.getenv('PATH') or '/usr/bin:/bin'),
  }
end
return config
