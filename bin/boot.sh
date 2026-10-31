#!/usr/bin/env bash
# 一键引导：启动 serve-web + 端口转发，并打印手机可用的访问地址。
# 用法：bash bin/boot.sh
set -u
cd "$(dirname "$0")/.." || exit 1

source ./config.env

echo "[1/3] 启动 VS Code serve-web ..."
bash bin/start-web.sh || { echo "start-web.sh 失败"; exit 1; }

echo "[2/3] 启动端口转发 0.0.0.0:8801 -> ${HOST}:${PORT} ..."
if [ -f run/forward.pid ] && kill -0 "$(cat run/forward.pid)" 2>/dev/null; then
  echo "  已在运行 pid=$(cat run/forward.pid)"
else
  nohup node bin/forward.js > logs/forward.log 2>&1 &
  echo $! > run/forward.pid
  sleep 1
  echo "  已启动 pid=$(cat run/forward.pid)"
fi

echo "[3/3] 可用访问地址（填进 App 的“服务器地址”）:"
IP="$(hostname -I 2>/dev/null | awk '{print $NF}')"
[ -n "$IP" ] && echo "  http://$IP:8801/"
echo "  http://127.0.0.1:${PORT}/   （仅当 App 与容器共享回环时可用）"
echo
echo "健康检查: bash bin/status-web.sh"