#!/usr/bin/env bash
# Ждёт, пока все загрузки Kpub завершатся (или пройдёт $1 секунд), и печатает сводку.
J="$HOME/Library/Application Support/Kpub/downloads.json"
LIMIT="${1:-560}"
summary() {
  python3 -I -c "
import json,sys
jobs=json.load(open(sys.argv[1]))
for x in jobs:
    print(x['status'], 'S%sE%s'%(x.get('seasonNumber'),x.get('episodeNumber')), str(round(x.get('progress',0)*100))+'%', x.get('speedText') or '', x.get('outputSize') or '', x.get('note') or '', x.get('errorMessage') or '')
print('DONE' if all(x['status'] in ('completed','failed','paused') for x in jobs) else 'RUNNING')
" "$J"
}
start=$(date +%s)
while :; do
  out=$(summary)
  if echo "$out" | tail -1 | grep -q DONE; then break; fi
  [ $(( $(date +%s) - start )) -ge "$LIMIT" ] && break
  sleep 30
done
summary
