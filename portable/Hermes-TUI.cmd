@echo off
rem Hermes Portable: Hermes TUI in this console window, inside the bundled Git Bash.
rem After the TUI exits the window stays at a Git Bash prompt; type "exit" to close.
setlocal
set "HP_MODE=console"
set "HP_AUTORUN=hermes --tui"
call "%~dp0portable\lib\start.cmd" %*
