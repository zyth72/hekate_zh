#!/usr/bin/env bash
#
# ci_sync_upstream.sh — 把上游(CTCaer/hekate)的更新合并进当前分支
#
#   * 默认合并上游最新的 v* 标签(稳定版);UPSTREAM_REF 可以指定别的引用,如 master
#   * 已经包含该引用时不会重复合并
#   * 合并冲突:中止合并;在 CI 里(GH_TOKEN 可用)自动开 issue 提醒手动处理,并以非 0 退出
#
# 输出(CI 里写入 $GITHUB_OUTPUT,本地运行时打印到 stdout):
#   changed=true|false   相对上一次发布是否有变化(决定要不要重新构建/发布)
#   sha=<提交>           构建要用的提交
#
# 环境变量:
#   UPSTREAM      默认 CTCaer/hekate
#   UPSTREAM_REF  指定上游引用;留空 = 最新的 v* 标签
#   FORCE         true = 就算没变化也标记为需要发布
#   SKIP_MERGE    true = 跳过合并(打 tag 触发构建时用),只输出当前提交
#   BRANCH        要推送到的分支,默认 master
#   DRY_RUN       true = 不 push、不开 issue(本地演练)
#
set -euo pipefail

UPSTREAM="${UPSTREAM:-CTCaer/hekate}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/${UPSTREAM}.git}"   # 可指到本地仓库做演练
UPSTREAM_REF="${UPSTREAM_REF:-}"
FORCE="${FORCE:-false}"
SKIP_MERGE="${SKIP_MERGE:-false}"
BRANCH="${BRANCH:-master}"
DRY_RUN="${DRY_RUN:-false}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

out() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		echo "$1" >> "$GITHUB_OUTPUT"
	else
		echo "$1"
	fi
}

hexsha() { git rev-parse --short=8 "$1"; }

# 打 tag 触发时不需要合并,直接构建该 tag
if [ "$SKIP_MERGE" = "true" ]; then
	info "跳过上游同步,构建当前提交 $(hexsha HEAD)"
	out "changed=true"
	out "sha=$(git rev-parse HEAD)"
	exit 0
fi

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
	git config user.name  >/dev/null 2>&1 || git config user.name  "github-actions[bot]"
	git config user.email >/dev/null 2>&1 || git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
fi

# --------------------------------------------------------------- 拉取上游更新
git remote add upstream "$UPSTREAM_URL" 2>/dev/null || git remote set-url upstream "$UPSTREAM_URL"
info "拉取 ${UPSTREAM} …"
git fetch --tags --force --quiet upstream
git fetch --quiet upstream master

if [ -n "$UPSTREAM_REF" ]; then
	target="$UPSTREAM_REF"
	git rev-parse --verify --quiet "$target" >/dev/null || target="upstream/$UPSTREAM_REF"
	git rev-parse --verify --quiet "$target" >/dev/null || die "找不到上游引用:$UPSTREAM_REF"
else
	target=$(git tag --list 'v*' --sort=-v:refname | head -1)
	[ -n "$target" ] || target="upstream/master"
fi
info "上游目标:${target} ($(hexsha "$target"))"

# ------------------------------------------------------------------- 合并
if git merge-base --is-ancestor "$target" HEAD; then
	info "已经包含 ${target},无需合并"
	merged=false
else
	info "合并 ${target}"
	if ! git merge --no-edit -m "Merge upstream ${target} into 中文版" "$target" >/dev/null; then
		conflicts=$(git diff --name-only --diff-filter=U | sed 's/^/  - /')
		git merge --abort || true
		warn "上游更新与汉化改动冲突,已中止合并:"
		echo "$conflicts"
		if [ -n "${GH_TOKEN:-}" ] && [ "$DRY_RUN" != "true" ]; then
			gh issue create \
				--title "上游 ${target} 需要手动合并($(date +%F))" \
				--body "$(printf '自动合并上游 %s 时发生冲突,已中止合并,未改动任何分支。\n\n冲突文件:\n```\n%s\n```\n\n本地处理方式:\n```bash\ngit fetch upstream --tags\ngit merge %s\n# 手动解决冲突后\ngit push origin master\n```\n\n也可以在上游合并完成后,手动触发一次 workflow_dispatch 重新构建发布。' \
					"$target" "$conflicts" "$target")" 2>/dev/null \
				|| warn "创建 issue 失败(检查 workflow 的 issues 权限)"
		fi
		exit 1
	fi
	merged=true
	if [ "$DRY_RUN" = "true" ]; then
		warn "DRY_RUN:跳过 push(合并结果保留在本地)"
	else
		git push origin "HEAD:${BRANCH}"
	fi
fi

# --------------------------------------------------- 相对上一次发布是否有变化
last=$(git tag --list 'zh-*' --sort=-v:refname | head -1 || true)
changed=false
if [ "$merged" = "true" ] || [ -z "$last" ]; then
	changed=true
elif [ "$(git rev-parse "$last^{commit}")" != "$(git rev-parse HEAD)" ]; then
	changed=true
fi
[ "$FORCE" = "true" ] && changed=true

head_sha=$(git rev-parse HEAD)
if [ -n "$last" ]; then
	info "上一次发布:${last} ($(hexsha "$last^{commit}"))"
else
	info "还没有发布过"
fi
info "当前提交:$(hexsha HEAD),changed=${changed}"

out "changed=${changed}"
out "sha=${head_sha}"
