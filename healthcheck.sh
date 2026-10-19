#!/bin/bash
# Docker HEALTHCHECK: TS_PORT may come from ts.ini, so read the runtime settings
# shellcheck source=/dev/null
[ -e /TS/runtime.env ] && . /TS/runtime.env
curl -fsS --max-time 5 "http://localhost:${TS_PORT:-8090}/echo" > /dev/null || exit 1
