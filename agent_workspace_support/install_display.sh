#!/bin/bash
apt-get update
apt-get install -y xorg
echo 'export DISPLAY=:0' >> ~/.bashrc
reboot