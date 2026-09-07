#!/bin/sh
set -eu

resources=$1
version=$2
case "$version" in ''|*[!a-zA-Z0-9_]*) exit 1 ;; esac
mv "$resources/view/netfleet/overview.js" "$resources/view/netfleet/overview-$version.js"
