#!/usr/bin/env bash
BASE=${BASE:-http://10.42.0.1:8090}
curl -s -X POST "$BASE/demo/lull" >/dev/null && curl -s "$BASE/status"; echo
