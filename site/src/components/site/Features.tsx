// Every feature as a tile with a small working demo of it. Demos that loop only run while
// the tile is on screen, and not at all when the visitor asks for reduced motion.
import { useEffect, useRef, useState, type ReactNode } from "react"
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react"
import {
  IconBattery3,
  IconDeviceMobile,
  IconLock,
  IconLockOpen,
  IconMoon,
  IconPlayerPauseFilled,
  IconPlayerPlayFilled,
  IconPlayerSkipForwardFilled,
  IconWifi,
  IconAntennaBars4,
  IconFileTypePdf,
  IconBolt,
} from "@tabler/icons-react"
import { GlowingEffect } from "@/components/ui/glowing-effect"
import { cn } from "@/lib/utils"
import { Photo, Wallpaper } from "./parts"
import { SectionHead, sectionPad } from "./Section"

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



/* Clipboard: copied on one side, there on the other; secrets stay put. */
const clips = ["Meet at Sable & Rye, 7pm", "https://example.com/tickets/4471", "••••••••••"]
function ClipboardDemo() {
  const { ref, tick } = useLoop(2400)
  const clip = clips[tick % clips.length]
  const secret = clip.startsWith("•")
  return (
    <div ref={ref} className="relative grid w-full max-w-[22rem] grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-2 text-[0.8rem]">
      <motion.span
        key={`chip${tick}`}
        aria-hidden="true"
        className={cn("absolute top-1/2 z-10 -translate-x-1/2 -translate-y-1/2 rounded-full px-2 py-0.5 text-[0.68rem] font-semibold whitespace-nowrap", secret ? "bg-[#3a3a3a] text-mist" : "bg-lime text-night")}
        initial={{ left: "22%", y: 0, opacity: 0, scale: 0.8 }}
        animate={secret ? { left: ["22%", "50%"], y: [0, -34], opacity: [0, 1, 0], scale: [0.8, 1, 0.8] } : { left: ["22%", "50%", "78%"], y: [0, -38, 0], opacity: [0, 1, 1, 0], scale: [0.8, 1.05, 0.8] }}
        transition={{ duration: 1, ease: "easeInOut" }}
      >
        {secret ? "Not sent" : "Copied"}
      </motion.span>
      <div className="rounded-xl bg-[#1c1c1c]/90 p-3 ring-1 ring-white/10">
        <p className="text-white/45">Mac</p>
        <AnimatePresence mode="wait">
          <motion.p key={clip} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="mt-1 truncate text-white/90">
            {clip}
          </motion.p>
        </AnimatePresence>
      </div>
      <span className="w-6" aria-hidden="true" />
      <div className="rounded-xl bg-[#f2f2f2] p-3 text-[#1c1b22]">
        <p className="text-black/45">Phone</p>
        <AnimatePresence mode="wait">
          <motion.p key={clip} initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.9 }} exit={{ opacity: 0 }} className={cn("mt-1 truncate", secret && "text-black/45 italic")}>
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
      <div className="grid h-24 w-32 place-items-end rounded-xl bg-[#1c1c1c]/90 p-2 ring-1 ring-white/10">
        <span className="h-1 w-full rounded-full bg-white/10" />
      </div>
      <div className="grid h-28 w-16 place-items-center rounded-[1rem] bg-[#f2f2f2] ring-4 ring-[#101014]">
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
      <div className="relative h-24 w-36 rounded-xl bg-[#1c1c1c]/90 ring-1 ring-white/10">
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
  { title: "Northern Lights", artist: "Lumen Park", art: "bg-lime" },
  { title: "Paper Boats", artist: "The Quiet Hours", art: "bg-pink" },
  { title: "Slow Tide", artist: "Mira Vale", art: "bg-[#f2f2f2]" },
]
function MusicDemo() {
  const [i, setI] = useState(0)
  const [playing, setPlaying] = useState(true)
  const reduce = useReducedMotion()
  const t = tracks[i]
  return (
    <div className="flex w-full max-w-[17rem] items-center gap-3 rounded-2xl bg-[#1c1c1c]/90 p-3 ring-1 ring-white/10">
      <motion.span key={t.title} initial={{ rotate: -8, scale: 0.9 }} animate={{ rotate: 0, scale: 1 }} className={cn("h-14 w-14 shrink-0 rounded-lg", t.art)} aria-hidden="true" />
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
    <button type="button" role="switch" aria-checked={on} onClick={onClick} className="flex w-full items-center justify-between gap-3 rounded-xl bg-[#1c1c1c]/90 px-3.5 py-2.5 text-[0.86rem] ring-1 ring-white/10">
      <span className="flex items-center gap-2">
        <IconMoon size={16} className={on ? "text-pink" : "text-white/40"} aria-hidden="true" />
        {label}
      </span>
      <span className={cn("flex h-6 w-10 items-center rounded-full p-0.5 transition-colors", on ? "bg-pink" : "bg-white/15")}>
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
            <motion.span key={d} className="absolute inset-0 rounded-full ring-2 ring-lime/50" initial={{ scale: 0.6, opacity: 0.9 }} animate={{ scale: 1.6, opacity: 0 }} transition={{ duration: 1.2, delay: d, repeat: Infinity }} aria-hidden="true" />
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
      <div className="ml-auto w-[13.5rem] rounded-b-xl rounded-tl-xl bg-[#1c1c1c]/95 p-3 text-[0.82rem] ring-1 ring-white/10">
        <p className="font-semibold">Asha's phone</p>
        <ul className="mt-2 space-y-1.5 text-white/75">
          <li className="flex items-center gap-2"><IconBattery3 size={15} className="text-lime" aria-hidden="true" />82%, charging <IconBolt size={12} className="text-lime" aria-hidden="true" /></li>
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
        <span className={cn("grid h-12 w-12 place-items-center rounded-xl ring-1 transition-colors", locked ? "bg-pink/15 ring-pink/40 text-pink" : "bg-white/5 ring-white/10")}>
          {locked ? <IconLock size={22} aria-hidden="true" /> : <IconLockOpen size={22} aria-hidden="true" />}
        </span>
        <span className="text-[0.8rem] text-haze" aria-live="polite">{locked ? "Mac locked" : "Phone nearby"}</span>
      </div>
      <label className="mt-4 block text-[0.78rem] text-haze" htmlFor="lock-distance">
        Walk away with your phone
      </label>
      <input id="lock-distance" type="range" min={0} max={100} value={d} onChange={(e) => setD(Number(e.target.value))} className="mt-2 w-full accent-[#ff2dab]" />
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
      <div className="relative h-24 flex-1 overflow-hidden rounded-xl bg-[#1c1c1c]/90 ring-1 ring-white/10" aria-hidden="true">
        <svg viewBox="0 0 24 24" className="absolute h-4 w-4 -translate-x-[2px] -translate-y-[2px] text-white drop-shadow transition-[left,top] duration-75" style={{ left: `${p.x}%`, top: `${p.y}%` }} fill="currentColor">
          <path d="M5 3l14 8-6 1.5L10 19z" stroke="#000" strokeWidth="1" />
        </svg>
      </div>
      <div
        ref={pad}
        onPointerMove={move}
        className="h-28 w-16 touch-none rounded-[1rem] bg-[#f2f2f2] ring-4 ring-[#101014]"
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
    <section id="features" aria-labelledby="features-h" className={`relative border-t border-line ${sectionPad}`}>
      <div className="wrap">
        <SectionHead id="features-h" title={<>And everything else your phone does, on the Mac.</>} lede={<>Notifications, codes, calls, photos and Full mode are in the day above. These are the rest, all built and in testing. Try them.</>} />

        <ul className="mt-16 grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          <Tile title="Shared clipboard" text="Copy on one, paste on the other. Text a password manager marks as secret is never sent.">
            <ClipboardDemo />
          </Tile>
          <Tile title="Files both ways" text="Drag onto the Phone window, or Send to Mac from the phone’s share sheet. Browse the phone's files and recent photos from the Mac.">
            <FilesDemo />
          </Tile>
          <Tile title="Instant screenshots" text="Take one on the phone and it lands on the Desktop, in Downloads or on the clipboard.">
            <ScreenshotsDemo />
          </Tile>
          <Tile title="Music controller" text="Track, artist and artwork, with play, pause, skip and volume.">
            <MusicDemo />
          </Tile>
          <Tile title="Focus, in sync" text="A Focus on the Mac turns on Do Not Disturb on the phone, and the other way round.">
            <FocusDemo />
          </Tile>
          <Tile title="Find my phone" text="Ring it at full volume from the Mac, even when it's on silent.">
            <FindDemo />
          </Tile>
          <Tile title="Phone status in the menu bar" text="Battery and charging, signal, Wi-Fi or mobile data, and whether it's connected.">
            <StatusDemo />
          </Tile>
          <Tile title="Auto-lock when you walk away" text="Opt-in. The Mac locks when the phone's Bluetooth signal stays away. It never unlocks it.">
            <LockDemo />
          </Tile>
          <Tile title="Trackpad and remote" text="Move the Mac's pointer from the phone, or change slides with a laser dot.">
            <TrackpadDemo />
          </Tile>
        </ul>
      </div>
    </section>
  )
}
