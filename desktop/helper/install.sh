#!/bin/sh
# Explicit administrator entry: installs immutable helper/core, never changes networking.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Administrator authorization is required' >&2; exit 1; }
[ "$#" = 2 ] || { echo 'usage: install.sh <built-helper> <mihomo>' >&2; exit 1; }
helper_source=$1
core_source=$2
[ -f "$helper_source" ] && [ ! -L "$helper_source" ] && [ -x "$helper_source" ]
[ -f "$core_source" ] && [ ! -L "$core_source" ] && [ -x "$core_source" ]
# Never replace executable bytes while its network session is active.
[ ! -S /var/run/opl-netfleet-network/control.sock ] || { echo 'Stop the NetFleet network session before installing' >&2; exit 1; }
for destination in /Library/PrivilegedHelperTools '/Library/Application Support/OPL NetFleet' '/Library/Application Support/OPL NetFleet/Privileged'; do
  [ ! -L "$destination" ] || { echo 'Refusing symlinked privileged installation directory' >&2; exit 1; }
  /usr/bin/install -d -o root -g wheel -m 755 "$destination"
done
/usr/bin/install -o root -g wheel -m 755 "$helper_source" /Library/PrivilegedHelperTools/org.opl.netfleet.network.new
/usr/bin/install -o root -g wheel -m 755 "$core_source" '/Library/Application Support/OPL NetFleet/Privileged/mihomo.new'
/bin/mv -f '/Library/Application Support/OPL NetFleet/Privileged/mihomo.new' '/Library/Application Support/OPL NetFleet/Privileged/mihomo'
/bin/mv -f /Library/PrivilegedHelperTools/org.opl.netfleet.network.new /Library/PrivilegedHelperTools/org.opl.netfleet.network
