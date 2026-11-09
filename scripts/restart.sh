#!/bin/zsh
launchctl kickstart -k gui/$(id -u)/com.user.dockmiddlequit 2>&1
sleep 1
cat /tmp/dock-middle-quit.log | tail -n 20
