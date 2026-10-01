"""PanelBackend: reads and controls the panel's local state for the ESPHome
device (tsx-esphome, and the voice satellite's plugin). Mirrors
rootfs/overlay/usr/local/sbin/tsx-mqtt's shell functions/paths (ledbar_state,
keypad_state, screen_state, als_state, volume_state, the R/IDLED/BCONF/KCONF/
ACONF/CARD/ASOUND env names) so both transports read the exact same state
files -- this is the "one backend"; tsx-mqtt
stays POSIX sh (busybox-only panel shell) while this is Python (the voice
satellite's own language), so the sharing is at the state-file/CLI level, not
literally one source file.

Privilege: reads never need root (every state file/sysfs node the panel
already creates world-readable, and "kiosk" is in the "audio" group for
ALSA). Writes are different: tsx-blank signals tsx-idled (root, pkill only
works same-UID-or-root), tsx-keypad/tsx-buttons.ctl and /run/tsx/brightness
are root:root 0600/0755 (checked in rootfs/src/tsx-buttons.c and
tsx-idled.c), and tsx-config apply refuses to run non-root. tsx-esphome runs
as root (like tsx-mqtt) so it calls the CLIs directly; the voice satellite
(tsx-voice) runs as kiosk:audio (least privilege for an always-on, network
-facing audio process) and cannot, so its plugin routes writes through the
tsx-panelctl FIFO -- a small, fixed-command root helper, the same shape as
the tsx-buttons.ctl FIFO already used by tsx-keypad. See
rootfs/overlay/usr/local/sbin/tsx-panelctl.

Env overrides (all also read by tsx-mqtt; new ones only for this module):
  TSX_RUN_DIR (/run/tsx), TSX_IDLED_STATE (/run/tsx-idled.state),
  TSX_BUTTONS_CONF (/etc/tsx/buttons.conf), TSX_KIOSK_CONF (/etc/kiosk.conf),
  TSX_ALS_CONF (/etc/tsx/als.conf), TSX_SOUND_CARD (the board's `tsx-board get TSX_SOUND_CARD`),
  TSX_BOARD_BIN (tsx-board),
  TSX_ASOUND_DIR (/proc/asound), TSX_BACKLIGHT_DIR (/sys/class/backlight),
  TSX_THERMAL_ZONE (/sys/class/thermal/thermal_zone0/temp),
  TSX_DEVTOOLS (127.0.0.1:9222, as buttons.conf's DEVTOOLS=),
  TSX_PANELCTL (/run/tsx/panelctl), TSX_BOOT_VERBOSE_FLAG (/etc/tsx/
  boot-verbose, the flag file `tsx-config apply` leaves for BOOT_VERBOSE=1;
  the initramfs reads the same file, see tsx-config's own comment),
  TSX_PANEL_DIRECT=1 (tests only: run
  privileged commands directly even when not root),
  TSX_LEDBAR/TSX_KEYPAD/TSX_BLANK/TSX_ALS_BIN/TSX_CONFIG_BIN/TSX_REBOOT_BIN/
  TSX_AMIXER/TSX_UPDATE_BIN (binary names, for test fixtures on $PATH).
  TSX_ORIENTATION_FILE (/etc/tsx/orientation: the screen orientation as
  `tsx-config apply` leaves it for the initramfs and the kiosk; absent =
  landscape).
"""

import json
import logging
import os
import socket
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Optional, Tuple

_LOGGER = logging.getLogger("tsx_panel.backend")


def _env(name, default):
    return os.environ.get(name, default)


def _read_first_line(path) -> Optional[str]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fobj:
            return fobj.readline().rstrip("\n")
    except OSError:
        return None


def _field(path, key) -> Optional[str]:
    """The rest of the first line "KEY ..." of a tsx-mqtt-style state file."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fobj:
            for line in fobj:
                if line.startswith(key + " "):
                    return line[len(key) + 1 :].rstrip("\n")
    except OSError:
        return None
    return None


def board_value(name) -> str:
    """A value of the board file (board.sh): the environment first, else
    `tsx-board get NAME`. Empty if the board does not define it."""
    val = os.environ.get(name, "")
    if val:
        return val
    try:
        return subprocess.run(
            [os.environ.get("TSX_BOARD_BIN", "tsx-board"), "get", name],
            check=False, capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


class PanelBackend:
    def __init__(self):
        self.run_dir = Path(_env("TSX_RUN_DIR", "/run/tsx"))
        self.idled_state = Path(_env("TSX_IDLED_STATE", "/run/tsx-idled.state"))
        self.buttons_conf = Path(_env("TSX_BUTTONS_CONF", "/etc/tsx/buttons.conf"))
        self.kiosk_conf = Path(_env("TSX_KIOSK_CONF", "/etc/kiosk.conf"))
        self.als_conf = Path(_env("TSX_ALS_CONF", "/etc/tsx/als.conf"))
        self.card = board_value("TSX_SOUND_CARD")
        self.asound_dir = Path(_env("TSX_ASOUND_DIR", "/proc/asound"))
        self.orientation_file = Path(_env("TSX_ORIENTATION_FILE", "/etc/tsx/orientation"))
        self.backlight_dir = Path(_env("TSX_BACKLIGHT_DIR", "/sys/class/backlight"))
        self.thermal_zone = Path(_env("TSX_THERMAL_ZONE", "/sys/class/thermal/thermal_zone0/temp"))
        self.devtools = _env("TSX_DEVTOOLS", "127.0.0.1:9222")
        self.panelctl = Path(_env("TSX_PANELCTL", str(self.run_dir / "panelctl")))
        self.boot_verbose_flag = Path(_env("TSX_BOOT_VERBOSE_FLAG", "/etc/tsx/boot-verbose"))
        self.ledbar_bin = _env("TSX_LEDBAR", "tsx-ledbar")
        self.keypad_bin = _env("TSX_KEYPAD", "tsx-keypad")
        self.blank_bin = _env("TSX_BLANK", "tsx-blank")
        self.als_bin = _env("TSX_ALS_BIN", "tsx-als")
        self.config_bin = _env("TSX_CONFIG_BIN", "tsx-config")
        self.reboot_bin = _env("TSX_REBOOT_BIN", "reboot")
        self.amixer_bin = _env("TSX_AMIXER", "amixer")
        self.update_bin = _env("TSX_UPDATE_BIN", "tsx-autoupdate")
        self._orientation_pending: Optional[Tuple[str, float]] = None
        self._last_key: Optional[Tuple[str, str]] = None
        self._blank_timeout_pending: Optional[Tuple[int, float]] = None
        self._verbose_boot_pending: Optional[Tuple[bool, float]] = None

    # ---- privilege boundary -------------------------------------------------
    def _privileged(self) -> bool:
        return os.geteuid() == 0 or _env("TSX_PANEL_DIRECT", "0") == "1"

    def _run(self, *args) -> None:
        try:
            subprocess.run(args, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except Exception:  # noqa: BLE001
            _LOGGER.warning("command failed: %s", args, exc_info=True)

    def _spawn(self, *args) -> None:
        """Like _run but does not wait for it to finish: "tsx-autoupdate
        now" can run an apk upgrade for minutes, and this is called from the
        ESPHome connection's own thread/loop (tsx-esphome runs privileged
        commands directly), so waiting on it would stall every other
        command and poll tick until the upgrade completes. Same fire-and-
        forget shape as tsx-mqtt's "tsx-autoupdate now &".
        """
        try:
            subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:  # noqa: BLE001
            _LOGGER.warning("command failed to start: %s", args, exc_info=True)

    def _ctl(self, *words) -> None:
        """Privileged command: run it directly (root) or hand it to the
        tsx-panelctl FIFO (one whitespace-separated line; see that script for
        the whitelist). Never blocks: a missing reader makes the non-blocking
        open fail immediately (ENXIO), logged and otherwise ignored -- the
        panel keeps working, just without that one command applied.
        """
        if self._privileged():
            self._run_privileged(*words)
            return
        line = " ".join(words) + "\n"
        try:
            fd = os.open(str(self.panelctl), os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            _LOGGER.warning("tsx-panelctl not listening (%s): %s", self.panelctl, words)
            return
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)

    def _run_privileged(self, *words) -> None:
        cmd = words[0]
        rest = list(words[1:])
        if cmd == "ledbar":
            self._run(self.ledbar_bin, *rest)
        elif cmd == "keypad":
            self._run(self.keypad_bin, *rest)
        elif cmd == "blank":
            self._run(self.blank_bin, *rest)
        elif cmd == "als":
            self._run(self.als_bin, *rest)
        elif cmd == "brightness":
            try:
                (self.run_dir / "brightness").write_text(rest[0] + "\n", encoding="utf-8")
            except OSError:
                _LOGGER.warning("could not write %s/brightness", self.run_dir, exc_info=True)
        elif cmd == "blank-timeout":
            # persisted in panel.conf; `apply` writes /run/tsx/blank-timeout,
            # which tsx-idled watches (same as tsx-panelctl's blank-timeout)
            self._run(self.config_bin, "set", "BLANK_TIMEOUT", rest[0])
            self._run(self.config_bin, "apply")
        elif cmd == "orientation":
            # persisted in panel.conf; `apply` turns the running kiosk
            self._run(self.config_bin, "set", "ORIENTATION", rest[0])
            self._run(self.config_bin, "apply")
        elif cmd == "volume":
            self._run(self.amixer_bin, "-q", "-c", self.card, "sset", "Master", rest[0] + "%")
        elif cmd == "config-url":
            self._run(self.config_bin, "set", "KIOSK_URL", rest[0])
            self._run(self.config_bin, "apply")
        elif cmd == "verbose-boot":
            self._run(self.config_bin, "set", "BOOT_VERBOSE", "1" if rest[0] == "on" else "0")
            self._run(self.config_bin, "apply")
        elif cmd == "reboot":
            self._run(self.reboot_bin)
        elif cmd == "update-install":
            self._spawn(self.update_bin, "now")
        else:
            _LOGGER.warning("tsx-panelctl: unknown command %r", cmd)

    # ---- LED bar -------------------------------------------------------------
    def ledbar_present(self) -> bool:
        """The USB LED bar tool is installed."""
        import shutil  # noqa: WPS433
        return shutil.which(self.ledbar_bin) is not None

    def get_ledbar(self):
        """(on, brightness 0..255, r,g,b 0..255), from ledbar.state "want R G B" 0..100."""
        raw = _field(self.run_dir / "ledbar.state", "want") or "0 0 0"
        try:
            r, g, b = (int(x) for x in raw.split()[:3])
        except ValueError:
            r = g = b = 0
        mx = max(r, g, b)
        if mx <= 0:
            return False, 0, 0, 0, 0
        bri = (mx * 255 + 50) // 100
        rr = (r * 255 + mx // 2) // mx
        gg = (g * 255 + mx // 2) // mx
        bb = (b * 255 + mx // 2) // mx
        return True, bri, rr, gg, bb

    def set_ledbar(self, on: bool, bri: int, r: int, g: int, b: int) -> None:
        if not on or bri <= 0:
            self._ctl("ledbar", "off")
            return
        # HA 0..255 rgb + 0..255 brightness -> bar 0..100 per channel
        rr = (r * bri * 100 + 32512) // 65025
        gg = (g * bri * 100 + 32512) // 65025
        bb = (b * bri * 100 + 32512) // 65025
        self._ctl("ledbar", "set", str(rr), str(gg), str(bb))

    # ---- key LEDs --------------------------------------------------------------
    def keypad_present(self) -> bool:
        """Front keys with LEDs (buttons.conf)."""
        return self.buttons_conf.is_file()

    def get_keypad(self):
        raw = _field(self.run_dir / "buttons.state", "led") or "0 unknown"
        try:
            level = int(raw.split()[0])
        except (ValueError, IndexError):
            level = 0
        return level > 0, level

    def set_keypad(self, on: bool, brightness: int) -> None:
        if not on:
            self._ctl("keypad", "led", "off")
        else:
            self._ctl("keypad", "led", str(max(1, min(255, brightness))))

    # ---- screen / backlight ------------------------------------------------
    def get_backlight_max(self) -> int:
        val = None
        try:
            for line in self.kiosk_conf.read_text(encoding="utf-8", errors="replace").splitlines():
                line = line.strip()
                if line.startswith("BACKLIGHT_MAX="):
                    val = line.split("=", 1)[1].split("#", 1)[0].strip()
        except OSError:
            pass
        try:
            return int(val) if val else 23
        except ValueError:
            return 23

    def get_screen(self):
        """(on, level|None)."""
        line = _read_first_line(self.idled_state) or ""
        parts = line.split()
        if parts and parts[0] == "blank":
            return False, None
        if len(parts) >= 2 and parts[0] == "on":
            try:
                return True, int(parts[1])
            except ValueError:
                return True, None
        return True, None

    def set_screen(self, on: bool) -> None:
        self._ctl("blank", "off" if on else "on")

    def set_backlight(self, level: float) -> None:
        # the ESPHome number arrives as a float (5.0): tsx-idled and
        # tsx-panelctl's is_uint check both want a plain integer
        level = max(1, min(self.get_backlight_max(), int(round(level))))
        on, _ = self.get_screen()
        if on:
            self._ctl("brightness", str(level))

    # ---- ambient light / auto-brightness -------------------------------------
    def als_present(self) -> bool:
        """The sensor (als.conf) or its state file (als.state)."""
        return self.als_conf.is_file() or (self.run_dir / "als.state").is_file()

    def get_lux(self) -> float:
        raw = _field(self.run_dir / "als.state", "report") or "0"
        try:
            return float(raw.split()[0])
        except (ValueError, IndexError):
            return 0.0

    def get_als_auto(self) -> bool:
        raw = _field(self.run_dir / "als.state", "auto") or "off"
        return raw.split()[0] == "on" if raw else False

    def set_als_auto(self, on: bool) -> None:
        self._ctl("als", "auto", "on" if on else "off")

    # ---- verbose boot (BOOT_VERBOSE, panel.conf) ------------------------------
    def get_verbose_boot(self) -> bool:
        """Read back from the flag file `tsx-config apply` leaves for
        BOOT_VERBOSE=1 (the initramfs reads the same file; it cannot read
        panel.conf under /data), not panel.conf itself: panel.conf is
        root-only (mode 600), so the voice satellite's plugin (user kiosk)
        could not read it -- same reasoning as _configured_kiosk_url above.
        A value just set is reported until `apply` has written the flag file
        (same short pending window as get_blank_timeout, for the same reason:
        the voice satellite's path goes through the tsx-panelctl FIFO, not a
        synchronous call).
        """
        value = self.boot_verbose_flag.exists()
        pending = self._verbose_boot_pending
        if pending and pending[0] != value and time.monotonic() - pending[1] < 10:
            return pending[0]
        self._verbose_boot_pending = None
        return value

    def set_verbose_boot(self, on: bool) -> None:
        self._verbose_boot_pending = (on, time.monotonic())
        self._ctl("verbose-boot", "on" if on else "off")

    # ---- eMMC health (tsx-emmc-state, every hour) ----------------------------------
    def emmc_present(self) -> bool:
        return (self.run_dir / "emmc.state").is_file()

    def _emmc_code(self, key: str) -> Optional[int]:
        raw = _field(self.run_dir / "emmc.state", key)
        try:
            return int(raw.split()[0], 16) if raw else None
        except (ValueError, IndexError):
            return None

    def get_emmc_life(self, which: str) -> Optional[float]:
        """Percent of the life used, as the upper bound of the JEDEC band:
        0x01 = up to 10 %, ... 0x0a = up to 100 %, 0x0b = exceeded (110).
        None when the eMMC does not report it (0x00)."""
        code = self._emmc_code("life_" + which)
        return None if not code or code > 0x0B else float(code * 10)

    def get_emmc_eol(self) -> str:
        return {1: "normal", 2: "warning", 3: "urgent"}.get(self._emmc_code("eol") or 0, "unknown")

    # ---- volume ------------------------------------------------------------
    def sound_card_present(self) -> bool:
        return (self.asound_dir / self.card).exists()

    def get_volume(self) -> float:
        if not self.sound_card_present():
            return 0.0
        try:
            out = subprocess.run(
                [self.amixer_bin, "-c", self.card, "sget", "Master"],
                check=False, capture_output=True, text=True, timeout=5,
            ).stdout
        except Exception:  # noqa: BLE001
            return 0.0
        for tok in out.split():
            if tok.startswith("[") and tok.endswith("%]"):
                try:
                    return float(tok[1:-2])
                except ValueError:
                    continue
        return 0.0

    def set_volume(self, percent: float) -> None:
        percent = max(0, min(100, int(round(percent))))
        self._ctl("volume", str(percent))

    # ---- sensors -------------------------------------------------------------
    def get_cpu_temp(self) -> float:
        raw = _read_first_line(self.thermal_zone)
        try:
            return round(int(raw) / 1000.0, 1) if raw else 0.0
        except ValueError:
            return 0.0

    def get_uptime(self) -> float:
        raw = _read_first_line("/proc/uptime")
        try:
            return round(float(raw.split()[0]), 0) if raw else 0.0
        except (ValueError, IndexError, AttributeError):
            return 0.0

    def get_ip(self) -> str:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.connect(("198.51.100.1", 1))  # TEST-NET-2; no packet sent (UDP)
                return sock.getsockname()[0]
        except OSError:
            return ""

    def get_touched_recently(self, recent_seconds: float = 30.0) -> bool:
        """True while the last real input (touch, front key, power key) is
        less than recent_seconds old: tsx-idled writes its epoch seconds to
        run_dir/last-input (at most once a second). Without that file (an
        older tsx-idled) it falls back to the last blank/wake transition.
        """
        raw = _read_first_line(self.run_dir / "last-input")
        if raw:
            try:
                return time.time() - int(raw.split()[0]) < recent_seconds
            except (ValueError, IndexError):
                pass
        on, _ = self.get_screen()
        if not on:
            return False
        try:
            age = time.time() - self.idled_state.stat().st_mtime
        except OSError:
            return on
        return age < recent_seconds

    # ---- blank timeout (tsx-idled) ------------------------------------------
    def _kiosk_conf_int(self, key: str, default: int) -> int:
        val = None
        try:
            for line in self.kiosk_conf.read_text(encoding="utf-8", errors="replace").splitlines():
                line = line.strip()
                if line.startswith(key + "="):
                    val = line.split("=", 1)[1].split("#", 1)[0].strip().strip("'\"")
        except OSError:
            pass
        try:
            return int(val) if val else default
        except ValueError:
            return default

    def get_blank_timeout(self) -> int:
        """Seconds without input before the screen goes dark (0 = never),
        as tsx-idled takes it: the runtime file `tsx-config apply` writes
        from panel.conf's BLANK_TIMEOUT, else kiosk.conf. A value just set
        is reported until apply has written it (a few seconds at most), so
        the Home Assistant number does not jump back meanwhile."""
        value = None
        raw = _read_first_line(self.run_dir / "blank-timeout")
        try:
            if raw and raw.strip():
                value = int(raw.split()[0])
        except ValueError:
            value = None
        if value is None:
            value = self._kiosk_conf_int("BLANK_TIMEOUT", 300)
        pending = self._blank_timeout_pending
        if pending and pending[0] != value and time.monotonic() - pending[1] < 10:
            return pending[0]
        self._blank_timeout_pending = None
        return value

    def set_blank_timeout(self, seconds: float) -> None:
        seconds = max(0, min(86400, int(round(seconds))))
        self._blank_timeout_pending = (seconds, time.monotonic())
        self._ctl("blank-timeout", str(seconds))

    # ---- screen orientation (ORIENTATION, panel.conf) -----------------------
    ORIENTATIONS = ("landscape", "portrait", "landscape-flipped", "portrait-flipped")

    def get_orientation(self) -> str:
        """Read back from the file `tsx-config apply` leaves on the root file
        system (world-readable; panel.conf itself is root-only, so the voice
        satellite's plugin could not read it). A value just set is reported
        until apply has written it (as get_blank_timeout)."""
        value = (_read_first_line(self.orientation_file) or "").strip()
        if value not in self.ORIENTATIONS:
            value = "landscape"
        pending = self._orientation_pending
        if pending and pending[0] != value and time.monotonic() - pending[1] < 10:
            return pending[0]
        self._orientation_pending = None
        return value

    def set_orientation(self, name: str) -> None:
        if name not in self.ORIENTATIONS:
            _LOGGER.warning("orientation %r refused", name)
            return
        self._orientation_pending = (name, time.monotonic())
        self._ctl("orientation", name)

    # ---- front keys --------------------------------------------------------
    def key_names(self):
        names = []
        try:
            for line in self.buttons_conf.read_text(encoding="utf-8", errors="replace").splitlines():
                line = line.strip()
                if line.startswith("button "):
                    parts = line.split()
                    if len(parts) >= 2:
                        names.append(parts[1])
        except OSError:
            pass
        return names

    def poll_key_event(self) -> Optional[Tuple[str, str]]:
        """Returns (name, event_type) once per new press, else None. HA event
        types: press/long/double (tsx-buttons reports short/long/hold; hold
        repeats while held -- mapped to "long" again, "double" is unused
        today, see entities.KeyEventEntity).
        """
        raw = _field(self.run_dir / "buttons.state", "last")
        if not raw:
            return None
        parts = raw.split()
        if len(parts) < 2 or parts[0] == "none":
            return None
        cur = (parts[0], parts[1])
        if cur == self._last_key:
            return None
        first = self._last_key is None
        self._last_key = cur
        if first:
            return None  # first read after start: not a new event
        mapped = {"short": "press", "long": "long", "hold": "long"}.get(cur[1])
        if not mapped:
            return None
        return cur[0], mapped

    # ---- kiosk (Chromium DevTools) -------------------------------------------
    def _devtools_page(self):
        url = f"http://{self.devtools}/json"
        with urllib.request.urlopen(url, timeout=3) as resp:
            tabs = json.loads(resp.read().decode("utf-8"))
        for tab in tabs:
            if tab.get("type") == "page":
                return tab
        return None

    def _configured_kiosk_url(self) -> str:
        """KIOSK_URL as the kiosk session reads it: tsx-config's override
        (run_dir/kiosk.conf, world-readable, written by `tsx-config apply`)
        wins over /etc/kiosk.conf. panel.conf itself is root-only, so the
        voice satellite's plugin (kiosk user) could not read it."""
        url = ""
        for path in (self.kiosk_conf, self.run_dir / "kiosk.conf"):
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for line in text.splitlines():
                line = line.strip()
                if line.startswith("KIOSK_URL="):
                    url = line.split("=", 1)[1].strip().strip("'\"")
        return url

    def get_kiosk_url(self) -> str:
        """The CONFIGURED start URL, not the page the browser shows right
        now: the live URL changes on every login redirect (HA's
        /auth/authorize?...) and dashboard click, and a Home Assistant text
        entity that echoed it back would save that transient URL as the new
        KIOSK_URL on the next edit. The live page URL is only the fallback
        when no KIOSK_URL is configured at all."""
        url = self._configured_kiosk_url()
        if url:
            return url
        try:
            page = self._devtools_page()
            if page:
                return page.get("url", "")
        except Exception:  # noqa: BLE001
            _LOGGER.debug("DevTools not reachable at %s", self.devtools, exc_info=True)
        return ""

    def set_kiosk_url(self, url: str) -> None:
        """Navigate the live page immediately, then persist (tsx-config, so
        it survives a restart/reinstall). Navigation first: persisting runs
        `tsx-config apply`, which may restart the process serving this
        entity (tsx-esphome) if other settings changed too."""
        self._navigate(url)
        self._ctl("config-url", url)

    def reload_page(self) -> None:
        page = None
        try:
            page = self._devtools_page()
        except Exception:  # noqa: BLE001
            _LOGGER.warning("DevTools not reachable at %s", self.devtools, exc_info=True)
            return
        if page:
            self._cdp_call(page["webSocketDebuggerUrl"], "Page.reload", {"ignoreCache": False})

    def _navigate(self, url: str) -> None:
        try:
            page = self._devtools_page()
        except Exception:  # noqa: BLE001
            _LOGGER.warning("DevTools not reachable at %s", self.devtools, exc_info=True)
            return
        if page:
            self._cdp_call(page["webSocketDebuggerUrl"], "Page.navigate", {"url": url})

    def _cdp_call(self, ws_url: str, method: str, params: dict) -> None:
        """One request/response over the page's own DevTools websocket.
        Synchronous (asyncio.to_thread'd by callers that are on the event
        loop): a page's own websocket only ever has one command in flight
        from us at a time, so a short-lived connection per call keeps this
        simple. Uses the `websockets` package already vendored for the voice
        satellite (see rootfs/voice/install-lva.sh); on the standalone
        tsx-esphome this needs the same PYTHONPATH (/opt/lva/lib) -- see
        tsx-esphome's launcher script.
        """
        import websockets.sync.client as ws_sync  # noqa: WPS433 (optional/heavy import kept local)

        try:
            with ws_sync.connect(ws_url, open_timeout=3, close_timeout=3) as ws:
                ws.send(json.dumps({"id": 1, "method": method, "params": params}))
                for _ in range(20):
                    msg = json.loads(ws.recv(timeout=3))
                    if msg.get("id") == 1:
                        return
        except Exception:  # noqa: BLE001
            _LOGGER.warning("CDP %s failed", method, exc_info=True)

    # ---- reboot --------------------------------------------------------------
    def reboot(self) -> None:
        self._ctl("reboot")

    # ---- update (tsx-autoupdate, docs/rootfs.md "Updates") --------------------------
    def get_update_status(self) -> dict:
        """tsx-autoupdate's own HA-ready status (same file tsx-mqtt's
        update_state() reads: $TSX_RUN_DIR/update-ha-state.json), or a safe
        default before it has ever run -- see tsx-autoupdate's write_ha_json."""
        path = self.run_dir / "update-ha-state.json"
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {
                "installed_version": "unknown",
                "latest_version": "unknown",
                "title": "TSX packages",
                "release_summary": "tsx-autoupdate has not run yet",
                "in_progress": False,
            }

    def install_update(self) -> None:
        """"Install" on the Update entity: the same "tsx-autoupdate now"
        tsx-mqtt's Install runs -- right away, outside the night window (the
        window/idle gate still applies to the reboot itself)."""
        self._ctl("update-install")
