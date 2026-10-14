#!/usr/bin/env python3
"""Derive visionOS's three-layer asset from the four-group Icon Composer source.

Run after editing App/AppIcon.icon. visionOS still uses a solid image stack;
keep this authoring utility out of the app and leave rendering to asset catalogs.
"""
import json
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / "App/AppIcon.icon"
icon = json.loads((source / "icon.json").read_text())
catalog = root / "App/Assets.xcassets"
stack = catalog / "AppIconVision.solidimagestack"
info = {"author": "xcode", "version": 1}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def artwork(group):
    layer = group["layers"][0]
    svg = (source / "Assets" / layer["image-name"]).read_text()
    body = svg[svg.index(">") + 1:svg.rindex("</svg>")]
    prefix = Path(layer["image-name"]).stem + "-"
    body = re.sub(r'id="([^"]+)"', lambda m: f'id="{prefix}{m[1]}"', body)
    body = re.sub(r'url\(#([^)]+)\)', lambda m: f'url(#{prefix}{m[1]})', body)
    position = layer.get("position", {})
    scale = position.get("scale", 1)
    x, y = position.get("translation-in-points", [0, 0])
    return f'<g transform="translate({x + 512} {y + 512}) scale({scale}) translate(-512 -512)">{body}</g>'


def layer(name, body):
    folder = stack / f"{name}.solidimagestacklayer"
    write_json(folder / "Contents.json", {"info": info})
    images = folder / "Content.imageset"
    write_json(images / "Contents.json", {
        "images": [{"filename": "Artwork.png", "idiom": "vision", "scale": "2x"}], "info": info
    })
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
        + body + '</svg>\n'
    )
    # Solid image stacks require raster textures. Apple's sips rasterizes the shared SVG paths.
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "Artwork.svg"
        path.write_text(svg)
        subprocess.run(["sips", "-s", "format", "png", str(path), "--out", str(images / "Artwork.png")], check=True, stdout=subprocess.DEVNULL)


write_json(catalog / "Contents.json", {"info": info})
write_json(stack / "Contents.json", {
    "info": info, "layers": [{"filename": f"{name}.solidimagestacklayer"} for name in ["Front", "Middle", "Back"]]
})
# Both formats enumerate front first. SVG paints back first. Inset artwork for the circular mask.
for name, groups in [("Front", icon["groups"][:2]), ("Middle", icon["groups"][2:])]:
    layer(name, '<g transform="translate(112.64 112.64) scale(0.78)">'
          + ''.join(artwork(group) for group in reversed(groups)) + '</g>')
colors = icon["fill-specializations"][0]["value"]["linear-gradient"]
stops = []
for offset, color in zip([0, 1], colors):
    rgb = [round(float(c) * 255) for c in color.split(":")[1].split(",")[:3]]
    stops.append(f'<stop offset="{offset}" stop-color="rgb({rgb[0]},{rgb[1]},{rgb[2]})"/>')
layer("Back", '<defs><linearGradient id="background" x2="0" y2="1">' + ''.join(stops)
      + '</linearGradient></defs><rect width="1024" height="1024" fill="url(#background)"/>')
