#!/bin/sh
set -eu

resources=$1
version=$2
case "$version" in ''|*[!a-zA-Z0-9_]*) exit 1 ;; esac
modules="$resources/netfleet/$version"
mkdir -p "$modules"
mv "$resources/netfleet/api.js" "$modules/api.js"
mv "$resources/netfleet/plugin-host.js" "$modules/plugin-host.js"
sed -e "s/require netfleet\./require netfleet.$version./g" \
	-e "s|netfleet/plugin-host.js|netfleet/$version/plugin-host.js|g" \
	"$resources/view/netfleet/overview.js" >"$resources/view/netfleet/overview-$version.js"
rm "$resources/view/netfleet/overview.js"
