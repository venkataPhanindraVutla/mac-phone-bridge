import { useEffect, useRef, useState, type ReactNode } from "react"
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react"
import {
  IconBrandGithub,
  IconCheck,
  IconCopy,
  IconDeviceLaptop,
  IconDeviceMobile,
  IconMessageCircleQuestion,
  IconPlus,
  IconCamera,
  IconWifi,
  IconAccessible,
  IconBatteryEco,
  IconShieldCheck,
  IconDevices,
  IconPackage,
} from "@tabler/icons-react"
import { GlowingEffect } from "@/components/ui/glowing-effect"
import { TextHoverEffect } from "@/components/ui/text-hover-effect"
import { Timeline } from "@/components/ui/timeline"
import { cn } from "@/lib/utils"
import { BRAND, REPO, docs } from "@/config"
import { LogoMark } from "./parts"

const commands = [`git clone ${REPO}.git`, "cd mac-phone-bridge"]
const comment = '# then follow "Build it" in README.md'

/** Types the commands out once the terminal is on screen. */
function Terminal() {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { once: true, amount: 0.6 })
  const reduce = useReducedMotion()
  const full = [...commands, comment].join("\n")
  const [n, setN] = useState(0)
  const [copied, setCopied] = useState(false)
  useEffect(() => {
    if (!inView) return
    if (reduce) return setN(full.length)
    const t = setInterval(() => setN((v) => (v >= full.length ? (clearInterval(t), v) : v + 1)), 22)
    return () => clearInterval(t)
  }, [inView, reduce, full.length])
  const lines = full.slice(0, n).split("\n")
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(commands.join("\n"))
      setCopied(true)
      setTimeout(() => setCopied(false), 1800)
    } catch {
      setCopied(false)
    }
  }
  return (
    <figure ref={ref} className="relative overflow-hidden rounded-2xl bg-[#070707] ring-1 ring-line">
      <figcaption className="flex items-center justify-between border-b border-line px-4 py-2.5 text-[0.85rem] text-haze">
        <span className="flex items-center gap-3">
          <span className="flex gap-1.5" aria-hidden="true">
            <i className="h-2.5 w-2.5 rounded-full bg-[#ff5f57]" />
            <i className="h-2.5 w-2.5 rounded-full bg-[#febc2e]" />
            <i className="h-2.5 w-2.5 rounded-full bg-[#28c840]" />
          </span>
          Terminal, on your Mac
        </span>
        <button type="button" onClick={copy} className="inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-mist hover:bg-white/5">
          {copied ? <IconCheck size={15} aria-hidden="true" /> : <IconCopy size={15} aria-hidden="true" />}
          {copied ? "Copied" : "Copy"}
        </button>
      </figcaption>
      <pre className="min-h-[9.5rem] overflow-x-auto px-5 py-5 font-mono text-[0.88rem] leading-7" aria-label={[...commands, comment].join(". ")}>
        <code aria-hidden="true">
          {lines.map((line, i) => (
            <span key={i} className={cn("block", line.startsWith("#") ? "text-haze/70" : "text-mist")}>
              {!line.startsWith("#") && <span className="text-lime select-none">$ </span>}
              {line}
              {i === lines.length - 1 && <span className="ml-0.5 inline-block h-[1.1em] w-[0.55em] translate-y-[0.2em] animate-pulse bg-mist/70" />}
            </span>
          ))}
        </code>
      </pre>
    </figure>
  )
}

function DeviceCard({ icon, title, rows }: { icon: ReactNode; title: string; rows: [string, string][] }) {
  return (
    <div className="relative rounded-[1.5rem] p-px">
      <GlowingEffect spread={40} glow disabled={false} proximity={64} inactiveZone={0.01} borderWidth={1.5} />
      <div className="relative h-full rounded-[calc(1.5rem-1px)] bg-deep p-7 ring-1 ring-line">
        <div className="flex items-center gap-3">
          <span className="grid h-11 w-11 place-items-center rounded-xl bg-white/[0.05] text-mist ring-1 ring-white/10" aria-hidden="true">
            {icon}
          </span>
          <h3 className="font-display text-[1.4rem] font-semibold tracking-tight">{title}</h3>
        </div>
        <dl className="mt-6 divide-y divide-line">
          {rows.map(([k, v]) => (
            <div key={k} className="grid grid-cols-[7.5rem_1fr] gap-4 py-3.5 text-[0.97rem]">
              <dt className="text-haze">{k}</dt>
              <dd>{v}</dd>
            </div>
          ))}
        </dl>
      </div>
    </div>
  )
}

export function Setup() {
  return (
    <section id="setup" aria-labelledby="setup-h" className="py-24 lg:py-36">
      <div className="wrap">
        <div className="grid items-end gap-6 lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)]">
          <h2 id="setup-h" className="display text-[clamp(2.2rem,5vw,4rem)]">
            What you need.
          </h2>
          <p className="max-w-[30rem] text-lg text-haze lg:justify-self-end">
            One Mac and one Android phone on the same network. A 5 GHz Wi-Fi network gives Full mode its best picture.
          </p>
        </div>

        <div className="mt-14 grid gap-4 md:grid-cols-2">
          <DeviceCard
            icon={<IconDeviceLaptop size={22} stroke={1.6} />}
            title="Mac"
            rows={[
              ["System", "macOS 14 Sonoma or later"],
              ["Chip", "Apple silicon. Intel builds, but is untested."],
              ["Permissions", "Accessibility, only if you use the trackpad or remote"],
            ]}
          />
          <DeviceCard
            icon={<IconDeviceMobile size={22} stroke={1.6} />}
            title="Android phone"
            rows={[
              ["Most features", "Android 10 or later"],
              ["Full mode", "Android 11 or later"],
              ["Setup", "Install the app and scan a QR code. Each permission is asked for when you first use it."],
            ]}
          />
        </div>

        <div className="mt-20 grid items-center gap-10 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:gap-16">
          <div>
            <h3 className="display text-[clamp(1.9rem,3.6vw,2.9rem)]">Build it from source today.</h3>
            <p className="mt-4 text-haze">There's no download yet. To try it now, build both apps on a Mac.</p>
            <p className="mt-3 text-[0.95rem] text-haze">
              You'll need Xcode, xcodegen, protoc, JDK 21 and the Android SDK. The README's{" "}
              <a className="text-mist underline decoration-line underline-offset-4 hover:decoration-pink" href={`${REPO}#build-it`}>
                Build it
              </a>{" "}
              section has the exact versions and commands.
            </p>
          </div>
          <Terminal />
        </div>
      </div>
    </section>
  )
}

function Chip({ icon, children, state }: { icon: ReactNode; children: ReactNode; state: "done" | "now" | "next" }) {
  return (
    <li
      className={cn(
        "flex items-center gap-3 rounded-xl px-4 py-3 text-[0.95rem] ring-1",
        state === "done" && "bg-lime/[0.06] ring-lime/20",
        state === "now" && "bg-pink/[0.07] ring-pink/25",
        state === "next" && "bg-white/[0.02] text-haze ring-line",
      )}
    >
      <span className={cn("shrink-0", state === "done" ? "text-lime" : state === "now" ? "text-pink" : "text-haze")} aria-hidden="true">
        {icon}
      </span>
      <span className="flex-1">{children}</span>
      {state === "done" && <IconCheck size={16} className="text-lime" aria-label="Built" />}
      {state === "now" && (
        <span className="relative flex h-2.5 w-2.5" aria-label="In progress">
          <span className="absolute inset-0 animate-ping rounded-full bg-pink/60" />
          <span className="relative h-2.5 w-2.5 rounded-full bg-pink" />
        </span>
      )}
    </li>
  )
}

const built = [
  ["0.1", "Pairing and the secure connection, phone status, find my phone"],
  ["0.2", "Notifications, one-time codes, contacts and calls"],
  ["0.3", "Clipboard, files, screenshots and photos"],
  ["0.4", "Music, Focus sync, auto-lock, trackpad and remote"],
  ["0.5", "Full mode"],
] as const

const timeline = [
  {
    title: "Built",
    content: (
      <div>
        <p className="mb-5 max-w-[34rem] text-haze">All five milestones are built and in testing.</p>
        <ul className="grid gap-2">
          {built.map(([v, text]) => (
            <Chip key={v} state="done" icon={<span className="font-display text-[0.95rem] font-semibold">{v}</span>}>
              {text}
            </Chip>
          ))}
        </ul>
      </div>
    ),
  },
  {
    title: "Beta, now",
    content: (
      <div>
        <p className="mb-5 max-w-[34rem] text-haze">A private beta, with testers on several phone models. This is where it is today.</p>
        <ul className="grid gap-2 sm:grid-cols-2">
          <Chip state="now" icon={<IconDevices size={18} />}>Hardening across phone makers and Android versions</Chip>
          <Chip state="now" icon={<IconBatteryEco size={18} />}>Under 4% battery a day when idle</Chip>
          <Chip state="now" icon={<IconAccessible size={18} />}>VoiceOver and TalkBack</Chip>
          <Chip state="now" icon={<IconShieldCheck size={18} />}>A security review</Chip>
        </ul>
      </div>
    ),
  },
  {
    title: "1.0",
    content: (
      <div>
        <p className="mb-5 max-w-[34rem] text-haze">The public release follows the beta.</p>
        <ul className="grid gap-2 sm:grid-cols-2">
          <Chip state="next" icon={<IconBrandGithub size={18} />}>Both apps on GitHub Releases</Chip>
          <Chip state="next" icon={<IconPackage size={18} />}>The Android app on F-Droid</Chip>
        </ul>
      </div>
    ),
  },
  {
    title: "2.0",
    content: (
      <div>
        <p className="mb-5 max-w-[34rem] text-haze">Later.</p>
        <ul className="grid gap-2 sm:grid-cols-2">
          <Chip state="next" icon={<IconCamera size={18} />}>The phone as your Mac's webcam and microphone</Chip>
          <Chip state="next" icon={<IconWifi size={18} />}>A one-click hotspot</Chip>
        </ul>
      </div>
    ),
  },
]

export function Status() {
  return (
    <section id="status" aria-labelledby="status-h" className="py-24 lg:py-32">
      <div className="wrap">
        <div className="grid items-end gap-6 lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)]">
          <h2 id="status-h" className="display text-[clamp(2.2rem,5vw,4rem)]">
            Where it's at.
          </h2>
          <p className="max-w-[30rem] text-lg text-haze lg:justify-self-end">Not released yet. Everything is built and being tested in a private beta. The public release follows.</p>
        </div>
        <div className="mt-6">
          <Timeline data={timeline} />
        </div>
        <div className="mt-4 flex flex-wrap gap-3 md:pl-20">
          <a href={`${REPO}/releases`} className="inline-flex h-11 items-center gap-2 rounded-full bg-lime px-5 font-semibold text-night hover:bg-[#e2ff7a]">
            <IconBrandGithub size={18} aria-hidden="true" />
            Watch releases on GitHub
          </a>
          <a href={docs("docs/ROADMAP.md")} className="inline-flex h-11 items-center rounded-full px-5 font-medium ring-1 ring-line ring-inset hover:bg-white/5">
            Read the roadmap
          </a>
        </div>
      </div>
    </section>
  )
}

const faqs: [string, string][] = [
  ["Is it free?", "Yes. It's free and open source under the Apache-2.0 licence. There's nothing to buy and no paid tier."],
  ["Do I need an account?", "No. There is no account and no server. You pair your phone and your Mac once with a QR code, and they talk to each other directly."],
  [
    "Which phones does it work with?",
    "Android 10 or later for everything except Full mode, which needs Android 11 or later. The beta has testers on several phone models, and the test plan covers Pixel, Samsung, Xiaomi, OnePlus and Motorola phones. Some makers add an extra developer switch for Full mode; the phone app tells you when yours does.",
  ],
  [
    "Does it read my messages?",
    "It never asks for SMS permission, so it can't read your text messages. It shows the notifications you allow, from the apps you choose, and one-time codes are found in that notification text only.",
  ],
  [
    "Why isn't it on the Play Store or the App Store yet?",
    "It isn't released yet. The plan for 1.0 is GitHub Releases for both apps and F-Droid for the Android app, with Google Play later. The Mac app won't be on the Mac App Store: controlling the pointer and keyboard doesn't fit the App Store's sandbox, so it will be downloaded directly.",
  ],
  [
    "Is it safe?",
    "Pairing uses a QR code and a 6-digit code you confirm on both devices. After that, every connection is mutual TLS 1.3 with certificates pinned at pairing, so an unpaired device can't connect. Nothing leaves your local network. Full mode's helper runs only while the Mac shows the phone's screen and accepts commands only from your paired Mac. The code is open for anyone to review.",
  ],
  ["Does it work when my phone and Mac are on different networks?", "Not in version 1. Both need to be on the same local network."],
  ["Are the screens on this page real?", "They're drawn for this page from the apps' real layouts and wording, with made-up names and messages."],
]

function Question({ q, a, open, onToggle, id }: { q: string; a: string; open: boolean; onToggle: () => void; id: string }) {
  return (
    <div className={cn("rounded-2xl ring-1 transition-colors", open ? "bg-deep ring-line" : "ring-transparent hover:bg-white/[0.02]")}>
      <h3>
        <button type="button" aria-expanded={open} aria-controls={id} onClick={onToggle} className="flex w-full items-center justify-between gap-6 px-5 py-5 text-left text-[1.06rem] font-medium">
          {q}
          <motion.span animate={{ rotate: open ? 45 : 0 }} transition={{ type: "spring", stiffness: 400, damping: 28 }} className={cn("grid h-8 w-8 shrink-0 place-items-center rounded-full ring-1", open ? "bg-pink text-night ring-pink" : "text-haze ring-line")}>
            <IconPlus size={16} aria-hidden="true" />
          </motion.span>
        </button>
      </h3>
      <AnimatePresence initial={false}>
        {open && (
          <motion.div id={id} key="a" initial={{ height: 0, opacity: 0 }} animate={{ height: "auto", opacity: 1 }} exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.3, ease: [0.22, 1, 0.36, 1] }} className="overflow-hidden">
            <p className="max-w-[44rem] px-5 pb-6 text-haze">{a}</p>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  )
}

export function Faq() {
  const [open, setOpen] = useState(0)
  return (
    <section id="faq" aria-labelledby="faq-h" className="py-24 lg:py-36">
      <div className="wrap grid gap-12 lg:grid-cols-[minmax(0,4fr)_minmax(0,8fr)]">
        <div className="lg:sticky lg:top-28 lg:self-start">
          <h2 id="faq-h" className="display text-[clamp(2.2rem,5vw,4rem)]">
            Questions.
          </h2>
          <div className="mt-8 rounded-[1.4rem] bg-deep p-6 ring-1 ring-line">
            <IconMessageCircleQuestion size={24} className="text-pink" aria-hidden="true" />
            <p className="mt-3 font-medium">Something missing?</p>
            <p className="mt-1 text-[0.95rem] text-haze">Ask on GitHub. Questions and bug reports both go there.</p>
            <a href={`${REPO}/issues`} className="mt-4 inline-flex h-10 items-center gap-2 rounded-full bg-white/[0.06] px-4 text-[0.92rem] font-medium ring-1 ring-white/10 ring-inset hover:bg-white/10">
              <IconBrandGithub size={17} aria-hidden="true" />
              Open an issue
            </a>
          </div>
        </div>
        <div className="space-y-1">
          {faqs.map(([q, a], i) => (
            <Question key={q} id={`faq-${i}`} q={q} a={a} open={open === i} onToggle={() => setOpen(open === i ? -1 : i)} />
          ))}
        </div>
      </div>
    </section>
  )
}

export function Footer() {
  return (
    <footer className="relative overflow-hidden border-t border-line pt-16 pb-10">
      <div className="wrap relative">
        <div className="grid gap-10 md:grid-cols-[minmax(0,6fr)_minmax(0,3fr)_minmax(0,3fr)]">
          <div>
            <p className="flex items-center gap-2.5 font-display text-lg font-semibold">
              <LogoMark className="h-7 w-7" />
              {BRAND}
            </p>
            <p className="mt-4 max-w-[26rem] text-[0.95rem] text-haze">
              Your Android phone, part of your Mac. Free and open source under the{" "}
              <a className="text-mist underline decoration-line underline-offset-4 hover:decoration-pink" href={docs("LICENSE")}>
                Apache-2.0 licence
              </a>
              .
            </p>
            <a href={REPO} className="mt-6 inline-flex h-11 items-center gap-2 rounded-full bg-lime px-5 font-semibold text-night hover:bg-[#e2ff7a]">
              <IconBrandGithub size={18} aria-hidden="true" />
              Star it on GitHub
            </a>
          </div>
          <nav aria-label="Project" className="flex flex-col gap-2.5 text-[0.95rem]">
            <h2 className="mb-1 font-medium">Project</h2>
            <a className="text-haze hover:text-mist" href={REPO}>Source on GitHub</a>
            <a className="text-haze hover:text-mist" href={`${REPO}/issues`}>Report an issue</a>
            <a className="text-haze hover:text-mist" href={`${REPO}/releases`}>Releases</a>
          </nav>
          <nav aria-label="Docs" className="flex flex-col gap-2.5 text-[0.95rem]">
            <h2 className="mb-1 font-medium">Docs</h2>
            <a className="text-haze hover:text-mist" href={docs("docs/PRD.md")}>Product requirements</a>
            <a className="text-haze hover:text-mist" href={docs("docs/ARCHITECTURE.md")}>Architecture</a>
            <a className="text-haze hover:text-mist" href={docs("docs/ROADMAP.md")}>Roadmap</a>
          </nav>
        </div>
        <div className="mt-10 hidden h-[clamp(8rem,16vw,15rem)] md:block" aria-hidden="true">
          <TextHoverEffect text={BRAND} width={760} />
        </div>
        <p className="mt-10 text-[0.82rem] text-haze/70 md:mt-4">
          Not affiliated with Apple or Google. Mac and macOS are trademarks of Apple Inc. Android is a trademark of Google LLC.
        </p>
      </div>
    </footer>
  )
}
