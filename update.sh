#!/usr/bin/env nix-shell
#! nix-shell -i bash -p nodejs_24 prefetch-npm-deps gnused gnugrep jq curl
set -euo pipefail
cd "$(dirname "$0")"

current=$(sed -n 's/^  version = "\(.*\)";$/\1/p' package.nix)
latest=$(npm view @paperclipai/server dist-tags.latest)
if [ "$current" = "$latest" ]; then
  echo "paperclip is up to date ($current)"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/server.tgz" "https://registry.npmjs.org/@paperclipai/server/-/server-$latest.tgz"
hash=$(nix hash file --sri "$tmp/server.tgz")

# Same lockfile recipe as package.nix: devDependencies include an unpublished package.
tar -xzf "$tmp/server.tgz" -C "$tmp" package/package.json
mkdir "$tmp/lock"
jq 'del(.devDependencies)' "$tmp/package/package.json" > "$tmp/lock/package.json"
(cd "$tmp/lock" && npm install --package-lock-only --omit=dev --ignore-scripts)
cp "$tmp/lock/package-lock.json" package-lock.json
depsHash=$(prefetch-npm-deps package-lock.json)

# Each pattern must match exactly one line, or we fail before editing.
replace() {
  [ "$(grep -c "$1" package.nix)" = 1 ] || { echo "pattern '$1' must match exactly one line" >&2; exit 1; }
  sed -i "s|$1.*|$2|" package.nix
}
replace '^  version = ' "  version = \"$latest\";"
replace '^    hash = ' "    hash = \"$hash\";"
replace '^  npmDepsHash = ' "  npmDepsHash = \"$depsHash\";"

echo "updated paperclip: $current -> $latest"
