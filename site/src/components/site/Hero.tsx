import { useRef } from "react"
import { motion, useReducedMotion, useScroll, useTransform } from "motion/react"
import { IconBrandGithub, IconDownload } from "@tabler/icons-react"
import { MacbookScroll } from "@/components/ui/macbook-scroll"
import { BRAND, RELEASE, REPO, page } from "@/config"
import { MacScreen } from "./MacScreen"
import { AppIcon, LogoMark } from "./parts"

const headline = ["Your", "Android", "phone,", "part", "of", "your", "Mac."]

export function Hero() {
  const ref = useRef<HTMLElement>(null)
  const reduce = useReducedMotion()
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start start", "end start"] })
  const fade = useTransform(scrollYProgress, [0, 0.12], [1, 0])
  const lift = useTransform(scrollYProgress, [0, 0.12], [0, -60])

  return (
    <section ref={ref} id="top" aria-labelledby="hero-h" className="relative overflow-x-clip">

      <motion.div style={reduce ? undefined : { opacity: fade, y: lift }} className="wrap relative z-10 pt-28 text-center sm:pt-36">
        <h1 id="hero-h" className="display mx-auto max-w-[13ch] text-[clamp(2.75rem,8.4vw,6.5rem)]">
          {headline.map((word, i) => (
            <motion.span
              key={i}
              className="inline-block pr-[0.22em] last:pr-0"
              initial={reduce ? false : { opacity: 0, y: "0.4em", filter: "blur(8px)" }}
              animate={{ opacity: 1, y: 0, filter: "blur(0px)" }}
              transition={{ duration: 0.9, delay: 0.08 * i, ease: [0.22, 1, 0.36, 1] }}
            >
              {word}
            </motion.span>
          ))}
        </h1>
        <motion.div
          initial={reduce ? false : { opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.8, delay: 0.7, ease: [0.22, 1, 0.36, 1] }}
        >
          <p className="mx-auto mt-7 max-w-[36rem] text-lg text-haze sm:text-xl">
            {BRAND} is a pair of native apps, one for your Mac and one for your phone. Notifications, calls, files, the clipboard and the
            phone's own screen come to your Mac, straight over your own Wi-Fi.
          </p>
          <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
            <a
              href={page("start/")}
              className="inline-flex h-12 items-center gap-2 rounded-full bg-lime px-6 font-semibold text-night transition-[transform,background-color] hover:bg-[#e2ff7a] active:scale-[0.98]"
            >
              <IconDownload size={20} stroke={1.8} aria-hidden="true" />
              Download the beta
            </a>
            <a
              href={REPO}
              className="inline-flex h-12 items-center gap-2 rounded-full px-6 font-medium text-mist ring-1 ring-line transition-[background-color,box-shadow] ring-inset hover:bg-white/5 hover:ring-haze/40"
            >
              <IconBrandGithub size={20} stroke={1.8} aria-hidden="true" />
              View on GitHub
            </a>
          </div>
          <p className="mt-5 text-sm text-haze">Free public beta, version {RELEASE.version}. For macOS 14 or later and Android 10 or later.</p>
        </motion.div>
      </motion.div>

      <div className="-mt-6 md:-mt-10">
        <MacbookScroll
          screen={<MacScreen />}
          lidMark={<LogoMark className="h-7 w-7 text-white/70" />}
          badge={<AppIcon className="h-10 w-10 -rotate-12" />}
        />
      </div>
    </section>
  )
}
