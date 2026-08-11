#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
SOURCE_ICON="$PROJECT_DIR/Assets/AppIcon-1024.png"
ICONSET_DIR="$PROJECT_DIR/Assets/AppIcon.iconset"
OUTPUT_ICON="$PROJECT_DIR/Assets/AppIcon.icns"

if [[ ! -f "$SOURCE_ICON" ]]; then
    echo "找不到图标源文件: $SOURCE_ICON" >&2
    exit 1
fi

case "$ICONSET_DIR" in
    "$PROJECT_DIR/Assets/"*) ;;
    *)
        echo "拒绝清理 Assets 之外的目录: $ICONSET_DIR" >&2
        exit 1
        ;;
esac

/bin/rm -rf "$ICONSET_DIR"
/bin/mkdir -p "$ICONSET_DIR"

function make_icon() {
    local size=$1
    local filename=$2
    /usr/bin/sips -z "$size" "$size" "$SOURCE_ICON" \
        --out "$ICONSET_DIR/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICON"
echo "$OUTPUT_ICON"
