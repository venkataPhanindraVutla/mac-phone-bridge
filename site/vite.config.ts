import path from "node:path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

// Served from GitHub Pages at /mac-phone-bridge/. Two pages: the home page and Get started.
export default defineConfig({
  base: "/mac-phone-bridge/",
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { "@": path.resolve(import.meta.dirname, "./src") },
  },
  build: {
    rollupOptions: {
      input: {
        main: path.resolve(import.meta.dirname, "index.html"),
        start: path.resolve(import.meta.dirname, "start/index.html"),
      },
    },
  },
})
