#!/usr/bin/env bash
# 只读状态检查：pid、内存、HTTP 状态码
set -uo pipefail

APP_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$APP_HOME/config.env"

echo "pidfile: $WEB_PID"
if [[ ! -f "$WEB_PID" ]]; then
  echo "状态: 未运行（无 pidfile）"
  exit 1
fi

PID="$(cat "$WEB_PID" 2>/dev/null)"
if [[ ! "$PID" =~ ^[0-9]+$ ]]; then
  echo "状态: pidfile 无效 ($PID)"
  exit 1
fi
echo "pid: $PID"

if ! kill -0 "$PID" 2>/dev/null; then
  echo "状态: 进程已消失"
  exit 1
fi

RSS_KB="$(awk '/^VmRSS:/{print $2}' "/proc/$PID/status" 2>/dev/null)"
[[ -n "$RSS_KB" ]] && echo "RSS: $((RSS_KB / 1024)) MB"
echo "URL: $BASE_URL/"

CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/" 2>/dev/null)"
[[ -z "$CODE" ]] && CODE="000"
echo "HTTP: $CODE"

case "$CODE" in
  200) echo "状态: 正常"; exit 0 ;;
  202) echo "状态: 供给中（首次下载/解包）"; exit 2 ;;
  000) echo "状态: 无法连接"; exit 1 ;;
  *)   echo "状态: 异常状态码 $CODE"; exit 1 ;;
esac