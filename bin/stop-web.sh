#!/usr/bin/env bash
# 停止 VS Code serve-web 服务端（只按 run/web.pid 精确停止，不做模糊匹配/整组杀进程）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$APP_HOME/config.env"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

PIDFILE="$WEB_PID"

if [ ! -f "$PIDFILE" ]; then
  log "未找到 pid 文件 $PIDFILE，服务端可能未在运行。"
  exit 0
fi

PID="$(tr -dc '0-9' < "$PIDFILE")"
if [ -z "$PID" ]; then
  log "pid 文件内容无效，删除并退出：$PIDFILE"
  rm -f "$PIDFILE"
  exit 0
fi

if ! kill -0 "$PID" 2>/dev/null; then
  log "pid=$PID 已不存在，清理 pid 文件。"
  rm -f "$PIDFILE"
  exit 0
fi

log "发送 SIGTERM 到 pid=$PID ..."
kill -TERM "$PID" 2>/dev/null

for i in $(seq 1 20); do
  if ! kill -0 "$PID" 2>/dev/null; then
    log "pid=$PID 已优雅退出（等待 ${i}00ms）。"
    rm -f "$PIDFILE"
    exit 0
  fi
  sleep 0.1
done

log "优雅退出超时，发送 SIGKILL 到 pid=$PID ..."
kill -KILL "$PID" 2>/dev/null
sleep 0.5

if kill -0 "$PID" 2>/dev/null; then
  log "错误：pid=$PID 仍存活，请手动检查。"
  exit 1
fi

rm -f "$PIDFILE"
log "已强制停止 pid=$PID，pid 文件已删除。"
exit 0
