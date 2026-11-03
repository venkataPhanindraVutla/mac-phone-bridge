import { useEffect, useState } from "react"
import { AnimatePresence, motion } from "motion/react"
import { IconBrandGithub, IconMenu2, IconX } from "@tabler/icons-react"
import { cn } from "@/lib/utils"
import { BRAND, REPO } from "@/config"
import { LogoMark } from "./parts"

const links = [
  ["A day with it", "day"],
  ["Features", "features"],
  ["Privacy", "privacy"],
  ["Get it", "setup"],
  ["Status", "status"],
  ["Questions", "faq"],
] as const

export function Nav() {
  const [scrolled, setScrolled] = useState(false)
  const [current, setCurrent] = useState<string | null>(null)
  const [open, setOpen] = useState(false)

  useEffect(() => {
    const onScroll = () => {
      setScrolled(window.scrollY > 24)
      // The last section is shorter than half a window, so mark it once the page bottoms out.
      if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4) setCurrent("faq")
    }
    onScroll()
    window.addEventListener("scroll", onScroll, { passive: true })
    return () => window.removeEventListener("scroll", onScroll)
  }, [])

  // The section under the middle of the window is the current one.
  useEffect(() => {
    const sections = links.map(([, id]) => document.getElementById(id)).filter((el): el is HTMLElement => !!el)
    const observer = new IntersectionObserver(
      (entries) => entries.forEach((e) => e.isIntersecting && setCurrent(e.target.id)),
      { rootMargin: "-50% 0px -50% 0px" },
    )
    sections.forEach((s) => observer.observe(s))
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false)
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [open])

  return (
    <header
      className={cn(
        "fixed inset-x-0 top-0 z-50 transition-[background-color,box-shadow,backdrop-filter] duration-300",
        scrolled || open ? "bg-night/80 shadow-[0_1px_0_var(--color-line)] backdrop-blur-xl" : "bg-transparent",
      )}
    >
      <div className="wrap flex h-16 items-center justify-between gap-6">
        <a href="#top" className="flex items-center gap-2.5 font-display text-[1.05rem] font-semibold tracking-tight" onClick={() => setOpen(false)}>
          <LogoMark className="h-7 w-7 text-mist" />
          {BRAND}
        </a>
        <nav aria-label="Sections" className="hidden items-center gap-1 text-[0.95rem] lg:flex">
          {links.map(([label, id]) => (
            <a
              key={id}
              href={`#${id}`}
              aria-current={current === id ? "location" : undefined}
              className={cn("relative isolate rounded-full px-3.5 py-1.5 transition-colors", current === id ? "text-mist" : "text-haze hover:text-mist")}
            >
              {current === id && <motion.span layoutId="nav-current" className="absolute inset-0 -z-10 rounded-full bg-white/[0.07]" transition={{ type: "spring", stiffness: 420, damping: 34 }} />}
              {label}
            </a>
          ))}
        </nav>
        <div className="flex items-center gap-2">
          <a
            href={REPO}
            className="inline-flex h-10 items-center gap-2 rounded-full bg-white/[0.06] px-4 text-[0.95rem] font-medium ring-1 ring-white/10 transition-colors ring-inset hover:bg-white/10"
          >
            <IconBrandGithub size={18} stroke={1.8} aria-hidden="true" />
            <span className="hidden sm:inline">GitHub</span>
          </a>
          <button
            type="button"
            onClick={() => setOpen((o) => !o)}
            aria-expanded={open}
            aria-controls="mobile-menu"
            aria-label={open ? "Close menu" : "Open menu"}
            className="grid h-10 w-10 place-items-center rounded-full ring-1 ring-white/10 ring-inset lg:hidden"
          >
            {open ? <IconX size={19} aria-hidden="true" /> : <IconMenu2 size={19} aria-hidden="true" />}
          </button>
        </div>
      </div>
      <AnimatePresence>
        {open && (
          <motion.nav
            id="mobile-menu"
            aria-label="Sections"
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: "auto", opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.25, ease: [0.22, 1, 0.36, 1] }}
            className="overflow-hidden border-t border-line lg:hidden"
          >
            <ul className="wrap py-3">
              {links.map(([label, id]) => (
                <li key={id}>
                  <a
                    href={`#${id}`}
                    onClick={() => setOpen(false)}
                    aria-current={current === id ? "location" : undefined}
                    className={cn("flex items-center justify-between py-3 font-display text-[1.35rem] font-semibold tracking-tight", current === id ? "text-lime" : "text-mist")}
                  >
                    {label}
                  </a>
                </li>
              ))}
            </ul>
          </motion.nav>
        )}
      </AnimatePresence>
    </header>
  )
}
