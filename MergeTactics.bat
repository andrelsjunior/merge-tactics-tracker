@echo off
rem Opens the panel: starts the app if it is not running, otherwise brings up
rem the panel of the instance that is.
start "" wscript.exe "%~dp0Start.vbs" show
