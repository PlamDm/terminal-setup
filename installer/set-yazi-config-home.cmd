@echo off
if not defined PD_ROOT for %%I in ("%~dp0.") do set "PD_ROOT=%%~fI"
set "PD_PLAYGROUND_ROOT=%PD_ROOT%"
set "PD_YAZI_CONFIG_FILE=%PD_ROOT%\config\path\yazi-config-home.txt"
set "YAZI_CONFIG_HOME=%PD_ROOT%\config\yazi"
set "PD_SAVED_YAZI_CONFIG_HOME="
if exist "%PD_YAZI_CONFIG_FILE%" for /f "usebackq delims=" %%I in ("%PD_YAZI_CONFIG_FILE%") do set "PD_SAVED_YAZI_CONFIG_HOME=%%I"
if not defined PD_SAVED_YAZI_CONFIG_HOME goto terminal_setup_yazi_config_check
if not exist "%PD_SAVED_YAZI_CONFIG_HOME%\yazi.toml" goto terminal_setup_yazi_config_check
set "YAZI_CONFIG_HOME=%PD_SAVED_YAZI_CONFIG_HOME%"

:terminal_setup_yazi_config_check
if exist "%YAZI_CONFIG_HOME%\yazi.toml" goto terminal_setup_yazi_config_ready

:terminal_setup_configure_yazi
if not exist "%PD_ROOT%\configure-paths.ps1" (
  echo terminal-setup: configure-paths.ps1 is missing from "%PD_ROOT%". 1>&2
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PD_ROOT%\configure-paths.ps1" -PlaygroundRoot "%PD_ROOT%" -EnsureYaziConfig
if errorlevel 1 exit /b 1
set "YAZI_CONFIG_HOME=%PD_ROOT%\config\yazi"
set "PD_SAVED_YAZI_CONFIG_HOME="
if exist "%PD_YAZI_CONFIG_FILE%" for /f "usebackq delims=" %%I in ("%PD_YAZI_CONFIG_FILE%") do set "YAZI_CONFIG_HOME=%%I"
if not exist "%YAZI_CONFIG_HOME%\yazi.toml" (
  echo terminal-setup: no valid Yazi config was selected. 1>&2
  exit /b 1
)

:terminal_setup_yazi_config_ready
set "PD_SAVED_YAZI_CONFIG_HOME="
exit /b 0
