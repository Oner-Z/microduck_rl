#!/usr/bin/env bash
# 本机 shell 里 source 了 ROS 2 Humble，PYTHONPATH 指向 python3.10，与本 venv 的 3.12 冲突
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
exec env -u PYTHONPATH uv run "$@"
