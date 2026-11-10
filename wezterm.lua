local wezterm = require 'wezterm'
local config = {}
local root = wezterm.config_dir:gsub('\\', '/') .. '/../..'
local msys2_root = os.getenv('PD_MSYS2_ROOT')
if not msys2_root then
  local path_file = io.open(root .. '/config/path/msys2-root.txt', 'r')
  if path_file then
    msys2_root = path_file:read('*a'):match('^%s*(.-)%s*$')
    path_file:close()
  end
end
msys2_root = (msys2_root or (root .. '/install/msys2')):gsub('\\', '/')
config.term = 'xterm-256color'
config.font_dirs = { root .. '/install/fonts' }
config.font = wezterm.font('JetBrainsMono Nerd Font')
if wezterm.target_triple:find('windows') then
  config.default_prog = {
    msys2_root .. '/usr/bin/bash.exe',
    '--rcfile', root .. '/config/bash/bashrc', '-i',
  }
  config.set_environment_variables = {
    MSYSTEM = 'UCRT64',
    CHERE_INVOKING = '1',
    MSYS2_PATH_TYPE = 'inherit',
    PATH = root .. '/bin;' .. msys2_root .. '/ucrt64/bin;' ..
      msys2_root .. '/usr/bin;' .. (os.getenv('PATH') or ''),
  }
else
  config.default_prog = { root .. '/bin/bash', '-i' }
  config.set_environment_variables = {
    PATH = root .. '/bin:' .. (os.getenv('PATH') or '/usr/bin:/bin'),
  }
end
return config
