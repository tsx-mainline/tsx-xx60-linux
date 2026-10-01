"""The hardware facts of the panel: /run/tsx/hw.conf, written at boot by
tsx-hw (rootfs/overlay/usr/local/sbin/tsx-hw, docs/hardware.md "Panel
variants"). A panel with government=1 (the TSW-760-NC) has MIC=no, BT=no
and CAMERA=no. A missing file or key means that the part is there.

Test hooks: TSX_HW_CONF, else TSX_RUN_DIR/hw.conf.
"""

import os


def conf_path():
    return os.environ.get("TSX_HW_CONF", os.path.join(os.environ.get("TSX_RUN_DIR", "/run/tsx"), "hw.conf"))


def get(key, path=None):
    """The value of KEY in hw.conf, or "" if the file or the key is missing."""
    value = ""
    try:
        with open(path or conf_path(), "r", encoding="utf-8") as fobj:
            for line in fobj:
                line = line.strip()
                if line.startswith(key + "="):
                    value = line.split("=", 1)[1].strip()
    except OSError:
        pass
    return value


def present(part, path=None):
    """False only when hw.conf says PART=no (MIC, BT, CAMERA)."""
    return get(part, path) != "no"


def reason(path=None):
    return get("REASON", path) or "government=" + (get("GOVERNMENT", path) or "unknown")
