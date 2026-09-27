// Applies the requested theme before any content is painted. Falls back to `theme` when
// `darkTheme` is missing or invalid (Quick Look and other single-id hosts).
(() => {
  // The kit's one theme id grammar (design §4.2, kit #125); preview.js uses the same.
  const idPattern = /^[a-z0-9]+(-[a-z0-9]+)*$/;
  const isThemeID = (id) => typeof id === "string" && id.length <= 32 && idPattern.test(id);
  const params = new URLSearchParams(location.search);
  const theme = params.get("theme");
  const darkTheme = params.get("darkTheme");
  const validTheme = isThemeID(theme) ? theme : null;
  const validDark = isThemeID(darkTheme) ? darkTheme : null;
  const preferDark = matchMedia("(prefers-color-scheme: dark)").matches;
  const chosen = preferDark && validDark ? validDark : validTheme;
  if (chosen) document.documentElement.dataset.theme = chosen;
})();
