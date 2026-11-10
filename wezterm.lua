local wezterm = require 'wezterm'
local config = {}
local root = wezterm.config_dir:gsub('\\', '/') .. '/../..'
config.term = 'xterm-256color'
config.font_dirs = { root .. '/install/fonts' }
config.font = wezterm.font('JetBrainsMono Nerd Font')
if wezterm.target_triple:find('windows') then
  config.default_prog = {
    root .. '/install/msys2/usr/bin/bash.exe',
    '--rcfile', root .. '/config/bash/bashrc', '-i',
  }
  config.set_environment_variables = {
    MSYSTEM = 'UCRT64',
    CHERE_INVOKING = '1',
    MSYS2_PATH_TYPE = 'inherit',
    PATH = root .. '/bin;' .. root .. '/install/msys2/ucrt64/bin;' ..
      root .. '/install/msys2/usr/bin;' .. (os.getenv('PATH') or ''),
  }
else
  config.default_prog = { root .. '/bin/bash', '-i' }
  config.set_environment_variables = {
    PATH = root .. '/bin:' .. (os.getenv('PATH') or '/usr/bin:/bin'),
  }
end
return config
