// Every feature as a tile with a small working demo of it. Demos that loop only run while
// the tile is on screen, and not at all when the visitor asks for reduced motion.
import { useEffect, useRef, useState, type ReactNode } from "react"
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react"
import {
  IconBattery3,
  IconBellOff,
  IconCheck,
  IconCopy,
  IconDeviceMobile,
  IconLock,
  IconLockOpen,
  IconMoon,
  IconPlayerPauseFilled,
  IconPlayerPlayFilled,
  IconPlayerSkipForwardFilled,
  IconPhone,
  IconWifi,
  IconAntennaBars4,
  IconFileTypePdf,
  IconBolt,
} from "@tabler/icons-react"
import { GlowingEffect } from "@/components/ui/glowing-effect"
import { cn } from "@/lib/utils"
import { Avatar, Photo, Wallpaper } from "./parts"

function useLoop(ms: number) {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { amount: 0.4 })
  const reduce = useReducedMotion()
  const [tick, setTick] = useState(0)
  useEffect(() => {
    if (!inView || reduce) return
    const t = setInterval(() => setTick((n) => n + 1), ms)
    return () => clearInterval(t)
  }, [inView, reduce, ms])
  return { ref, tick, still: !!reduce }
}

function Tile({ title, text, children, className, desktop }: { title: string; text: string; children: ReactNode; className?: string; desktop?: boolean }) {
  return (
    <li className={cn("relative list-none rounded-[1.5rem] p-px", className)}>
      <GlowingEffect spread={40} glow disabled={false} proximity={64} inactiveZone={0.01} borderWidth={1.5} />
      <div className="relative flex h-full flex-col overflow-hidden rounded-[calc(1.5rem-1px)] bg-deep ring-1 ring-line">
        <div className={cn("relative flex min-h-[11rem] flex-1 items-center justify-center overflow-hidden px-5 pt-6 pb-2", desktop && "m-2 mb-0 rounded-[1.1rem] py-8")}>
          {desktop && <Wallpaper className="opacity-90" />}
          <div className="relative flex w-full justify-center">{children}</div>
        </div>
        <div className="px-6 pt-3 pb-6">
          <h3 className="font-display text-[1.15rem] font-semibold tracking-tight">{title}</h3>
          <p className="mt-1.5 text-[0.95rem] leading-relaxed text-haze">{text}</p>
        </div>
      </div>
    </li>
  )
}

/* Notifications: a live feed, with per-app filters you can switch. */
const feed = [
  { app: "Messages", who: "Priya", text: "Running a bit late, start without me?", tint: "from-[#ffb38a] to-[#e2729a]" },
  { app: "Calendar", who: "Design review", text: "In 10 minutes, Room 4", tint: "from-[#ff8a80] to-[#d84a5c]" },
  { app: "Deliveries", who: "Your order is out", text: "Arriving between 2 and 3 pm", tint: "from-[#ffd36b] to-[#e59a2f]" },
  { app: "Messages", who: "Dev", text: "Pushed the fix, can you check?", tint: "from-[#9be7c4] to-[#3fa98a]" },
  { app: "Calendar", who: "Gym", text: "Tomorrow at 7:00", tint: "from-[#ff8a80] to-[#d84a5c]" },
]

function NotificationsDemo() {
  const { ref, tick } = useLoop(2200)
  const [muted, setMuted] = useState<string[]>([])
  const allowed = feed.filter((n) => !muted.includes(n.app))
  // Entry number tick is the newest; each tick pushes the others down one place.
  const n = allowed.length
  const shown = n ? [0, 1, 2].slice(0, Math.min(3, n)).map((i) => ({ id: tick - i, item: allowed[(((tick - i) % n) + n) % n] })) : []
  return (
    <div ref={ref} className="flex w-full max-w-[28rem] flex-col items-stretch gap-4">
      <div className="relative h-[13.5rem]">
        <AnimatePresence initial={false}>
          {shown.map(({ id, item }, i) => (
            <motion.div
              key={`${id}-${item.who}`}
              layout
              initial={{ opacity: 0, y: -24, scale: 0.96 }}
              animate={{ opacity: 1 - i * 0.28, y: i * 70, scale: 1 - i * 0.04 }}
              exit={{ opacity: 0, y: 230, scale: 0.9 }}
              transition={{ type: "spring", stiffness: 260, damping: 30 }}
              className="absolute inset-x-0 top-0 flex gap-3 rounded-2xl bg-[#232945]/90 p-3.5 ring-1 ring-white/10 backdrop-blur"
              style={{ zIndex: 10 - i }}
            >
              <span className={cn("grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-gradient-to-br text-sm font-semibold text-[#21122b]", item.tint)}>{item.who[0]}</span>
              <div className="min-w-0 flex-1 leading-snug">
                <div className="flex justify-between gap-2 text-[0.88rem]">
                  <span className="truncate font-semibold">{item.who}</span>
                  <span className="shrink-0 text-[0.75rem] text-white/45">{item.app}</span>
                </div>
                <p className="truncate text-[0.86rem] text-white/75">{item.text}</p>
              </div>
            </motion.div>
          ))}
        </AnimatePresence>
        {!shown.length && <p className="grid h-full place-items-center text-sm text-haze">Every app is off. Turn one back on.</p>}
      </div>
      <div className="flex flex-wrap justify-center gap-2" role="group" aria-label="Apps that come through">
        {["Messages", "Calendar", "Deliveries"].map((app) => {
          const on = !muted.includes(app)
          return (
            <button
              key={app}
              type="button"
              aria-pressed={on}
              onClick={() => setMuted((m) => (on ? [...m, app] : m.filter((a) => a !== app)))}
              className={cn(
                "inline-flex h-8 items-center gap-1.5 rounded-full px-3 text-[0.82rem] ring-1 transition-colors ring-inset",
                on ? "bg-[#0f1526]/80 text-teal ring-teal/40 backdrop-blur" : "bg-[#0f1526]/60 text-haze ring-white/15 backdrop-blur hover:text-mist",
              )}
            >
              {on ? <IconCheck size={14} aria-hidden="true" /> : <IconBellOff size={14} aria-hidden="true" />}
              {app}
            </button>
          )
        })}
      </div>
    </div>
  )
}

function CodeDemo() {
  const [copied, setCopied] = useState(false)
  return (
    <div className="w-full max-w-[17rem] rounded-2xl bg-[#232945]/90 p-4 ring-1 ring-white/10">
      <p className="text-[0.82rem] text-white/55">Kestrel Bank</p>
      <p className="mt-1 text-[0.9rem] text-white/85">
        Your code is{" "}
        <span className="relative inline-block font-semibold text-mist">
          482913
          <motion.span
            aria-hidden="true"
            className="absolute inset-x-[-3px] inset-y-0 -z-0 rounded bg-iris/25"
            initial={{ scaleX: 0 }}
            whileInView={{ scaleX: 1 }}
            viewport={{ once: true, amount: 1 }}
            transition={{ duration: 0.6, delay: 0.3 }}
            style={{ originX: 0 }}
          />
        </span>
      </p>
      <button
        type="button"
        onClick={() => {
          navigator.clipboard?.writeText("482913").catch(() => {})
          setCopied(true)
          setTimeout(() => setCopied(false), 1600)
        }}
        className="mt-3 flex h-9 w-full items-center justify-center gap-2 rounded-lg bg-white/10 text-[0.86rem] font-medium transition-colors hover:bg-white/15"
      >
        {copied ? <IconCheck size={15} aria-hidden="true" /> : <IconCopy size={15} aria-hidden="true" />}
        {copied ? "Copied" : "Copy code"}
      </button>
    </div>
  )
}

/* Calls: the number resolves to a contact name. */
function CallsDemo() {
  const { ref, tick } = useLoop(2600)
  const named = tick % 2 === 1
  return (
    <div ref={ref} className="flex w-full max-w-[17rem] items-center gap-3 rounded-full bg-[#232945]/90 p-2 pr-2.5 ring-1 ring-white/10">
      <span className="relative">
        <span className="absolute inset-0 animate-ping rounded-full bg-teal/25" aria-hidden="true" />
        <Avatar letter={named ? "P" : "#"} className="relative h-10 w-10 text-sm" />
      </span>
      <div className="min-w-0 flex-1">
        <AnimatePresence mode="wait" initial={false}>
          <motion.p key={String(named)} initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }} className="truncate text-[0.9rem] font-semibold">
            {named ? "Priya" : "+44 7700 900123"}
          </motion.p>
        </AnimatePresence>
        <p className="text-[0.75rem] text-white/50">{named ? "From your contacts" : "Incoming call"}</p>
      </div>
      <span className="grid h-9 w-9 place-items-center rounded-full bg-[#30d158] text-[#06210f]" aria-hidden="true">
        <IconPhone size={17} />
      </span>
    </div>
  )
}

/* Clipboard: copied on one side, there on the other; secrets stay put. */
const clips = ["Meet at Sable & Rye, 7pm", "https://example.com/tickets/4471", "••••••••••"]
function ClipboardDemo() {
  const { ref, tick } = useLoop(2400)
  const clip = clips[tick % clips.length]
  const secret = clip.startsWith("•")
  return (
    <div ref={ref} className="grid w-full max-w-[22rem] grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-2 text-[0.8rem]">
      <div className="rounded-xl bg-[#232945]/90 p-3 ring-1 ring-white/10">
        <p className="text-white/45">Mac</p>
        <AnimatePresence mode="wait">
          <motion.p key={clip} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="mt-1 truncate text-white/90">
            {clip}
          </motion.p>
        </AnimatePresence>
      </div>
      <motion.span key={tick} initial={{ x: -6, opacity: 0 }} animate={{ x: 4, opacity: 1 }} transition={{ duration: 0.6 }} className={secret ? "text-white/30" : "text-teal"} aria-hidden="true">
        →
      </motion.span>
      <div className="rounded-xl bg-[#f4f1fa] p-3 text-[#1c1b22]">
        <p className="text-black/45">Phone</p>
        <AnimatePresence mode="wait">
          <motion.p key={clip} initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.5 }} exit={{ opacity: 0 }} className={cn("mt-1 truncate", secret && "text-black/45 italic")}>
            {secret ? "Secret, not sent" : clip}
          </motion.p>
        </AnimatePresence>
      </div>
    </div>
  )
}

/* Files: a PDF crossing over, with progress. */
function FilesDemo() {
  const { ref, tick } = useLoop(2800)
  return (
    <div ref={ref} className="relative flex w-full max-w-[22rem] items-center justify-between">
      <div className="grid h-24 w-32 place-items-end rounded-xl bg-[#232945]/90 p-2 ring-1 ring-white/10">
        <span className="h-1 w-full rounded-full bg-white/10" />
      </div>
      <div className="grid h-28 w-16 place-items-center rounded-[1rem] bg-[#f4f1fa] ring-4 ring-[#101014]">
        <motion.span key={tick} initial={{ opacity: 0, scale: 0.6 }} animate={{ opacity: 1, scale: 1 }} transition={{ delay: 1.3 }} className="text-[#d6453d]">
          <IconFileTypePdf size={26} stroke={1.5} aria-hidden="true" />
        </motion.span>
      </div>
      <motion.span
        key={`f${tick}`}
        className="absolute top-6 left-12 text-[#ff7a70]"
        initial={{ x: 0, y: 0, opacity: 1 }}
        animate={{ x: [0, 90, 205], y: [0, -26, 4], opacity: [1, 1, 0] }}
        transition={{ duration: 1.3, ease: "easeInOut" }}
        aria-hidden="true"
      >
        <IconFileTypePdf size={34} stroke={1.5} />
      </motion.span>
      <p className="absolute -bottom-1 left-0 text-[0.72rem] text-haze">Boarding pass.pdf</p>
    </div>
  )
}

/* Screenshots: taken on the phone, on the Mac a moment later. */
function ScreenshotsDemo() {
  const { ref, tick } = useLoop(3000)
  return (
    <div ref={ref} className="relative flex w-full max-w-[22rem] items-center justify-center gap-6">
      <div className="relative h-32 w-[4.5rem] overflow-hidden rounded-[1rem] ring-4 ring-[#101014]">
        <Photo kind={(["cliffs", "ferry", "dumplings"] as const)[tick % 3]} className="h-full w-full" />
        <motion.span key={tick} className="absolute inset-0 bg-white" initial={{ opacity: 0.9 }} animate={{ opacity: 0 }} transition={{ duration: 0.5 }} aria-hidden="true" />
      </div>
      <div className="relative h-24 w-36 rounded-xl bg-[#232945]/90 ring-1 ring-white/10">
        <motion.div
          key={tick}
          className="absolute right-2 bottom-2 h-12 w-7 overflow-hidden rounded-md ring-2 ring-white/80"
          initial={{ opacity: 0, x: -90, scale: 1.5 }}
          animate={{ opacity: 1, x: 0, scale: 1 }}
          transition={{ delay: 0.5, type: "spring", stiffness: 200, damping: 22 }}
        >
          <Photo kind={(["cliffs", "ferry", "dumplings"] as const)[tick % 3]} className="h-full w-full" />
        </motion.div>
        <p className="absolute top-2 left-2.5 text-[0.7rem] text-white/45">Desktop</p>
      </div>
    </div>
  )
}

const tracks = [
  { title: "Northern Lights", artist: "Lumen Park", art: "from-[#5b4fd6] to-[#6fe3c1]" },
  { title: "Paper Boats", artist: "The Quiet Hours", art: "from-[#f2a07b] to-[#e2729a]" },
  { title: "Slow Tide", artist: "Mira Vale", art: "from-[#2b3f8f] to-[#8fb8ff]" },
]
function MusicDemo() {
  const [i, setI] = useState(0)
  const [playing, setPlaying] = useState(true)
  const reduce = useReducedMotion()
  const t = tracks[i]
  return (
    <div className="flex w-full max-w-[17rem] items-center gap-3 rounded-2xl bg-[#232945]/90 p-3 ring-1 ring-white/10">
      <motion.span key={t.title} initial={{ rotate: -8, scale: 0.9 }} animate={{ rotate: 0, scale: 1 }} className={cn("h-14 w-14 shrink-0 rounded-lg bg-gradient-to-br", t.art)} aria-hidden="true" />
      <div className="min-w-0 flex-1">
        <p className="truncate text-[0.9rem] font-semibold">{t.title}</p>
        <p className="truncate text-[0.78rem] text-white/55">{t.artist}</p>
        <div className="mt-2 h-1 overflow-hidden rounded-full bg-white/10">
          <motion.span
            key={`${t.title}${playing}`}
            className="block h-full origin-left rounded-full bg-mist"
            initial={{ scaleX: playing ? 0.15 : 0.4 }}
            animate={{ scaleX: playing && !reduce ? 1 : 0.4 }}
            transition={{ duration: playing ? 14 : 0, ease: "linear" }}
          />
        </div>
      </div>
      <div className="flex gap-1">
        <button type="button" onClick={() => setPlaying((p) => !p)} aria-label={playing ? "Pause" : "Play"} className="grid h-8 w-8 place-items-center rounded-full hover:bg-white/10">
          {playing ? <IconPlayerPauseFilled size={16} /> : <IconPlayerPlayFilled size={16} />}
        </button>
        <button type="button" onClick={() => setI((n) => (n + 1) % tracks.length)} aria-label="Next track" className="grid h-8 w-8 place-items-center rounded-full hover:bg-white/10">
          <IconPlayerSkipForwardFilled size={15} />
        </button>
      </div>
    </div>
  )
}

function Switch({ on, label, onClick }: { on: boolean; label: string; onClick: () => void }) {
  return (
    <button type="button" role="switch" aria-checked={on} onClick={onClick} className="flex w-full items-center justify-between gap-3 rounded-xl bg-[#232945]/90 px-3.5 py-2.5 text-[0.86rem] ring-1 ring-white/10">
      <span className="flex items-center gap-2">
        <IconMoon size={16} className={on ? "text-iris" : "text-white/40"} aria-hidden="true" />
        {label}
      </span>
      <span className={cn("flex h-6 w-10 items-center rounded-full p-0.5 transition-colors", on ? "bg-iris" : "bg-white/15")}>
        <motion.span layout transition={{ type: "spring", stiffness: 500, damping: 32 }} className={cn("h-5 w-5 rounded-full bg-white", on && "ml-auto")} />
      </span>
    </button>
  )
}
function FocusDemo() {
  const [on, setOn] = useState(false)
  return (
    <div className="flex w-full max-w-[16rem] flex-col gap-2">
      <Switch on={on} label="Focus on the Mac" onClick={() => setOn((v) => !v)} />
      <Switch on={on} label="Do Not Disturb on the phone" onClick={() => setOn((v) => !v)} />
    </div>
  )
}

function FindDemo() {
  const [ringing, setRinging] = useState(false)
  useEffect(() => {
    if (!ringing) return
    const t = setTimeout(() => setRinging(false), 3200)
    return () => clearTimeout(t)
  }, [ringing])
  return (
    <div className="flex flex-col items-center gap-4">
      <div className="relative grid h-20 w-20 place-items-center">
        {ringing &&
          [0, 0.4, 0.8].map((d) => (
            <motion.span key={d} className="absolute inset-0 rounded-full ring-2 ring-teal/50" initial={{ scale: 0.6, opacity: 0.9 }} animate={{ scale: 1.6, opacity: 0 }} transition={{ duration: 1.2, delay: d, repeat: Infinity }} aria-hidden="true" />
          ))}
        <motion.span animate={ringing ? { rotate: [0, -12, 12, -12, 12, 0] } : { rotate: 0 }} transition={{ duration: 0.5, repeat: ringing ? Infinity : 0, repeatDelay: 0.3 }}>
          <IconDeviceMobile size={44} stroke={1.4} className="text-mist" aria-hidden="true" />
        </motion.span>
      </div>
      <button type="button" onClick={() => setRinging((r) => !r)} className="h-9 rounded-full bg-white/10 px-4 text-[0.86rem] font-medium hover:bg-white/15" aria-live="polite">
        {ringing ? "Ringing at full volume" : "Ring my phone"}
      </button>
    </div>
  )
}

function StatusDemo() {
  return (
    <div className="w-full max-w-[17rem]">
      <div className="flex h-7 items-center justify-end gap-3 rounded-t-lg bg-white/[0.06] px-3 text-[0.72rem] text-white/80">
        <span className="flex items-center gap-1 rounded bg-white/15 px-1.5 py-0.5">
          <IconDeviceMobile size={12} aria-hidden="true" /> 82%
        </span>
        <IconWifi size={13} aria-hidden="true" />
        <span>Tue 10:24</span>
      </div>
      <div className="ml-auto w-[13.5rem] rounded-b-xl rounded-tl-xl bg-[#232945]/95 p-3 text-[0.82rem] ring-1 ring-white/10">
        <p className="font-semibold">Asha's phone</p>
        <ul className="mt-2 space-y-1.5 text-white/75">
          <li className="flex items-center gap-2"><IconBattery3 size={15} className="text-teal" aria-hidden="true" />82%, charging <IconBolt size={12} className="text-teal" aria-hidden="true" /></li>
          <li className="flex items-center gap-2"><IconAntennaBars4 size={15} aria-hidden="true" />Strong signal, 5G</li>
          <li className="flex items-center gap-2"><IconWifi size={15} aria-hidden="true" />On Home Wi-Fi</li>
        </ul>
      </div>
    </div>
  )
}

/* Auto-lock: drag the phone away from the Mac. */
function LockDemo() {
  const [d, setD] = useState(20)
  const locked = d > 70
  return (
    <div className="w-full max-w-[17rem]">
      <div className="flex items-center justify-between text-mist">
        <span className={cn("grid h-12 w-12 place-items-center rounded-xl ring-1 transition-colors", locked ? "bg-iris/15 ring-iris/40 text-iris" : "bg-white/5 ring-white/10")}>
          {locked ? <IconLock size={22} aria-hidden="true" /> : <IconLockOpen size={22} aria-hidden="true" />}
        </span>
        <span className="text-[0.8rem] text-haze" aria-live="polite">{locked ? "Mac locked" : "Phone nearby"}</span>
      </div>
      <label className="mt-4 block text-[0.78rem] text-haze" htmlFor="lock-distance">
        Walk away with your phone
      </label>
      <input id="lock-distance" type="range" min={0} max={100} value={d} onChange={(e) => setD(Number(e.target.value))} className="mt-2 w-full accent-[#a99bff]" />
    </div>
  )
}

/* Trackpad: move on the phone, the pointer moves on the Mac. */
function TrackpadDemo() {
  const [p, setP] = useState({ x: 50, y: 50 })
  const pad = useRef<HTMLDivElement>(null)
  const move = (e: React.PointerEvent) => {
    const r = pad.current!.getBoundingClientRect()
    setP({ x: Math.min(100, Math.max(0, ((e.clientX - r.left) / r.width) * 100)), y: Math.min(100, Math.max(0, ((e.clientY - r.top) / r.height) * 100)) })
  }
  return (
    <div className="flex w-full max-w-[18rem] items-center gap-4">
      <div className="relative h-24 flex-1 overflow-hidden rounded-xl bg-[#232945]/90 ring-1 ring-white/10" aria-hidden="true">
        <svg viewBox="0 0 24 24" className="absolute h-4 w-4 -translate-x-[2px] -translate-y-[2px] text-white drop-shadow transition-[left,top] duration-75" style={{ left: `${p.x}%`, top: `${p.y}%` }} fill="currentColor">
          <path d="M5 3l14 8-6 1.5L10 19z" stroke="#000" strokeWidth="1" />
        </svg>
      </div>
      <div
        ref={pad}
        onPointerMove={move}
        className="h-28 w-16 touch-none rounded-[1rem] bg-[#f4f1fa] ring-4 ring-[#101014]"
        role="img"
        aria-label="Phone used as a trackpad. Move over it to move the Mac's pointer."
      >
        <p className="px-1.5 pt-10 text-center text-[0.6rem] leading-tight text-black/45">Move here</p>
      </div>
    </div>
  )
}

export function Features() {
  return (
    <section id="features" aria-labelledby="features-h" className="relative py-24 lg:py-36">
      <div className="wrap">
        <div className="grid items-end gap-6 lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)]">
          <h2 id="features-h" className="display text-[clamp(2.2rem,5vw,4rem)]">
            Everything your phone does, on the Mac you're already using.
          </h2>
          <p className="max-w-[30rem] text-lg text-haze lg:justify-self-end">
            Every feature here is built and in testing. None of them needs developer settings on the phone, except Full mode. Go ahead and try the tiles.
          </p>
        </div>

        <ul className="mt-16 grid gap-4 md:grid-cols-2 lg:grid-cols-6 lg:grid-rows-[auto]">
          <Tile desktop className="md:col-span-2 lg:col-span-4 lg:row-span-2" title="Notifications with actions" text="Real Mac notifications, with their buttons and inline reply. Choose which apps come through, and dismiss on either device to clear both.">
            <NotificationsDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="One-time codes" text="Copy code, straight from the notification. It never reads your SMS.">
            <CodeDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="Calls and caller ID" text="Answer, decline or mute from the Mac; audio stays on the phone. Names come from contacts kept encrypted on the Mac.">
            <CallsDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="Shared clipboard" text="Copy on one, paste on the other. Text a password manager marks as secret is never sent.">
            <ClipboardDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="Files both ways" text="Drag onto the Phone window, use the Share menu, or Send to Mac. Browse the phone's files and recent photos from the Mac.">
            <FilesDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="Instant screenshots" text="Take one on the phone and it lands on the Desktop, in Downloads or on the clipboard.">
            <ScreenshotsDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="Music controller" text="Track, artist and artwork, with play, pause, skip and volume.">
            <MusicDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="Focus, in sync" text="A Focus on the Mac turns on Do Not Disturb on the phone, and the other way round.">
            <FocusDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="Find my phone" text="Ring it at full volume from the Mac, even when it's on silent.">
            <FindDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="Phone status in the menu bar" text="Battery and charging, signal, Wi-Fi or mobile data, and whether it's connected.">
            <StatusDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="Auto-lock when you walk away" text="Opt-in. The Mac locks when the phone's Bluetooth signal stays away. It never unlocks it.">
            <LockDemo />
          </Tile>
          <Tile className="lg:col-span-2" title="Trackpad and remote" text="Move the Mac's pointer from the phone, or change slides with a laser dot.">
            <TrackpadDemo />
          </Tile>
        </ul>
      </div>
    </section>
  )
}
