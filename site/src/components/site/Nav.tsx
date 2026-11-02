import { useEffect, useState } from "react"
import { IconBrandGithub } from "@tabler/icons-react"
import { cn } from "@/lib/utils"
import { BRAND, REPO } from "@/config"
import { LogoMark } from "./parts"

const links = [
  ["A day with it", "#day"],
  ["Features", "#features"],
  ["Privacy", "#privacy"],
  ["Status", "#status"],
  ["Questions", "#faq"],
] as const

export function Nav() {
  const [scrolled, setScrolled] = useState(false)
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24)
    onScroll()
    window.addEventListener("scroll", onScroll, { passive: true })
    return () => window.removeEventListener("scroll", onScroll)
  }, [])

  return (
    <header
      className={cn(
        "fixed inset-x-0 top-0 z-50 transition-[background-color,box-shadow,backdrop-filter] duration-300",
        scrolled ? "bg-night/70 shadow-[0_1px_0_var(--color-line)] backdrop-blur-xl" : "bg-transparent",
      )}
    >
      <div className="wrap flex h-16 items-center justify-between gap-6">
        <a href="#top" className="flex items-center gap-2.5 font-display text-[1.05rem] font-semibold tracking-tight">
          <LogoMark className="h-7 w-7 text-mist" />
          {BRAND}
        </a>
        <nav aria-label="Sections" className="hidden items-center gap-7 text-[0.95rem] text-haze lg:flex">
          {links.map(([label, href]) => (
            <a key={href} href={href} className="transition-colors hover:text-mist">
              {label}
            </a>
          ))}
        </nav>
        <a
          href={REPO}
          className="inline-flex h-10 items-center gap-2 rounded-full bg-white/[0.06] px-4 text-[0.95rem] font-medium ring-1 ring-white/10 transition-colors ring-inset hover:bg-white/10"
        >
          <IconBrandGithub size={18} stroke={1.8} aria-hidden="true" />
          GitHub
        </a>
      </div>
    </header>
  )
}
