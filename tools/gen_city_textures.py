"""Surface textures for Calder City's buildings (scripts/story/StoryCity.gd).

    tools/.venv-fusion/Scripts/python.exe tools/gen_city_textures.py

Writes into assets/story/city/:

    <name>.webp     albedo, sRGB, 1024 px
    <name>_n.png    normal map, 512 px, OpenGL convention (green points UP the
                    image), which is the one Godot expects
    skins.json      the linear-RGB mean of every albedo

Albedo is LOSSY WebP on purpose. Godot recompresses it to a GPU format on import
whatever it arrives as, so a lossless source buys nothing on screen and costs
ten times the space in git every time these are regenerated. Normal maps stay
lossless — WebP halves the resolution of its colour channels, and in a normal
map the colour IS the data — at half size, which is still several times what
the map camera can resolve.

StoryCity reads skins.json and tints each texture so its AVERAGE lands exactly
on the flat colour that style used to be. That is the most important property
these have, because from map height the average is most of what the camera
sees: a brick at 124 m is a fraction of a pixel, and the only parts of a texture
that survive the mipmaps are its mean and whatever varies over a metre or more.
So:

  * the town keeps its palette. From the map camera it is the same colours it
    was, with structure in them instead of flat fills;
  * the variation that matters is the LARGE one — concrete panels, stone
    blocks, brick from different batches in patches a metre across, tile
    courses. Those are what these are designed around;
  * mortar, grain and tie holes are for the entry zoom, and cost nothing;
  * and nothing is dirty. No stains, streaks, moss or cracks: the city is not
    damaged (see StoryCity's header), and from above weathering reads as decay.

Everything tiles. Noise is synthesised in the frequency domain, which is
periodic by construction, and every layout divides its tile exactly. The tile
sizes here are the `metres` column of StoryCity.SKINS — change one, change both.

Orientation, which the layouts depend on: StoryCity maps image-UP to world-UP on
walls and to UP-THE-SLOPE on roofs, and puts a floor line (walls) or the eave
(roofs) on the tile's top/bottom edge. So a feature that sits just above a floor
is drawn just above the BOTTOM of the image.
"""

import json
import os

import numpy as np
from PIL import Image

N = 1024
NORMAL_N = 512
ALBEDO_QUALITY = 90
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "assets", "story", "city"))


# ── Plumbing ─────────────────────────────────────────────────────────────────

def to_linear(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def noise(blob_px, seed, stretch=(1.0, 1.0)):
    """Periodic smooth noise with unit standard deviation.

    `blob_px` is roughly how wide one blob comes out. `stretch` widens the blobs
    along x and y separately — (7, 1) gives the horizontal grain of sandstone
    bedding or split slate."""
    rng = np.random.default_rng(seed)
    white = rng.standard_normal((N, N))
    sigma = max(blob_px, 0.3) / 2.5
    fx = np.fft.fftfreq(N)[None, :] * sigma * stretch[0]
    fy = np.fft.fftfreq(N)[:, None] * sigma * stretch[1]
    # The frequency response of a gaussian blur, applied to white noise.
    spec = np.fft.fft2(white) * np.exp(-2.0 * np.pi * np.pi * (fx * fx + fy * fy))
    out = np.real(np.fft.ifft2(spec))
    return out / (out.std() + 1e-12)


def grid(tile_m):
    """Pixel-centre coordinates in metres, and pixels per metre."""
    ppm = N / tile_m
    y, x = np.mgrid[0:N, 0:N].astype(np.float64)
    return (x + 0.5) / ppm, (y + 0.5) / ppm, ppm


def tinted(value, warm):
    """A neutral detail map: `value` everywhere, nudged warm (+) or cool (-).
    StoryCity supplies the actual colour through the tint."""
    out = np.repeat(value[..., None], 3, axis=-1)
    out[..., 0] *= 1.0 + warm
    out[..., 2] *= 1.0 - warm
    return out


def normal_map(height_m, ppm):
    dx = (np.roll(height_m, -1, axis=1) - np.roll(height_m, 1, axis=1)) * (ppm * 0.5)
    dy = (np.roll(height_m, -1, axis=0) - np.roll(height_m, 1, axis=0)) * (ppm * 0.5)
    # +x right, +y UP the image. Rows count downward, so height rising DOWN the
    # image tilts the normal UP it — hence +dy, not -dy.
    n = np.stack([-dx, dy, np.ones_like(height_m)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n * 0.5 + 0.5


def write(name, albedo_lin, means, height_m=None, ppm=None, normal_name=None):
    os.makedirs(OUT, exist_ok=True)
    rgb = (to_srgb(albedo_lin) * 255.0 + 0.5).astype(np.uint8)
    path = os.path.join(OUT, name + ".webp")
    Image.fromarray(rgb).save(path, "WEBP", quality=ALBEDO_QUALITY, method=6)
    # Measured off the file as written, since that is what the game samples.
    saved = to_linear(np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0)
    means[name] = [round(float(v), 5) for v in saved.reshape(-1, 3).mean(axis=0)]
    if height_m is not None:
        # Box-average the height down before differentiating, rather than
        # resizing the finished normals — averaged normals are no longer unit
        # length, and the shader would read them as flatter than they are.
        k = N // NORMAL_N
        small = height_m.reshape(NORMAL_N, k, NORMAL_N, k).mean(axis=(1, 3))
        nrm = (normal_map(small, ppm / k) * 255.0 + 0.5).astype(np.uint8)
        Image.fromarray(nrm).save(
            os.path.join(OUT, (normal_name or name) + "_n.png"), optimize=True)
    print("  %-11s mean %s" % (name, means[name]))


# ── Walls ────────────────────────────────────────────────────────────────────

WALL_TILE = 6.3          # two storeys of StoryCity.STOREY, so floor lines tile


def brick(name, target_srgb, means, with_normal):
    """Stretcher bond, 215 x 65 mm bricks on 10 mm joints.

    The colour is carried here rather than in the tint, because mortar has to
    stay grey whatever colour the bricks are — a tint can only multiply, and a
    red multiply turns grey mortar pink. So the brick faces are adjusted until
    the whole texture averages to `target_srgb`, and the tint comes out ~1."""
    xm, ym, ppm = grid(WALL_TILE)
    L, H, J = 0.225, 0.075, 0.010
    per_row, rows = round(WALL_TILE / L), round(WALL_TILE / H)   # 28 x 84; rows even
    course = np.floor(ym / H).astype(int)
    xs = xm + (course % 2) * (L * 0.5)
    col = np.floor(xs / L).astype(int)
    fu = xs - col * L
    fv = ym - course * H
    edge = np.minimum(np.minimum(fu, L - fu), np.minimum(fv, H - fv))
    ids = (course % rows) * per_row + (col % per_row)

    # One stream for both colours: the bricks are the same bricks, which is what
    # lets them share a normal map.
    rng = np.random.default_rng(1101)
    count = rows * per_row
    tone = 1.0 + 0.09 * rng.standard_normal(count)
    warm = 0.045 * rng.standard_normal(count)
    pick = rng.random(count)

    # Patches a metre or two across, as if laid from different pallets. This is
    # the part of a brick wall that still reads from the map camera.
    batch = 0.055 * noise(0.9 * ppm, 1102) + 0.035 * noise(2.6 * ppm, 1103)
    grain = noise(1.2, 1104)
    arris = 0.84 + 0.16 * smoothstep(J * 0.5, J * 0.5 + 0.012, edge)
    face = smoothstep(J * 0.5 - 0.5 / ppm, J * 0.5 + 0.5 / ppm, edge)[..., None]
    mortar = to_linear([0.600, 0.580, 0.545]) * (1.0 + 0.05 * noise(2.5, 1105))[..., None]

    target = to_linear(target_srgb)
    base = target.copy()
    for _ in range(4):
        per = np.tile(base, (count, 1)) * tone[:, None]
        per[:, 0] *= 1.0 + warm
        per[:, 2] *= 1.0 - warm
        per[pick < 0.07] *= [0.58, 0.52, 0.58]      # over-fired: darker, a touch purple
        per[pick > 0.95] *= [1.16, 1.12, 1.02]      # under-fired: paler, oranger
        bricks = per[ids] * ((1.0 + batch + 0.045 * grain) * arris)[..., None]
        albedo = mortar * (1.0 - face) + bricks * face
        base *= target / albedo.reshape(-1, 3).mean(axis=0)

    height = 0.006 * smoothstep(J * 0.5 - 0.5 / ppm, J * 0.5 + 0.008, edge) + 0.0004 * grain
    write(name, albedo, means, height if with_normal else None, ppm, "brick")


def render(means):
    """Painted render: sand grain, faint trowel sweeps, and broad tone patches.
    Tinted, so cream and sage stucco are the same texture."""
    xm, ym, ppm = grid(WALL_TILE)
    grain = noise(0.8, 4101)
    sand = noise(2.5, 4102)
    trowel = noise(0.10 * ppm, 4103, stretch=(2.2, 1.0))
    patch = 0.036 * noise(0.8 * ppm, 4104) + 0.026 * noise(2.2 * ppm, 4105)
    warm = 0.012 * noise(1.6 * ppm, 4106)
    value = 0.80 * (1.0 + 0.03 * grain + 0.02 * sand + 0.018 * trowel + patch)
    height = 0.0006 * grain + 0.0008 * sand + 0.0010 * trowel
    write("render", tinted(value, warm), means, height, ppm)


def stone(means):
    """Sandstone ashlar: 450 mm courses of blocks of random length.

    Seven courses to a storey, and the course sitting on each floor line is a
    string course — longer, paler stones that stand proud and throw a shadow on
    the wall below. On the ground floor that lands on the plinth, which is where
    a real one would be. Tinted."""
    xm, ym, ppm = grid(WALL_TILE)
    H, rows, J = 0.45, 14, 0.008
    string_courses = (6, 13)       # the course just above each floor line
    rng = np.random.default_rng(2101)

    joints = []
    for c in range(rows):
        lo, hi = (1.8, 2.4) if c in string_courses else (0.7, 1.35)
        for _attempt in range(400):
            lengths = []
            while sum(lengths) < WALL_TILE:
                lengths.append(rng.uniform(lo, hi))
            lengths = np.array(lengths) * (WALL_TILE / sum(lengths))
            xs = np.sort((np.cumsum(lengths) + rng.uniform(0.0, WALL_TILE)) % WALL_TILE)
            if c == 0:
                break
            # A joint straight over the one below is a crack waiting to happen,
            # and it reads as one.
            d = np.abs(xs[:, None] - joints[-1][None, :])
            if np.minimum(d, WALL_TILE - d).min() > 0.16:
                break
        joints.append(xs)

    xs_px = xm[0]
    block_x = np.zeros((rows, N), dtype=int)
    joint_x = np.zeros((rows, N))
    for c, j in enumerate(joints):
        d = np.abs(xs_px[:, None] - j[None, :])
        joint_x[c] = np.minimum(d, WALL_TILE - d).min(axis=1)
        block_x[c] = c * 64 + np.searchsorted(j, xs_px) % len(j)

    course = np.floor(ym / H).astype(int) % rows
    fv = ym - np.floor(ym / H) * H
    cols = np.broadcast_to(np.arange(N)[None, :], (N, N))
    block = block_x[course, cols]
    edge = np.minimum(joint_x[course, cols], np.minimum(fv, H - fv))
    is_string = np.isin(course, string_courses)

    tone = 1.0 + 0.08 * rng.standard_normal(rows * 64)
    warm_b = 0.025 * rng.standard_normal(rows * 64)
    bedding = noise(0.25 * ppm, 2102, stretch=(8.0, 1.0))
    grain = noise(1.5, 2103)
    mottle = noise(1.8 * ppm, 2104)

    value = 0.80 * tone[block] * (1.0 + 0.04 * bedding + 0.035 * grain + 0.03 * mottle)
    value *= np.where(is_string, 1.07, 1.0)
    value *= 0.88 + 0.12 * smoothstep(J * 0.5, J * 0.5 + 0.015, edge)
    joint = smoothstep(J * 0.5 + 0.5 / ppm, J * 0.5 - 0.5 / ppm, edge)
    value *= 1.0 - 0.22 * joint
    # The shadow a string course throws onto the top of the course beneath it.
    under = np.isin((course - 1) % rows, string_courses)
    value *= np.where(under, 0.70 + 0.30 * smoothstep(0.0, 0.025, fv), 1.0)

    height = (0.008 * smoothstep(J * 0.5, J * 0.5 + 0.012, edge)
              + np.where(is_string, 0.012, 0.0) + 0.0006 * grain)
    write("stone", tinted(value, warm_b[block]), means, height, ppm)


def concrete(means):
    """Precast panels, 2.1 m wide and a storey tall.

    StoryCity stretches each wall so one panel lands on every window bay, which
    puts these joints between the windows rather than through them. The panels
    differ in tone from pour to pour — a patchwork a couple of metres across is
    what makes a concrete wall read as concrete from the map. Tinted."""
    xm, ym, ppm = grid(WALL_TILE)
    PW, PH, J = 2.1, 3.15, 0.022
    col = np.floor(xm / PW).astype(int)
    row = np.floor(ym / PH).astype(int)
    fu = xm - col * PW
    fv = ym - row * PH
    edge = np.minimum(np.minimum(fu, PW - fu), np.minimum(fv, PH - fv))
    panel = (row % 2) * 3 + (col % 3)

    rng = np.random.default_rng(3101)
    tone = 1.0 + 0.05 * rng.standard_normal(6)
    warm = 0.012 * rng.standard_normal(6)
    cloud = 0.03 * noise(0.7 * ppm, 3102) + 0.02 * noise(0.18 * ppm, 3103)
    grain = noise(0.9, 3104)
    speck = rng.random((N, N))
    spots = np.where(speck < 0.012, -1.0, np.where(speck > 0.993, 0.7, 0.0))
    spots = np.real(np.fft.ifft2(np.fft.fft2(spots) * np.exp(-2.0 * np.pi ** 2 * 0.36 * (
        np.fft.fftfreq(N)[None, :] ** 2 + np.fft.fftfreq(N)[:, None] ** 2))))

    # Form-tie holes: the cones the shuttering was bolted through.
    hu = np.array([0.35, 1.05, 1.75])
    hv = np.array([0.45, 1.25, 2.05, 2.80])
    du = np.abs(fu[..., None] - hu).min(axis=-1)
    dv = np.abs(fv[..., None] - hv).min(axis=-1)
    r = np.sqrt(du * du + dv * dv)
    hole = smoothstep(0.016, 0.010, r)
    rim = smoothstep(0.030, 0.016, r) - hole

    joint = smoothstep(J * 0.5 + 0.5 / ppm, J * 0.5 - 0.5 / ppm, edge)
    chamfer = smoothstep(J * 0.5 + 0.012, J * 0.5, edge) * (1.0 - joint)

    value = 0.80 * tone[panel] * (1.0 + cloud + 0.025 * grain + 0.12 * spots)
    value *= (1.0 - 0.45 * hole - 0.06 * rim) * (1.0 - 0.55 * joint - 0.08 * chamfer)
    height = (0.004 * smoothstep(J * 0.5, J * 0.5 + 0.012, edge) - 0.003 * hole
              + 0.0003 * grain)
    write("concrete", tinted(value, warm[panel]), means, height, ppm)


# ── Roofs ────────────────────────────────────────────────────────────────────

ROOF_TILE = 4.2


def courses(tile, width, gauge, seed):
    """Staggered courses running across the image, stacked down it — the layout
    both tiles and slates share. Down the image is down the slope."""
    xm, ym, ppm = grid(tile)
    per_row, rows = round(tile / width), round(tile / gauge)
    course = np.floor(ym / gauge).astype(int)
    fv = ym - course * gauge            # 0 where it tucks under the course above
    xs = xm + (course % 2) * (width * 0.5)
    col = np.floor(xs / width).astype(int)
    fu = xs - col * width
    ids = (course % rows) * per_row + (col % per_row)
    return ids, fu, fv, ppm, rows * per_row, np.random.default_rng(seed)


def roof_tile(means):
    """Plain clay tiles, 300 mm wide on a 350 mm gauge.

    The line that matters is the shadow along the top of every course, where the
    butts of the course above sit on it — that is the grain a tiled roof has from
    the air, and it runs along the ridge. Tinted."""
    W, G = 0.30, 0.35
    ids, fu, fv, ppm, count, rng = courses(ROOF_TILE, W, G, 5101)
    # Quieter per tile than it looks like it should be. Every tile a different
    # shade reads as a chequerboard from above, not as a roof; the courses have
    # to win.
    tone = 1.0 + 0.06 * rng.standard_normal(count)
    warm = 0.03 * rng.standard_normal(count)
    dark = np.where(rng.random(count) < 0.05, 0.80, 1.0)

    shade = 0.50 + 0.50 * smoothstep(0.0, 0.08, fv)
    camber = 0.93 + 0.07 * np.sin(np.pi * fu / W)
    gap = smoothstep(0.003, 0.007, np.minimum(fu, W - fu))
    mottle = 0.045 * noise(1.1 * ppm, 5102) + 0.03 * noise(2.8 * ppm, 5103)
    grain = noise(1.0, 5104)

    value = 0.80 * tone[ids] * dark[ids] * shade * camber * (0.45 + 0.55 * gap)
    value *= 1.0 + mottle + 0.04 * grain
    # Each tile rises toward its butt, where it rests on the course below, then
    # steps down onto the next one.
    height = (0.012 * (fv / G) + 0.003 * np.sin(np.pi * fu / W)
              - 0.004 * (1.0 - gap) + 0.0004 * grain)
    write("roof_tile", tinted(value, warm[ids]), means, height, ppm)


def slate(means):
    """Natural slate, 350 mm wide on a 262.5 mm gauge. Thinner courses than tile,
    quieter tone, and a split grain along each slate. Tinted."""
    W, G = 0.35, 0.2625
    ids, fu, fv, ppm, count, rng = courses(ROOF_TILE, W, G, 6101)
    tone = 1.0 + 0.06 * rng.standard_normal(count)
    warm = 0.035 * rng.standard_normal(count)

    shade = 0.66 + 0.34 * smoothstep(0.0, 0.05, fv)
    gap = smoothstep(0.002, 0.005, np.minimum(fu, W - fu))
    split = noise(0.05 * ppm, 6102, stretch=(7.0, 1.0))
    mottle = 0.03 * noise(1.4 * ppm, 6103)
    grain = noise(1.0, 6104)

    value = 0.80 * tone[ids] * shade * (0.55 + 0.45 * gap)
    value *= 1.0 + 0.04 * split + mottle + 0.025 * grain
    height = 0.006 * (fv / G) - 0.002 * (1.0 - gap) + 0.0005 * split
    write("slate", tinted(value, warm[ids]), means, height, ppm)


def membrane(means):
    """Mineral-surfaced felt on a flat roof: metre-wide strips lapped along their
    top edge, with one end lap across each. Seams a metre apart are fine enough
    to read as a roof and coarse enough to survive map height. Tinted."""
    tile = 6.0
    xm, ym, ppm = grid(tile)
    strips = 6
    S = tile / strips
    strip = np.floor(ym / S).astype(int) % strips
    fv = ym - np.floor(ym / S) * S

    rng = np.random.default_rng(7101)
    tone = 1.0 + 0.06 * rng.standard_normal(strips)
    ends = rng.uniform(0.0, tile, strips)
    dx = np.abs(xm - ends[strip])
    dx = np.minimum(dx, tile - dx)
    end = smoothstep(0.016, 0.005, dx)
    lap = smoothstep(0.018, 0.005, fv)
    granules = noise(0.7, 7102)
    broad = noise(1.6 * ppm, 7103)

    value = 0.80 * tone[strip] * (1.0 + 0.07 * granules + 0.04 * broad)
    value *= (1.0 - 0.32 * lap) * (1.0 - 0.26 * end)
    # The doubled-up band along each lap stands a few millimetres proud.
    height = (0.003 * (1.0 - smoothstep(0.07, 0.09, fv))
              + 0.002 * smoothstep(0.012, 0.004, dx) + 0.0004 * granules)
    write("membrane", tinted(value, 0.01 * broad), means, height, ppm)


def main():
    means = {}
    print("writing %s" % OUT)
    # Mirrors StoryCity.BUILDING_STYLES[0] and [5]. Only the average depends on
    # these, and StoryCity's tint corrects the average anyway — they just keep
    # that correction close to 1, so the mortar stays the grey it was drawn.
    brick("brick_red", [0.605, 0.408, 0.330], means, with_normal=True)
    brick("brick_buff", [0.660, 0.500, 0.412], means, with_normal=False)
    render(means)
    stone(means)
    concrete(means)
    roof_tile(means)
    slate(means)
    membrane(means)
    with open(os.path.join(OUT, "skins.json"), "w", newline="\r\n") as f:
        json.dump(means, f, indent=1, sort_keys=True)
        f.write("\n")
    print("done")


if __name__ == "__main__":
    main()
