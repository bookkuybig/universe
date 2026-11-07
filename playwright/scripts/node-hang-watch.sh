#!/usr/bin/env bash
# CI-only debug aid: watch the localnet minotari_node and, when its HTTP
# get_tip_info stops answering, dump every thread's stack with gdb.
# Usage: node-hang-watch.sh <out-dir>
set -u
out=$1; mkdir -p "$out"
fails=0; dumps=0; last_pid=""
log() { echo "$(date -u +%H:%M:%S) $*" >> "$out/watch.log"; }

while sleep 10; do
  all=$(pgrep -f '[m]inotari_node.*com.tari.universe.test' | tr '\n' ' ')
  # More than one means runner pods share a PID namespace (cross-job pkill risk).
  [ "$(echo $all | wc -w)" -gt 1 ] && log "multiple node pids: $all"
  pid=$(echo $all | cut -d' ' -f1)
  [ -z "$pid" ] && { fails=0; continue; }
  if [ "$pid" != "$last_pid" ]; then log "node pid=$pid"; last_pid=$pid; dumps=0; fails=0; fi
  port=$(tr '\0' '\n' < /proc/$pid/cmdline 2>/dev/null | sed -n 's/.*http_wallet_query_service.port=//p')
  [ -z "$port" ] && continue
  if tip=$(curl -s -m 10 "http://127.0.0.1:$port/get_tip_info"); then
    [ $fails -gt 0 ] && log "recovered after $fails failures"
    fails=0
    log "ok $(echo "$tip" | grep -o '"best_block_height":[0-9]*')"
  else
    fails=$((fails + 1)); log "get_tip_info failed ($fails)"
    if [ $fails -ge 3 ] && [ $dumps -lt 2 ]; then
      dumps=$((dumps + 1)); f="$out/stack-$pid-$dumps.txt"
      log "dumping stacks to $f"
      { cat /proc/$pid/status; echo; top -H -b -n1 -p "$pid" | head -60; echo; } > "$f" 2>&1
      sudo gdb -p "$pid" -batch -ex 'set pagination off' -ex 'thread apply all bt' >> "$f" 2>&1
      sleep 50  # second dump ~60s later shows which threads never moved
    fi
  fi
done
