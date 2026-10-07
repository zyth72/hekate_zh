#!/usr/bin/env bash
#
# publish_zh_fork.sh — 中文版 hekate 的一键维护脚本
#
#   1. 首次运行时把 CTCaer/hekate fork 到你的 GitHub 账号(已存在则跳过)
#   2. 配置远端:origin = 你的 fork,upstream = CTCaer/hekate
#   3. 提交本地汉化改动并推送
#   4. 可选:编译(--build)、打包成可刷写的 zip(--package)、发 GitHub Release(--release)
#
# 用法:
#   tools/publish_zh_fork.sh                   # fork + 提交 + 推送
#   tools/publish_zh_fork.sh --build           # 顺带用 devkitARM 编译 Nyx
#   tools/publish_zh_fork.sh --build --package # 编译并打出可刷写 zip
#   tools/publish_zh_fork.sh --release 1.0.0   # 打包并创建 GitHub Release
#
# 可用环境变量覆盖:
#   UPSTREAM=CTCaer/hekate   FORK_NAME=hekate   BRANCH=master
#   COMMIT_MSG="..."         OWNER=<github 用户名>
#
set -euo pipefail

UPSTREAM="${UPSTREAM:-CTCaer/hekate}"
FORK_NAME="${FORK_NAME:-hekate}"
BRANCH="${BRANCH:-master}"
COMMIT_MSG="${COMMIT_MSG:-zh-cn: Nyx 中文界面(UTF-8 + HarmonyOS Sans 中文字体 + 全角标点字形)}"

DO_BUILD=0
DO_PACKAGE=0
RELEASE_TAG=""

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--build)   DO_BUILD=1 ;;
		--package) DO_PACKAGE=1 ;;
		--release) RELEASE_TAG="${2:-}"; [ -n "$RELEASE_TAG" ] || die "--release 需要一个 tag,例如 --release 1.0.0"; DO_PACKAGE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数: $1(用 --help 查看用法)" ;;
	esac
	shift
done

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# 版本号(来自 Versions.inc):hekate 6.5.4 / Nyx 1.9.4
ver() { sed -n "s/^$1 *:= *\([0-9]*\)/\1/p;" Versions.inc | head -1; }
BL_VER="$(ver BLVERSION_MAJOR).$(ver BLVERSION_MINOR).$(ver BLVERSION_HOTFX)"
NYX_VER="$(ver NYXVERSION_MAJOR).$(ver NYXVERSION_MINOR).$(ver NYXVERSION_HOTFX)"

# ---------------------------------------------------------------- 依赖与账号
command -v git >/dev/null || die "缺少 git"
command -v gh  >/dev/null || die "缺少 gh(GitHub CLI):https://cli.github.com"
gh auth status >/dev/null 2>&1 || die "gh 未登录,先执行:gh auth login"

OWNER="${OWNER:-$(gh api user -q .login)}"
FORK="${OWNER}/${FORK_NAME}"

# ------------------------------------------------------------------- 创建 fork
if gh api "repos/${FORK}" >/dev/null 2>&1; then
	info "fork 已存在:${FORK}"
else
	info "创建 fork:${FORK}"
	gh repo fork "${UPSTREAM}" --clone=false >/dev/null
fi

# ---------------------------------------------------------------------- 远端
# 本地仓库原来的 origin 指向原仓库时,改名为 upstream;origin 指向自己的 fork。
origin_url=$(git remote get-url origin 2>/dev/null || true)
if ! git remote get-url upstream >/dev/null 2>&1; then
	case "$origin_url" in
		*"${UPSTREAM}"*) git remote rename origin upstream ;;
		*)               git remote add upstream "https://github.com/${UPSTREAM}.git" ;;
	esac
fi
if ! git remote get-url origin >/dev/null 2>&1; then
	git remote add origin "https://github.com/${FORK}.git"
elif [ "$(git remote get-url origin)" != "https://github.com/${FORK}.git" ] \
	&& [ "$(git remote get-url origin)" != "git@github.com:${FORK}.git" ]; then
	info "origin 改指到 fork:${FORK}"
	git remote set-url origin "https://github.com/${FORK}.git"
fi
info "origin   -> $(git remote get-url origin)"
info "upstream -> $(git remote get-url upstream)"

# 忽略文件权限位差异(WSL/NTFS 挂载会把所有文件标成 755)
git config core.fileMode false

# ----------------------------------------------------------------- 提交并推送
info "暂存改动"
git add -A

if git diff --cached --quiet; then
	info "没有需要提交的改动"
else
	info "提交:${COMMIT_MSG}"
	git commit -m "${COMMIT_MSG}"
fi

info "推送到 ${FORK} (${BRANCH})"
git push -u origin "${BRANCH}"

# ------------------------------------------------------------------- 编译_NYX
if [ "$DO_BUILD" = 1 ]; then
	[ -n "${DEVKITARM:-}" ] || die "未设置 DEVKITARM,请看 https://devkitpro.org/wiki/Getting_Started"
	info "编译(DEVKITARM=${DEVKITARM})"
	make clean >/dev/null
	make -j"$(nproc)"
	info "产物:output/nyx.bin ($(wc -c <output/nyx.bin) 字节)"
fi

# ---------------------------------------------------------------- 打包 zip
if [ "$DO_PACKAGE" = 1 ]; then
	[ -f output/nyx.bin ] || die "output/nyx.bin 不存在,先加 --build 编译"
	# 打包逻辑与 CI 共用 tools/package_release.sh
	bash tools/package_release.sh --nyx output/nyx.bin
	info "刷写方式:解压后覆盖 SD 卡;最少只需替换 bootloader/sys/nyx.bin"
fi

# ------------------------------------------------------------------ Release
if [ -n "$RELEASE_TAG" ]; then
	zip_path=$(ls -t output/hekate_zh_ctcaer_*_Nyx_*.zip 2>/dev/null | head -1 || true)
	[ -n "$zip_path" ] || die "找不到 zip,先用 --package 打包"
	info "创建 GitHub Release:${RELEASE_TAG}"
	gh release create "$RELEASE_TAG" "$zip_path" \
		--repo "${FORK}" \
		--title "hekate 中文版 ${RELEASE_TAG}" \
		--notes "基于 CTCaer/hekate v${BL_VER} + Nyx ${NYX_VER} 的中文版。

- Nyx 界面全中文(UTF-8 + HarmonyOS Sans 中文字体,含全角标点字形)
- 刷写:解压后覆盖 SD 卡;最少只需替换 bootloader/sys/nyx.bin
- hekate 自身的文字菜单仍为英文(内置 8x8 点阵字库 + 126KB 体积上限)
- 中文字体与译文来自 easyworld/hekate 的汉化(GPL-2)" \
		|| warn "Release ${RELEASE_TAG} 已存在;可用 gh release upload ${RELEASE_TAG} ${zip_path} 补传"
fi

info "完成:https://github.com/${FORK}"
