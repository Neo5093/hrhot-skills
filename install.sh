#!/usr/bin/env bash
#
# HRHOT Agent Skill 安装器
#
# 行为规格（与方案文档 5.7 一致）：
#   0. 环境自检（bash + curl + sha256sum/shasum + ln）
#   1. 下载 manifest.sha256 清单
#   2. 白名单解析（拒绝 .. / 绝对路径 / 清单外条目；且必须与内置期望文件集一致）
#   3. 逐文件下载 + 即时 SHA-256 验签（任一不符即中止并清理）
#   4. SKILL.md frontmatter 校验（name: hrhot 且 description 非空）
#   5. 旧副本检测（默认拒绝；--migrate-legacy 备份为 .bak-<时间戳> 后继续）
#   6. 原子替换（暂存目录与目标同文件系统 -> mv rename；失败 trap 回滚）
#   7. 软链（--target claude -> ~/.claude/skills/hrhot 指向目标目录，不复制第二份；
#            软链不可用时兜底 Windows 目录联接 mklink /J）
#   8. 清理与输出（trap 保证不留半成品；中断信号同样回滚）
#
# 用法:
#   install.sh [--target agents|claude] [--dir <path>] [--base <url>]
#              [--migrate-legacy] [--force] [--help]
#
# 说明:
#   - 从不用 sudo；只写用户主目录下的文件。
#   - Windows 请使用 Git Bash 执行。
#   - 安装包共 8 个文件：manifest 内 7 个 + manifest.sha256 自身。

set -u

SKILL_NAME="hrhot"
SKILL_VERSION="1.0.0"
BASE_URL_DEFAULT="https://hrhot.gaiying.top/hrhot-skill"

# 基地址优先级: --base 参数 > HRHOT_SKILL_BASE_URL > BASE_URL > 默认值
BASE_URL="${HRHOT_SKILL_BASE_URL:-${BASE_URL:-$BASE_URL_DEFAULT}}"

# 安装器内置白名单：manifest 的文件集必须与此完全一致（防清单被篡改后任意文件拉取）
EXPECTED_FILES="SKILL.md README.md LICENSE install.sh agents/openai.yaml references/api.md references/errors.md"
EXPECTED_COUNT=7          # manifest 内文件数；连同 manifest.sha256 自身，安装后共 8 个文件
INSTALLED_FILE_COUNT=8

# 旧副本检测点（真实目录/文件即视为旧副本；已指向本目标的链接除外）
LEGACY_SPOTS="$HOME/.claude/skills/$SKILL_NAME $HOME/.codex/skills/$SKILL_NAME"

# ---------- 运行态变量 ----------
TARGET="agents"
TARGET_DIR=""
OPT_BASE=""
MIGRATE_LEGACY=0
FORCE=0
RUN_TS=$(date +%Y%m%d%H%M%S)

TMP_DIR=""        # 系统临时目录（下载与验签）
STAGE_DIR=""      # 与目标同文件系统的暂存目录（原子替换源）
BACKUP_DIR=""     # 旧目标目录备份（回滚用）
LEGACY_BACKUPS="" # 旧副本备份列表（回滚用，空格分隔）
LOCK_DIR="$HOME/.hrhot-skill-install.lock"
LOCK_HELD=0
INSTALL_DONE=0

# ---------- 基础函数 ----------

log()  { printf '[hrhot-skill] %s\n' "$*"; }
warn() { printf '[hrhot-skill] 警告: %s\n' "$*" >&2; }
die()  { printf '[hrhot-skill] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
HRHOT Agent Skill 安装器

用法:
  install.sh [--target agents|claude] [--dir <path>] [--base <url>]
             [--migrate-legacy] [--force] [--help]

选项:
  --target agents|claude  安装目标（默认 agents）。
                          agents: 安装到 ~/.agents/skills/hrhot
                          claude: 同上，并在 ~/.claude/skills/hrhot 建立指向目标目录的软链
                                  （不复制第二份；软链不可用时自动兜底为目录联接）
  --dir <path>            自定义安装目录（默认 ~/.agents/skills/hrhot）
  --base <url>            托管基地址（默认 https://hrhot.gaiying.top/hrhot-skill）
  --migrate-legacy        检测到旧副本时，将旧目录备份为 <dir>.bak-<时间戳> 后继续安装
  --force                 已安装时强制重装（同样会备份旧目录）
  -h, --help              显示本帮助

环境变量:
  HRHOT_SKILL_BASE_URL    覆盖默认基地址（优先级高于 BASE_URL）
  BASE_URL                覆盖默认基地址

示例:
  install.sh --target claude
  curl -fsSL https://hrhot.gaiying.top/hrhot-skill/install.sh | bash -s -- --target claude
EOF
}

# 失败回滚 + 清理（trap EXIT/INT/TERM/HUP）：任何失败路径都不留半成品
cleanup() {
  if [ "$INSTALL_DONE" != "1" ]; then
    if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
      rm -rf "$STAGE_DIR"
    fi
    # 恢复旧副本备份
    if [ -n "$LEGACY_BACKUPS" ]; then
      local pair orig bak
      for pair in $LEGACY_BACKUPS; do
        orig="${pair%%|*}"; bak="${pair##*|}"
        if [ -d "$bak" ] || [ -L "$bak" ] || [ -f "$bak" ]; then
          [ -e "$orig" ] || mv "$bak" "$orig" 2>/dev/null || true
        fi
      done
    fi
    # 恢复旧目标目录
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] && [ -n "$TARGET_DIR" ] && [ ! -e "$TARGET_DIR" ]; then
      mv "$BACKUP_DIR" "$TARGET_DIR" 2>/dev/null || true
    fi
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
  if [ "$LOCK_HELD" = "1" ] && [ -d "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# 全局安装锁（mkdir 原子创建；超 1 小时视为陈旧锁可夺取）
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    date +%s > "$LOCK_DIR/ts" 2>/dev/null || true
    LOCK_HELD=1
    return 0
  fi
  local ts now
  ts=$(cat "$LOCK_DIR/ts" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - ts)) -gt 3600 ]; then
    warn "发现陈旧安装锁（超过 1 小时），已自动清除"
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
      date +%s > "$LOCK_DIR/ts" 2>/dev/null || true
      LOCK_HELD=1
      return 0
    fi
  fi
  die "另一个 HRHOT Skill 安装似乎正在进行（锁目录: $LOCK_DIR）。如确信没有，请手动删除该目录后重试。"
}

# 判断链接是否已指向目标（兼容真软链与 Windows 目录联接）
link_points_to_target() {
  local link="$1" target="$2" cur a b
  [ -e "$link" ] || [ -L "$link" ] || return 1
  cur=$(readlink "$link" 2>/dev/null || true)
  [ "$cur" = "$target" ] && return 0
  a=$(cd "$link" 2>/dev/null && pwd -P) || return 1
  b=$(cd "$target" 2>/dev/null && pwd -P) || return 1
  [ "$a" = "$b" ]
}

# 创建目录链接：优先 ln -s；Windows 无建链权限时兜底 mklink /J（目录联接，无需管理员）
create_dir_link() {
  local link="$1" target="$2" wlink wtarget
  if ln -s "$target" "$link" 2>/dev/null && { [ -L "$link" ] || [ -e "$link" ]; }; then
    return 0
  fi
  if command -v cmd >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    wlink=$(cygpath -w "$link" 2>/dev/null || true)
    wtarget=$(cygpath -w "$target" 2>/dev/null || true)
    if [ -n "$wlink" ] && [ -n "$wtarget" ] \
       && cmd //c "mklink /J \"$wlink\" \"$wtarget\"" </dev/null >/dev/null 2>&1 \
       && [ -d "$link" ]; then
      return 0
    fi
  fi
  return 1
}

# 校验已安装目录：SKILL.md frontmatter + 逐文件比对本包 manifest
verify_installed_package() {
  local dir="$1" f expected actual
  [ -f "$dir/SKILL.md" ] || return 1
  grep -Eq '^name:[[:space:]]*hrhot[[:space:]]*$' "$dir/SKILL.md" 2>/dev/null || return 1
  [ -f "$dir/manifest.sha256" ] || return 1
  for f in $EXPECTED_FILES; do
    [ -f "$dir/$f" ] || return 1
    expected=$(awk -v file="$f" '{ t = $2; sub(/^\*/, "", t); if (t == file) print $1 }' "$dir/manifest.sha256")
    [ -n "$expected" ] || return 1
    actual=$(sha256_of "$dir/$f")
    [ "$actual" = "$expected" ] || return 1
  done
  return 0
}

# 确保 ~/.claude/skills/hrhot 链接存在并指向目标目录
ensure_claude_link() {
  [ "$TARGET" = "claude" ] || return 0
  local LINK="$HOME/.claude/skills/$SKILL_NAME"
  mkdir -p "$(dirname "$LINK")" || die "无法创建目录: $(dirname "$LINK")"
  if link_points_to_target "$LINK" "$TARGET_DIR"; then
    log "软链已存在: $LINK -> $TARGET_DIR"
    return 0
  fi
  if [ -e "$LINK" ] || [ -L "$LINK" ]; then
    # 旧副本检测通常已处理；双保险
    if [ "$MIGRATE_LEGACY" != "1" ]; then
      die "$LINK 已存在且未指向本 skill；如要迁移请加 --migrate-legacy"
    fi
    mv "$LINK" "$LINK.bak-$RUN_TS" || die "无法备份旧软链: $LINK"
    LEGACY_BACKUPS="$LEGACY_BACKUPS $LINK|$LINK.bak-$RUN_TS"
  fi
  create_dir_link "$LINK" "$TARGET_DIR" \
    || die "无法创建链接: $LINK -> $TARGET_DIR（Windows 上可尝试以管理员权限或开发者模式运行 Git Bash，或改用 --target agents）"
  log "已创建软链: $LINK -> $TARGET_DIR"
}

# ---------- 参数解析 ----------

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 2 ] || die "--target 缺少参数（agents|claude）"
      TARGET="$2"; shift 2 ;;
    --target=*)
      TARGET="${1#--target=}"; shift ;;
    --dir)
      [ $# -ge 2 ] || die "--dir 缺少参数"
      TARGET_DIR="$2"; shift 2 ;;
    --dir=*)
      TARGET_DIR="${1#--dir=}"; shift ;;
    --base)
      [ $# -ge 2 ] || die "--base 缺少参数"
      OPT_BASE="$2"; shift 2 ;;
    --base=*)
      OPT_BASE="${1#--base=}"; shift ;;
    --migrate-legacy)
      MIGRATE_LEGACY=1; shift ;;
    --force)
      FORCE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "未知参数: $1（--help 查看用法）" ;;
  esac
done

[ -n "$OPT_BASE" ] && BASE_URL="$OPT_BASE"
case "$TARGET" in
  agents|claude) ;;
  *) die "--target 仅支持 agents 或 claude（收到: $TARGET）" ;;
esac

# 去掉基地址末尾斜杠，避免双斜杠
BASE_URL="${BASE_URL%/}"

# ---------- 步骤 0：环境自检 ----------

[ -n "${BASH_VERSION:-}" ] || die "需要 bash 执行本脚本（Windows 请使用 Git Bash）"
for cmd in curl ln mktemp mv rm mkdir date grep awk head; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖命令: $cmd"
done
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die "缺少依赖命令: sha256sum（或 shasum -a 256）"
fi

# ---------- 目标目录解析 ----------

if [ -z "$TARGET_DIR" ]; then
  TARGET_DIR="$HOME/.agents/skills/$SKILL_NAME"
fi
case "$TARGET_DIR" in
  /*) ;;
  *)  TARGET_DIR="$PWD/$TARGET_DIR" ;;
esac
# 规范化：去掉末尾斜杠（保留根目录特殊情况）
while [ "${#TARGET_DIR}" -gt 1 ] && [ "${TARGET_DIR%/}" != "$TARGET_DIR" ]; do
  TARGET_DIR="${TARGET_DIR%/}"
done

log "安装目标: $TARGET_DIR"
log "托管基地址: $BASE_URL"

acquire_lock

# ---------- 步骤 5（前置）：旧副本检测 ----------

check_legacy_spots() {
  local spot
  for spot in $LEGACY_SPOTS; do
    [ "$spot" = "$TARGET_DIR" ] && continue
    [ -e "$spot" ] || [ -L "$spot" ] || continue
    # 已指向本目标的链接视为正常（由步骤 7 幂等处理）
    link_points_to_target "$spot" "$TARGET_DIR" && continue
    if [ "$MIGRATE_LEGACY" != "1" ]; then
      die "检测到旧副本: $spot。默认拒绝安装；确认要迁移请加 --migrate-legacy（旧目录将备份为 .bak-<时间戳>）"
    fi
    mv "$spot" "$spot.bak-$RUN_TS" || die "无法备份旧副本: $spot"
    LEGACY_BACKUPS="$LEGACY_BACKUPS $spot|$spot.bak-$RUN_TS"
    log "旧副本已备份: $spot -> $spot.bak-$RUN_TS"
  done
}
check_legacy_spots

# 目标目录已存在：默认拒绝；已安装且本地验签通过则提示无需重复安装
SKIP_DOWNLOAD=0
if [ -e "$TARGET_DIR" ] || [ -L "$TARGET_DIR" ]; then
  if [ "$FORCE" != "1" ] && [ "$MIGRATE_LEGACY" != "1" ]; then
    if verify_installed_package "$TARGET_DIR"; then
      SKIP_DOWNLOAD=1
      log "HRHOT Skill 已安装于 $TARGET_DIR 且本地验签通过。"
    else
      die "目标目录已存在: $TARGET_DIR。默认拒绝覆盖；如确认要迁移请加 --migrate-legacy"
    fi
  fi
fi

# ---------- 步骤 1：下载 manifest ----------

if [ "$SKIP_DOWNLOAD" != "1" ]; then

TMP_DIR=$(mktemp -d 2>/dev/null) || die "无法创建临时目录"
MANIFEST_FILE="$TMP_DIR/manifest.sha256"
log "下载清单: $BASE_URL/manifest.sha256"
curl -fsSL --connect-timeout 15 --max-time 120 -o "$MANIFEST_FILE" "$BASE_URL/manifest.sha256" \
  || die "清单下载失败: $BASE_URL/manifest.sha256"

# ---------- 步骤 2：白名单解析与校验 ----------

total=$(grep -c '[^[:space:]]' "$MANIFEST_FILE" 2>/dev/null || echo 0)
[ "$total" = "$EXPECTED_COUNT" ] || die "manifest 条目数（$total）与期望（$EXPECTED_COUNT）不一致，已中止"

# 格式：64 位十六进制哈希 + 两个空格 + 安全相对路径（兼容 Windows coreutils 的 'hash *file' 二进制标记）
bad_line=$(awk '{ if ($0 !~ /^[0-9a-fA-F]{64}  \*?[A-Za-z0-9._\/-]+$/) print NR }' "$MANIFEST_FILE")
[ -z "$bad_line" ] || die "manifest 第 $bad_line 行格式非法（应为 '<sha256>  <相对路径>'），已中止"

# 路径安全：拒绝绝对路径与 ..
for p in $(awk '{ f = $2; sub(/^\*/, "", f); print f }' "$MANIFEST_FILE"); do
  case "$p" in
    /*)   die "manifest 含绝对路径: $p，已中止" ;;
    *..*) die "manifest 含非法路径（..）: $p，已中止" ;;
    *\\*) die "manifest 含非法路径（反斜杠）: $p，已中止" ;;
  esac
done

# 文件集必须与安装器内置白名单完全一致（顺序无关）
actual_set=$(awk '{ f = $2; sub(/^\*/, "", f); print f }' "$MANIFEST_FILE" | LC_ALL=C sort | tr '\n' ' ')
expect_set=$(printf '%s\n' $EXPECTED_FILES | LC_ALL=C sort | tr '\n' ' ')
[ "$actual_set" = "$expect_set" ] || die "manifest 文件集与安装器内置白名单不一致（可能被篡改），已中止"

# ---------- 步骤 3：逐文件下载 + 即时验签 ----------

STAGE_DIR=$(mktemp -d "$(dirname "$TARGET_DIR")/.hrhot-skill-stage-XXXXXX" 2>/dev/null) \
  || STAGE_DIR=$(mktemp -d) \
  || die "无法创建暂存目录"

i=0
for f in $EXPECTED_FILES; do
  i=$((i + 1))
  dest="$TMP_DIR/$f"
  mkdir -p "$(dirname "$dest")" || die "无法创建目录: $(dirname "$dest")"
  curl -fsSL --connect-timeout 15 --max-time 120 -o "$dest" "$BASE_URL/$f" \
    || die "下载失败: $BASE_URL/$f"
  actual=$(sha256_of "$dest")
  expected=$(awk -v file="$f" '{ f2 = $2; sub(/^\*/, "", f2); if (f2 == file) print $1 }' "$MANIFEST_FILE")
  [ -n "$expected" ] || die "manifest 中缺少条目: $f"
  if [ "$actual" != "$expected" ]; then
    die "验签失败: $f（期望 $expected，实际 $actual）—— 可能被篡改或传输损坏，已中止"
  fi
  log "[$i/$EXPECTED_COUNT] $f 下载并验签通过"
done

# ---------- 步骤 4：frontmatter 校验 ----------

SKILL_MD="$TMP_DIR/SKILL.md"
head -n 1 "$SKILL_MD" | grep -q '^---' || die "SKILL.md 缺少 frontmatter 起始行（---）"
fm=$(awk 'NR==1 && $0 !~ /^---/ {exit 1} NR>1 && $0 ~ /^---/ {exit} NR>1 {print}' "$SKILL_MD")
echo "$fm" | grep -Eq '^name:[[:space:]]*hrhot[[:space:]]*$' \
  || die "SKILL.md frontmatter 缺少 name: hrhot"
echo "$fm" | grep -Eq '^description:[[:space:]]*[^[:space:]]' \
  || die "SKILL.md frontmatter 的 description 为空"
log "SKILL.md frontmatter 校验通过（name: hrhot）"

# ---------- 组装暂存目录（保留目录结构；manifest 自身已位于 $TMP_DIR） ----------

for f in $EXPECTED_FILES manifest.sha256; do
  mkdir -p "$STAGE_DIR/$(dirname "$f")" || die "无法创建暂存目录: $STAGE_DIR/$(dirname "$f")"
  cp "$TMP_DIR/$f" "$STAGE_DIR/$f" || die "无法复制文件: $f"
done

file_count=$(find "$STAGE_DIR" -type f | wc -l | tr -d ' ')
[ "$file_count" = "$INSTALLED_FILE_COUNT" ] || die "暂存文件数（$file_count）与期望（$INSTALLED_FILE_COUNT）不一致，已中止"

# ---------- 步骤 6：原子替换 ----------

PARENT_DIR=$(dirname "$TARGET_DIR")
mkdir -p "$PARENT_DIR" || die "无法创建父目录: $PARENT_DIR"

if [ -e "$TARGET_DIR" ] || [ -L "$TARGET_DIR" ]; then
  BACKUP_DIR="$TARGET_DIR.bak-$RUN_TS"
  mv "$TARGET_DIR" "$BACKUP_DIR" || die "无法备份旧目录: $TARGET_DIR"
  log "旧目录已备份: $BACKUP_DIR"
fi

# 暂存目录与目标同文件系统（mktemp 于目标父目录），mv 即原子 rename
if ! mv "$STAGE_DIR" "$TARGET_DIR" 2>/dev/null; then
  # 兜底：跨文件系统时先复制再 rename（理论不触发，暂存已在同父目录）
  warn "mv 失败，尝试跨文件系统复制路径"
  TMP_TARGET="$TARGET_DIR.tmp-$$"
  rm -rf "$TMP_TARGET"
  cp -r "$STAGE_DIR" "$TMP_TARGET" || die "复制到目标失败: $TMP_TARGET"
  mv "$TMP_TARGET" "$TARGET_DIR" || { rm -rf "$TMP_TARGET"; die "原子替换失败: $TARGET_DIR"; }
fi
STAGE_DIR=""
INSTALL_DONE=1
log "已安装到: $TARGET_DIR（共 $INSTALLED_FILE_COUNT 个文件）"

fi  # SKIP_DOWNLOAD != 1

# ---------- 步骤 7：软链（--target claude） ----------

ensure_claude_link

# ---------- 步骤 8：完成输出 ----------

if [ "$SKIP_DOWNLOAD" = "1" ]; then
  cat <<'EOF'

HRHOT Skill 已是最新状态（本地验签通过），无需重复安装。
如需强制更新请使用 --force 或 --migrate-legacy。
EOF
else
  printf '\nHRHOT Skill 安装完成（v%s）。\n\n' "$SKILL_VERSION"
  printf '安装位置: %s\n' "$TARGET_DIR"
fi
if [ "$TARGET" = "claude" ]; then
  printf 'Claude 软链: %s -> %s\n' "$HOME/.claude/skills/$SKILL_NAME" "$TARGET_DIR"
fi
cat <<'EOF'

试试问你的 Agent：
  「过去 24 小时 HR 圈最重要的 5 件事」
  「今天有什么 HR 新政」
  「竞业限制相关的新闻」

合规提示：数据供个人免费使用，商业用途须取得 HRHOT 书面授权；
API 摘要由 AI 生成，引用前请回原文核对。
EOF

exit 0
