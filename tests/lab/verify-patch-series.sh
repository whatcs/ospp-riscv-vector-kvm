#!/bin/bash
set -euo pipefail

if test "$#" -lt 3; then
	echo "usage: $0 REPOSITORY BASE PATCH..." >&2
	exit 2
fi

repo=$1
base=$2
shift 2

index_file=$(mktemp)
rm -f "$index_file"
cleanup()
{
	rm -f "$index_file"
}
trap cleanup EXIT

export GIT_INDEX_FILE=$index_file
git -C "$repo" read-tree "$base"

for patch in "$@"; do
	printf 'APPLY %s\n' "$patch"
	git -C "$repo" apply --cached --check "$patch"
	git -C "$repo" apply --cached "$patch"
done

git -C "$repo" diff --cached --check
git -C "$repo" diff --cached --stat
