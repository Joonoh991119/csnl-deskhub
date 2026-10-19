# 테마 원본 팔레트

`scripts/build_themes.py` 가 이 폴더의 공식 팔레트를 읽어 `Resources/themes.json` (DeskHub 색 토큰) 을 만든다.
다시 만들기: `cd Resources/theme-sources && python3 ../../scripts/build_themes.py ../themes.json`

| 파일 | 출처 (2026-10-13 내려받음) | 라이선스 |
|---|---|---|
| catppuccin.json | https://github.com/catppuccin/palette | MIT |
| rosepine.json | https://github.com/rose-pine/palette | MIT |
| nord.css | https://github.com/nordtheme/nord | MIT |
| solarized.vim | https://github.com/altercation/vim-colors-solarized | MIT |
| gruvbox.vim | https://github.com/morhetz/gruvbox | MIT/X11 |
| tokyonight_storm.lua · tokyonight_moon.lua | https://github.com/folke/tokyonight.nvim | Apache-2.0 |

0.42.0 C7 에 더한 원본 (2026-10-19 내려받음 — 받은 파일에서 필요한 줄만 옮겼다. hex 는 이 파일들에서만 읽는다):

| 파일 | 출처 | 라이선스 |
|---|---|---|
| primer_light.css · primer_dark.css | https://unpkg.com/@primer/primitives@11.10.0/dist/css/functional/themes/{light,dark}.css (github.com/primer/primitives) | MIT |
| carbon_white.js · carbon_g100.js | https://unpkg.com/@carbon/themes@11.83.0/js/generated/themes/{white,g100}.js (github.com/carbon-design-system/carbon) | Apache-2.0 |
| radix_{slate,blue,green,red}.css · radix_*_dark.css | https://unpkg.com/@radix-ui/colors@3.0.0/ (github.com/radix-ui/colors) — sRGB 블록만. blue-11 #0d74ce · red-11 #ce2c31(라이트) 원본 확인 | MIT |
| tokyonight_night.lua · tokyonight_day.lua | https://raw.githubusercontent.com/folke/tokyonight.nvim/main/extras/lua/tokyonight_{night,day}.lua — 'local colors' 블록만 | Apache-2.0 |
| catppuccin.json (frappe · macchiato) | 위 catppuccin 파일 그대로 | MIT |
| everforest_palette.md | https://raw.githubusercontent.com/sainnhe/everforest/master/palette.md — 'Palette Variants' 절만(medium) | MIT |

대비 규칙: 본문 글자 ≥ 7:1, 보조 글자·강조색(ink/ok/signal) ≥ 4.5:1, 흐린 글자 ≥ 3:1 (surface 위). 모자라면 색상·채도는 두고 명도만 조정한다.
검사(0.42.0 C7): 위 기준에 하나라도 미달이면 build_themes.py 가 종료 1 — 고대비 프리셋(Theme.swift)도 같은 검사. 테마 이름은 원 출처 영어 이름.
사용자 테마를 더하려면 `~/Library/Application Support/DeskHub/themes.json` 에 같은 형식으로 넣는다 (같은 id 면 덮어씀).
