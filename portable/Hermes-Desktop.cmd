@echo off
rem Hermes Portable: Hermes Desktop. The portable environment is prepared by the
rem bundled Git Bash in a hidden window; logs go to data\logs\desktop-launcher.log.
setlocal
set "HP_MODE=hidden"
call "%~dp0portable\lib\start.cmd" %*
