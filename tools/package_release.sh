#!/usr/bin/env bash
#
# package_release.sh — 用官方发布包 + 本地编译的 nyx.bin 打出可刷写 zip
#
#   1. 从 CTCaer/hekate 的 GitHub Release 下载当前版本的官方 zip
#   2. 用中文版 nyx.bin 替换其中的 bootloader/sys/nyx.bin
#   3. 官方 payload 改名为 payload.bin(RCM 注入器/烧录器惯用名,内容不变,不重复放两份)
#   4. 重新打包成 output/hekate_zh_ctcaer_<hekate 版本>_Nyx_<Nyx 版本>.zip
#
# 只替换 nyx.bin:hekate 自身、res.pak、模块等都保持官方版本不变。
#
# 用法:
#   tools/package_release.sh [--nyx <nyx.bin>] [--out <zip>] [--upstream <owner/repo>]
#
# 依赖:python3(解包/打包);有 curl 即可下载,gh 已登录时优先用 gh。
#
set -euo pipefail

UPSTREAM="${UPSTREAM:-CTCaer/hekate}"
NYX_BIN="output/nyx.bin"
OUT=""
VERBOSE=0

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--nyx)      NYX_BIN="$2"; shift ;;
		--out)      OUT="$2"; shift ;;
		--upstream) UPSTREAM="$2"; shift ;;
		-v)         VERBOSE=1 ;;
		-h|--help)  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)          die "未知参数:$1" ;;
	esac
	shift
done

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

[ -f "$NYX_BIN" ] || die "$NYX_BIN 不存在,先编译(make)或指定 --nyx"
command -v python3 >/dev/null || die "缺少 python3"

ver() { sed -n "s/^$1 *:= *\([0-9]*\)/\1/p;" Versions.inc | head -1; }
BL_VER="$(ver BLVERSION_MAJOR).$(ver BLVERSION_MINOR).$(ver BLVERSION_HOTFX)"
NYX_VER="$(ver NYXVERSION_MAJOR).$(ver NYXVERSION_MINOR).$(ver NYXVERSION_HOTFX)"

[ -n "$BL_VER" ] || die "读不到 Versions.inc 里的版本号"
[ -n "$OUT" ] || OUT="output/hekate_zh_ctcaer_${BL_VER}_Nyx_${NYX_VER}.zip"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ------------------------------------------------------------------ 下载官方包
asset="hekate_ctcaer_${BL_VER}_Nyx_${NYX_VER}.zip"
url="https://github.com/${UPSTREAM}/releases/download/v${BL_VER}/${asset}"
info "获取官方发布包:${asset}"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
	gh release download "v${BL_VER}" --repo "${UPSTREAM}" \
		--pattern "hekate_ctcaer_${BL_VER}_Nyx_*.zip" --dir "$work" --clobber
else
	curl -fL --retry 3 -o "$work/${asset}" "$url"
fi

# ------------------------------------------------------- 替换 nyx.bin 并重打包
info "替换 bootloader/sys/nyx.bin 为中文版"
mkdir -p "$work/pkg"
python3 - "$work" "$work/pkg" "$NYX_BIN" "$repo_root/$OUT" <<-'PY'
	import glob, os, shutil, sys, zipfile

	work, dst, nyx_bin, out = sys.argv[1:5]
	official = glob.glob(os.path.join(work, 'hekate_ctcaer_*.zip'))
	if not official:
	    sys.exit('没有找到官方 zip: %s' % work)

	with zipfile.ZipFile(official[0]) as z:
	    z.extractall(dst)

	target = os.path.join(dst, 'bootloader', 'sys', 'nyx.bin')
	if not os.path.exists(target):
	    sys.exit('官方包里没有 bootloader/sys/nyx.bin,可能版本不匹配')
	with open(nyx_bin, 'rb') as src, open(target, 'wb') as fp:
	    fp.write(src.read())

	# 官方 payload 改名为 payload.bin(RCM 注入器、烧录器惯用的文件名),
	# 内容不变、也不保留两份同样的文件。
	for payload in glob.glob(os.path.join(dst, 'hekate_ctcaer_*.bin')):
	    os.replace(payload, os.path.join(dst, 'payload.bin'))

	with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
	    for root, dirs, files in os.walk(dst):
	        for d in sorted(dirs):        # 保留官方包里的空目录(ini/、payloads/ 等)
	            full = os.path.join(root, d)
	            z.write(full, os.path.relpath(full, dst) + '/')
	        for f in sorted(files):
	            full = os.path.join(root, f)
	            z.write(full, os.path.relpath(full, dst))
	PY

sha=$(sha256sum "$OUT" | cut -d' ' -f1)
info "已生成:${OUT} ($(wc -c <"$OUT") 字节)"
info "sha256:${sha}"
if [ "$VERBOSE" = 1 ]; then
	python3 -c "import sys,zipfile; print('\n'.join(sorted(zipfile.ZipFile(sys.argv[1]).namelist())))" "$OUT"
fi
