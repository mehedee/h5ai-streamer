#!/usr/bin/env python3
"""Generate Myra's three layered Icon Composer documents and every rendered PNG.

Icon Composer's ictool is the source of truth for all renditions. Aperture is the
default; it is also the bundle icon in AppIcon.appiconset. Spotlight and Ribbon M
are Dock choices rendered to Sources/Myra/Resources/MyraIcons for runtime use.
Glyphs are centred inside the macOS safe area of a 1024 pt master and contain no text.

Every bitmap rendition follows the macOS icon grid: the squircle body is 824/1024 of the canvas,
centred (100 px margin at 1024), with a soft drop shadow (10 px down, 28 px blur, 30% black).
ictool renders the full-bleed body; Scripts/compose-myra-icon.swift places it on the canvas.
"""
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
ICON_TOOL = pathlib.Path(os.environ.get(
    'MYRA_ICTOOL',
    '/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool'))
ICONS_DIR = ROOT / 'Resources' / 'MyraIcons'
RUNTIME_DIR = ROOT / 'Sources' / 'Myra' / 'Resources' / 'MyraIcons'
APPICON_DIR = ROOT / 'Resources' / 'Assets.xcassets' / 'AppIcon.appiconset'

COMPOSE_SOURCE = ROOT / 'Scripts' / 'compose-myra-icon.swift'
# The icon grid: the body is 824 of 1024 units wide and the rest is margin for the shadow.
BODY_UNITS = 824
CANVAS_UNITS = 1024
RUNTIME_CANVAS = 512

# Renditions: (Icon Composer rendition name, runtime suffix).
RENDITIONS = [('Default', 'default'), ('Dark', 'dark'), ('ClearLight', 'clear'), ('TintedLight', 'tinted')]
# macOS 14-15 bundle icon sizes: (pixel size, appiconset filename).
APPICON_SIZES = [
    (16, 'icon_16x16.png'), (32, 'icon_16x16@2x.png'), (32, 'icon_32x32.png'),
    (64, 'icon_32x32@2x.png'), (128, 'icon_128x128.png'), (256, 'icon_128x128@2x.png'),
    (256, 'icon_256x256.png'), (512, 'icon_256x256@2x.png'), (512, 'icon_512x512.png'),
    (1024, 'icon_512x512@2x.png'),
]


def srgb(hex_colour):
    """Convert #rrggbb to Icon Composer's srgb:r,g,b,a string."""
    value = hex_colour.lstrip('#')
    parts = [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return 'srgb:' + ','.join(f'{p:.4f}' for p in parts) + ',1'


def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" fill="white">'
            + body + '</svg>')


# Concept geometry and colours follow docs/artifacts/redesign/preview.html (concepts array).
CONCEPTS = {
    'aperture': {
        'name': 'Aperture',
        'light': ('#6a5cff', '#2a1a78'),
        'dark': ('#2a2440', '#0c0a18'),
        'secondary': ('Aperture ring', svg(
            '<circle cx="512" cy="512" r="300" fill="none" stroke="white" stroke-width="44"/>'), 0.55),
        'primary': ('Play mark', svg('<path d="M430 352v320l256-160z"/>'), None),
    },
    'spotlight': {
        'name': 'Spotlight',
        'light': ('#ff8a4c', '#9b1d5c'),
        'dark': ('#3a1f2e', '#120810'),
        'secondary': ('Spotlight beam', svg(
            '<path d="M512 150 300 830h424z" fill-opacity="0.7"/>'
            '<ellipse cx="512" cy="820" rx="250" ry="46" fill-opacity="0.9"/>'), 0.5),
        'primary': ('Play mark', svg('<path d="M450 470v240l190-120z"/>'), None),
    },
    'ribbon-m': {
        'name': 'Ribbon M',
        'light': ('#22c1c3', '#2b4bd8'),
        'dark': ('#14303a', '#080f1c'),
        'secondary': ('Ribbon forward chevron', svg(
            '<path transform="translate(-22 0)" d="M754 320l70 200-70 200" fill="none" stroke="white" '
            'stroke-width="40" stroke-linecap="round" stroke-linejoin="round"/>'), 0.55),
        'primary': ('Ribbon M', svg(
            '<path transform="translate(-22 0)" d="M270 720V320l242 220 242-220v400" fill="none" '
            'stroke="white" stroke-width="92" stroke-linecap="round" stroke-linejoin="round"/>'), None),
    },
}


def gradient(colours):
    return {'linear-gradient': [srgb(colours[0]), srgb(colours[1])],
            'orientation': {'start': {'x': 0.5, 'y': 0}, 'stop': {'x': 0.5, 'y': 0.7}}}


def write_document(key, concept):
    document = ICONS_DIR / (key + '.icon')
    (document / 'Assets').mkdir(parents=True, exist_ok=True)
    secondary_name, secondary_svg, secondary_opacity = concept['secondary']
    primary_name, primary_svg, _ = concept['primary']
    (document / 'Assets' / 'secondary.svg').write_text(secondary_svg + '\n')
    (document / 'Assets' / 'primary.svg').write_text(primary_svg + '\n')
    secondary_layer = {'image-name': 'secondary.svg', 'name': secondary_name, 'glass': True,
                       'opacity': secondary_opacity}
    primary_layer = {'image-name': 'primary.svg', 'name': primary_name, 'glass': True,
                     'fill': 'automatic'}
    data = {
        # Background layer: the document fill, with an explicit dark appearance.
        'fill': gradient(concept['light']),
        'fill-specializations': [{'appearance': 'dark', 'value': gradient(concept['dark'])}],
        'supported-platforms': {'squares': 'shared'},
        # Glyph layers sit above the background, lit and glassed by the system.
        'groups': [{
            'layers': [secondary_layer, primary_layer],
            'lighting': 'individual',
            'shadow': {'kind': 'neutral', 'opacity': 0.5},
            'specular': True,
            'translucency': {'enabled': True, 'value': 0.3},
        }],
    }
    (document / 'icon.json').write_text(json.dumps(data, indent=2) + '\n')
    return document


def render(document, rendition, size, output):
    """Render the full-bleed body with ictool at `size` pixels."""
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(ICON_TOOL), str(document), '--export-image', '--output-file', str(output),
                    '--platform', 'macOS', '--rendition', rendition, '--width', str(size),
                    '--height', str(size), '--scale', '1'], check=True)


def body_size(canvas):
    return round(canvas * BODY_UNITS / CANVAS_UNITS)


def build_composer(directory):
    binary = pathlib.Path(directory) / 'compose-myra-icon'
    subprocess.run(['swiftc', '-O', str(COMPOSE_SOURCE), '-o', str(binary)], check=True)
    return binary


def main():
    if not ICON_TOOL.exists():
        raise SystemExit(f'ictool not found at {ICON_TOOL}; set MYRA_ICTOOL to render icons')
    with tempfile.TemporaryDirectory() as scratch:
        scratch = pathlib.Path(scratch)
        composer = build_composer(scratch)

        def compose(document, rendition, canvas, output):
            body = scratch / 'body.png'
            render(document, rendition, body_size(canvas), body)
            output.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run([str(composer), 'compose', str(body), str(output), str(canvas)],
                           check=True)

        for key, concept in CONCEPTS.items():
            document = write_document(key, concept)
            for rendition, suffix in RENDITIONS:
                compose(document, rendition, RUNTIME_CANVAS, RUNTIME_DIR / f'{key}-{suffix}.png')
        aperture = ICONS_DIR / 'aperture.icon'
        master = scratch / 'master.png'
        compose(aperture, 'Default', CANVAS_UNITS, master)
        for size, filename in APPICON_SIZES:
            output = APPICON_DIR / filename
            if size == CANVAS_UNITS:
                output.write_bytes(master.read_bytes())
            else:
                subprocess.run([str(composer), 'resize', str(master), str(output), str(size)],
                               check=True)


if __name__ == '__main__':
    main()
