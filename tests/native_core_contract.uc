import { prepare } from "../openwrt/files/usr/libexec/opl-netfleet/core/native_core.uc";

function check(value, name) { if (!value) die(name); };
const input = {
	"proxy-providers": { source: { type: "file", path: "/etc/opl-netfleet/native/cache/alpha.json" } },
	"proxy-groups": [{ name: "Outbound", type: "select", use: ["source"] }],
	rules: ["MATCH,Outbound"], "mixed-port": 17890,
	"external-controller": "0.0.0.0:9090", secret: "private-secret",
	"tproxy-port": 17893, "redir-port": 17892, listeners: [{ name: "remote", port: 8080 }],
	"allow-lan": true, dns: { enable: true }, tun: { enable: true }
};
const sources = { alpha: { ready: true, cache_sha256: "digest" } };
const result = prepare(input, sources);
check(result.ok && result.stage.sources.alpha == "digest", "bind source");
const profile = result.stage.profile;
check(profile.dns.enable == false && profile.tun.enable == false && profile["allow-lan"] == false &&
	profile["bind-address"] == "127.0.0.1" && profile["tproxy-port"] == null && profile["redir-port"] == null &&
	profile.listeners == null && profile.secret == null && profile["external-controller"] == null &&
	profile["external-controller-unix"] == "/etc/opl-netfleet/native/core/controller.sock", "local core only");
check(!prepare({ ...input, "mixed-port": 53 }, sources).ok, "privileged port");
check(!prepare({ ...input, "mixed-port": "17890" }, sources).ok, "port type");
check(!prepare(input, {}).ok, "source absent");
check(!prepare(input, { alpha: { ready: false } }).ok, "source stale");
check(!prepare({ ...input, proxies: [{ name: "inline" }] }, sources).ok, "inline nodes");
check(!prepare({ ...input, "rule-providers": { remote: { type: "http" } } }, sources).ok, "remote rules");
check(!prepare({ ...input, rules: ["GEOIP,CN,DIRECT"] }, sources).ok, "implicit geodata download");
for (let path in ["/etc/nikki/subscriptions/alpha.yaml", "/etc/opl-netfleet/native/cache/../alpha.json"]) {
	check(!prepare({ ...input, "proxy-providers": { source: { type: "file", path: path } } }, sources).ok, "foreign cache");
}
check(!prepare({ ...input, "proxy-providers": { source: { type: "http", path: input["proxy-providers"].source.path } } }, sources).ok,
	"remote subscription writer");
print("native_core_contract_ok\n");
