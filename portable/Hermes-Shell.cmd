@echo off
rem Hermes Portable: the bundled Git Bash with the portable environment.
rem   Hermes-Shell.cmd                   interactive shell (hermes, hermes-portable, npx, uvx ...)
rem   Hermes-Shell.cmd COMMAND [ARGS]    run one command and exit with its status
setlocal
set "HP_AUTORUN="
if "%~1"=="" (set "HP_MODE=console") else (set "HP_MODE=exec")
call "%~dp0portable\lib\start.cmd" %*
