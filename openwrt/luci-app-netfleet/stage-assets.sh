#!/bin/sh
set -eu

resources=$1
version=$2
case "$version" in ''|*[!a-zA-Z0-9_]*) exit 1 ;; esac
modules="$resources/netfleet/$version"
mkdir -p "$modules"
for name in api config managed compatibility management product; do
	sed "s/require netfleet\./require netfleet.$version./g" \
		"$resources/netfleet/$name.js" >"$modules/$name.js"
	rm "$resources/netfleet/$name.js"
done
mv "$resources/netfleet/native.css" "$modules/native.css"
sed -e "s/require netfleet\./require netfleet.$version./g" \
	-e "s|netfleet/native.css|netfleet/$version/native.css|g" \
	"$resources/view/netfleet/overview.js" >"$resources/view/netfleet/overview-$version.js"
rm "$resources/view/netfleet/overview.js"
