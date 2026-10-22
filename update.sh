#!/usr/bin/env nix-shell
#! nix-shell -i bash -p nodejs_24 prefetch-npm-deps gnused gnugrep jq curl
set -euo pipefail
cd "$(dirname "$0")"

current=$(sed -n 's/^  version = "\(.*\)";$/\1/p' package.nix)
latest=$(npm view @paperclipai/server dist-tags.latest)
[[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "unexpected version '$latest'" >&2; exit 1; }
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
depsHash=$(prefetch-npm-deps "$tmp/lock/package-lock.json")

# Check every pattern before touching any file, so a failure leaves the repo unchanged.
for pat in '^  version = ' '^    hash = ' '^  npmDepsHash = '; do
  [ "$(grep -c "$pat" package.nix)" = 1 ] || { echo "pattern '$pat' must match exactly one line" >&2; exit 1; }
done
sed -i -e "s|^  version = .*|  version = \"$latest\";|" \
  -e "s|^    hash = .*|    hash = \"$hash\";|" \
  -e "s|^  npmDepsHash = .*|  npmDepsHash = \"$depsHash\";|" package.nix
cp "$tmp/lock/package-lock.json" package-lock.json

echo "updated paperclip: $current -> $latest"
