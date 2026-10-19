#if os(macOS)
/// A gallery theme exactly as the website serves it: nord 1.0.1, from mars-dawn-website
/// `origin/release` @ 2567da8e840ef44c3d2ac28bf7de0ee638792659,
/// `public/themes/v1/nord/1.0.1/theme.json` (SHA-256 bc50d00ae2d1e6a7476800bc425ded3f533afd80c3b083e55df062f0b61b00c9,
/// the digest `published.json` lists for it). Kept as source so the kit's test bundle stays as it is.
enum GalleryThemeFixture {
    static let nordID = "nord"
    static let nord = ##"""
{
  "schemaVersion": 1,
  "id": "nord",
  "version": "1.0.1",
  "name": {
    "en": "Nord"
  },
  "summary": {
    "en": "An arctic, north-bluish palette, with an original light companion — adapted from Nord, adjusted for readability",
    "zh-Hant": "北歐冰藍色調，並原創搭配一款淺色版本 — 改編自 Nord，為可讀性調整",
    "zh-Hans": "北欧冰蓝色调，并原创搭配一款浅色版本 — 改编自 Nord，为可读性调整",
    "ja": "北極のような北国ブルーのパレット。ライト版は独自追加 — Nord を基に、読みやすさのために調整",
    "de": "Eine arktische, nordisch-bläuliche Palette mit eigener heller Variante – nach Nord, für bessere Lesbarkeit angepasst",
    "fr": "Palette arctique aux bleus nordiques, avec une variante claire originale – adaptée de Nord, ajustée pour la lisibilité",
    "es": "Una paleta ártica de azules nórdicos, con una variante clara original —adaptada de Nord y ajustada para leer mejor",
    "ko": "북극의 푸른빛 팔레트에 새로 만든 라이트 버전을 더함 — Nord를 바탕으로 가독성에 맞게 조정"
  },
  "fontDesign": "sans",
  "scenarios": [
    "technical-docs",
    "agent-review"
  ],
  "author": {
    "name": "Southern Light",
    "github": "redtear1115"
  },
  "license": "Apache-2.0",
  "light": {
    "background": "#ECEFF4",
    "surface": "#E5E9F0",
    "text": "#2E3440",
    "muted": "#4C566A",
    "border": "#D8DEE9",
    "heading": "#4E6E97",
    "accent": "#B44953",
    "link": "#4E6E97",
    "quote": "#4393AA",
    "syntax": {
      "keyword": "#4B6B92",
      "string": "#47733B",
      "comment": "#4C566A",
      "number": "#885A80",
      "function": "#077480",
      "type": "#3A6BA1"
    },
    "diagram": {
      "node": "#D8DEE9",
      "nodeBorder": "#5C7FAB",
      "text": "#2E3440",
      "line": "#4C566A",
      "secondary": "#DCEAE9",
      "tertiary": "#F1EDF4",
      "note": "#F1E9D4"
    }
  },
  "dark": {
    "background": "#2E3440",
    "surface": "#3B4252",
    "text": "#D8DEE9",
    "muted": "#A4AFBF",
    "border": "#4C566A",
    "heading": "#88C0D0",
    "accent": "#88C0D0",
    "link": "#81A1C1",
    "quote": "#707E98",
    "syntax": {
      "keyword": "#96B1CB",
      "string": "#A3BE8C",
      "comment": "#A4AFBF",
      "number": "#C3A5BD",
      "function": "#88C0D0",
      "type": "#8FBCBB"
    },
    "diagram": {
      "node": "#3B4252",
      "nodeBorder": "#88C0D0",
      "text": "#ECEFF4",
      "line": "#707E98",
      "secondary": "#2E3B3A",
      "tertiary": "#332E3D",
      "note": "#3A3626"
    }
  },
  "style": {
    "radius": 4,
    "hr": {
      "style": {
        "type": "line",
        "color": "border",
        "thickness": 1
      }
    },
    "table": {
      "header": {
        "type": "surface"
      }
    },
    "blockquote": {
      "style": {
        "type": "bar",
        "width": 3
      }
    },
    "listMarker": "muted"
  }
}
"""##
}
#endif
