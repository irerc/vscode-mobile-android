#!/usr/bin/env bash
# 把一个 .vsix 扩展装进 VS Code serve-web 树（离线 / 侧载场景用）
# 用法：install-vsix.sh /path/to/xxx.vsix
#      install-vsix.sh --list            只列已装扩展
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_HOME="$(dirname "$HERE")"
# shellcheck disable=SC1091
source "$APP_HOME/config.env"

if [ "$#" -eq 0 ]; then
  echo "用法：install-vsix.sh "
  echo "      install-vsix.sh --list"
  exit 2
fi

# 统一走 CLI 包装，保证 extensions-dir 与 serve-web 看到的是同一份
cli() { bash "$HERE/code-cli.sh" "$@"; }

if [ "$1" = "--list" ]; then
  exec bash "$HERE/code-cli.sh" --list-extensions --show-versions
fi

VSIX="$1"
if [ ! -f "$VSIX" ]; then
  echo "错误：找不到文件 $VSIX" >&2
  exit 1
fi
case "$VSIX" in
  *.vsix) ;;
  *) echo "错误：$VSIX 不是 .vsix 文件" >&2; exit 1 ;;
esac

mkdir -p "$EXTENSIONS_DIR"
echo "安装 $VSIX"
echo "扩展目录：$EXTENSIONS_DIR"

if cli --install-extension "$VSIX" --force; then
  echo "已安装，当前扩展列表："
  cli --list-extensions --show-versions || true
  exit 0
fi

echo "错误：安装失败，可查看 $WEB_LOG 里的 CLI 输出" >&2
exit 1