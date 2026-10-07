#!/bin/sh
# Start Codenotch on Linux.
#
#   * The notch has to sit on a screen edge, and a Wayland client cannot place its own window.
#     So it always runs as an X11 client: native on an X11 session, through XWayland on Wayland.
#     (GDK_BACKEND=x11 is a no-op on X11.)
#   * A shell started from a snap (VS Code's terminal, for one) exports that snap's library
#     paths, and they break a binary built against the system glibc.
#   * CODENOTCH_WEBKIT_SAFE=1 turns off WebKitGTK's DMA-BUF renderer. Try it if the notch shows up
#     as an empty or black rectangle, which some NVIDIA driver / WebKitGTK combinations do.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin=${CODENOTCH_BIN:-$root/target/release/codenotch}
[ -x "$bin" ] || bin=$root/target/debug/codenotch

if [ ! -x "$bin" ]; then
  echo "No binary yet. Build one first:  cargo build --release   (from $root)" >&2
  exit 1
fi

if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && [ -z "${DISPLAY:-}" ]; then
  echo "Wayland session without XWayland (DISPLAY is empty): the notch cannot be placed." >&2
  echo "On GNOME/Ubuntu XWayland is normally on; check 'echo \$DISPLAY' in a normal terminal." >&2
  exit 1
fi

safe=""
[ "${CODENOTCH_WEBKIT_SAFE:-0}" = "1" ] && safe="WEBKIT_DISABLE_DMABUF_RENDERER=1"

# shellcheck disable=SC2086
exec env -u LD_LIBRARY_PATH -u GTK_PATH -u GIO_MODULE_DIR -u GSETTINGS_SCHEMA_DIR \
         -u LOCPATH -u GDK_PIXBUF_MODULE_FILE -u GDK_PIXBUF_MODULEDIR \
         GDK_BACKEND=x11 $safe \
    "$bin" "$@"
