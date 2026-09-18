// Applies the requested theme before any content is painted. Falls back to `theme` when
// `darkTheme` is missing or invalid (Quick Look and other single-id hosts).
(() => {
  const idPattern = /^[a-z0-9-]+$/;
  const params = new URLSearchParams(location.search);
  const theme = params.get("theme");
  const darkTheme = params.get("darkTheme");
  const validTheme = theme && idPattern.test(theme) ? theme : null;
  const validDark = darkTheme && idPattern.test(darkTheme) ? darkTheme : null;
  const preferDark = matchMedia("(prefers-color-scheme: dark)").matches;
  const chosen = preferDark && validDark ? validDark : validTheme;
  if (chosen) document.documentElement.dataset.theme = chosen;
})();
