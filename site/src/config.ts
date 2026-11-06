// BRAND: rename here. The name also appears in index.html's <title> and meta tags, and in public/404.html.
export const BRAND = "Mac Phone Bridge"
export const REPO = "https://github.com/venkataPhanindraVutla/mac-phone-bridge"
export const docs = (file: string) => `${REPO}/blob/main/${file}`

// The current beta on GitHub Releases. Bump all three together for the next build.
const TAG = "v0.9.0-beta.1"
export const RELEASE = {
  version: "0.9.0 beta 1",
  page: `${REPO}/releases/tag/${TAG}`,
  dmg: { url: `${REPO}/releases/download/${TAG}/MacPhoneBridge-0.9.0-beta.1.dmg`, size: "7.7 MB" },
  apk: { url: `${REPO}/releases/download/${TAG}/MacPhoneBridge-0.9.0-beta.1.apk`, size: "43.6 MB" },
}

/** Paths inside this site, which is served from a sub-folder on GitHub Pages. */
export const page = (path = "") => `${import.meta.env.BASE_URL}${path}`
