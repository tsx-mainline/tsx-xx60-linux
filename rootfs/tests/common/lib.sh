# lib.sh: the setup of the tests in this folder. Each test sources it:
#   . "$(dirname "$0")/lib.sh"
# The tests in this folder run the shared panel software of tsx-linux-common
# with the real xx60 board files of this repository. No test holds a copy of
# a board file.
#
# TSX_COMMON is the top of a tsx-linux-common checkout (the folder that has
# base/ and tests/). The default is the folder tsx-linux-common next to this
# repository. A test stops with exit code 2 when it finds no checkout there.
#
# The file sets these names:
#   XX60            the top of this repository
#   COMMON          the top of the tsx-linux-common checkout
#   TSX_ROOT        the same as COMMON. tests/lib/paths.sh reads it.
#   TSX_BOARD_CONF  the xx60 board file (rootfs/overlay/usr/local/lib/tsx/board.sh)
#   TSX_BOARD_BIN   tsx-board of tsx-linux-common
#   XX60_PANEL_BOARD  the xx60 panel-board.conf
#   XX60_BUTTONS    the xx60 key definitions (buttons-board.conf of the xx60 overlay, the
#                   board layer of tsx-buttons. buttons.conf is the template of
#                   tsx-linux-common, and P etc/tsx/buttons.conf finds it)
#   XX60_HW         tsx-hw of the xx60, the writer of /run/tsx/hw.conf
#   XX60_LIB        tsx-lib.sh of the rescue system, which the board file needs there
#   XX60_ESPHOME_D, XX60_CONFIG_D, XX60_SETUP_D
#                   the plugin folders of the xx60 overlay (esphome.d, config.d and
#                   setup.d). A test that uses them sets the test hook of the
#                   folder (TSX_ESPHOME_PLUGIN_DIR, TSX_CONFIG_PLUGIN_DIR or
#                   TSX_SETUP_PLUGIN_DIR) and TSX_PLUGIN_OWNER_UID to its own user id
#   P PATH          prints the path of a file of tsx-linux-common by the path
#                   that the file has on the panel (from tests/lib/paths.sh)
XX60=$(cd "$(dirname "$0")/../../.." && pwd)
COMMON=${TSX_COMMON:-$XX60/../tsx-linux-common}
if [ ! -r "$COMMON/tests/lib/paths.sh" ] || [ ! -r "$COMMON/base/usr/local/bin/tsx-board" ]; then
	echo "no tsx-linux-common checkout at $COMMON" >&2
	echo "Set TSX_COMMON to the top of a tsx-linux-common checkout." >&2
	exit 2
fi
COMMON=$(cd "$COMMON" && pwd)
TSX_ROOT=$COMMON
export TSX_ROOT
. "$COMMON/tests/lib/paths.sh"
TSX_BOARD_CONF=$XX60/rootfs/overlay/usr/local/lib/tsx/board.sh
TSX_BOARD_BIN=$COMMON/base/usr/local/bin/tsx-board
XX60_PANEL_BOARD=$XX60/rootfs/overlay/etc/tsx/panel-board.conf
XX60_BUTTONS=$XX60/rootfs/overlay/etc/tsx/buttons-board.conf
XX60_HW=$XX60/rootfs/overlay/usr/local/sbin/tsx-hw
XX60_LIB=$XX60/rootfs/initramfs/overlay/usr/share/tsx/tsx-lib.sh
XX60_ESPHOME_D=$XX60/rootfs/overlay/usr/local/share/tsx/esphome.d
XX60_CONFIG_D=$XX60/rootfs/overlay/usr/local/lib/tsx/config.d
XX60_SETUP_D=$XX60/rootfs/overlay/usr/local/share/tsx/setup.d
export TSX_BOARD_CONF TSX_BOARD_BIN
