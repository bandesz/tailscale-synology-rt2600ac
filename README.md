# Tailscale for the Synology RT2600ac

Unofficial [Tailscale](https://tailscale.com/) package for the Synology RT2600ac running SRM 1.3. It installs and runs from Package Center: install, start, stop, reboot, and upgrade, with the Tailscale web UI in the SRM main menu.

This is not a Tailscale or Synology product. The `tailscale` and `tailscaled` binaries are Tailscale's own armv7 DSM 7 build, downloaded at build time from [pkgs.tailscale.com](https://pkgs.tailscale.com/stable/). This repository repackages them so SRM will accept the package.

Tailscale is [BSD-licensed](https://github.com/tailscale/tailscale/blob/main/LICENSE). The packaging in this repository is [MIT-licensed](LICENSE).

## Why the official SPK does not install

Tailscale publishes Synology packages for DSM 6 and DSM 7. Package Center on the RT2600ac rejects them:

- The router platform is `ipq806x`. The DSM package says `armv7`.
- SRM 1.3 reports a version such as `1.3.2-9366`. The DSM package requires DSM 6 or DSM 7.
- The sideload packages are unsigned. With the default trust level, Package Center reports that the package does not contain a digital signature. Synology does not publish a key that third parties can sign with.

The armv7 DSM 7 binaries themselves run on this router. People have confirmed that by unpacking the SPK and starting `tailscaled` by hand. This package is that same payload, with metadata and scripts Package Center understands, plus the changes SRM needs for the admin UI.

It is built for the RT2600ac only. It is not a package for other SRM models. The RT6600ax, for example, is a 64-bit platform (`cypress`) and needs a different binary.

## Install

Download `tailscale-ipq806x-<version>-srm1.3.spk` from the Releases page of this repository, or build it yourself.

1. Open Package Center on the router.
2. Set the trust level to **Any publisher**. The package is unsigned, which is the same situation as other unsigned SRM packages. The setting is under Package Center settings.
3. Choose **Manual Install** and select the `.spk` file.
4. Start **Tailscale** after installation.

Package Center creates the service, starts it on boot, and keeps Tailscale's state across upgrades. State is stored in `/var/packages/Tailscale/var`, which an upgrade does not replace.

### Open the admin page

SRM lists the package in the main menu. Package Center's **Open** button goes to the same page. The address is:

```text
http://<router>:8000/webman/3rdparty/Tailscale/index.cgi/
```

On the default hostname that is `http://router.synology.com:8000/webman/3rdparty/Tailscale/index.cgi/`.

The page is Tailscale's own web UI (`tailscale web`), served by SRM's admin Apache. Use it to log in and change settings.

### DNS on a router

Each time the service starts, the package runs `tailscale set --accept-dns=false`. Tailscale's default after login is to send this machine's DNS queries to `100.100.100.100`. On the RT2600ac that machine is the router, so leaving the default on replaces the router's resolver and can take its own internet lookups down with it.

The setting is stored with the node and applied again on every start, including after a reboot. Other devices on the tailnet keep the DNS settings from the Tailscale admin console. Turning DNS back on in the Tailscale web UI lasts until the next time this service starts.

The package links the CLI at `/usr/local/bin/tailscale` when the service is running.

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

The SPK is written to `dist/`. Downloaded upstream packages are cached in `cache/` after their published SHA-256 is checked. Neither directory is part of the source tree.

What the build does:

1. Reads the latest stable version from the [tailscale/tailscale](https://github.com/tailscale/tailscale) GitHub releases, unless you passed a version.
2. Downloads `tailscale-armv7-<version>-<syno>-dsm7.spk` from `https://pkgs.tailscale.com/stable/` and checks `*.spk.sha256`.
3. Rewrites the package metadata for arch `ipq806x` and SRM 1.3 (`os_min_ver` `1.3-9193`).
4. Installs the lifecycle scripts in `srm/`.
5. Cross-compiles a small CGI helper (`srm/cgiwrap`) for 32-bit ARM. SRM serves the admin UI with Apache, as the web user. `tailscaled` only accepts configuration changes from root or from its configured operator, so the helper is installed setuid root and then runs `tailscale web -cgi`.

`mise run ci` is what GitHub Actions runs: shellcheck, a check of the Synology version numbering, and a full build.

| Task | Purpose |
| --- | --- |
| `mise run lint` | shellcheck on the scripts |
| `mise run test` | Synology version numbers used in download URLs |
| `mise run build` | Download Tailscale and build the SPK |
| `mise run ci` | lint, test, and build |
| `mise run release` | Build and attach the SPK to a GitHub release |

mise installs the two tools the build needs: Go (to cross-compile the CGI helper) and shellcheck. `curl` comes from the system.

## GitHub releases

A push of a tag named like `v1.104.7` builds that Tailscale version and attaches the SPK to a GitHub release of the same name:

```sh
git tag v1.104.7
git push origin v1.104.7
```

You can also run the Release workflow by hand from the Actions tab and type a version. Leave the version empty to package whatever the latest stable Tailscale release is.

From a checkout with the [GitHub CLI](https://cli.github.com/) already authenticated:

```sh
mise run release -- 1.104.7
```

If that release already exists, the SPK is uploaded again and replaces the previous asset.

## How it runs on the router

Package Center calls `srm/start-stop-status`.

- **start** loads the `tun` kernel module, creates `/dev/net/tun`, and starts `tailscaled` with its state and socket under `/var/packages/Tailscale/var`. The socket path matches what the `tailscale` binary looks for on anything other than DSM 6. SRM's version file is major version 1, so it is not treated as DSM 6.
- **start** also publishes the web UI into `/usr/syno/synoman/webman/3rdparty/Tailscale`, runs `tailscale set --accept-dns=false`, and, when it can see the admin web server's account, runs `tailscale set --operator` for that account.
- **stop** stops the daemon and removes the UI files.
- **status** exits 0 when `tailscaled` is running and 3 when it is stopped.

The package runs as root. `tailscaled` has to insert `tun.ko` and create the tunnel device. A package user cannot do that.

Upgrades replace `target/` and leave `var/` in place, so the node identity survives. There is no boot script outside Package Center.

## Limitations

- RT2600ac (arch `ipq806x`, 32-bit ARM) and SRM 1.3 only. The first SRM 1.3 release is `1.3-9193`.
- Unsigned. Package Center must trust any publisher, or installation stops with a missing-signature error.
- The web UI depends on SRM's Apache on port 8000. The menu URL is `3rdparty/Tailscale/index.cgi/` because the desktop is already under `/webman/`.
- `tailscale update` does not know the `ipq806x` platform. Upgrade by installing a newer SPK from this repository.
