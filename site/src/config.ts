// BRAND: rename here. The name also appears in index.html's <title> and meta tags, and in public/404.html.
export const BRAND = "Mac Phone Bridge"
export const REPO = "https://github.com/venkataPhanindraVutla/mac-phone-bridge"
export const docs = (file: string) => `${REPO}/blob/main/${file}`

// The current beta on GitHub Releases. Bump all three together for the next build.
const TAG = "v0.9.0-beta.3"
export const RELEASE = {
  version: "0.9.0 beta 3",
  page: `${REPO}/releases/tag/${TAG}`,
  dmg: { url: `${REPO}/releases/download/${TAG}/MacPhoneBridge-0.9.0-beta.3.dmg`, size: "11.3 MB" },
  apk: { url: `${REPO}/releases/download/${TAG}/MacPhoneBridge-0.9.0-beta.3.apk`, size: "5.9 MB" },
}

/** Paths inside this site, which is served from a sub-folder on GitHub Pages. */
export const page = (path = "") => `${import.meta.env.BASE_URL}${path}`

/** Installs the beta over USB, for phones where Play Protect blocks it (scripts/install-phone.sh). */
export const INSTALL_OVER_USB = "curl -fsSL https://raw.githubusercontent.com/venkataPhanindraVutla/mac-phone-bridge/main/scripts/install-phone.sh | sh"
