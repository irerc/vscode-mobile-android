#!/usr/bin/env bash
# 打开（必要时先启动）VS Code Web 工作台，输出可直接给内置浏览器加载的 URL
# 用法：open-vscode.sh [目录]     例：open-vscode.sh /root/workspace
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_HOME="$(dirname "$HERE")"
# shellcheck disable=SC1091
source "$APP_HOME/config.env"

FOLDER="${1:-/root/workspace}"
if [[ ! -d "$FOLDER" ]]; then
  echo "提示：目录 $FOLDER 不存在，回退到 /root/workspace" >&2
  FOLDER=/root/workspace
fi

bash "$HERE/start-web.sh" || exit 1

# serve-web 的文件夹参数形如 ?folder=
url="$BASE_URL/?folder=$FOLDER"
echo "WORKBENCH_URL=$url"
echo "用内置浏览器（GeckoView）或容器内 curl 打开上面的地址即可。"
exit 0