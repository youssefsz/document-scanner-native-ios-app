#!/usr/bin/env python3
"""Render the DocScanner iPhone App Store screenshot campaign."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
SOURCES = ROOT / "sources"
REALISTIC_DIR = ROOT / "Realistic"
CANVAS_SIZE = (1320, 2868)

BACKGROUND = SOURCES / "campaign-background.png"
LIBRARY_SCREEN = SOURCES / "01-library-source.png"
FOLDERS_SCREEN = SOURCES / "02-folders-source.png"
DOCUMENT_VIEWER_SCREEN = SOURCES / "03-document-viewer-source.png"
PDF_QUALITY_SCREEN = SOURCES / "04-pdf-quality-source.png"
SETTINGS_SCREEN = SOURCES / "05-settings-source.png"
FRAME_REFERENCE = SOURCES / "phone-frame-reference.png"
LIBRARY_OUTPUT = ROOT / "01-library.png"
LIBRARY_OUTPUT_V2 = REALISTIC_DIR / "01-library.png"
FOLDERS_OUTPUT = REALISTIC_DIR / "02-folders.png"
DOCUMENT_VIEWER_OUTPUT = REALISTIC_DIR / "03-document-viewer.png"
PDF_QUALITY_OUTPUT = REALISTIC_DIR / "04-pdf-quality.png"
SETTINGS_OUTPUT = REALISTIC_DIR / "05-settings.png"

HELVETICA = "/System/Library/Fonts/HelveticaNeue.ttc"
AVENIR = "/System/Library/Fonts/Avenir Next.ttc"


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Resize and center-crop an image to fill size."""
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
    """Round only the top corners of a screen that continues below the canvas."""
    mask = Image.new("L", image.size, 255)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rectangle((0, 0, image.width - 1, radius), fill=0)
    mask_draw.rounded_rectangle(
        (0, 0, image.width - 1, radius * 2),
        radius=radius,
        fill=255,
    )
    result = image.convert("RGBA")
    result.putalpha(mask)
    return result


def add_phone(canvas: Image.Image, screen_path: Path) -> None:
    screen = Image.open(screen_path).convert("RGB")
    screen_width = 1060
    screen_height = round(screen.height * screen_width / screen.width)
    screen = screen.resize((screen_width, screen_height), Image.Resampling.LANCZOS)
    screen = rounded_image(screen, radius=122)

    border = 24
    phone_width = screen_width + 2 * border
    phone_height = screen_height + 2 * border
    phone_x = (CANVAS_SIZE[0] - phone_width) // 2
    phone_y = 600
    phone_radius = 150

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


def add_realistic_phone(
    canvas: Image.Image,
    screen_path: Path,
    *,
    fully_visible: bool = False,
    fit_screen_to_canvas: bool = False,
) -> None:
    """Combine the generated titanium treatment with the untouched app UI."""
    if fully_visible:
        # Close the device inside the canvas so neither the screen nor the bezel
        # can run through the bottom edge of the App Store artwork.
        outer_box = (88, 593, 1232, 2836)
        bezel_box = (116, 614, 1204, 2810)
        screen_box = (140, 640, 1180, 2784)
    else:
        outer_box = (88, 593, 1232, 3070)
        bezel_box = (116, 614, 1204, 3070)
        screen_box = (140, 640, 1180, 2896)

    shadow = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (98, 608, 1222, 3070),
        radius=170,
        fill=(1, 4, 18, 170),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(58))
    canvas.alpha_composite(shadow, (0, 24))

    device_base = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    device_base_draw = ImageDraw.Draw(device_base)
    device_base_draw.rounded_rectangle(
        outer_box,
        radius=178,
        fill=(4, 5, 8, 255),
        outline=(111, 113, 119, 255),
        width=8,
    )
    device_base_draw.rounded_rectangle(
        (outer_box[0] + 8, outer_box[1] + 8, outer_box[2] - 8, outer_box[3] - 8),
        radius=170,
        outline=(25, 27, 32, 255),
        width=7,
    )
    device_base_draw.rounded_rectangle(
        bezel_box,
        radius=158,
        fill=(2, 3, 6, 255),
    )
    canvas.alpha_composite(device_base)

    screen = Image.open(screen_path).convert("RGB")
    screen_size = (
        screen_box[2] - screen_box[0],
        screen_box[3] - screen_box[1],
    )
    if fully_visible:
        # Preserve the source aspect ratio and trim only the unavailable bottom
        # portion. The app UI itself is never regenerated or stretched.
        scale = screen_size[0] / screen.width
        screen = screen.resize(
            (screen_size[0], round(screen.height * scale)),
            Image.Resampling.LANCZOS,
        ).crop((0, 0, screen_size[0], screen_size[1]))
        screen = rounded_image(screen, radius=132)
    elif fit_screen_to_canvas:
        # Keep the campaign's off-canvas phone crop, but show the complete source
        # screenshot inside the visible part of the display. This preserves the
        # Share PDF sheet's own rounded bottom corners at the export edge.
        visible_screen_size = (
            screen_size[0],
            CANVAS_SIZE[1] - screen_box[1],
        )
        screen = screen.resize(visible_screen_size, Image.Resampling.LANCZOS)
        screen = top_rounded_image(screen, radius=132)
    else:
        screen = screen.resize(screen_size, Image.Resampling.LANCZOS)
        screen = rounded_image(screen, radius=132)
    canvas.alpha_composite(screen, (screen_box[0], screen_box[1]))

    frame = cover(Image.open(FRAME_REFERENCE).convert("RGB"), CANVAS_SIZE).convert(
        "RGBA"
    )
    frame_mask = Image.new("L", CANVAS_SIZE, 0)
    frame_mask_draw = ImageDraw.Draw(frame_mask)
    frame_mask_draw.rounded_rectangle(outer_box, radius=178, fill=255)
    frame_mask_draw.rounded_rectangle(bezel_box, radius=158, fill=0)
    if fully_visible:
        # The generated reference was intentionally cropped at the bottom.
        # Keep its photorealistic top and side rails, then use the closed device
        # base above for the bottom rail instead of leaking reference UI pixels.
        frame_mask_draw.rectangle((0, 2500, CANVAS_SIZE[0], CANVAS_SIZE[1]), fill=0)
    frame.putalpha(frame_mask)
    canvas.alpha_composite(frame)

    if fully_visible:
        rail = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
        rail_draw = ImageDraw.Draw(rail)
        rail_draw.rounded_rectangle(
            outer_box,
            radius=178,
            outline=(79, 81, 87, 255),
            width=7,
        )
        rail_draw.rounded_rectangle(
            (96, 601, 1224, 2828),
            radius=170,
            outline=(155, 156, 161, 170),
            width=3,
        )
        rail_draw.rounded_rectangle(
            bezel_box,
            radius=158,
            outline=(0, 0, 0, 255),
            width=10,
        )
        canvas.alpha_composite(rail)

    island = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    island_draw = ImageDraw.Draw(island)
    island_draw.rounded_rectangle(
        (500, 663, 820, 760),
        radius=49,
        fill=(0, 0, 1, 255),
    )
    island_draw.ellipse((762, 693, 796, 727), fill=(5, 12, 25, 255))
    island_draw.ellipse((772, 701, 789, 718), fill=(12, 29, 57, 255))
    canvas.alpha_composite(island)


def render_library() -> None:
    background = cover(Image.open(BACKGROUND).convert("RGB"), CANVAS_SIZE)
    canvas = background.convert("RGBA")

    # A faint top veil keeps the headline readable without flattening the backdrop.
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

    title = "Your scans.\nNeatly organized."
    title_box = draw.multiline_textbbox(
        (0, 0), title, font=title_font, spacing=4, align="center"
    )
    title_width = title_box[2] - title_box[0]
    title_x = (CANVAS_SIZE[0] - title_width) // 2
    title_y = 118
    draw.multiline_text(
        (title_x, title_y),
        title,
        font=title_font,
        fill=(255, 255, 255, 255),
        spacing=4,
        align="center",
        stroke_width=1,
        stroke_fill=(255, 255, 255, 255),
    )

    subtitle = "Everything stays easy to find."
    subtitle_box = draw.textbbox((0, 0), subtitle, font=subtitle_font)
    subtitle_width = subtitle_box[2] - subtitle_box[0]
    draw.text(
        ((CANVAS_SIZE[0] - subtitle_width) // 2, 410),
        subtitle,
        font=subtitle_font,
        fill=(225, 237, 255, 255),
    )

    add_phone(canvas, LIBRARY_SCREEN)
    canvas.convert("RGB").save(LIBRARY_OUTPUT, format="PNG", optimize=True)


def render_library_v2() -> None:
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
    title_font = ImageFont.truetype(HELVETICA, 98, index=1)
    subtitle_font = ImageFont.truetype(AVENIR, 40, index=5)

    title = "Keep every scan\norganized."
    title_box = draw.multiline_textbbox(
        (0, 0), title, font=title_font, spacing=1, align="center"
    )
    title_width = title_box[2] - title_box[0]
    draw.multiline_text(
        ((CANVAS_SIZE[0] - title_width) // 2, 94),
        title,
        font=title_font,
        fill=(255, 255, 255, 255),
        spacing=1,
        align="center",
        stroke_width=1,
        stroke_fill=(255, 255, 255, 255),
    )

    subtitle = "Search by title or browse folders."
    subtitle_box = draw.textbbox((0, 0), subtitle, font=subtitle_font)
    subtitle_width = subtitle_box[2] - subtitle_box[0]
    draw.text(
        ((CANVAS_SIZE[0] - subtitle_width) // 2, 413),
        subtitle,
        font=subtitle_font,
        fill=(225, 237, 255, 255),
    )

    add_realistic_phone(canvas, LIBRARY_SCREEN)
    canvas.convert("RGB").save(LIBRARY_OUTPUT_V2, format="PNG", optimize=True)


def render_folders() -> None:
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
    title_font = ImageFont.truetype(HELVETICA, 98, index=1)
    subtitle_font = ImageFont.truetype(AVENIR, 40, index=5)

    title = "Sort scans into\nfolders."
    title_box = draw.multiline_textbbox(
        (0, 0), title, font=title_font, spacing=1, align="center"
    )
    title_width = title_box[2] - title_box[0]
    draw.multiline_text(
        ((CANVAS_SIZE[0] - title_width) // 2, 94),
        title,
        font=title_font,
        fill=(255, 255, 255, 255),
        spacing=1,
        align="center",
        stroke_width=1,
        stroke_fill=(255, 255, 255, 255),
    )

    subtitle = "Lock private folders when you need to."
    subtitle_box = draw.textbbox((0, 0), subtitle, font=subtitle_font)
    subtitle_width = subtitle_box[2] - subtitle_box[0]
    draw.text(
        ((CANVAS_SIZE[0] - subtitle_width) // 2, 413),
        subtitle,
        font=subtitle_font,
        fill=(225, 237, 255, 255),
    )

    add_realistic_phone(canvas, FOLDERS_SCREEN)
    canvas.convert("RGB").save(FOLDERS_OUTPUT, format="PNG", optimize=True)


def render_document_viewer() -> None:
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
    title_font = ImageFont.truetype(HELVETICA, 98, index=1)
    subtitle_font = ImageFont.truetype(AVENIR, 40, index=5)

    title = "Open scans in\nfull detail."
    title_box = draw.multiline_textbbox(
        (0, 0), title, font=title_font, spacing=1, align="center"
    )
    title_width = title_box[2] - title_box[0]
    draw.multiline_text(
        ((CANVAS_SIZE[0] - title_width) // 2, 94),
        title,
        font=title_font,
        fill=(255, 255, 255, 255),
        spacing=1,
        align="center",
        stroke_width=1,
        stroke_fill=(255, 255, 255, 255),
    )

    subtitle = "Rename and share from the same screen."
    subtitle_box = draw.textbbox((0, 0), subtitle, font=subtitle_font)
    subtitle_width = subtitle_box[2] - subtitle_box[0]
    draw.text(
        ((CANVAS_SIZE[0] - subtitle_width) // 2, 413),
        subtitle,
        font=subtitle_font,
        fill=(225, 237, 255, 255),
    )

    add_realistic_phone(canvas, DOCUMENT_VIEWER_SCREEN)
    canvas.convert("RGB").save(DOCUMENT_VIEWER_OUTPUT, format="PNG", optimize=True)


def render_pdf_quality() -> None:
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
    title_font = ImageFont.truetype(HELVETICA, 98, index=1)
    subtitle_font = ImageFont.truetype(AVENIR, 40, index=5)

    title = "Choose PDF quality\nbefore sharing."
    title_box = draw.multiline_textbbox(
        (0, 0), title, font=title_font, spacing=1, align="center"
    )
    title_width = title_box[2] - title_box[0]
    draw.multiline_text(
        ((CANVAS_SIZE[0] - title_width) // 2, 94),
        title,
        font=title_font,
        fill=(255, 255, 255, 255),
        spacing=1,
        align="center",
        stroke_width=1,
        stroke_fill=(255, 255, 255, 255),
    )

    subtitle = "Compare file size and detail before you send."
    subtitle_box = draw.textbbox((0, 0), subtitle, font=subtitle_font)
    subtitle_width = subtitle_box[2] - subtitle_box[0]
    draw.text(
        ((CANVAS_SIZE[0] - subtitle_width) // 2, 413),
        subtitle,
        font=subtitle_font,
        fill=(225, 237, 255, 255),
    )

    add_realistic_phone(canvas, PDF_QUALITY_SCREEN, fit_screen_to_canvas=True)
    canvas.convert("RGB").save(PDF_QUALITY_OUTPUT, format="PNG", optimize=True)


def render_settings() -> None:
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
    title_font = ImageFont.truetype(HELVETICA, 98, index=1)
    subtitle_font = ImageFont.truetype(AVENIR, 40, index=5)

    title = "Set your\npreferences."
    title_box = draw.multiline_textbbox(
        (0, 0), title, font=title_font, spacing=1, align="center"
    )
    title_width = title_box[2] - title_box[0]
    draw.multiline_text(
        ((CANVAS_SIZE[0] - title_width) // 2, 94),
        title,
        font=title_font,
        fill=(255, 255, 255, 255),
        spacing=1,
        align="center",
        stroke_width=1,
        stroke_fill=(255, 255, 255, 255),
    )

    subtitle = "Control display, sharing, and text recognition."
    subtitle_box = draw.textbbox((0, 0), subtitle, font=subtitle_font)
    subtitle_width = subtitle_box[2] - subtitle_box[0]
    draw.text(
        ((CANVAS_SIZE[0] - subtitle_width) // 2, 413),
        subtitle,
        font=subtitle_font,
        fill=(225, 237, 255, 255),
    )

    add_realistic_phone(canvas, SETTINGS_SCREEN)
    canvas.convert("RGB").save(SETTINGS_OUTPUT, format="PNG", optimize=True)


if __name__ == "__main__":
    REALISTIC_DIR.mkdir(parents=True, exist_ok=True)
    render_library_v2()
    render_folders()
    render_document_viewer()
    render_pdf_quality()
    render_settings()
    print(SETTINGS_OUTPUT)
