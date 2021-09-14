#!/bin/bash
echo Starting do.sh

# exit when any command fails
set -e

git pull
../Beef/IDE/dist/BeefBuild -config=Debug
../Beef/IDE/dist/BeefBuild -config=Release
./build/Debug_Linux64/iStats/iStats
