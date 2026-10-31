#!/usr/bin/env bash
# 幂等启动 VS Code serve-web（PID 文件 + 端口占用检测 + 健康检查）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_HOME="$(dirname "$HERE")"
# shellcheck disable=SC1091
source "$APP_HOME/config.env"

mkdir -p "$RUN_DIR" "$LOG_DIR" "$SERVER_DATA_DIR"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

if [[ -f "$WEB_PID" ]]; then
  oldpid="$(cat "$WEB_PID" 2>/dev/null || true)"
  if [[ -n "${oldpid:-}" ]] && kill -0 "$oldpid" 2>/dev/null; then
    log "已在运行 (pid=$oldpid)，跳过启动"
    exit 0
  fi
  log "清理陈旧 PID 文件 (pid=${oldpid:-空})"
  rm -f "$WEB_PID"
fi

if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$PORT "; then
  log "错误：端口 $PORT 已被其他进程占用，未启动。"
  exit 1
fi

[[ -x "$VSCODE_BIN" ]] || { log "错误：$VSCODE_BIN 不可执行"; exit 1; }
[[ -f "$VSCODE_CLI" ]] || { log "错误：$VSCODE_CLI 不存在"; exit 1; }

# serve-web 1.144.0 支持的参数（实测 --help）：
# --host --port --without-connection-token --accept-server-license-terms
# --disable-telemetry --server-data-dir --default-folder
# 不支持：--disable-updates / --user-data-dir / --extensions-dir
log "启动 serve-web，监听 $HOST:$PORT ..."
ELECTRON_RUN_AS_NODE=1 \
NODE_OPTIONS="--max-old-space-size=$NODE_HEAP_MB" \
"$VSCODE_BIN" "$VSCODE_CLI" serve-web \
  --host "$HOST" --port "$PORT" \
  --without-connection-token \
  --accept-server-license-terms \
  --disable-telemetry \
  --server-data-dir "$SERVER_DATA_DIR" \
  --default-folder "$APP_HOME" \
  >> "$WEB_LOG" 2>&1 &

pid=$!
echo "$pid" > "$WEB_PID"
log "已拉起 pid=$pid，等待健康检查（最多 ${HEALTH_TIMEOUT}s）..."

code="000"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
while (( $(date +%s) < deadline )); do
  if ! kill -0 "$pid" 2>/dev/null; then
    log "进程已退出，日志尾部："
    tail -n 50 "$WEB_LOG"
    rm -f "$WEB_PID"
    exit 1
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BASE_URL/" || true)"
  if [[ "$code" == "200" ]]; then
    log "健康检查通过 (HTTP 200)"
    exit 0
  fi
  sleep 1
done

log "健康检查超时（最后 HTTP=$code），日志尾部："
tail -n 50 "$WEB_LOG"
exit 1
