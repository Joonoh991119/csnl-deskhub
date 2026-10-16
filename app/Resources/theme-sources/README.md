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
| tokyonight_*.lua | https://github.com/folke/tokyonight.nvim | Apache-2.0 |

대비 규칙: 본문 글자 ≥ 7:1, 보조 글자·강조색(ink/ok/signal) ≥ 4.5:1, 흐린 글자 ≥ 3:1 (surface 위). 모자라면 색상·채도는 두고 명도만 조정한다.
사용자 테마를 더하려면 `~/Library/Application Support/DeskHub/themes.json` 에 같은 형식으로 넣는다 (같은 id 면 덮어씀).
