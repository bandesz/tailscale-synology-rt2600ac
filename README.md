# Tailscale for Synology SRM

Unofficial [Tailscale](https://tailscale.com/) packages for Synology routers running SRM 1.3. The supported models are the RT2600ac and the WRX560. A package installs and runs from Package Center: install, start, stop, reboot, and upgrade, with the Tailscale web UI in the SRM main menu.

This is not a Tailscale or Synology product. The `tailscale` and `tailscaled` binaries are Tailscale's own armv7 DSM 7 build, downloaded at build time from [pkgs.tailscale.com](https://pkgs.tailscale.com/stable/). This repository repackages them so SRM will accept the package.

Tailscale is [BSD-licensed](https://github.com/tailscale/tailscale/blob/main/LICENSE). The packaging in this repository is [MIT-licensed](LICENSE).

## Why the official SPK does not install

Tailscale publishes Synology packages for DSM 6 and DSM 7. Package Center on the RT2600ac and the WRX560 rejects them:

- The router platform is `ipq806x` (RT2600ac) or `hawkeye` (WRX560). The DSM package says `armv7`.
- SRM 1.3 reports a version such as `1.3.2-9366`. The DSM package requires DSM 6 or DSM 7.
- The sideload packages are unsigned. With the default trust level, Package Center reports that the package does not contain a digital signature. Synology does not publish a key that third parties can sign with.

The armv7 DSM 7 binaries themselves run on these routers. People have confirmed that by unpacking the SPK and starting `tailscaled` by hand. This package is that same payload, with metadata and scripts Package Center understands, plus the changes SRM needs for the admin UI.

Supported build targets are RT2600ac (`ipq806x`, the default) and WRX560 (`hawkeye`). Other SRM models are not supported. [Adding another SRM router](#adding-another-srm-router) is how a fork adds one. The RT6600ax, for example, is a 64-bit platform (`cypress`) and needs a different binary.

## Install

For the RT2600ac, download `tailscale-ipq806x-<version>-<syno>-srm1.3.spk` from the Releases page of this repository, or build it yourself. For the WRX560, download `tailscale-hawkeye-<version>-<syno>-srm1.3.spk` from the Releases page, or build it with the instructions below.

`<syno>` is the Synology build number in Tailscale's package (700104007 for 1.104.7), and a built file follows the upstream INFO version when that string differs from the `--print-target` preview.

The WRX560 needs a storage volume before the package can start. On the tested router, Package Center failed with "There is no volume" until a USB drive was attached. Operation without USB storage is not established.

1. Open Package Center on the router.
2. Set the trust level to **Any publisher**. The package is unsigned, which is the same situation as other unsigned SRM packages. The setting is under Package Center settings.
3. Choose **Manual Install** and select the `.spk` file.
4. On the **Tailscale routing** step, leave both boxes checked or clear the ones you do not want. **Advertise LAN subnets** offers this router's LANs. **Advertise as an exit node** offers this router's internet connection. The same step is shown again when the package is upgraded, with the saved choices already filled in.
5. Start **Tailscale** after installation.

Package Center creates the service, starts it on boot, and keeps Tailscale's state across upgrades. State is stored in `/var/packages/Tailscale/var` and is backed up and restored by the package lifecycle scripts during upgrades.

### Open the admin page

SRM lists the package in the main menu. On the tested WRX560 installation, the main-menu entry opens the web UI, but Package Center does not show an **Open** button. Where available, the Package Center **Open** button goes to the same page. The address is:

```text
http://<router>:8000/webman/3rdparty/Tailscale/index.cgi/
```

On the default hostname that is `http://router.synology.com:8000/webman/3rdparty/Tailscale/index.cgi/`.

The page is Tailscale's own web UI (`tailscale web`), served by SRM's admin Apache. Use it to log in and change settings.

### DNS on a router

Each time the service starts, the package runs `tailscale set --accept-dns=false`. Tailscale's default after login is to send this machine's DNS queries to `100.100.100.100`. On the RT2600ac/WRX560 that machine is the router, so leaving the default on replaces the router's resolver and can take its own internet lookups down with it.

The setting is stored with the node and applied again on every start, including after a reboot. Other devices on the tailnet keep the DNS settings from the Tailscale admin console. Turning DNS back on in the Tailscale web UI lasts until the next time this service starts.

The package links the CLI at `/usr/local/bin/tailscale` when the service is running.

### Subnet routes and exit node

On each start the package turns on IPv4 forwarding and applies the choices from installation. If the node is not logged in yet, it waits and applies them once login finishes. The page in the SRM menu does not edit these offers.

Approve them in the [Tailscale admin console](https://login.tailscale.com/admin/machines) before other devices can use them. Tailscale on Synology forwards approved traffic in userspace (TCP and UDP). This package does not add iptables rules. The router cannot itself send its traffic through some other exit node.

**Advertise LAN subnets** offers the private IPv4 networks that are directly connected, excluding the WAN interface (the one with the default route) and `tailscale0`. To advertise a different list, write the prefixes to `/var/packages/Tailscale/var/advertise-routes`, separated by commas or whitespace. An empty file advertises no routes. Delete the file to go back to detecting the LANs. That file is ignored while the LAN choice is off.

**Advertise as an exit node** offers this router as an exit node (`tailscale set --advertise-exit-node`). Other devices can select it after the admin console approval.

The choices are stored as `true` or `false` in `/var/packages/Tailscale/var/advertise-lan` and `/var/packages/Tailscale/var/advertise-exit-node`. A missing file stays on, which is what happens when Package Center does not show the routing step. The files are kept across an upgrade together with the node key. Change a choice by upgrading the package, or by writing `true` or `false` into the file and restarting the service.

### Direct connections

The daemon listens on UDP port 41641. Without a firewall pass for that port, Tailscale still works and relays connections through DERP. Allowing UDP 41641 on the router is what makes direct WireGuard connections possible. This package does not add that firewall rule.

## Build

Install [mise](https://mise.jdx.dev/), then, from this directory:

```sh
mise install
mise run build
```

`mise run build` with no arguments packages the latest stable Tailscale release. To package a specific release:

```sh
mise run build -- 1.104.7
```

The default target remains RT2600ac (`ipq806x`). To build for WRX560:

```sh
SRM_ARCH=hawkeye mise run build -- 1.104.7
```

You can also invoke the build script directly with `SRM_ARCH=hawkeye`.
Target selection changes the package metadata and output filename; both
targets use the upstream armv7 DSM 7 payload and the ARMv7 CGI helper.

The SPK is written to `dist/`. Downloaded upstream packages are cached in `cache/` after their published SHA-256 is checked. Neither directory is part of the source tree.

What the build does:

1. Reads the latest stable version from the [tailscale/tailscale](https://github.com/tailscale/tailscale) GitHub releases, unless you passed a version.
2. Downloads `tailscale-armv7-<version>-<syno>-dsm7.spk` from `https://pkgs.tailscale.com/stable/` and checks `*.spk.sha256`.
3. Rewrites the package metadata for the selected arch (`ipq806x` or `hawkeye`) and SRM 1.3 (`os_min_ver` `1.3-9193`).
4. Installs the lifecycle scripts in `srm/`.
5. Cross-compiles a small CGI helper (`srm/cgiwrap`) for 32-bit ARM. SRM serves the admin UI with Apache, as the web user. `tailscaled` only accepts configuration changes from root or from its configured operator, so the helper is installed setuid root and then runs `tailscale web -cgi`.

`mise run ci` runs shellcheck, the shell tests, and a build of the default arch. GitHub Actions runs the lint and tests once, then builds `ipq806x` and `hawkeye` separately.

| Task | Purpose |
| --- | --- |
| `mise run lint` | shellcheck on the scripts |
| `mise run test` | Synology version numbers, DNS off on start, LAN route advertisement, and the install routing choices |
| `mise run build` | Download Tailscale and build the SPK for the selected arch (`ipq806x` by default) |
| `mise run ci` | lint, test, and build the default arch |
| `mise run release` | Build both SRM packages and attach them to a GitHub release |

mise installs the two tools the build needs: Go (to cross-compile the CGI helper) and shellcheck. `curl` comes from the system.

## GitHub releases

A push of a tag named like `v1.104.7` builds that Tailscale version for both RT2600ac (`ipq806x`) and WRX560 (`hawkeye`) and attaches both SPKs to a GitHub release of the same name:

```sh
git tag v1.104.7
git push origin v1.104.7
```

You can also run the Release workflow by hand from the Actions tab and type a version. Leave the version empty to package whatever the latest stable Tailscale release is.

From a checkout with the [GitHub CLI](https://cli.github.com/) already authenticated:

```sh
mise run release -- 1.104.7
```

If that release already exists, both SPKs are uploaded again, replacing
assets with the same filenames. Existing release notes are not changed.

The release task always builds both targets, independently of `SRM_ARCH`.
Both packages use the same Tailscale version. To build and inspect the release
without invoking GitHub CLI or publishing anything, set `RELEASE_DRY_RUN=1`.
The build still downloads upstream packages as needed.

## How it runs on the router

Package Center calls `srm/start-stop-status`.

- **start** loads the `tun` kernel module, creates `/dev/net/tun`, and starts `tailscaled` with its state and socket under `/var/packages/Tailscale/var`. The socket path matches what the `tailscale` binary looks for on anything other than DSM 6. SRM's version file is major version 1, so it is not treated as DSM 6.
- **start** also publishes the web UI into `/usr/syno/synoman/webman/3rdparty/Tailscale`, runs `tailscale set --accept-dns=false`, enables IPv4 forwarding, applies the saved LAN and exit-node choices with `tailscale set --advertise-routes` and `tailscale set --advertise-exit-node`, and, when it can see the admin web server's account, runs `tailscale set --operator` for that account.
- **stop** stops the daemon and removes the UI files.
- **status** exits 0 when `tailscaled` is running and 3 when it is stopped.

The package runs as root. `tailscaled` has to insert `tun.ko` and create the tunnel device. A package user cannot do that.

Upgrades replace `target/`. On SRM that also removes `var/`, which is where Tailscale keeps its node key, so before the files are removed the key is copied to `/usr/syno/etc/packages/Tailscale` and restored afterwards. There is no boot script outside Package Center.

## Limitations

- RT2600ac (arch `ipq806x`) and WRX560 (arch `hawkeye`), using 32-bit ARM binaries on SRM 1.3 only. The first SRM 1.3 release is `1.3-9193`.
- Unsigned. Package Center must trust any publisher, or installation stops with a missing-signature error.
- The web UI depends on SRM's Apache on port 8000. The menu URL is `3rdparty/Tailscale/index.cgi/` because the desktop is already under `/webman/`.
- These SRM packages should not be upgraded using `tailscale update`. Upgrade by installing a newer SPK from this repository.
- The WRX560 needs a storage volume. Without one, Package Center reports "There is no volume" and the package does not start. The tested installation used USB storage.

### WRX560 testing status

Tested on a WRX560 running SRM 1.3.2-9366 Update 3, with an
ARMv7 Linux 4.4.60 kernel, using Tailscale 1.104.7:

- Manual installation through Package Center succeeded.
- A same-version Package Center upgrade completed successfully.
- Package stop/start succeeded and preserved the Tailscale IP.
- Automatic package startup and reconnection after reboot were verified
  without interacting with the Tailscale web UI. The router initially had
  an incorrect clock; after time synchronization, Tailscale reconnected by
  approximately two minutes of router uptime.
- Post-reboot Tailscale ping to another tailnet device succeeded via DERP.
  Direct peer connectivity was not established by this test.
- Normal Wi-Fi internet access and the SRM main-menu web UI entry worked.
- Package Center did not offer an Open button on the tested installation.
- Subnet forwarding and exit-node forwarding have not been verified.
- Testing used attached USB storage. Before attaching it, an earlier
  installation attempt failed to start with a "There is no volume" error.
  Operation without USB storage has not been established.

These results do not establish support for other SRM router models.

## Adding another SRM router

This repository ships packages for the RT2600ac and the WRX560. A fork
adds and tests another SRM 1.3 router by adding one `arch model` row to
`srm/targets`. The first row is the default when `SRM_ARCH` is unset.

`build-srm-spk.sh`, `scripts/release.sh`, and `.github/workflows/ci.yml`
already read `srm/targets`. Do not copy the router into those files.
`test/srm-targets.sh` reads the same list.

These pieces are shared:

- The lifecycle scripts in `srm/`.
- The armv7 DSM 7 payload.
- `srm/cgiwrap`.
- `os_min_ver` `1.3-9193`.

These pieces are model-specific:

- The INFO arch and the model name.
- The package path `dist/tailscale-<arch>-<version>-<syno>-srm1.3.spk`.
- Device notes such as the storage volume, the Open button, and the clock,
  in the README install and limitations text and in the release notes.
  Those notes are prose in `scripts/release.sh`, next to the per-model
  bullet that `srm/targets` already fills in.

A 64-bit model such as the RT6600ax (`cypress`) is not a new row. This
tree downloads the armv7 DSM 7 SPK only.

Build the new arch with:

```sh
SRM_ARCH=<arch> mise run build -- <version>
```

Local checks are `mise run test` and
`sh build-srm-spk.sh --print-target <version>`. Set `SRM_ARCH` on that
print command when the row is not the default. `mise run ci` builds the
default arch only. GitHub Actions builds every row.

On the device, use the WRX560 results above as the checklist: manual
install, same-version upgrade, stop/start, reboot and reconnect, clock,
storage volume, and whether Package Center shows Open. Subnet and
exit-node forwarding stay unverified until tried. Record model-specific
failures in this README. The RT2600ac and the WRX560 do not cover the new
router.
