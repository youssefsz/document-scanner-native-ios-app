#!/usr/bin/env python3
"""Render a separate App Store set using the original 01-library method."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
SOURCES = ROOT / "sources"
OUTPUT_DIR = ROOT / "Code Rendered"
CANVAS_SIZE = (1320, 2868)

BACKGROUND = SOURCES / "campaign-background.png"
HELVETICA = "/System/Library/Fonts/HelveticaNeue.ttc"
AVENIR = "/System/Library/Fonts/Avenir Next.ttc"

SCREENS = [
    (
        "01-library.png",
        SOURCES / "01-library-source.png",
        "Keep every scan\norganized.",
        "Search by title or browse folders.",
        False,
    ),
    (
        "02-folders.png",
        SOURCES / "02-folders-source.png",
        "Sort scans into\nfolders.",
        "Lock private folders when you need to.",
        False,
    ),
    (
        "03-document-viewer.png",
        SOURCES / "03-document-viewer-source.png",
        "Open scans in\nfull detail.",
        "Rename and share from the same screen.",
        False,
    ),
    (
        "04-pdf-quality.png",
        SOURCES / "04-pdf-quality-source.png",
        "Choose PDF quality\nbefore sharing.",
        "Compare file size and detail before you send.",
        True,
    ),
    (
        "05-settings.png",
        SOURCES / "05-settings-source.png",
        "Set your\npreferences.",
        "Control display, sharing, and text recognition.",
        False,
    ),
]


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    target_width, target_height = size
    scale = max(target_width / image.width, target_height / image.height)
    resized = image.resize(
        (round(image.width * scale), round(image.height * scale)),
        Image.Resampling.LANCZOS,
    )
    left = (resized.width - target_width) // 2
    top = (resized.height - target_height) // 2
    return resized.crop((left, top, left + target_width, top + target_height))


def rounded_image(image: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, image.width - 1, image.height - 1),
        radius=radius,
        fill=255,
    )
    result = image.convert("RGBA")
    result.putalpha(mask)
    return result


def top_rounded_image(image: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", image.size, 255)
    draw = ImageDraw.Draw(mask)
    draw.rectangle((0, 0, image.width - 1, radius), fill=0)
    draw.rounded_rectangle(
        (0, 0, image.width - 1, radius * 2),
        radius=radius,
        fill=255,
    )
    result = image.convert("RGBA")
    result.putalpha(mask)
    return result


def add_phone(
    canvas: Image.Image,
    screen_path: Path,
    *,
    fit_content_to_visible_area: bool = False,
) -> None:
    """Use the same phone geometry and treatment as 01-library.png."""
    source = Image.open(screen_path).convert("RGB")
    screen_width = 1060
    screen_height = round(source.height * screen_width / source.width)

    border = 24
    phone_width = screen_width + 2 * border
    phone_height = screen_height + 2 * border
    phone_x = (CANVAS_SIZE[0] - phone_width) // 2
    phone_y = 600
    phone_radius = 150

    if fit_content_to_visible_area:
        visible_height = CANVAS_SIZE[1] - phone_y - border
        screen = source.resize(
            (screen_width, visible_height),
            Image.Resampling.LANCZOS,
        )
        screen = top_rounded_image(screen, radius=122)
    else:
        screen = source.resize(
            (screen_width, screen_height),
            Image.Resampling.LANCZOS,
        )
        screen = rounded_image(screen, radius=122)

    shadow_pad = 90
    shadow = Image.new(
        "RGBA",
        (phone_width + 2 * shadow_pad, phone_height + 2 * shadow_pad),
        (0, 0, 0, 0),
    )
    ImageDraw.Draw(shadow).rounded_rectangle(
        (
            shadow_pad,
            shadow_pad,
            shadow_pad + phone_width,
            shadow_pad + phone_height,
        ),
        radius=phone_radius,
        fill=(5, 10, 36, 155),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(54))
    canvas.alpha_composite(
        shadow,
        (phone_x - shadow_pad, phone_y - shadow_pad + 32),
    )

    device = Image.new("RGBA", (phone_width, phone_height), (0, 0, 0, 0))
    device_draw = ImageDraw.Draw(device)
    device_draw.rounded_rectangle(
        (0, 0, phone_width - 1, phone_height - 1),
        radius=phone_radius,
        fill=(9, 12, 22, 255),
        outline=(151, 177, 255, 210),
        width=3,
    )
    device.alpha_composite(screen, (border, border))

    island_width = 265
    island_height = 72
    island_x = (phone_width - island_width) // 2
    island_y = border + 20
    device_draw.rounded_rectangle(
        (
            island_x,
            island_y,
            island_x + island_width,
            island_y + island_height,
        ),
        radius=island_height // 2,
        fill=(0, 0, 0, 255),
    )
    canvas.alpha_composite(device, (phone_x, phone_y))


def render(
    output_name: str,
    screen_path: Path,
    title: str,
    subtitle: str,
    fit_content_to_visible_area: bool,
) -> Path:
    background = cover(Image.open(BACKGROUND).convert("RGB"), CANVAS_SIZE)
    canvas = background.convert("RGBA")

    veil = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    veil_pixels = veil.load()
    for y in range(620):
        alpha = round(58 * (1 - y / 620))
        for x in range(CANVAS_SIZE[0]):
            veil_pixels[x, y] = (5, 8, 52, alpha)
    canvas.alpha_composite(veil)

    draw = ImageDraw.Draw(canvas)
    title_font = ImageFont.truetype(HELVETICA, 104, index=1)
    subtitle_font = ImageFont.truetype(AVENIR, 42, index=5)

    title_box = draw.multiline_textbbox(
        (0, 0), title, font=title_font, spacing=4, align="center"
    )
    title_width = title_box[2] - title_box[0]
    draw.multiline_text(
        ((CANVAS_SIZE[0] - title_width) // 2, 118),
        title,
        font=title_font,
        fill=(255, 255, 255, 255),
        spacing=4,
        align="center",
        stroke_width=1,
        stroke_fill=(255, 255, 255, 255),
    )

    subtitle_box = draw.textbbox((0, 0), subtitle, font=subtitle_font)
    subtitle_width = subtitle_box[2] - subtitle_box[0]
    draw.text(
        ((CANVAS_SIZE[0] - subtitle_width) // 2, 410),
        subtitle,
        font=subtitle_font,
        fill=(225, 237, 255, 255),
    )

    add_phone(
        canvas,
        screen_path,
        fit_content_to_visible_area=fit_content_to_visible_area,
    )
    output_path = OUTPUT_DIR / output_name
    canvas.convert("RGB").save(output_path, format="PNG", optimize=True)
    return output_path


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for item in SCREENS:
        print(render(*item))


if __name__ == "__main__":
    main()
