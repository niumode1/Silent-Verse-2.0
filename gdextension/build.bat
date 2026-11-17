@echo off
setlocal

set "VS=C:\Program Files\Microsoft Visual Studio\18\Community"
if not exist "%VS%\VC\Auxiliary\Build\vcvars64.bat" (
  set "VS=E:\Program Files\Microsoft Visual Studio\18\Community"
)
if not exist "%VS%\VC\Auxiliary\Build\vcvars64.bat" (
  echo ERROR: vcvars64.bat not found
  exit /b 1
)

set "CMAKE=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set "NINJA=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
set "PROJ=%~dp0.."
set "BUILD=%PROJ%\build\gdextension"

call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo ERROR: vcvars64 failed
  exit /b 1
)

"%CMAKE%" -S "%PROJ%\gdextension" -B "%BUILD%" -G Ninja ^
  -DCMAKE_MAKE_PROGRAM="%NINJA%" -DCMAKE_BUILD_TYPE=Release
if errorlevel 1 exit /b 1

"%NINJA%" -C "%BUILD%"
exit /b %errorlevel%
