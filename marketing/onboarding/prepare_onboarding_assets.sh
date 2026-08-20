#!/bin/zsh

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 /path/to/v2-library.png /path/to/v2-folders.png" >&2
    exit 64
fi

library_source="$1"
folders_source="$2"
script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
asset_root="$repository_root/document-scaner/Assets.xcassets"
minimum_width=700
minimum_height=1500
minimum_aspect=0.45
maximum_aspect=0.47
target_width=852
target_height=1847
maximum_image_bytes=$((250 * 1024))
maximum_total_bytes=$((2500 * 1024))

validate_source() {
    local source_path="$1"
    local width
    local height
    local aspect

    if [[ ! -f "$source_path" ]]; then
        echo "Missing source screenshot: $source_path" >&2
        exit 66
    fi

    width="$(sips -g pixelWidth "$source_path" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
    height="$(sips -g pixelHeight "$source_path" 2>/dev/null | awk '/pixelHeight/ {print $2}')"

    aspect="$(awk -v width="$width" -v height="$height" 'BEGIN { printf "%.4f", width / height }')"

    if (( width < minimum_width || height < minimum_height )); then
        echo "Screenshot is too small (${width}x${height}): $source_path" >&2
        exit 65
    fi

    if ! awk -v value="$aspect" -v minimum="$minimum_aspect" -v maximum="$maximum_aspect" 'BEGIN { exit !(value >= minimum && value <= maximum) }'; then
        echo "Expected a full portrait screenshot (aspect 0.45-0.47), got ${aspect}: $source_path" >&2
        exit 65
    fi
}

prepare_asset() {
    local source_path="$1"
    local image_set_name="$2"
    local image_filename="$3"
    local image_set_path="$asset_root/$image_set_name.imageset"
    local destination="$image_set_path/$image_filename"

    ffmpeg \
        -hide_banner \
        -loglevel error \
        -y \
        -i "$source_path" \
        -vf "scale=${target_width}:${target_height}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${target_width}:${target_height}:(ow-iw)/2:(oh-ih)/2:color=0xF2F2F7" \
        -q:v 3 \
        -pix_fmt yuvj420p \
        "$destination"

    local contents_path="$image_set_path/Contents.json"
    if grep -q '"filename"' "$contents_path"; then
        sed -i '' -E "s/\"filename\" : \"[^\"]+\"/\"filename\" : \"$image_filename\"/" "$contents_path"
    else
        sed -i '' "/\"idiom\" : \"universal\"/i\\
      \"filename\" : \"$image_filename\",\
" "$contents_path"
    fi

    local image_bytes
    image_bytes="$(stat -f '%z' "$destination")"
    if (( image_bytes > maximum_image_bytes )); then
        echo "$image_filename is larger than 250 KB: $image_bytes bytes" >&2
        exit 65
    fi
}

validate_source "$library_source"
validate_source "$folders_source"

prepare_asset "$library_source" "OnboardingV2Library" "OnboardingV2Library.jpg"
prepare_asset "$folders_source" "OnboardingFolders" "OnboardingFolders.jpg"

total_bytes="$(find "$asset_root" -path '*Onboarding*.imageset/*' -type f \( -name '*.jpg' -o -name '*.png' \) -exec stat -f '%z' {} \; | awk '{sum += $1} END {print sum + 0}')"
if (( total_bytes > maximum_total_bytes )); then
    echo "Onboarding screenshots exceed the 2.5 MB combined limit: $total_bytes bytes" >&2
    exit 65
fi

echo "Prepared onboarding assets. Combined size: $total_bytes bytes"
