#!/usr/bin/env python3
"""
Pack rendered frames (diffuse + shadow) into Factorio sprite sheets.

Default folder layout (run from the folder that contains them):
    diffuse/   0001.png 0002.png ...   (one frame per rotation step)
    shadow/    0001.png 0002.png ...

Usage:
    python pack_sprites.py                          # all defaults
    python pack_sprites.py --name survey-probe --columns 8
    python pack_sprites.py --diffuse renders/beauty --shadow renders/shadow
    python pack_sprites.py --no-trim                # keep full frame size

What it does:
  * Loads every PNG in each folder, sorted by the numbers in the file names.
  * Trims the empty border shared by ALL frames of a pass (same crop on every
    frame, so nothing jitters) and works out the Factorio `shift` for it.
  * Lays frames out in a grid and splits into several files if a sheet would
    go past --max-size pixels (8192 by default).
  * Prints a ready-to-paste Lua RotatedSprite with both layers.
  * Writes <name>.lua with the sizes and shifts; copy it into the mod's
    graphics/entity/ folder next to the PNGs and the mod picks it up.

Assumes renders at 64 px per tile (ortho scale = resolution / 64), used in game
at scale 0.5. Needs Pillow (pip install pillow).
"""
import argparse, math, os, re, sys
from PIL import Image


def natural_key(name):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", name)]


def load_frames(folder):
    if not os.path.isdir(folder):
        sys.exit(f"Folder not found: {folder}")
    files = sorted((f for f in os.listdir(folder) if f.lower().endswith(".png")), key=natural_key)
    if not files:
        sys.exit(f"No PNG files in {folder}")
    frames = [Image.open(os.path.join(folder, f)).convert("RGBA") for f in files]
    size = frames[0].size
    for f, im in zip(files, frames):
        if im.size != size:
            sys.exit(f"{folder}/{f} is {im.size}, expected {size} like the first frame")
    return frames


def shared_bbox(frames, pad, alpha_threshold):
    """Union of the visible area of every frame, plus padding.
    Pixels fainter than alpha_threshold (render noise, shadow-catcher haze) are ignored."""
    box = None
    lut = [0 if v < alpha_threshold else 255 for v in range(256)]
    for im in frames:
        b = im.getchannel("A").point(lut).getbbox()
        if b is None:
            continue
        box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]),
                                     max(box[2], b[2]), max(box[3], b[3]))
    w, h = frames[0].size
    if box is None:
        return (0, 0, w, h)
    return (max(0, box[0] - pad), max(0, box[1] - pad), min(w, box[2] + pad), min(h, box[3] + pad))


def pack(frames, name, suffix, columns, max_size, trim, pad, px_per_tile, out_dir, alpha_threshold):
    full_w, full_h = frames[0].size
    box = shared_bbox(frames, pad, alpha_threshold) if trim else (0, 0, full_w, full_h)
    fw, fh = box[2] - box[0], box[3] - box[1]

    # Shift (in tiles) of the cropped frame's centre relative to the render's centre.
    cx = (box[0] + box[2]) / 2 - full_w / 2
    cy = (box[1] + box[3]) / 2 - full_h / 2
    shift = (round(cx / px_per_tile, 4), round(cy / px_per_tile, 4))

    columns = min(columns, len(frames))
    if columns * fw > max_size:
        columns = max(1, max_size // fw)
    rows = math.ceil(len(frames) / columns)
    rows_per_file = max(1, min(rows, max_size // fh))
    n_files = math.ceil(rows / rows_per_file)

    filenames = []
    for fi in range(n_files):
        first_row = fi * rows_per_file
        rows_here = min(rows_per_file, rows - first_row)
        sheet = Image.new("RGBA", (columns * fw, rows_here * fh), (0, 0, 0, 0))
        for r in range(rows_here):
            for c in range(columns):
                idx = (first_row + r) * columns + c
                if idx >= len(frames):
                    break
                sheet.paste(frames[idx].crop(box), (c * fw, r * fh))
        fname = f"{name}-{suffix}" + (f"-{fi + 1}" if n_files > 1 else "") + ".png"
        sheet.save(os.path.join(out_dir, fname), optimize=True)
        filenames.append(fname)
        print(f"  wrote {fname}  ({sheet.width}x{sheet.height})")

    return {"filenames": filenames, "width": fw, "height": fh, "line_length": columns,
            "lines_per_file": rows_per_file, "count": len(frames), "shift": shift}


def lua_layer(info, mod_path, shadow):
    if len(info["filenames"]) == 1:
        files = f'filename = "{mod_path}/{info["filenames"][0]}",'
    else:
        names = ", ".join(f'"{mod_path}/{f}"' for f in info["filenames"])
        files = f'filenames = {{ {names} }},\n      lines_per_file = {info["lines_per_file"]},'
    return f"""    {{
      {files}
      priority = "extra-high",
      width = {info["width"]},
      height = {info["height"]},
      direction_count = {info["count"]},
      line_length = {info["line_length"]},
      shift = {{{info["shift"][0]}, {info["shift"][1]}}},
      scale = 0.5,{chr(10) + '      draw_as_shadow = true,' if shadow else ''}
    }}"""


def main():
    ap = argparse.ArgumentParser(description="Pack diffuse + shadow frames into Factorio sprite sheets.")
    ap.add_argument("--diffuse", default="diffuse", help="folder of diffuse frames (default: diffuse)")
    ap.add_argument("--shadow", default="shadow", help="folder of shadow frames (default: shadow); use '' to skip")
    ap.add_argument("--name", default="sprite", help="output file name prefix (default: sprite)")
    ap.add_argument("--out", default="packed", help="output folder (default: packed)")
    ap.add_argument("--columns", type=int, default=8, help="frames per row (default: 8)")
    ap.add_argument("--max-size", type=int, default=8192, help="max sheet width/height in px (default: 8192)")
    ap.add_argument("--no-trim", action="store_true", help="don't crop empty borders")
    ap.add_argument("--pad", type=int, default=2, help="px of padding kept around the trimmed area (default: 2)")
    ap.add_argument("--alpha-threshold", type=int, default=8,
                    help="ignore pixels fainter than this (0-255) when trimming (default: 8)")
    ap.add_argument("--px-per-tile", type=float, default=64, help="render density (default: 64)")
    ap.add_argument("--mod-path", default="__your-mod__/graphics/entity", help="path prefix for the Lua snippet")
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    layers = []
    print(f"Diffuse: {a.diffuse}")
    d = pack(load_frames(a.diffuse), a.name, "diffuse", a.columns, a.max_size,
             not a.no_trim, a.pad, a.px_per_tile, a.out, a.alpha_threshold)
    layers.append(lua_layer(d, a.mod_path, shadow=False))

    if a.shadow:
        print(f"Shadow: {a.shadow}")
        s_frames = load_frames(a.shadow)
        if len(s_frames) != d["count"]:
            print(f"  WARNING: {len(s_frames)} shadow frames vs {d['count']} diffuse frames", file=sys.stderr)
        s = pack(s_frames, a.name, "shadow", a.columns, a.max_size,
                 not a.no_trim, a.pad, a.px_per_tile, a.out, a.alpha_threshold)
        layers.append(lua_layer(s, a.mod_path, shadow=True))

    # Machine-readable copy for the mod: drop <name>.lua into graphics/entity/
    def meta(info):
        return ("{ width = %d, height = %d, shift = { %s, %s }, line_length = %d, direction_count = %d }"
                % (info["width"], info["height"], info["shift"][0], info["shift"][1], info["line_length"], info["count"]))
    lua_path = os.path.join(a.out, f"{a.name}.lua")
    with open(lua_path, "w") as fh:
        fh.write("-- Generated by pack_sprites.py\nreturn {\n")
        fh.write(f"  diffuse = {meta(d)},\n")
        if a.shadow:
            fh.write(f"  shadow = {meta(s)},\n")
        fh.write("}\n")
    print(f"  wrote {a.name}.lua  (sprite sizes + shifts for the mod)")

    print("\n-- Paste into your radar prototype:")
    print("pictures = {\n  layers = {\n" + ",\n".join(layers) + "\n  }\n}")


if __name__ == "__main__":
    main()
