#!/bin/sh
set -eu
set -x
umask 077
test -f /tmp/netfleet-native-vm-authorized
work=$1
test -n "$work"
main=/usr/libexec/opl-netfleet/main.uc
root=/etc/opl-netfleet/native/rule-data
run=/etc/opl-netfleet/native/run
config=$run/config.yaml
policy=/etc/opl-netfleet/policy.json
lock=/etc/opl-netfleet/rulesets.lock.json
test ! -e "$root"
mkdir -p "$work/bin" "$run/rulesets"
profile=$(uci get netfleet.config.profile)
case "$profile" in file:*) source=/etc/opl-netfleet/native/profiles/$(printf '%s' "$profile" | cut -d: -f2-);; *) exit 1;; esac
cp -L "$config" "$work/config.json"
cp -L "$source" "$work/source.json"
cp "$policy" "$work/policy.json"
[ ! -f "$lock" ] || cp "$lock" "$work/lock.json"
nft -j list table inet netfleet >"$work/nft.json"
ucode -e 'import * as fs from "fs";
 const commands=[]; for(let row in json(fs.readfile(ARGV[0])).nftables ?? []) {
  if(index(["china_ip","china_ip6"],row.set?.name)<0) continue;
  const name=row.set.name; push(commands,{flush:{set:{family:"inet",table:"netfleet",name}}});
  if(length(row.set.elem??[])) push(commands,{add:{element:{family:"inet",table:"netfleet",name,elem:row.set.elem}}});
 } fs.writefile(ARGV[1],sprintf("%J",{nftables:commands}));' "$work/nft.json" "$work/restore-nft.json"
cleanup() {
 rc=$?; trap - EXIT INT TERM; set +e
 if [ "$rc" != 0 ]; then for evidence in "$work"/accepted.json "$work"/invalid.json "$work"/rollback.json; do [ ! -f "$evidence" ] || cat "$evidence" >&2; done; fi
 cp "$work/source.json" "$source"
 cp "$work/config.json" "$config"
 cp "$work/policy.json" "$policy"
 if [ -f "$work/lock.json" ]; then cp "$work/lock.json" "$lock"; else rm -f "$lock"; fi
 /usr/bin/curl -q -fsS --unix-socket "$run/controller.sock" -X PUT -H 'Content-Type: application/json' --data-binary "{\"path\":\"$config\"}" 'http://localhost/configs?force=true' >/dev/null
 nft -j -f "$work/restore-nft.json"
 rm -rf "$root"
 /etc/init.d/opl-netfleet-core restart >/dev/null 2>&1
 exit "$rc"
}
trap cleanup EXIT INT TERM
cp /tmp/runtime-rulesets/cn-domain.mrs "$work/fixture.mrs"
cp "$work/fixture.mrs" "$run/rulesets/cn-domain.mrs"
printf '203.0.113.0/24\n2001:db8:abcd::/48\n' >"$work/cn.list"
ucode -e 'import * as fs from "fs";
 const p=json(fs.readfile(ARGV[0]));p.policy_source={kind:"bundle",ref:"bundle:base-v1"};p.automation.rule_refresh_enabled=true;p.automation.rule_refresh_interval_seconds=604800;
 fs.writefile(ARGV[0],sprintf("%J",p));
 for(let file in [ARGV[1],ARGV[2]]) {const c=json(fs.readfile(file));c["rule-providers"]??={};c["rule-providers"]["cn-domain"]={type:"file",behavior:"domain",format:"mrs",path:"./rulesets/cn-domain.mrs"};c.rules=["RULE-SET,cn-domain,DIRECT",...(c.rules??[])];fs.writefile(file,sprintf("%J",c));}
 fs.writefile(ARGV[3],sprintf("%J",{upstream:{repository:"MetaCubeX/meta-rules-dat",commit:"1111111111111111111111111111111111111111"},rulesets:[{id:"cn-domain",url:"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/1111111111111111111111111111111111111111/geo/geosite/cn.mrs"}]}));' "$policy" "$source" "$config" "$lock"
/usr/bin/curl -q -fsS --unix-socket "$run/controller.sock" -X PUT -H 'Content-Type: application/json' --data-binary "{\"path\":\"$config\"}" 'http://localhost/configs?force=true'
cat >"$work/bin/curl" <<'CURL'
#!/bin/sh
output=''; previous='';url=''
for arg do
 [ "$previous" != -o ] || output=$arg
 previous=$arg
 case "$arg" in http*) url=$arg;; esac
done
case "$url" in
 https://api.github.com/repos/MetaCubeX/meta-rules-dat/commits/meta) printf '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"$output";;
 https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/*/geo/geosite/cn.mrs) cp "$RULE_DATA_FIXTURE/fixture.mrs" "$output";;
 https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/*/geo/geoip/cn.list) cp "$RULE_DATA_FIXTURE/cn.list" "$output";;
 'http://localhost/configs?force=true')
  if [ -f "$RULE_DATA_FIXTURE/fail-reload-once" ]; then rm "$RULE_DATA_FIXTURE/fail-reload-once"; exit 22; fi
  exec /usr/bin/curl "$@";;
 *) exec /usr/bin/curl "$@";;
esac
CURL
chmod 0755 "$work/bin/curl"
export RULE_DATA_FIXTURE="$work"
export PATH="$work/bin:$PATH"
run_update() { flock /var/lock/opl-netfleet-deploy.lock ucode "$main" rules-refresh fixture; }
getpid() { ubus call service list '{"name":"opl-netfleet-core"}' | jsonfilter -e '@["opl-netfleet-core"].instances.core.pid'; }
before_pid=$(getpid)
run_update >"$work/accepted.json"
test "$(jsonfilter -i "$work/accepted.json" -e '@.ok')" = true
test "$(getpid)" = "$before_pid"
first_success=$(jsonfilter -i "$root/history.json" -e '@.last_success_at')
first_config=$(sha256sum "$config")
first_active=$(sha256sum "$root/active.json")
printf 'invalid mrs' >"$work/fixture.mrs"
if run_update >"$work/invalid.json"; then exit 1; fi
test "$(sha256sum "$config")" = "$first_config"
test "$(sha256sum "$root/active.json")" = "$first_active"
test "$(jsonfilter -i "$root/history.json" -e '@.last_success_at')" = "$first_success"
cp /tmp/runtime-rulesets/cn-domain.mrs "$work/fixture.mrs"
printf '198.51.100.0/24\n2001:db8:beef::/48\n' >"$work/cn.list"
touch "$work/fail-reload-once"
if run_update >"$work/rollback.json"; then exit 1; fi
test "$(sha256sum "$config")" = "$first_config"
test ! -e "$root/pending.json"
test "$(sha256sum "$root/active.json")" = "$first_active"
/etc/init.d/opl-netfleet-core restart >/dev/null 2>&1
sleep 2
ucode -e 'import * as fs from "fs";const a=json(fs.readfile(ARGV[0])),c=json(fs.readfile(ARGV[1]));assert(c["rule-providers"]["cn-domain"].path==a.rules["cn-domain"].path);' "$root/active.json" "$config"
nft -j list set inet netfleet china_ip | grep -q '203.0.113.0'
nft -j list set inet netfleet china_ip6 | grep -q '2001:db8:abcd::'
printf '{"ok":true,"checks":{"real_core_reload":true,"core_pid_preserved":true,"invalid_mrs_retained":true,"reload_failure_rollback":true,"restart_generation_preserved":true,"both_country_sets":true}}\n'
