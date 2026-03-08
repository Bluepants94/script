#!/usr/bin/env bash
set -u

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/docker-compose-projects.list"
LOG_FILE="${SCRIPT_DIR}/docker-compose-auto-update.log"

# 同时输出到终端和日志
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date '+%F %T')] ===== docker-compose auto update start ====="

# 检查 docker
if ! command -v docker >/dev/null 2>&1; then
  echo "[$(date '+%F %T')] ERROR: docker 未安装或不在 PATH 中"
  exit 1
fi

# 检查配置文件
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[$(date '+%F %T')] ERROR: 配置文件不存在: $CONFIG_FILE"
  exit 1
fi

# 优先使用 docker compose，其次 docker-compose
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "[$(date '+%F %T')] ERROR: 未找到 docker compose / docker-compose"
  exit 1
fi

success_count=0
fail_count=0
skip_count=0

while IFS= read -r line || [[ -n "$line" ]]; do
  # 去掉前后空白
  project_dir="$(echo "$line" | sed 's/^\s*//;s/\s*$//')"

  # 忽略空行和注释
  [[ -z "$project_dir" || "$project_dir" =~ ^# ]] && continue

  echo "[$(date '+%F %T')] ---- 处理目录: $project_dir ----"

  if [[ ! -d "$project_dir" ]]; then
    echo "[$(date '+%F %T')] WARN: 目录不存在，跳过: $project_dir"
    ((skip_count++))
    continue
  fi

  # 判断 compose 文件是否存在
  if [[ ! -f "$project_dir/docker-compose.yml" && \
        ! -f "$project_dir/docker-compose.yaml" && \
        ! -f "$project_dir/compose.yml" && \
        ! -f "$project_dir/compose.yaml" ]]; then
    echo "[$(date '+%F %T')] WARN: 未找到 compose 文件，跳过: $project_dir"
    ((skip_count++))
    continue
  fi

  # 更新：pull + up -d
  if (cd "$project_dir" && $COMPOSE_CMD pull && $COMPOSE_CMD up -d); then
    echo "[$(date '+%F %T')] OK: 更新成功: $project_dir"
    ((success_count++))
  else
    echo "[$(date '+%F %T')] ERROR: 更新失败: $project_dir"
    ((fail_count++))
  fi

done < "$CONFIG_FILE"

# 清理悬空镜像（dangling images）
echo "[$(date '+%F %T')] 开始清理悬空镜像..."
if docker image prune -f; then
  echo "[$(date '+%F %T')] OK: 悬空镜像清理完成"
else
  echo "[$(date '+%F %T')] ERROR: 悬空镜像清理失败"
fi

echo "[$(date '+%F %T')] 汇总: success=$success_count, fail=$fail_count, skip=$skip_count"
echo "[$(date '+%F %T')] ===== docker-compose auto update end ====="
