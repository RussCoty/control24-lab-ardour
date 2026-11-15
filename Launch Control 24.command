#!/bin/zsh
cd "${0:A:h}" || exit 1
echo 'Control|24 Lab — open http://127.0.0.1:8124 in your browser.'
echo 'Press Control-C in this window to stop the local bridge.'
exec python3 -m control24.server --osc-port 9124
