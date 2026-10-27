@echo off
rem Hermes Portable launcher core, called by the top-level Hermes-*.cmd files.
rem HP_MODE: console = interactive bundled Git Bash in this console window
rem          exec    = run the given command in the portable environment and exit
rem          hidden  = Hermes Desktop, environment prepared by a hidden mintty
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0..\..") do set "HP_ROOT=%%~fI"
if not exist "%HP_ROOT%\portable\paths.cmd" (
  echo [Hermes Portable] portable\paths.cmd is missing - this folder is not a complete build.
  pause
  exit /b 2
)
call "%HP_ROOT%\portable\paths.cmd"
set "HP_GIT=%HP_ROOT%\%HP_GIT_REL%"
if not exist "%HP_GIT%\usr\bin\bash.exe" (
  echo [Hermes Portable] bundled Git Bash not found: "%HP_GIT%"
  pause
  exit /b 2
)

rem Remember the real profile, then keep host settings away from bash startup.
rem portable/lib/scrub.sh removes everything else that is not allowlisted.
set "HP_REAL_USERPROFILE=%USERPROFILE%"
set "HP_REAL_APPDATA=%APPDATA%"
set "HP_REAL_LOCALAPPDATA=%LOCALAPPDATA%"
set "HP_REAL_PATH=%PATH%"
set "HP_LAUNCH_CWD=%CD%"
for %%V in (BASH_ENV ENV SHELLOPTS BASHOPTS CDPATH GLOBIGNORE PROMPT_COMMAND HISTFILE INPUTRC HOME MSYS MSYS2_PATH_TYPE MSYS2_ARG_CONV_EXCL MSYS_NO_PATHCONV HP_SCRUBBED) do set "%%V="
set "MSYSTEM=MINGW64"
set "CHERE_INVOKING=1"
set "PATH=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\Wbem"

if /i "%HP_MODE%"=="hidden" goto hidden
if /i "%HP_MODE%"=="exec" goto exec
title Hermes Portable
"%HP_GIT%\usr\bin\bash.exe" --rcfile "%HP_ROOT%\portable\lib\bashrc" -i
exit /b %ERRORLEVEL%

:exec
"%HP_GIT%\usr\bin\bash.exe" --noprofile --norc "%HP_ROOT%\portable\lib\run.sh" %*
exit /b %ERRORLEVEL%

:hidden
start "" "%HP_GIT%\usr\bin\mintty.exe" --window hide --exec /usr/bin/bash --noprofile --norc "%HP_ROOT%\portable\lib\launch-desktop.sh" %*
exit /b 0
