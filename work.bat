@echo off

pushd "%~dp0"

REM Windows Terminal with a cmd tab and a neovim tab
start wt --profile "cmd" -d . cmd /k "jai build.jai" ; new-tab --profile "Neovim" -d . nvim -p "source/main.jai"

REM Open the debugger
start remedybg bin\debug.rdbg

popd
