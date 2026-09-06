#!/bin/sh
# Sestavení hry Tetris z jednoho zdrojáku v ARM64 assembleru.
# Na Apple Silicon musí být i "bezknihovní" program natažen dynamickým
# linkerem, proto se odkazuje na libSystem — žádná její funkce se ale
# nevolá, veškeré I/O jde přes přímé syscally.
set -e
SDK=$(xcrun --show-sdk-path)
clang -c -arch arm64 -o tetris.o tetris.s
ld -o tetris tetris.o -e _start -arch arm64 -lSystem -L "$SDK/usr/lib" \
   -platform_version macos 26.0 26.0
codesign -s - -f tetris
rm -f tetris.o
echo "Hotovo: ./tetris"
