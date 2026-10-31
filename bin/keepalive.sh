#!/usr/bin/env bash
# keepalive.sh —— 守护容器内的 VS Code serve-web 进程。
# 只用 PID 文件判定生命周期，绝不按命令行模式匹配杀进程。
set -u

APP_HOME="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
. "$APP_HOME/config.env"

mkdir -p "$RUN_DIR" "$LOG_DIR"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$KEEPALIVE_LOG"; }

pid_alive() {
  local f="$1"
  [ -f "$f" ] || return 1
  local p
  p="$(cat "$f" 2>/dev/null)"
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -d "/proc/$p" ] || return 1
  return 0
}

http_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/" 2>/dev/null
}

restarts=0
while :; do
  if pid_alive "$WEB_PID"; then
    code="$(http_code)"
    if [ "$code" != "200" ] && [ "$code" != "202" ]; then
      log "pid $(cat "$WEB_PID") alive but HTTP=$code"
    fi
  else
    log "server pid missing/dead, restarting (restart #$((restarts + 1)) this run)"
    bash "$APP_HOME/bin/start-web.sh" >>"$KEEPALIVE_LOG" 2>&1
    restarts=$((restarts + 1))
    if [ "$restarts" -gt "$KEEPALIVE_MAX_RESTARTS_PER_HOUR" ]; then
      log "restart budget exhausted ($KEEPALIVE_MAX_RESTARTS_PER_HOUR), backing off 30 min"
      sleep 1800
      restarts=0
    fi
  fi
  sleep "$KEEPALIVE_INTERVAL"
done