#!/bin/zsh
set -euo pipefail
project="${0:A:h:h}"
upstream="${INODE_ENGINE_SOURCE:-https://github.com/helson-lin/iNode_Client_Sequoia.git}"
commit="dd9ac3f26815c262a67a3e434bfaa2e6f178d510"
destination="${INODE_ENGINE_DESTINATION:-$HOME/Library/Application Support/iNode for Mac/vendor-mac}"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

for tool in git python3 xcrun codesign; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print -u2 "缺少 $tool；请先安装 Xcode Command Line Tools。"
        exit 1
    fi
done
xcrun -f install_name_tool >/dev/null

print "正在从原项目取得本机所需的 iNode 组件…"
git clone --quiet "$upstream" "$temp_dir/sequoia"
git -C "$temp_dir/sequoia" checkout --quiet "$commit"
actual="$(git -C "$temp_dir/sequoia" rev-parse HEAD)"
if [[ "$actual" != "$commit" ]]; then
    print -u2 "上游提交校验失败。"
    exit 1
fi
python3 "$project/scripts/prepare_vendor.py" --source-path "$temp_dir/sequoia" --output "$temp_dir/vendor-mac"
mkdir -p "${destination:h}"
chmod 700 "$temp_dir/vendor-mac"
if [[ -e "$destination" ]]; then
    mv "$destination" "$temp_dir/previous-vendor-mac"
fi
if ! mv "$temp_dir/vendor-mac" "$destination"; then
    if [[ -e "$temp_dir/previous-vendor-mac" ]]; then mv "$temp_dir/previous-vendor-mac" "$destination"; fi
    exit 1
fi
print "已在本机安装 iNode 组件。现在可以在应用中使用普通认证。"
