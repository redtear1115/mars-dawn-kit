// Applies the requested theme before any content is painted.
(() => {
  const theme = new URLSearchParams(location.search).get("theme");
  if (theme && /^[a-z0-9-]+$/.test(theme)) document.documentElement.dataset.theme = theme;
})();
