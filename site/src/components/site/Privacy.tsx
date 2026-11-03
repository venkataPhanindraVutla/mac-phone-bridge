import { useState } from "react"
import { AnimatePresence, motion, useReducedMotion } from "motion/react"
import { IconCloudOff, IconDeviceLaptop, IconShieldCheck, IconShieldX, IconCode, IconLock } from "@tabler/icons-react"
import { BackgroundBeams } from "@/components/ui/background-beams"
import { AndroidPhone, MacBook } from "./devices"
import { LogoMark, Wallpaper } from "./parts"
import { cn } from "@/lib/utils"
import { SectionHead, sectionPad } from "./Section"

const path = "M 92 150 C 220 70, 380 70, 508 150"
const strangerPath = "M 300 262 C 330 220, 420 200, 470 170"

function Bridge() {
  const reduce = useReducedMotion()
  const [stranger, setStranger] = useState<"idle" | "trying" | "refused">("idle")
  const tryStranger = () => {
    setStranger("trying")
    setTimeout(() => setStranger("refused"), 1100)
  }
  return (
    <div className="relative mx-auto w-full max-w-[44rem]">
      <svg viewBox="0 0 600 290" className="w-full" aria-hidden="true">
        {/* The route data never takes: up to a server and back. */}
        <path d="M 92 150 L 300 40 L 508 150" fill="none" stroke="#3a3a3a" strokeWidth="1.5" strokeDasharray="4 7" />
                <path d={path} fill="none" stroke="#d4ff3f" strokeWidth="3" strokeLinecap="round" />
        {!reduce &&
          [0, 0.9, 1.8].map((delay) => (
            <motion.circle
              key={delay}
              r="4.5"
              fill="#ff2dab"
              style={{ offsetPath: `path("${path}")` }}
              initial={{ offsetDistance: "0%", opacity: 0 }}
              animate={{ offsetDistance: ["0%", "100%"], opacity: [0, 1, 1, 0] }}
              transition={{ duration: 2.7, delay, repeat: Infinity, ease: "easeInOut" }}
            />
          ))}
        <AnimatePresence>
          {stranger !== "idle" && (
            <motion.path
              key="stranger"
              d={strangerPath}
              fill="none"
              stroke={stranger === "refused" ? "#ff7a7a" : "#9a9a9a"}
              strokeWidth="2"
              strokeDasharray="5 6"
              initial={{ pathLength: 0, opacity: 0 }}
              animate={{ pathLength: stranger === "refused" ? 0.78 : 0.9, opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.9 }}
            />
          )}
        </AnimatePresence>
      </svg>

      <Node className="top-[51.7%] left-[15.3%]" device="phone" label="Your phone" />
      <Node className="top-[51.7%] left-[84.7%]" device="mac" label="Your Mac" />
      <div className="absolute top-[13.8%] left-1/2 -translate-x-1/2 -translate-y-1/2 text-center">
        <span className="mx-auto grid h-11 w-11 place-items-center rounded-full bg-night text-haze/70 ring-1 ring-line">
          <IconCloudOff size={21} stroke={1.5} aria-hidden="true" />
        </span>
        <p className="mt-1.5 text-[0.75rem] whitespace-nowrap text-haze/70">No server</p>
      </div>
      <div className="relative mt-10 flex justify-center sm:absolute sm:top-[90%] sm:left-1/2 sm:mt-0 sm:-translate-x-1/2 sm:-translate-y-1/2">
        <button
          type="button"
          onClick={stranger === "idle" ? tryStranger : () => setStranger("idle")}
          className={cn(
            "inline-flex h-10 items-center gap-2 rounded-full px-4 text-[0.88rem] whitespace-nowrap ring-1 transition-colors ring-inset",
            stranger === "refused" ? "bg-[#ff7a7a]/10 text-[#ffb0b0] ring-[#ff7a7a]/40" : "bg-deep text-mist ring-line hover:ring-haze/40",
          )}
        >
          {stranger === "refused" ? <IconShieldX size={17} aria-hidden="true" /> : <IconDeviceLaptop size={17} aria-hidden="true" />}
          {stranger === "idle" && "Connect a stranger's laptop"}
          {stranger === "trying" && "Connecting…"}
          {stranger === "refused" && "Refused: not paired"}
        </button>
      </div>
      <p className="sr-only" aria-live="polite">
        {stranger === "refused" ? "The Mac refused the connection, because the laptop's certificate wasn't pinned at pairing." : ""}
      </p>
    </div>
  )
}

function Node({ className, device, label }: { className: string; device: "phone" | "mac"; label: string }) {
  // The same hardware as the day story, drawn small: em sizes scale with this font size.
  return (
    <div className={cn("absolute -translate-x-1/2 -translate-y-[62%] text-center", className)}>
      <div aria-hidden="true" className="text-[4px] sm:text-[5.5px]">
        {device === "phone" ? (
          <AndroidPhone className="mx-auto w-[11em]">
            <div className="grid h-full place-items-center bg-lime text-night">
              <LogoMark className="h-[5em] w-[5em]" />
            </div>
          </AndroidPhone>
        ) : (
          <MacBook className="mx-auto w-[25em] sm:w-[30em]">
            <div className="absolute inset-0">
              <Wallpaper />
            </div>
          </MacBook>
        )}
      </div>
      <p className="mt-3 text-sm whitespace-nowrap text-haze">{label}</p>
    </div>
  )
}

function PairCodes() {
  return (
    <div className="flex items-center justify-center gap-3 py-2" aria-hidden="true">
      {["Mac", "Phone"].map((d, i) => (
        <div key={d} className={cn("rounded-xl px-3 py-2.5 text-center ring-1", i === 0 ? "bg-[#1c1c1c] ring-white/10" : "bg-[#f2f2f2] text-[#1c1b22] ring-black/5")}>
          <p className={cn("text-[0.7rem]", i === 0 ? "text-white/50" : "text-black/45")}>{d}</p>
          <p className="font-display text-[1.05rem] font-semibold tracking-[0.08em] whitespace-nowrap tabular-nums">418 027</p>
        </div>
      ))}
      <motion.span initial={{ scale: 0 }} whileInView={{ scale: 1 }} viewport={{ once: true }} transition={{ delay: 0.4, type: "spring" }} className="grid h-7 w-7 place-items-center rounded-full bg-lime text-night">
        <IconShieldCheck size={16} />
      </motion.span>
    </div>
  )
}

const steps = [
  ["Pair once", "The Mac shows a QR code. Scan it with the phone, then check that the same 6-digit code shows on both screens.", <PairCodes key="p" />],
  ["Connect directly", "From then on they find each other on the same network and connect with mutual TLS 1.3, using certificates pinned at pairing. An unpaired device can't connect.", null],
  ["Stay on your devices", "Nothing is relayed through a server. Remove the pairing from either side whenever you like.", null],
] as const

const without = [
  ["An account", "Nothing to sign up for, nothing to sign in to."],
  ["The cloud", "Your data stays on your two devices."],
  ["Telemetry", "No analytics. If crash reporting is ever added, it will be opt-in."],
  ["SMS access", "The Android app asks for no SMS permission."],
] as const

function Struck({ children, delay }: { children: string; delay: number }) {
  return (
    <span className="relative inline-block">
      {children}
      <motion.span
        aria-hidden="true"
        className="absolute top-[54%] right-[-0.08em] left-[-0.08em] h-[0.09em] rounded-full bg-pink"
        initial={{ scaleX: 0 }}
        whileInView={{ scaleX: 1 }}
        viewport={{ once: true, amount: 1 }}
        transition={{ duration: 0.5, delay, ease: [0.22, 1, 0.36, 1] }}
        style={{ originX: 0 }}
      />
    </span>
  )
}

export function Privacy() {
  return (
    <section id="privacy" aria-labelledby="privacy-h" className={`relative overflow-x-clip border-t border-line ${sectionPad}`}>
      <div aria-hidden="true" className="pointer-events-none absolute inset-x-0 top-0 h-[44rem] opacity-70 [mask-image:linear-gradient(to_bottom,black,transparent)]">
        <BackgroundBeams />
      </div>
      <div className="wrap relative">
        <SectionHead id="privacy-h" center title={<>Phone to Mac, and nothing in between.</>} lede={<>The two apps find each other on your local network and talk directly. There is no server, so there's nothing to sign in to.</>} />

        <div className="mt-12">
          <Bridge />
        </div>

        <ol className="mx-auto mt-20 grid max-w-[66rem] gap-4 md:grid-cols-3">
          {steps.map(([title, text, extra]) => (
            <li key={title} className="rounded-[1.4rem] bg-deep/70 p-6 ring-1 ring-line">
              {extra && <div className="mb-4">{extra}</div>}
              <h3 className="font-display text-[1.25rem] font-semibold tracking-tight">{title}</h3>
              <p className="mt-2 text-[0.97rem] leading-relaxed text-haze">{text}</p>
            </li>
          ))}
        </ol>

        <div className="mx-auto mt-28 grid max-w-[66rem] gap-14 lg:grid-cols-[minmax(0,6fr)_minmax(0,5fr)] lg:gap-20">
          <div>
            <h3 className="display text-[clamp(1.9rem,3.6vw,2.9rem)]">Private by design. Here's what it works without.</h3>
            <dl className="mt-10 space-y-7">
              {without.map(([term, text], i) => (
                <div key={term} className="grid gap-1 sm:grid-cols-[13rem_1fr] sm:gap-6">
                  <dt className="font-display text-[1.6rem] leading-tight font-semibold tracking-tight text-mist/80">
                    <Struck delay={0.15 * i}>{term}</Struck>
                  </dt>
                  <dd className="text-haze sm:pt-1.5">{text}</dd>
                </div>
              ))}
            </dl>
          </div>
          <div className="grid content-start gap-4">
            <div className="rounded-[1.4rem] bg-lime p-6 text-night">
              <IconLock size={22} aria-hidden="true" />
              <p className="mt-4 font-display text-[1.25rem] font-semibold tracking-tight">Encrypted at rest</p>
              <p className="mt-2 text-[0.97rem] leading-relaxed text-night/75">Synced contacts are stored encrypted on the Mac, and wiped when you turn caller ID off or unpair.</p>
            </div>
            <div className="rounded-[1.4rem] bg-pink p-6 text-night">
              <IconCode size={22} aria-hidden="true" />
              <p className="mt-4 font-display text-[1.25rem] font-semibold tracking-tight">Open source</p>
              <p className="mt-2 text-[0.97rem] leading-relaxed text-night/75">Every line is on GitHub under Apache-2.0, for anyone to read.</p>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
