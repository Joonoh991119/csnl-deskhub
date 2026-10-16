#!/usr/bin/env python3
"""웹에서 받은 공식 팔레트 → DeskHub 색 토큰 (themes.json).

토큰: backdrop · card · cardBorder · surface · heroBG · text · text2 · text3 · ink · ok · signal · onAccent · divider · fillNeutral
규칙: 강조색(ink/ok/signal)은 surface 위에서 대비 4.5 이상, text2 ≥ 4.5, text3 ≥ 3.0 이 되도록 명도만 조정한다(색상·채도 유지).
"""
import colorsys, json, sys

def rgb(h): h = h.lstrip("#"); return tuple(int(h[i:i+2], 16) / 255 for i in (0, 2, 4))
def hexs(c): return "#" + "".join(f"{round(max(0, min(1, x)) * 255):02x}" for x in c)
def lum(c):
    f = lambda x: x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4
    r, g, b = map(f, c); return 0.2126 * r + 0.7152 * g + 0.0722 * b
def contrast(a, b):
    la, lb = sorted((lum(rgb(a)), lum(rgb(b))), reverse=True); return (la + 0.05) / (lb + 0.05)
def mix(a, b, t): A, B = rgb(a), rgb(b); return hexs(tuple(x * (1 - t) + y * t for x, y in zip(A, B)))
def fit(fg, bg, target, dark):
    """대비가 모자라면 HLS 명도만 움직여 target 을 맞춘다 (다크는 밝게, 라이트는 어둡게)."""
    h, l, s = colorsys.rgb_to_hls(*rgb(fg)); step = 0.01 if dark else -0.01
    while contrast(hexs(colorsys.hls_to_rgb(h, l, s)), bg) < target and 0 <= l <= 1: l += step
    return hexs(colorsys.hls_to_rgb(h, max(0, min(1, l)), s))

def variant(dark, card, backdrop, surface, text, text2, text3, ink, ok, signal):
    v = dict(card=card, backdrop=backdrop, surface=surface, text=fit(text, surface, 7.0, dark),
             text2=fit(text2, surface, 4.5, dark), text3=fit(text3, surface, 3.0, dark),
             ink=fit(ink, surface, 4.5, dark), ok=fit(ok, surface, 4.5, dark), signal=fit(signal, surface, 4.5, dark))
    v["heroBG"] = mix(card, v["ink"], 0.14)
    v["onAccent"] = card if contrast(card, v["ink"]) >= contrast("#ffffff", v["ink"]) else "#ffffff"
    v["cardBorder"] = v["text"] + ("1f" if dark else "14")    # 12% / 8%
    v["divider"] = v["text"] + ("1a" if dark else "14")
    v["fillNeutral"] = v["text"] + "12"
    v["_contrast"] = {k: round(contrast(v[k], surface), 2) for k in ("text", "text2", "text3", "ink", "ok", "signal")}
    return v

cat = json.load(open("catppuccin.json"))
def ctp(f, dark):
    c = {k: v["hex"] for k, v in cat[f]["colors"].items()}
    return variant(dark, c["base"], c["crust"], c["mantle"], c["text"], c["subtext1"], c["overlay1"], c["blue"], c["green"], c["red"])
rp = {k: {c["role"]: "#" + c["hex"] for c in v} for k, v in json.load(open("rosepine.json")).items()}
def rose(f, dark):
    c = rp[f]
    return variant(dark, c["base"], c["overlay"] if not dark else c["surface"], c["surface"] if dark else c["overlay"],
                   c["text"], c["subtle"], c["muted"], c["pine"] if not dark else c["foam"], c["pine"] if dark else c["foam"], c["love"])
nord = {f"nord{i}": h for i, h in enumerate(["#2e3440", "#3b4252", "#434c5e", "#4c566a", "#d8dee9", "#e5e9f0", "#eceff4", "#8fbcbb", "#88c0d0", "#81a1c1", "#5e81ac", "#bf616a", "#d08770", "#ebcb8b", "#a3be8c", "#b48ead"])}
sol = dict(base03="#002b36", base02="#073642", base01="#586e75", base00="#657b83", base0="#839496", base1="#93a1a1", base2="#eee8d5", base3="#fdf6e3",
           red="#dc322f", blue="#268bd2", green="#859900", cyan="#2aa198")
gb = dict(dark0_hard="#1d2021", dark0="#282828", dark1="#3c3836", dark2="#504945", gray="#928374", light0_hard="#f9f5d7", light0="#fbf1c7", light1="#ebdbb2",
          light2="#d5c4a1", light4="#a89984", dark4="#7c6f64", bright_red="#fb4934", bright_green="#b8bb26", bright_blue="#83a598",
          faded_red="#9d0006", faded_green="#79740e", faded_blue="#076678")
tn_storm = dict(bg="#24283b", bg_dark="#1f2335", bg_hl="#292e42", fg="#c0caf5", fg_dark="#a9b1d6", comment="#565f89", dark5="#737aa2", blue="#7aa2f7", green="#9ece6a", red="#f7768e")

themes = {
    "csnl": {"name": "CSNL (기본)", "source": "DeskHub 디자인 스펙 2026-10-12",
             "light": variant(False, "#ffffff", "#e6e8ed", "#f2f4f7", "#1c1e22", "#5a6069", "#808690", "#1f3b5c", "#1c6b54", "#a8302d"),
             "dark": variant(True, "#1c1f26", "#0f1217", "#262932", "#e6e7ea", "#a6aab2", "#7f848d", "#9ebde0", "#73b899", "#ee8a82")},
    "catppuccin": {"name": "Catppuccin (Latte / Mocha)", "source": "github.com/catppuccin/palette (MIT)",
                   "light": ctp("latte", False), "dark": ctp("mocha", True)},
    "rosepine": {"name": "Rosé Pine (Dawn / Moon)", "source": "github.com/rose-pine/palette (MIT)",
                 "light": rose("dawn", False), "dark": rose("moon", True)},
    "nord": {"name": "Nord", "source": "github.com/nordtheme/nord (MIT)",
             "light": variant(False, nord["nord6"], nord["nord4"], nord["nord5"], nord["nord0"], nord["nord3"], nord["nord3"], nord["nord10"], nord["nord14"], nord["nord11"]),
             "dark": variant(True, nord["nord0"], "#242933", nord["nord1"], nord["nord6"], nord["nord4"], nord["nord3"], nord["nord8"], nord["nord14"], nord["nord11"])},
    "solarized": {"name": "Solarized", "source": "github.com/altercation/vim-colors-solarized (MIT)",
                  "light": variant(False, sol["base3"], sol["base2"], sol["base2"], sol["base01"], sol["base00"], sol["base1"], sol["blue"], sol["green"], sol["red"]),
                  "dark": variant(True, sol["base03"], "#001f27", sol["base02"], sol["base1"], sol["base0"], sol["base01"], sol["blue"], sol["green"], sol["red"])},
    "gruvbox": {"name": "Gruvbox", "source": "github.com/morhetz/gruvbox (MIT/X11)",
                "light": variant(False, gb["light0"], gb["light1"], gb["light0_hard"], gb["dark1"], gb["dark4"], gb["light4"], gb["faded_blue"], gb["faded_green"], gb["faded_red"]),
                "dark": variant(True, gb["dark0"], gb["dark0_hard"], gb["dark1"], gb["light1"], gb["light4"], gb["gray"], gb["bright_blue"], gb["bright_green"], gb["bright_red"])},
    "tokyonight": {"name": "Tokyo Night (Storm · 항상 다크)", "source": "github.com/folke/tokyonight.nvim (Apache-2.0)", "alwaysDark": True,
                   "light": variant(True, tn_storm["bg"], tn_storm["bg_dark"], tn_storm["bg_hl"], tn_storm["fg"], tn_storm["fg_dark"], tn_storm["dark5"], tn_storm["blue"], tn_storm["green"], tn_storm["red"]),
                   "dark": variant(True, tn_storm["bg"], tn_storm["bg_dark"], tn_storm["bg_hl"], tn_storm["fg"], tn_storm["fg_dark"], tn_storm["dark5"], tn_storm["blue"], tn_storm["green"], tn_storm["red"])},
}
bad = [(t, m, k, c) for t, th in themes.items() for m in ("light", "dark") for k, c in th[m]["_contrast"].items()
       if c < {"text3": 3.0}.get(k, 4.5)]
for t, th in themes.items():
    for m in ("light", "dark"):
        print(f"{t:11s} {m:5s}", " ".join(f"{k}={c}" for k, c in th[m]["_contrast"].items()))
print("대비 미달:", bad or "없음")
json.dump(themes, open(sys.argv[1] if len(sys.argv) > 1 else "themes.json", "w"), ensure_ascii=False, indent=2)
