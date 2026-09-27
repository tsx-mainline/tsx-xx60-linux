#!/bin/sh
# Install wyoming-satellite (Home Assistant Assist voice satellite, pure Python)
# into DESTROOT/opt/wyoming and the launcher DESTROOT/usr/local/bin/wyoming-satellite.
# Runs in the armv7 Alpine build container (mkrootfs.sh host test);
# the target needs python3 + py3-zeroconf from Alpine (packages.txt).
#
# Pinned: wyoming-satellite 1.4.1 (GitHub tag; PyPI only has 1.0.0),
# wyoming 1.5.4 (the version 1.4.1 asks for), pyring-buffer 1.1.0. The
# satellite pins zeroconf==0.88.0; Alpine's py3-zeroconf (0.147) is used
# instead (--no-deps; the AsyncZeroconf/AsyncServiceInfo API it uses is
# unchanged). No compiled extensions: webrtc noise suppression / auto gain and
# the silero VAD are not installed (the ZL38051 does AEC + NR in hardware).
set -eu
DEST=${1:?usage: install-wyoming.sh DESTROOT}
W=${WYOMING_CACHE:-/build/wyoming}
SAT=1.4.1
mkdir -p "$W"
apk add -q --no-cache python3 py3-pip py3-setuptools curl >/dev/null
fetch() {  # url file sha256
	[ -s "$W/$2" ] || curl -fsSL -o "$W/$2" "$1"
	echo "$3  $W/$2" | sha256sum -c -
}
fetch https://github.com/rhasspy/wyoming-satellite/archive/refs/tags/v$SAT.tar.gz \
	wyoming-satellite-$SAT.tar.gz a539789b30f6b4d957cc75bf54549536a8e9b8508e99dda1e2d4cfd62eaffb6b
fetch https://files.pythonhosted.org/packages/py3/w/wyoming/wyoming-1.5.4-py3-none-any.whl \
	wyoming-1.5.4-py3-none-any.whl cb044b8d9e0f625907efb1bde32cc38eaef67fdd495075f6127d98d3b12c0683
fetch https://files.pythonhosted.org/packages/py3/p/pyring-buffer/pyring_buffer-1.1.0-py3-none-any.whl \
	pyring_buffer-1.1.0-py3-none-any.whl a6eb24aa9966d3e3c6018bf14a3cb25047d982ce5a86dbfee9f8ac53995b7f00
rm -rf "$W/src" && mkdir -p "$W/src" && tar -C "$W/src" -xzf "$W/wyoming-satellite-$SAT.tar.gz"
L=$DEST/opt/wyoming/lib
rm -rf "$DEST/opt/wyoming" && mkdir -p "$L"
pip install -q --no-deps --no-compile --no-build-isolation --disable-pip-version-check \
	--root-user-action=ignore --target "$L" \
	"$W/wyoming-1.5.4-py3-none-any.whl" "$W/pyring_buffer-1.1.0-py3-none-any.whl" \
	"$W/src/wyoming-satellite-$SAT"
# setuptools drops the wyoming_satellite.utils subpackage from this tree: copy the sources
cp -r "$W/src/wyoming-satellite-$SAT/wyoming_satellite/." "$L/wyoming_satellite/"
rm -rf "$L/bin"
echo "wyoming-satellite $SAT, wyoming 1.5.4, pyring-buffer 1.1.0 (install-wyoming.sh)" > "$DEST/opt/wyoming/VERSION"
mkdir -p "$DEST/usr/local/bin"
cat > "$DEST/usr/local/bin/wyoming-satellite" <<'EOT'
#!/bin/sh
PYTHONPATH=/opt/wyoming/lib${PYTHONPATH:+:$PYTHONPATH} exec python3 -m wyoming_satellite "$@"
EOT
chmod 755 "$DEST/usr/local/bin/wyoming-satellite"
echo "installed $(cat "$DEST/opt/wyoming/VERSION") in $DEST/opt/wyoming ($(du -sh "$DEST/opt/wyoming" | cut -f1))"
