<p align="center">
  <img src="assets/branding/opl-netfleet-logo.png" alt="OPL NetFleet logo" width="136" />
</p>

<p align="center">
  <a href="./README.md">中文</a> | <strong>English</strong>
</p>

<h1 align="center">OPL NetFleet</h1>

<p align="center"><strong>A network enhancement plugin for OpenWrt</strong></p>
<p align="center">Multi-provider integration · layered selection · smooth switching · automatic recovery</p>

<p align="center">
  <a href="https://github.com/gaofeng21cn/opl-netfleet/actions"><img src="https://img.shields.io/github/actions/workflow/status/gaofeng21cn/opl-netfleet/netfleet-release.yml?label=checks" alt="Checks" /></a>
  <a href="https://github.com/gaofeng21cn/opl-netfleet/releases/latest"><img src="https://img.shields.io/github/v/release/gaofeng21cn/opl-netfleet" alt="Latest release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="Apache-2.0 license" /></a>
</p>

NetFleet makes multi-provider network management easier on OpenWrt devices that
use Nikki and Mihomo. It organizes nodes by provider, region, and purpose,
chooses an appropriate exit from current measurements, and switches paths as
network conditions change.

You continue to use LuCI to view status, adjust preferences, and turn the
enhancement off. NetFleet keeps a native profile available as the recovery
destination, so a failed takeover can return the device to a familiar working
configuration.

## What You Get

- **One view for multiple providers.** See providers, regions, nodes, latency, and subscription usage together.
- **A clear path to a better exit.** NetFleet compares regions, provider tiers, and individual nodes in that order.
- **Purpose-based exits.** Standard traffic and services with region requirements can use separate capabilities, or share a region when conditions allow.
- **Primary and reserve tiers.** Normal traffic prefers primary providers, then reserve providers, and finally `DIRECT`.
- **Continuous health checks.** Scheduled refreshes update subscriptions, measurements, transparent proxy, and DNS state.
- **Controlled activation.** Setup, candidate generation, and live takeover are separate steps with visible state and a native recovery profile.

## Design Approach

NetFleet separates what a user needs from the node that happens to provide it.
Rules select stable capabilities such as standard connectivity or a
region-constrained service. Providers and nodes remain replaceable resources.
Adding a provider or replacing a node therefore does not require rewriting the
user's rules.

Selection has three layers:

1. **Region** shapes distance, availability, and connection experience.
2. **Provider** represents an independent service and quota domain.
3. **Node** is selected and refreshed by Mihomo URLTest within the chosen region.

Each round uses current measurements and a switch margin, keeping the active
path stable during small latency fluctuations. History helps explain what the
device has seen; the current choice follows the latest healthy measurements.

Nikki continues to manage subscriptions, profiles, and the OpenWrt data-plane
lifecycle. Mihomo continues to manage connections and node health. NetFleet
adds the shared policy model, automatic selection, and recovery experience on
top of those capabilities.

Read the [product whitepaper](docs/product/whitepaper.md) for the full rationale
and the [architecture overview](docs/architecture/overview.md) for current
implementation behavior.

## Current Features

The current release includes native LuCI pages and a device-side runtime with:

- first-run discovery of the native Nikki profile, provider caches, regions, and the `MATCH` entry group;
- primary/reserve provider roles and region scope settings;
- automatic region selection for `standard` and `ai-compatible` capabilities;
- provider, region, and node health checks;
- protected probes, layered Fail-Open, and native profile recovery;
- provider, region, node, subscription, event, and connection diagnostics;
- scheduled subscription refresh, configuration compilation, and automatic selection;
- OpenWrt APK/IPK packages, signed APK feeds, and Fleet declarative deployment.

The connections page currently focuses on practical read-only diagnosis. A
full Mihomo real-time observation surface is being designed separately.

## Installation

### Prerequisites

The target device should have:

- a working OpenWrt package manager;
- Nikki and Mihomo installed and running;
- a native Nikki profile that can be used independently;
- at least one stable named subscription with a valid local cache.

Download both packages from the same release. For OpenWrt 25.12 with APK:

```sh
apk add --upgrade ./opl-netfleet-<version>.apk ./luci-app-netfleet-<version>.apk
```

Open **Services -> NetFleet** in LuCI. First-run setup will:

1. discover the native profile, provider caches, regions, and the `MATCH` entry group;
2. check the environment and show a recommended configuration;
3. generate and compile the policy after your confirmation;
4. start NetFleet and read back runtime and probe status.

Subscriptions remain managed by Nikki and stored in the device's private
configuration. After setup, provider roles, region scope, refresh interval, and
protected probes can be adjusted from the configuration page.

## Upgrading

Install the two packages from the same release together:

```sh
apk add --upgrade ./opl-netfleet-<version>.apk ./luci-app-netfleet-<version>.apk
```

Releases also provide a signed `packages.adb` feed for OpenWrt's package
manager. Package upgrades refresh program files while keeping policy,
subscription caches, and the active configuration in place. Review the status
page after the upgrade and apply a new configuration when ready.

## Everyday Use

### Automatic Selection

When enabled, NetFleet refreshes subscriptions on schedule and runs one bounded
health-check round. The root capability chooses a region first. A capability
with additional region requirements follows that region when it qualifies, or
chooses its own fastest qualified region. Mihomo URLTest keeps the node inside
that region healthy.

The visible fallback order is:

```text
preferred -> other primary providers -> reserve providers -> DIRECT
```

LuCI shows the active capability, region, provider, node, selection reason, and
fallback state.

### Closing And Recovery

Disabling NetFleet switches back to the Recovery Profile selected during setup
and checks Nikki, Mihomo, transparent proxy, and DNS state. If that native
profile cannot be restored, Nikki's official cleanup path provides direct
traffic and the device reports the actual probe result.

## Fleet Deployment

Direct LuCI setup suits a single device. For reproducible multi-device rollout,
use the Fleet deployment entry point with a bundle rendered by a private OPL
Instance:

```bash
scripts/deploy-openwrt.sh <ssh-target> --ref <release-or-commit> \
  --packages /private/path/netfleet-packages \
  --instance /private/path/deployment-bundle
```

The bundle contains policy, subscription references, a Nikki mixin, and a
platform declaration. The default path installs, compiles, and reads back a
staged result. Add `--activate` after the same source has passed OpenWrt QEMU
qualification to enable the target and perform the final readback.

For rollout, complete the full compile, enable, readback, and disable cycle on
a locally recoverable canary before promoting the same package and configuration
to separately authorized replicas. See [Canary promotion and recovery](docs/operations/canary-promotion.md).

## Development

Fast source and contract checks:

```bash
scripts/check-fast.sh
```

Full fake-device deployment matrix:

```bash
scripts/check-full.sh
```

The React/Vite surface is a quick local reference for information hierarchy and
interaction. Native LuCI remains the device surface:

```bash
cd ui
bun install
NETFLEET_UI_TARGET=<ssh-alias> NETFLEET_UI_TARGET_LABEL="Canary" bun run dev
```

## Documentation And License

- [Documentation index](docs/README.md)
- [Architecture overview](docs/architecture/overview.md)
- [UI design](docs/design/ui.md)
- [Product whitepaper](docs/product/whitepaper.md)
- [Development and device-operation rules](AGENTS.md)

OPL NetFleet is released under the [Apache License 2.0](./LICENSE).
