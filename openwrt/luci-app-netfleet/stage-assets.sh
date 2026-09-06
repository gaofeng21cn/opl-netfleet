#!/bin/sh
set -eu

resources=$1
version=$2
case "$version" in ''|*[!a-zA-Z0-9_]*) exit 1 ;; esac
modules="$resources/netfleet/$version"
mkdir -p "$modules"
for name in api config managed compatibility management; do
	sed "s/require netfleet\./require netfleet.$version./g" \
		"$resources/netfleet/$name.js" >"$modules/$name.js"
	rm "$resources/netfleet/$name.js"
done
sed "s/require netfleet\./require netfleet.$version./g" \
	"$resources/view/netfleet/overview.js" >"$resources/view/netfleet/overview-$version.js"
rm "$resources/view/netfleet/overview.js"
