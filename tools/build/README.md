# Kernel and rootfs build tools

Builds are local by default. `tools/build/kbuild.sh` builds the kernel in docker on the machine where you run it (see `docs/kernel.md` and the header of the script). `rootfs/build-rootfs.sh` builds the rootfs and `rootfs/mkbootimg.sh` builds the packed boot image, in the same way. None of these scripts needs a build host, ccache or an environment variable.

`tools/build/remote-build.sh` is an opt-in wrapper. It runs one of these builds on another machine over ssh. Use it for a bigger machine or one with a warm ccache. It changes nothing unless you set `BUILD_HOST` (the ssh destination) and `BUILD_DIR` (the path on that machine where the script mirrors this repo). If you set neither, it runs the same local build as the scripts above.

## Kernel flavors

The build uses one fork (`github.com/tsx-mainline/linux`) for two kernel flavors. See [../../docs/kernel.md](../../docs/kernel.md) for the branches and the order in which a change reaches them.

| Flavor | Branch | Pin file | Use |
|---|---|---|---|
| `lts` (default) | `tsx-xx60-lts` | `kernel/KERNEL_REV.lts` | Users install this flavor |
| `stable` | `tsx-xx60-stable` | `kernel/KERNEL_REV.stable` | The newest stable kernel |

A pin holds one commit hash. Every build tool below takes `-f` or `--flavor lts|stable` (or `$FLAVOR`). The default is `lts`.

## Tasks

### Build locally

```
tools/build/kbuild.sh                        # lts kernel: zImage + dtbs + modules + boot image
tools/build/kbuild.sh --flavor stable        # same, stable flavor
CCACHE=1 tools/build/kbuild.sh               # same, with a persistent ccache (~/.cache/tsx-ccache)
TSX_APK_LOCAL=<apk tree> rootfs/build-rootfs.sh all   # rootfs.ext4/.tar.gz + initramfs-switchroot.cpio.gz, from packages
rootfs/mkbootimg.sh                          # packs the installed-system boot image
PROFILE=console TSX_APK_LOCAL=<apk tree> rootfs/build-rootfs.sh rootfs   # a rootfs without the kiosk and Home Assistant
```

`kbuild.sh` reads the kernel source from `LINUX_DIR` (default: `../linux-<flavor>`, for example `../linux-lts`, a sibling checkout of this repo). If that directory does not exist, the script clones `https://github.com/tsx-mainline/linux` and checks out the commit that `kernel/KERNEL_REV.<flavor>` pins. The script uses an existing `LINUX_DIR` as it is and never changes it. If its HEAD does not match `kernel/KERNEL_REV.<flavor>`, the script only prints a warning.

### Build remotely (optional)

1. Make sure `ssh -o BatchMode=yes BUILD_HOST` works without a prompt. `BUILD_HOST` needs docker and rsync.
2. Make sure the kernel fork checkout is at `$(dirname BUILD_DIR)/linux` on both machines. Set `REMOTE_LINUX_DIR` to change this path.
3. Make sure the fork checkout has one worktree for each branch on both machines: `git worktree add ../linux-6.18 tsx-xx60-lts` and `git worktree add ../linux-7.2 tsx-xx60-stable`. `remote-build.sh` finds the right worktree by its branch. It does not create worktrees.
4. Run the build:

```
BUILD_HOST=<ssh host> BUILD_DIR=<path on that host> \
  tools/build/remote-build.sh [--flavor lts|stable] [--dest DIR] [--no-pull] [-j N] <command> [arg]
```

A kernel build with a cold cache takes a long time. Start it as a background job and read the log.

### Leave the artifacts on the build host

Use `--no-pull` (or `REMOTE_PULL=0`). The artifacts of a rootfs build are about 1.1 GB. Over a slow link, such as a VPN, the copy can take much longer than the build. The copy is also wasted work when the next step (`image`, packaging, install) runs on `BUILD_HOST` too.

```
BUILD_HOST=<ssh host> BUILD_DIR=<path on that host> \
  tools/build/remote-build.sh --no-pull rootfs
# artifacts left on <ssh host>: <path>/rootfs.ext4, ...
```

### Stage the kernel modules

The image gets its kernel modules from the kernel packages, which hold both flavors. `rootfs/build-rootfs.sh modules` is for the kernel bundle of tsx-aports (the `kbundle` job of `.github/workflows/release.yml`). The release build also puts the staged tree of its own kernel in the image when no kernel package has it. A `rootfs` build through `remote-build.sh` clears `rootfs/modules/` on the host first. The command stages one kernel build dir (`KBUILD`) into `rootfs/modules/lib/modules/<release>`. It replaces only that release and older trees of the same series (the same `major.minor`). The tree of the other flavor stays. If you do not set `KBUILD`, it stages every default flavor build dir that `kbuild.sh` made next to this repo (`../build-lts` and `../build-stable`).

```
tools/build/kbuild.sh --flavor lts kernel
tools/build/kbuild.sh --flavor stable kernel
rootfs/build-rootfs.sh modules      # both trees
```

### Run kbuild.sh directly on the build host

`kbuild.sh` is a plain local build script. If you already have a shell on the remote host, run it there in the same way as locally. It does not need `remote-build.sh`.

```
ssh $BUILD_HOST "$BUILD_DIR/tools/build/kbuild.sh -w $REMOTE_LINUX_DIR stats"
```

### Make a release build

Use a clean export or worktree, because `remote-build.sh` refuses ignored and proprietary files (see "Ignored and proprietary files"):

```
git worktree add ../wt-build <commit>
# or: git archive <commit> | tar -x -C <empty dir>
```

## Reference

### Rootfs variables

| Variable | Meaning |
|---|---|
| `PROFILE` | `console`, `kiosk` or `ha` (default `ha`, see `docs/rootfs.md` "Profiles") |
| `TSX_DEV_ROOT_HASH` | A crypt(3) hash for the root password of a test image. Without it, the root password is locked and the installer sets the login (`docs/rootfs.md` "Root login"). Make a hash with `openssl passwd -6 PASSWORD`. A public image never uses it |
| `TSX_DEV_RESCUE_HASH` | The same for the rescue initramfs (`rootfs/build-rootfs.sh initramfs`, `docs/recovery.md` "Rescue login") |
| `CHROMIUM_ES2_PATCH` | `0` builds the rootfs without the Chromium ES2 patch |
| `TSX_ALLOW_PROPRIETARY` | `1` fetches the proprietary files and skips the check. For a private image on your own machine. Never use it for a release |

`remote-build.sh rootfs` passes `TSX_DEV_ROOT_HASH` and `TSX_DEV_RESCUE_HASH` to the build host.

### kbuild.sh

```
tools/build/kbuild.sh [-f lts|stable] [-w LINUX_DIR] [-o BUILD_DIR] [-d OUT_DIR] [-j N] [config|kernel|image|cmd "<make args>"|stats]...
```

| Option | Default |
|---|---|
| `-f` | `lts` |
| `-w` | `$LINUX_DIR` |
| `-o` | `<LINUX_DIR>/../build-<flavor>` |
| `-d` | `<LINUX_DIR>/../out-<flavor>` |
| `-j` | All cores |
| Steps | `kernel image` |

The default directories of the two flavors never collide, so a build of one flavor does not disturb the other.

| Step | What it does |
|---|---|
| `config` | Merges `multi_v7_defconfig`. Then it runs `merge_config.sh` with `arch/arm/configs/tsx-xx60.config` (the fragment has the same name on both branches). Then it runs `olddefconfig`. Last, it prints a `WARN:` line for each fragment option that did not survive |
| `kernel` | Builds `zImage dtbs modules`. It runs `config` automatically when `.config` is missing or the fragment changed. Only `build-rootfs.sh modules` needs the modules |
| `image` | Copies `zImage` and the board DTB to the out dir. It packs `test.img` with `kernel/mkimage.sh`. It adds an initrd if `rootfs/out/initramfs-switchroot.cpio.gz` already exists |
| `cmd "<make args>"` | Runs `make` with the given arguments |
| `stats` | Prints ccache statistics (only with `CCACHE=1`) |

`CCACHE=1` builds `ci/Dockerfile.ccache` on top of `ci/Dockerfile.mainline` and mounts a persistent cache (`CCACHE_DIR`, default `~/.cache/tsx-ccache`). This is optional. A first build without ccache works. Only rebuilds are slower.

### remote-build.sh commands

| Command | What it does |
|---|---|
| `kernel [BRANCH]` | Pushes the worktree with `BRANCH` checked out, and the shared `.git`. The default branch follows `--flavor` or `$FLAVOR`: `lts` (the default) uses `tsx-xx60-lts` and `stable` uses `tsx-xx60-stable`. An explicit `BRANCH` argument overrides this. Then it runs `kbuild.sh -f <flavor>` on `BUILD_HOST` and pulls back `zImage`, the board DTB, `test.img`, `kernel.release` and `kernel.commit` |
| `rootfs` | Needs `TSX_APK_LOCAL`, a local copy of the published apk tree (`rootfs/fetch-apk-tree.sh` makes one). Pushes the `rootfs/` sources and the tree, runs `build-rootfs.sh rootfs` there and pulls back `rootfs.{ext4,tar.gz,manifest,sizes,sha256}` |
| `initramfs` | Needs `TSX_APK_LOCAL` too. Runs `build-rootfs.sh initramfs` to make `initramfs-switchroot.cpio.gz` |
| `image [BRANCH]` | Runs `mkbootimg.sh` with the kernel build of the host for the resolved flavor and branch. `kernel` must have run there first |
| `sync` | Mirrors the full tree again (no `--delete`) |
| `jobs` | Lists the last jobs on the host and their exit codes |

| Option | What |
|---|---|
| `--flavor lts\|stable` | Kernel flavor (also `$FLAVOR`) |
| `--dest DIR` | Puts the pulled-back artifacts in `DIR` instead of the default place |
| `--no-pull` | Does not copy the built artifacts back. It only prints where they are on `BUILD_HOST` (also `REMOTE_PULL=0`) |
| `-j N` | Parallel jobs of the kernel make (default: all cores on the host) |

If you do not set `BUILD_HOST`, each command runs the matching local script (`kbuild.sh`, `build-rootfs.sh`, `mkbootimg.sh`) and exits. `BUILD_DIR` is then unused. `kernel` still uses `--flavor` and `$FLAVOR`, because `kbuild.sh` takes them. If you set `BUILD_HOST`, `BUILD_DIR` is required.

### What gets sent

- Always: `tools/build/` (without its `state/` job logs), `ci/`, `kernel/mkimage.sh`, `kernel/aml-dt.py`, `kernel/KERNEL_REV.lts`, `kernel/KERNEL_REV.stable` and `kernel/out/initramfs.cpio.gz` if it exists. The script sends both pins whatever `--flavor` says. This is cheap, and `kbuild.sh` then warns correctly for either flavor.
- `kernel`: the shared `.git/` of the fork (with `--delete`, `*.lock` excluded) and the worktree directory (with `--delete`). The push includes uncommitted changes, so the remote build matches the local working tree exactly. The `.git` file of a linked worktree and `worktrees/<name>/gitdir` of the fork hold local absolute paths. After the push, the script rewrites them to the remote copy. Git on the host then never reads a repository that exists at the local path there (wrong HEAD, `-dirty` release).
- `rootfs`, `initramfs`, `image`: `rootfs/{overlay,profiles,src,initramfs,config}/` (with `--delete`), `mkrootfs.sh`, `build-rootfs.sh`, `profile.sh`, `mkbootimg.sh` and `authorized_keys`.

The script uses `--delete` only on these source directories on the remote host. It never sends or deletes the build and output directories there.

### Ignored and proprietary files

Before it sends anything, the script runs `git status --ignored` on the folders it copies. It stops with a non-zero exit when one of them holds an ignored file, or an untracked `.cnt`, `.puf` or `.psr` file. The message lists the files and sends nothing. The build output directories are allowed. A tree that is not a git checkout, such as a `git archive` export, has nothing to check.

A `rootfs` build through this script uses `TFA_VENDOR_FETCH=no` and runs `ci/check-no-proprietary.sh` on the finished tarball on the host. The build fails when the tarball holds a Crestron file, and nothing comes back.

### Safety rules

- The script never deletes a local file. The copy back uses `rsync` without `--delete` and writes only the named artifacts. It does overwrite files with the same names in the destination. Use `--dest` if another process reads the same `out/` directory at the same time.
- The build runs detached on the remote host (`setsid`). If the ssh link breaks or this script stops, the job continues. Its log is in `<BUILD_DIR>/tools/build/state/jobs/<job>.log` (`remote-build.sh jobs`).
- Two kernel builds of the same branch wait for each other (`flock` on the host, for each branch). Builds of different worktrees run in parallel. This includes the `lts` and `stable` flavors at the same time. `rootfs` and `initramfs` share one lock.
- If two callers build the same branch on the same host at the same time, they overwrite the sources of each other during the push. Build a branch from one caller at a time.

### Limits

- `remote-build.sh` has no `vendor`, `dtbs_check` or busybox-initramfs targets. Run those directly on the target machine with the existing scripts. `ci/Dockerfile.dt` builds the `dtbs_check` image.
- `image` uses the kernel in `out-<flavor>/` on the same host. For a remote build, run `kernel` there first (with the same `--flavor`).

## CI release asset for tsx-aports (`tsx-xx60-kernel-<flavor>-bundle.tar.zst`)

The `kbundle` job (matrix `lts` and `stable`) in `.github/workflows/release.yml`
packs one extra small asset for each tagged release. The release publishes it
next to the install payload tarballs. The asset holds these files:

- `zImage`
- the board DTB
- the packed eMMC boot image (renamed `tsxboot-emmc.img`, the same file as
  `tsxboot.img` from `rootfs/mkbootimg.sh`)
- the stripped `.ko` tree of the flavor, as `modules-<kernelrelease>.tar.gz`
- `kernel.release`
- `kernel.commit`
- `CHECKSUMS.sha256`, with the sha256 of `zImage`, the board DTB, the boot
  image and the modules tarball

The first six files are the files that `scripts/stage-kernel.sh` in the
[tsx-aports](https://github.com/tsx-mainline/tsx-aports) repo stages from a
build host. The job does not rebuild anything. It uses the artifacts of the
`kernel` and `payload` jobs.

The CI of tsx-aports has no build host to stage from (see the header of
`scripts/stage-kernel.sh` in that repo). It uses this asset. The packages
`xx60/tsx-xx60-kernel-lts` and `xx60/tsx-xx60-kernel-stable` pin a release tag
and the sha512sum of this bundle in `source=` and `sha512sums=` of their
`APKBUILD`. Plain `abuild` then fetches and verifies the bundle over the
network. It needs no secret, no ssh and no copy of the kernel build logic.
For a local or `BUILD_HOST` package build of a kernel that has no tag, use
`stage-kernel.sh`. See its header.

## Vendor kernel bootstrap

`kernel/restore-vendor-asm.sh` restores the missing `.S` files from the GPL
drop of the vendor 3.10 kernel. You need it only to work on that tree, not on
the mainline port.

### Rebuild the images of a release (images only)

A tag starts `release.yml`, which builds the images from the packages that are live at that time. The packages of the same release go live in tsx-aports later, because their recipes need the tag archives and the kernel bundles. So the payloads of a new release can have the packages of the previous release.

Do not rerun the whole release run for this. The `kbundle` job would pack the kernel bundles again with new sha512 sums, and the kernel recipes in tsx-aports would no longer match them. Use the images-only run instead:

1. Make sure that the tsx-aports packages of the release are live.
2. Run `gh workflow run release.yml -f tag=<tag>`, for example `-f tag=v0.2.1`.

The run checks out the tag and builds the kernels, the rootfs, the rescue image and both payloads from the packages that are live now. The `kbundle` job does not run. The run replaces only `tsx-xx60-lts-payload.tar.zst`, `tsx-xx60-stable-payload.tar.zst` and their two lines in `SHA256SUMS`. The kernel bundles and the other kernel files of the release stay as they are.
