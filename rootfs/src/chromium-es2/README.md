# Chromium ES3 to ES2 fallback patch (browser)

The Mali-450 GPU of the panel supports only OpenGL ES 2.0. This patch changes one branch in the Chromium binary, so that Chromium falls back from ES3 to ES2 when the ES3 context fails.

## Tasks

### Check, apply or revert the patch on the panel

Run these commands on the panel. The tool needs no python.

1. Run `tsx-chromium-es2 check` or `tsx-chromium-es2 status` to see the state.
2. To patch the binary again, run `tsx-chromium-es2 apply`.
3. To go back, see "Revert".

### Add a new Chromium package version

The project apk repository (tsx-aports) builds `tsx-xx60-chromium` with `patch-chromium.py` and `sigs.json` of this folder. The image build installs that package. `rootfs/packages.txt` pins `chromium=<ver>` to the exact build that the signature list covers, but the image build drops that line. A new `sigs.json` entry must reach tsx-aports too (see its README, section "Chromium").

1. Change the pin. Set `chromium=<ver>` in `rootfs/packages.txt` to the new version. To find the exact `<ver>-rN` string, run `apk add --root ... --simulate chromium` against `dl-cdn.alpinelinux.org/alpine/vX.Y/community/armv7`.
2. Get the new binary. Take `/usr/lib/chromium/chromium` from the Alpine package (`apk fetch chromium=<ver>`, then `tar -xzf chromium-<ver>.apk usr/lib/chromium/chromium`).
3. Run `python3 patch-chromium.py --derive chromium --name alpine-vX.Y-armv7-chromium-<ver>-rN --package "<pkg>"` (see "What --derive does").
4. Check the listing by eye. The fall-through path must lead to the second `eglGetError` and LOG with the next line number (`mov.w r2, #374` in 152). It must also lead to the `EGL_BAD_MATCH` (0x3009) and `EGL_BAD_ATTRIBUTE` (0x3004) compares. The branch target must be the LOG with `movw r2, #363`. Line numbers change between versions, so compare with `ui/gl/gl_context_egl.cc` at the new tag. Also make sure that the failure did not move to another gate. These gates are `gl_features.cc ShouldFallbackToSWIfGLES3NotSupported()` and the check `"GLES3 is unsupported and ES version fallback is disabled"`. The second check runs only without `EGL_KHR_no_config_context`.
5. Add the signature. Run the same command with `--add`. Build the package `tsx-xx60-chromium` in tsx-aports, and build the image from it. The log line `chromium-es2-patch: tsx-xx60-chromium: ... patched (verified)` must appear (also in `out/rootfs.sizes`).
6. Test on the panel with `KIOSK_GPU=browser`. `chrome://gpu` must show "Compositing: Hardware accelerated".

To work by hand, run `arm-linux-gnueabihf-objdump -d -M force-thumb --start-address=0x... --stop-address=0x... chromium` (or `llvm-objdump --triple=thumbv7a`) around the reference. Find the reference with `grep -abo 'ES version fallback is disabled' chromium`.

### Revert

- Panel: run `rc-service kiosk stop; tsx-chromium-es2 revert; rc-service kiosk start`. This writes `60 d0` back and verifies the original sha256. `tsx-chromium-es2 apply` patches the binary again. Alternatively, run `apk fix chromium` (needs the network) to reinstall the stock file. Then remove `/etc/tsx/chromium-es2-patched`.
- Build: the patch is part of the package `tsx-xx60-chromium`. The image build has no switch to turn it off.

The panel does not keep the unpatched binary (192 MB). The 2 original bytes and both hashes in the record are enough to go back. `apk audit` lists `usr/lib/chromium/chromium` as changed. This is normal.

## Reference

### Files

| File | What |
|---|---|
| `patch-chromium.py` | Patches the binary. Options: `--check`, `--revert`, `--derive`. `--derive` needs numpy and runs on the host only |
| `sigs.json` | Lists the known builds: sha256 before and after, file offset, 6 context bytes, original bytes and NOP bytes |
| `../../overlay/usr/local/sbin/tsx-chromium-es2` | Panel side, no python. Commands: `check`, `status`, `revert`, `apply` (from `/etc/tsx/chromium-es2-patched`) |

### What the patch changes

The code is in `ui/gl/gl_context_egl.cc` (Chromium 152, lines 358 to 367):

```c++
context_ = eglCreateContext(...);
if (context_) {
  return true;
} else if (!attribs.allow_es_version_fallback) {   // ldrb.w r0,[r8,#0x14]; cmp r0,#0; beq LOG363
  LOG(ERROR) << "eglCreateContext ES " ... << ". ES version fallback is disabled.";
  return false;
}
// fallback 3.1 -> 3.0 -> 2.0 when EGL_KHR_no_config_context and BAD_MATCH/BAD_ATTRIBUTE
```

The patch replaces the `beq` with two NOP bytes (`00 bf`), so the fallback always runs. On Linux, only `gpu/config/gpu_info_collector.cc` sets `allow_es_version_fallback = false`. The ES3 and WebGL2 decoder contexts set it too, so the kiosk uses `--disable-webgl2`. The compositor contexts already allow the fallback.

### Known build

| Item | Value |
|---|---|
| Package | Alpine v3.24 armv7 `chromium-152.0.7977.82-r0` |
| sha256 | `bd982025...5514` before, `bb683d8f...3ff3` after |
| File offset | `0x77c8712` (vaddr `0x77d8712`) |
| Bytes | `60 d0` becomes `00 bf` |

### What --derive does

1. It finds the anchor string `". ES version fallback is disabled."` (it must be unique) and the vaddr of the string in the ELF program headers.
2. It finds the Thumb PIC references to the string (`ldr rN,[pc,#imm]` ... `add rN, pc`, where the literal plus pc equals the string).
3. It searches the 0x600 bytes before each reference for a `beq`, `beq.w` or `cbz`. The target of this branch must be the start of the LOG(ERROR) block (`movs r0, #2` = severity ERROR, within 0x100 bytes before the reference).
4. It accepts exactly one candidate of the form `ldrb.w rX,[rY,#imm]; cmp rX,#0; beq` (or `cbz`). It prints an objdump listing of the site, the sha256 before and after, and the `sigs.json` entry.

If it finds no candidate or several candidates, it exits with code 2. Then derive the patch by hand.
