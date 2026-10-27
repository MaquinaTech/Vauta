#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
# usage: dl_one.sh <archive id> <dest>  -- resumable download with retries (archive.org nodes are sometimes slow)
id="$1"; dest="$2"
name=$(python3 -I -c "
import json,urllib.request,sys
d=json.load(urllib.request.urlopen('https://archive.org/metadata/$id'))
print(max((f for f in d['files'] if f['name'].lower().endswith('.mp3') and f.get('length')),key=lambda f:float(f['length']))['name'])")
url="https://archive.org/download/$id/$(python3 -I -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$name")"
for i in $(seq 1 60); do
  curl -sS -L -C - --connect-timeout 20 --speed-limit 100000 --speed-time 20 -o "$dest.part" "$url" && mv "$dest.part" "$dest" && break
  sleep 2
done
