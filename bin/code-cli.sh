#!/usr/bin/env bash
# 在容器内调用 VS Code 命令行（打开文件/文件夹、装扩展等）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$APP_HOME/config.env"

if [ "$#" -eq 0 ]; then
  echo "用法：code-cli.sh <VS Code CLI 参数...>"
  echo "示例：code-cli.sh --version"
  echo "      code-cli.sh --list-extensions"
  echo "      code-cli.sh --install-extension <vsix路径>"
  exit 2
fi

if [ ! -x "$VSCODE_BIN" ]; then
  echo "错误：找不到可执行的 VS Code CLI：$VSCODE_BIN" >&2
  exit 1
fi

# serve-web 不使用 --user-data-dir/--extensions-dir，CLI 侧用受支持的全局参数
exec "$VSCODE_BIN" \
  --cli-data-dir "$DATA/cli" \
  --extensions-dir "$EXTENSIONS_DIR" \
  --user-data-dir "$USER_DATA_DIR" \
  "$@"
