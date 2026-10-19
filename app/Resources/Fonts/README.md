# 번들 글꼴 (DeskHub 0.42.0 C7, R4)

SIL Open Font License 1.1 글꼴만. 원문은 `licenses/`. 앱은 `Info.plist` 의 `ATSApplicationFontsPath = Fonts` 로 등록하고(코드 등록 없음),
Display 판 'Font' 행·`--key font:<id>`·`DESKHUB_FONT` 로 고른다. 기본은 시스템 글꼴(결정 D-9) — 고른 사람만 바뀐다.
받은 압축은 새 빈 폴더에 풀고 아래 파일과 라이선스만 옮겼다 (2026-10-19).

| 파일 | 글꼴 · 버전 | 출처 | 크기(B) | sha256 |
|---|---|---|---|---|
| Pretendard-Regular.otf | Pretendard 1.3.9 (static OTF) | https://github.com/orioncactus/pretendard/releases/download/v1.3.9/Pretendard-1.3.9.zip → public/static/ | 1574352 | 3ffbacde6ab8411f1d2db54bb9b1f0b3ee2a738932033722cf0388c06aed1c93 |
| Pretendard-Medium.otf | Pretendard 1.3.9 (static OTF) | https://github.com/orioncactus/pretendard/releases/download/v1.3.9/Pretendard-1.3.9.zip → public/static/ | 1584068 | d39e50e4bb52b4993b6a4eeb821a171254745bd824446af01e1f616b89fface0 |
| Pretendard-SemiBold.otf | Pretendard 1.3.9 (static OTF) | https://github.com/orioncactus/pretendard/releases/download/v1.3.9/Pretendard-1.3.9.zip → public/static/ | 1583704 | c89bc43027dc7cde5726e96223376f8eec09302b2fc1f8147fd5b57cfc376118 |
| Pretendard-Bold.otf | Pretendard 1.3.9 (static OTF) | https://github.com/orioncactus/pretendard/releases/download/v1.3.9/Pretendard-1.3.9.zip → public/static/ | 1576660 | 2e91915fab54df71cc9598ebf608b2bdb54c6fe3c066ac61dff0bc44fca71cc7 |
| IBMPlexSansKR-Regular.otf | IBM Plex Sans KR @ibm/plex-sans-kr 1.1.0 (OTF) | https://github.com/IBM/plex/releases/download/%40ibm%2Fplex-sans-kr%401.1.0/ibm-plex-sans-kr.zip → fonts/complete/otf/ | 1051004 | 3638df0e5b7f8cc131d90e6d755f7b9fe8b78b01e59aadf9f64faa0a826aaa92 |
| IBMPlexSansKR-Medium.otf | IBM Plex Sans KR @ibm/plex-sans-kr 1.1.0 (OTF) | https://github.com/IBM/plex/releases/download/%40ibm%2Fplex-sans-kr%401.1.0/ibm-plex-sans-kr.zip → fonts/complete/otf/ | 1056076 | d42f23d1ab94c7851156d48bf08fb8878f8bfec11041577a961fc4a13fe51efe |
| IBMPlexSansKR-SemiBold.otf | IBM Plex Sans KR @ibm/plex-sans-kr 1.1.0 (OTF) | https://github.com/IBM/plex/releases/download/%40ibm%2Fplex-sans-kr%401.1.0/ibm-plex-sans-kr.zip → fonts/complete/otf/ | 1060344 | 74751b835a0643eb6e6ab3040dda9f1342616c1ca2dff436eb79de51ce676d20 |
| IBMPlexSansKR-Bold.otf | IBM Plex Sans KR @ibm/plex-sans-kr 1.1.0 (OTF) | https://github.com/IBM/plex/releases/download/%40ibm%2Fplex-sans-kr%401.1.0/ibm-plex-sans-kr.zip → fonts/complete/otf/ | 882532 | 0c453bf67c976edaef9b544d120bcfa28ec96e7900e5d629392e0b60df50bd90 |
| SUIT-Variable.ttf | SUIT 2.0.5 (Variable TTF) | https://github.com/sun-typeface/SUIT/releases/download/v2.0.5/SUIT-Variable-ttf.zip | 1585020 | 12e1fea375d27869a686d7432c1e6a38154d394994f5d82ace24f36a7db68333 |

| 라이선스 | 파일 |
|---|---|
| Pretendard — OFL 1.1 (Copyright 2021 Kil Hyung-jin) | licenses/Pretendard-OFL.txt |
| IBM Plex Sans KR — OFL 1.1 (Copyright 2017 IBM Corp., Reserved Font Name "Plex") | licenses/IBMPlexSansKR-OFL.txt |
| SUIT — OFL 1.1 (Copyright 2022 SUNN) | licenses/SUIT-OFL.txt |

PostScript 이름 (굵기 → 이름, HubDisplay.fontFaces 와 같음):
- pretendard: Pretendard-Regular · Pretendard-Medium · Pretendard-SemiBold · Pretendard-Bold
- plex: IBMPlexSansKR · IBMPlexSansKR-Medm · IBMPlexSansKR-SmBld · IBMPlexSansKR-Bold
- suit: SUITVariable-Regular · SUITVariable-Medium · SUITVariable-SemiBold · SUITVariable-Bold (가변 글꼴의 이름 붙은 인스턴스)
가벼운 굵기(light 이하)는 Regular, heavy·black 은 Bold 로. 등록 확인(NSFont(name:))에 실패하면 시스템 글꼴로 대체한다.
