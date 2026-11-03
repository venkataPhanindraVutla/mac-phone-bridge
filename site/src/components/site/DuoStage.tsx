// The day story's stage: a MacBook with an Android phone resting in front of it. Each moment
// plays by itself once it scrolls into view, with whatever crosses over travelling along a lit
// beam between the two. The visitor can step in at any point: type, answer, drag, press.
import { useEffect, useRef, useState, type ReactNode, type RefObject } from "react"
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react"
import { IconCheck, IconCopy, IconMicrophone, IconPhone, IconPhoneOff, IconRefresh, IconSend2, IconVolume } from "@tabler/icons-react"
import { cn } from "@/lib/utils"
import { AndroidPhone, MacBook } from "./devices"
import { Avatar, Photo, TrafficLights, Wallpaper } from "./parts"

export type Scene = "message" | "code" | "call" | "photos" | "full"
type Point = { x: number; y: number }
type Kind = "ferry" | "dumplings" | "cliffs"
type Flight = { id: number; path: Point[]; body: ReactNode; done: () => void }
type Drag = { kind: Kind; p: Point; over: boolean } | null

const lime = "#d4ff3f"
const times: Record<Scene, string> = { message: "9:02", code: "9:40", call: "11:15", photos: "14:30", full: "16:00" }

export function DuoStage({ scene }: { scene: Scene }) {
  const [run, setRun] = useState(0)
  return (
    <div>
      <Run key={`${scene}-${run}`} scene={scene} />
      <div className="mt-4 flex justify-end">
        <button type="button" onClick={() => setRun((r) => r + 1)} className="inline-flex h-9 items-center gap-1.5 rounded-full px-3.5 text-[0.85rem] text-haze ring-1 ring-line transition-colors ring-inset hover:text-mist">
          <IconRefresh size={15} aria-hidden="true" /> Play again
        </button>
      </div>
    </div>
  )
}

function Run({ scene }: { scene: Scene }) {
  const reduce = useReducedMotion()
  const stage = useRef<HTMLDivElement>(null)
  const inView = useInView(stage, { amount: 0.55, once: true })
  const [flights, setFlights] = useState<Flight[]>([])
  const [beam, setBeam] = useState<{ d: string; key: number; stream?: boolean } | null>(null)
  const [buzz, setBuzz] = useState(0)
  const [drag, setDrag] = useState<Drag>(null)
  const [pulse, setPulse] = useState<Record<string, number>>({})
  const ids = useRef(0)
  const took = useRef(false) // the visitor has stepped in; autoplay stops typing for them
  const timers = useRef<number[]>([])
  const alive = useRef(true)

  // Shared state the scenes draw from.
  const [s, setS] = useState({
    phoneNotif: false,
    macBanner: false,
    draft: "",
    sent: "",
    copied: false,
    filled: 0,
    call: "none" as "none" | "ringing" | "live",
    secs: 0,
    muted: false,
    sending: false,
    received: [] as Kind[],
    typing: "",
    mirror: [] as string[],
  })
  const set = (patch: Partial<typeof s>) => alive.current && setS((v) => ({ ...v, ...patch }))

  const refs = {
    phone: useRef<HTMLDivElement>(null),
    mac: useRef<HTMLDivElement>(null),
    phoneNotif: useRef<HTMLDivElement>(null),
    macBanner: useRef<HTMLDivElement>(null),
    replySend: useRef<HTMLButtonElement>(null),
    phoneChatEnd: useRef<HTMLDivElement>(null),
    finder: useRef<HTMLDivElement>(null),
    mirror: useRef<HTMLDivElement>(null),
    thumbs: useRef<Partial<Record<Kind, HTMLDivElement | null>>>({}),
  }

  const wait = (ms: number) => new Promise<void>((r) => timers.current.push(window.setTimeout(r, reduce ? Math.min(ms, 50) : ms)))
  const bump = (k: string) => setPulse((p) => ({ ...p, [k]: (p[k] ?? 0) + 1 }))

  const at = (el: Element | null | undefined): Point => {
    const st = stage.current!.getBoundingClientRect()
    const r = el!.getBoundingClientRect()
    return { x: r.left - st.left + r.width / 2, y: r.top - st.top + r.height / 2 }
  }
  const curve = (a: Point, b: Point) => {
    const lift = Math.min(140, Math.hypot(b.x - a.x, b.y - a.y) * 0.35 + 30)
    return { x: (a.x + b.x) / 2, y: Math.min(a.y, b.y) - lift }
  }
  const sample = (a: Point, m: Point, b: Point) =>
    [0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1].map((t) => ({
      x: (1 - t) ** 2 * a.x + 2 * (1 - t) * t * m.x + t ** 2 * b.x,
      y: (1 - t) ** 2 * a.y + 2 * (1 - t) * t * m.y + t ** 2 * b.y,
    }))

  /** Sends `body` from one element to another along a lit beam; resolves when it lands. */
  const fly = (from: Element | null | undefined, to: Element | null | undefined, body: ReactNode, start?: Point) =>
    new Promise<void>((resolve) => {
      if (!alive.current || !stage.current || !from || !to) return resolve()
      const a = start ?? at(from)
      const b = at(to)
      const m = curve(a, b)
      if (reduce) return resolve()
      const id = ids.current++
      setBeam({ d: `M ${a.x} ${a.y} Q ${m.x} ${m.y} ${b.x} ${b.y}`, key: id })
      setFlights((f) => [...f, { id, path: sample(a, m, b), body, done: resolve }])
    })
  const land = (f: Flight) => {
    setFlights((all) => all.filter((x) => x.id !== f.id))
    setBeam((bm) => (bm && bm.key === f.id && !bm.stream ? null : bm))
    f.done()
  }

  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
      timers.current.forEach(clearTimeout)
    }
  }, [])

  // Call timer.
  useEffect(() => {
    if (s.call !== "live") return
    const t = setInterval(() => setS((v) => ({ ...v, secs: v.secs + 1 })), 1000)
    return () => clearInterval(t)
  }, [s.call])

  const typeInto = async (text: string, key: "draft" | "typing") => {
    for (let i = 1; i <= text.length; i++) {
      if (!alive.current || took.current) return false
      set({ [key]: text.slice(0, i) } as Partial<typeof s>)
      await wait(55)
    }
    return true
  }

  const sendReply = async (text: string) => {
    if (!text.trim()) return
    set({ draft: "", sending: true })
    await fly(refs.replySend.current, refs.phoneChatEnd.current, <Chip>{text}</Chip>)
    set({ sent: text, sending: false })
    bump("phone")
  }

  const sendMirror = async (text: string) => {
    if (!text.trim()) return
    set({ typing: "" })
    setS((v) => ({ ...v, mirror: [...v.mirror, text].slice(-2) }))
  }

  const copyCode = async (user: boolean) => {
    if (user) navigator.clipboard?.writeText("482913").catch(() => {})
    set({ copied: true })
    for (let i = 1; i <= 6; i++) {
      await wait(90)
      set({ filled: i })
    }
  }

  const sendPhotos = async () => {
    set({ sending: true })
    for (const k of ["ferry", "dumplings", "cliffs"] as Kind[]) {
      if (!alive.current) return
      await fly(refs.thumbs.current[k], refs.finder.current, <Photo kind={k} className="h-[4em] w-[4em] rounded-[0.5em] ring-2 ring-white" />)
      setS((v) => ({ ...v, received: v.received.includes(k) ? v.received : [...v.received, k] }))
      bump("finder")
      await wait(120)
    }
    set({ sending: false })
  }

  // The choreography for each moment.
  useEffect(() => {
    if (!inView) return
    let cancelled = false
    const go = async () => {
      await wait(400)
      if (scene === "message") {
        set({ phoneNotif: true })
        setBuzz((b) => b + 1)
        await wait(900)
        await fly(refs.phoneNotif.current, refs.macBanner.current, <NoteChip who="Priya" text="Running a bit late, start without me?" />)
        set({ macBanner: true })
        bump("banner")
        await wait(900)
        if (cancelled || took.current) return
        if (await typeInto("No rush, I'll order for you", "draft")) {
          await wait(350)
          if (!took.current) await sendReply("No rush, I'll order for you")
        }
      }
      if (scene === "code") {
        set({ phoneNotif: true })
        setBuzz((b) => b + 1)
        await wait(900)
        await fly(refs.phoneNotif.current, refs.macBanner.current, <NoteChip who="Kestrel Bank" text="Your sign-in code is 482913" />)
        set({ macBanner: true })
        bump("banner")
        await wait(1100)
        if (!cancelled && !took.current) await copyCode(false)
      }
      if (scene === "call") {
        set({ call: "ringing" })
        setBuzz((b) => b + 1)
        await fly(refs.phone.current, refs.macBanner.current, <span className="grid h-[2.4em] w-[2.4em] place-items-center rounded-full bg-[#30d158] text-[#06210f]"><IconPhone size={16} /></span>)
        bump("banner")
        setBuzz((b) => b + 1)
        await wait(1600)
        if (!cancelled && !took.current) set({ call: "live" })
      }
      if (scene === "photos") {
        await wait(700)
        if (!cancelled && !took.current) await sendPhotos()
      }
      if (scene === "full") {
        if (!reduce && refs.phone.current && refs.mirror.current) {
          const a = at(refs.phone.current)
          const b = at(refs.mirror.current)
          const m = curve(a, b)
          setBeam({ d: `M ${a.x} ${a.y} Q ${m.x} ${m.y} ${b.x} ${b.y}`, key: -1, stream: true })
        }
        await wait(900)
        if (!cancelled && !took.current && (await typeInto("Ordering now 🥟", "typing"))) {
          await wait(300)
          if (!took.current) await sendMirror("Ordering now 🥟")
        }
      }
    }
    go()
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [inView, scene])

  const clock = `${Math.floor(s.secs / 60)}:${String(s.secs % 60).padStart(2, "0")}`

  return (
    <div
      ref={stage}
      className="relative isolate w-full select-none [container-type:inline-size]"
      style={{ fontSize: "clamp(7px, 1.72cqw, 13px)" }}
    >
      <div className="relative pt-[2%] pr-[5%] pb-[5%] pl-[16%]">
        <MacBook ref={refs.mac}>
          <MacScreen scene={scene} s={s} set={set} refs={refs} pulse={pulse} took={took} sendReply={sendReply} sendMirror={sendMirror} copyCode={copyCode} clock={clock} />
        </MacBook>
        <div className="absolute bottom-0 left-0 z-20 w-[25%]">
          <AndroidPhone ref={refs.phone} buzz={buzz}>
            <PhoneScreen scene={scene} s={s} set={set} refs={refs} pulse={pulse} took={took} sendPhotos={sendPhotos} clock={clock} stage={stage} fly={fly} setS={setS} bump={bump} drag={drag} setDrag={setDrag} />
          </AndroidPhone>
        </div>
      </div>

      {/* The beam, and whatever is crossing it */}
      <svg className="pointer-events-none absolute inset-0 z-30 h-full w-full overflow-visible" aria-hidden="true">
        <AnimatePresence>
          {beam && (
            <motion.g key={beam.key} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.25 }}>
              <path d={beam.d} fill="none" stroke={lime} strokeOpacity="0.18" strokeWidth="9" strokeLinecap="round" />
              <motion.path
                d={beam.d}
                fill="none"
                stroke={lime}
                strokeWidth="2"
                strokeLinecap="round"
                strokeDasharray="2 10"
                initial={{ strokeDashoffset: 0 }}
                animate={{ strokeDashoffset: -120 }}
                transition={{ duration: 1.4, repeat: Infinity, ease: "linear" }}
              />
            </motion.g>
          )}
        </AnimatePresence>
      </svg>
      <div className="pointer-events-none absolute inset-0 z-40" aria-hidden="true">
        {flights.map((f) => (
          <motion.div
            key={f.id}
            className="absolute top-0 left-0"
            initial={{ x: f.path[0].x, y: f.path[0].y, scale: 0.85, opacity: 0 }}
            animate={{ x: f.path.map((p) => p.x), y: f.path.map((p) => p.y), scale: [0.85, 1, 1.06, 1.06, 1, 0.95, 0.9, 0.85], opacity: [0, 1, 1, 1, 1, 1, 1, 0.9] }}
            transition={{ duration: 1.05, ease: [0.4, 0, 0.2, 1] }}
            onAnimationComplete={() => land(f)}
          >
            <div className="-translate-x-1/2 -translate-y-1/2 drop-shadow-[0_0.8em_1.2em_rgba(0,0,0,0.6)]">{f.body}</div>
          </motion.div>
        ))}
        {drag && (
          <div className="absolute top-0 left-0" style={{ transform: `translate(${drag.p.x}px, ${drag.p.y}px)` }}>
            <div className="-translate-x-1/2 -translate-y-1/2 -rotate-6 drop-shadow-[0_0.8em_1.2em_rgba(0,0,0,0.6)]">
              <Photo kind={drag.kind} className={cn("h-[5em] w-[5em] rounded-[0.6em] ring-2", drag.over ? "ring-lime" : "ring-white")} />
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ pieces */

function Chip({ children }: { children: ReactNode }) {
  return <span className="block rounded-[1em] rounded-br-[0.3em] bg-pink px-[0.9em] py-[0.5em] text-[1.05em] font-medium whitespace-nowrap text-night">{children}</span>
}

function NoteChip({ who, text }: { who: string; text: string }) {
  return (
    <div className="flex w-[17em] items-center gap-[0.6em] rounded-[0.9em] bg-white p-[0.6em] text-night">
      <Avatar letter={who[0]} className="h-[2em] w-[2em] text-[0.85em]" />
      <div className="min-w-0 leading-tight">
        <p className="text-[0.9em] font-semibold">{who}</p>
        <p className="truncate text-[0.85em] text-black/65">{text}</p>
      </div>
    </div>
  )
}

function Pulse({ k, pulse, children, className }: { k: string; pulse: Record<string, number>; children: ReactNode; className?: string }) {
  return (
    <motion.div key={pulse[k] ?? 0} initial={false} animate={pulse[k] ? { scale: [1, 1.035, 1] } : undefined} transition={{ duration: 0.35 }} className={className}>
      {children}
    </motion.div>
  )
}

type StageState = {
  phoneNotif: boolean
  macBanner: boolean
  draft: string
  sent: string
  copied: boolean
  filled: number
  call: "none" | "ringing" | "live"
  secs: number
  muted: boolean
  sending: boolean
  received: Kind[]
  typing: string
  mirror: string[]
}
type Refs = {
  phone: RefObject<HTMLDivElement | null>
  mac: RefObject<HTMLDivElement | null>
  phoneNotif: RefObject<HTMLDivElement | null>
  macBanner: RefObject<HTMLDivElement | null>
  replySend: RefObject<HTMLButtonElement | null>
  phoneChatEnd: RefObject<HTMLDivElement | null>
  finder: RefObject<HTMLDivElement | null>
  mirror: RefObject<HTMLDivElement | null>
  thumbs: RefObject<Partial<Record<Kind, HTMLDivElement | null>>>
}

function MacScreen({
  scene,
  s,
  set,
  refs,
  pulse,
  took,
  sendReply,
  sendMirror,
  copyCode,
  clock,
}: {
  scene: Scene
  s: StageState
  set: (p: Partial<StageState>) => void
  refs: Refs
  pulse: Record<string, number>
  took: RefObject<boolean>
  sendReply: (t: string) => void
  sendMirror: (t: string) => void
  copyCode: (user: boolean) => void
  clock: string
}) {
  return (
    <div className="absolute inset-0 text-white">
      <Wallpaper />
      <div className="relative z-10 flex h-[1.9em] items-center justify-between bg-black/45 px-[1em] text-[0.85em] font-medium whitespace-nowrap backdrop-blur-md">
        <span className="flex gap-[1.1em]">
          <span className="font-semibold">Finder</span>
          <span>File</span>
          <span>Edit</span>
          <span>View</span>
        </span>
        <span className="flex items-center gap-[1em]">
          <span className="rounded-[0.3em] bg-white/15 px-[0.5em] py-[0.1em]">Asha's phone 82%</span>
          <span>Tue {times[scene]}</span>
        </span>
      </div>

      {/* Banner slot, top right: notifications and calls land here */}
      <div ref={refs.macBanner} className="absolute top-[9%] right-[2.5%] z-20 w-[36%]">
        <Pulse k="banner" pulse={pulse}>
          <AnimatePresence>
            {(scene === "message" || scene === "code") && s.macBanner && (
              <motion.div initial={{ opacity: 0, x: 24 }} animate={{ opacity: 1, x: 0 }} className="rounded-[0.9em] bg-[#1c1c1c]/90 p-[0.8em] ring-1 ring-white/15 backdrop-blur-xl">
                <div className="flex gap-[0.6em]">
                  <Avatar letter={scene === "message" ? "P" : "K"} className="h-[2.2em] w-[2.2em] text-[0.85em]" />
                  <div className="min-w-0 flex-1 leading-snug">
                    <div className="flex justify-between text-[0.9em]">
                      <span className="font-semibold">{scene === "message" ? "Priya" : "Kestrel Bank"}</span>
                      <span className="text-white/45">now</span>
                    </div>
                    <p className="text-[0.88em] text-white/85">{scene === "message" ? "Running a bit late, start without me?" : "Your sign-in code is 482913. It expires in 10 minutes."}</p>
                  </div>
                </div>
                {scene === "message" &&
                  (s.sent ? (
                    <p className="mt-[0.6em] flex items-center gap-[0.3em] text-[0.85em] text-lime">
                      <IconCheck size={14} aria-hidden="true" /> Sent from Asha's phone
                    </p>
                  ) : (
                    <form
                      className="mt-[0.6em] flex gap-[0.4em]"
                      onSubmit={(e) => {
                        e.preventDefault()
                        took.current = true
                        sendReply(s.draft)
                      }}
                    >
                      <label className="sr-only" htmlFor={`reply-${scene}`}>
                        Reply to Priya
                      </label>
                      <input
                        id={`reply-${scene}`}
                        value={s.draft}
                        onChange={(e) => {
                          took.current = true
                          set({ draft: e.target.value })
                        }}
                        onFocus={() => (took.current = true)}
                        placeholder="Reply"
                        autoComplete="off"
                        className="h-[2.2em] min-w-0 flex-1 rounded-[0.5em] bg-white/10 px-[0.7em] text-[0.9em] text-white placeholder:text-white/40 focus:outline-none"
                      />
                      <button ref={refs.replySend} type="submit" aria-label="Send reply" className="grid h-[2.2em] w-[2.2em] place-items-center rounded-[0.5em] bg-pink text-night">
                        <IconSend2 size={14} aria-hidden="true" />
                      </button>
                    </form>
                  ))}
                {scene === "code" && (
                  <button
                    type="button"
                    onClick={() => {
                      took.current = true
                      copyCode(true)
                    }}
                    className={cn("mt-[0.6em] flex h-[2.2em] w-full items-center justify-center gap-[0.4em] rounded-[0.5em] text-[0.88em] font-medium transition-colors", s.copied ? "bg-lime text-night" : "bg-white/15")}
                  >
                    {s.copied ? <IconCheck size={14} aria-hidden="true" /> : <IconCopy size={14} aria-hidden="true" />}
                    {s.copied ? "Copied" : "Copy code"}
                  </button>
                )}
              </motion.div>
            )}
            {scene === "call" && s.call !== "none" && (
              <motion.div initial={{ opacity: 0, x: 24 }} animate={{ opacity: 1, x: 0 }} className="rounded-[0.9em] bg-[#1c1c1c]/92 p-[0.9em] ring-1 ring-white/15 backdrop-blur-xl">
                <div className="flex items-center gap-[0.7em]">
                  <span className="relative">
                    {s.call === "ringing" && <span className="absolute inset-0 animate-ping rounded-full bg-lime/40" />}
                    <Avatar letter="P" className="relative h-[2.6em] w-[2.6em]" />
                  </span>
                  <div className="leading-tight">
                    <p className="text-[0.95em] font-semibold">Priya</p>
                    <p className="text-[0.82em] text-white/60">{s.call === "ringing" ? "Calling Asha's phone" : `${clock}, audio on the phone`}</p>
                  </div>
                </div>
                <div className="mt-[0.8em] flex gap-[0.4em] text-[0.85em] font-medium">
                  {s.call === "ringing" ? (
                    <>
                      <button type="button" onClick={() => ((took.current = true), set({ call: "none" }))} className="flex flex-1 items-center justify-center gap-[0.3em] rounded-[0.5em] bg-[#ff5a52] py-[0.45em]">
                        <IconPhoneOff size={13} aria-hidden="true" /> Decline
                      </button>
                      <button type="button" onClick={() => ((took.current = true), set({ call: "live" }))} className="flex flex-1 items-center justify-center gap-[0.3em] rounded-[0.5em] bg-[#30d158] py-[0.45em] text-[#06210f]">
                        <IconPhone size={13} aria-hidden="true" /> Answer
                      </button>
                    </>
                  ) : (
                    <>
                      <button type="button" onClick={() => set({ muted: !s.muted })} aria-pressed={s.muted} className={cn("flex flex-1 items-center justify-center gap-[0.3em] rounded-[0.5em] py-[0.45em]", s.muted ? "bg-white text-night" : "bg-white/15")}>
                        <IconMicrophone size={13} aria-hidden="true" /> {s.muted ? "Muted" : "Mute"}
                      </button>
                      <button type="button" onClick={() => set({ call: "none" })} className="flex flex-1 items-center justify-center gap-[0.3em] rounded-[0.5em] bg-[#ff5a52] py-[0.45em]">
                        <IconPhoneOff size={13} aria-hidden="true" /> Hang up
                      </button>
                    </>
                  )}
                </div>
              </motion.div>
            )}
          </AnimatePresence>
        </Pulse>
      </div>

      {scene === "code" && (
        <div className="absolute top-[30%] left-[24%] w-[46%] overflow-hidden rounded-[0.8em] bg-[#f2f2f2] text-night shadow-[0_1.5em_3em_-1em_rgba(0,0,0,0.7)]">
          <div className="flex items-center gap-[0.8em] border-b border-black/5 px-[0.8em] py-[0.55em]">
            <TrafficLights />
            <span className="flex-1 truncate rounded-[0.4em] bg-black/5 px-[0.6em] py-[0.2em] text-center text-[0.78em] text-black/55">kestrelbank.example/sign-in</span>
          </div>
          <div className="p-[1.2em]">
            <p className="font-display text-[1.15em] font-semibold">Enter your sign-in code</p>
            <div className="mt-[0.8em] grid grid-cols-6 gap-[0.4em]">
              {"482913".split("").map((d, i) => (
                <span key={i} className={cn("grid aspect-[4/5] place-items-center rounded-[0.5em] text-[1.3em] font-semibold ring-1", i < s.filled ? "bg-white ring-pink" : "bg-white/60 ring-black/10")}>
                  {i < s.filled ? d : ""}
                </span>
              ))}
            </div>
            <p className="mt-[0.7em] text-[0.8em] text-black/50">{s.filled === 6 ? "Pasted from the notification." : "Waiting for the code"}</p>
          </div>
        </div>
      )}

      {scene === "photos" && (
        <Pulse k="finder" pulse={pulse} className="absolute top-[22%] left-[22%] w-[48%]">
          <div ref={refs.finder} className="overflow-hidden rounded-[0.8em] bg-[#f2f2f2] text-night shadow-[0_1.5em_3em_-1em_rgba(0,0,0,0.7)]">
            <div className="flex items-center gap-[0.8em] border-b border-black/5 px-[0.8em] py-[0.55em] text-[0.85em]">
              <TrafficLights />
              <span className="font-semibold">Downloads</span>
            </div>
            <div className="grid min-h-[8em] grid-cols-3 gap-[0.7em] p-[1em]">
              {s.received.map((k, i) => (
                <motion.div key={k} initial={{ scale: 0.5, opacity: 0 }} animate={{ scale: 1, opacity: 1 }} transition={{ type: "spring", stiffness: 420, damping: 22 }}>
                  <Photo kind={k} className="block aspect-square w-full rounded-[0.4em]" />
                  <p className="mt-[0.3em] truncate text-[0.72em] text-black/55">IMG_{2041 + i}.jpg</p>
                </motion.div>
              ))}
              {!s.received.length && <p className="col-span-3 self-center text-center text-[0.85em] text-black/45">Photos you send land here</p>}
            </div>
          </div>
        </Pulse>
      )}

      {scene === "full" && (
        <div className="absolute top-[8%] left-[36%] flex h-[86%] gap-[1.4em]">
          <div ref={refs.mirror} className="flex h-full flex-col overflow-hidden rounded-[0.8em] bg-[#161616] ring-1 ring-white/15" style={{ aspectRatio: "9 / 18" }}>
            <div className="flex items-center justify-between px-[0.6em] py-[0.35em] text-[0.75em] text-white/80">
              <TrafficLights />
              <span>Asha's phone</span>
              <span className="w-[2em]" />
            </div>
            <div className="mx-[0.4em] mb-[0.4em] flex-1 overflow-hidden rounded-[0.6em] text-[0.8em]">
              <Chat sent={[]} mirror={s.mirror} typing={s.typing} />
            </div>
          </div>
          <form
            className="w-[15em] self-center"
            onSubmit={(e) => {
              e.preventDefault()
              took.current = true
              sendMirror(s.typing)
            }}
          >
            <div className="rounded-[0.9em] bg-[#1c1c1c]/90 p-[0.9em] ring-1 ring-white/15 backdrop-blur">
              <label htmlFor="fm-type" className="text-[0.85em] font-medium">
                Type with the Mac's keyboard
              </label>
              <input
                id="fm-type"
                value={s.typing}
                onChange={(e) => {
                  took.current = true
                  set({ typing: e.target.value })
                }}
                onFocus={() => (took.current = true)}
                placeholder="Emoji too"
                autoComplete="off"
                className="mt-[0.5em] h-[2.3em] w-full rounded-[0.5em] bg-white/10 px-[0.7em] text-[0.9em] text-white placeholder:text-white/40 focus:outline-none"
              />
              <p className="mt-[0.5em] text-[0.75em] text-white/55">Press Return to send it from the phone.</p>
            </div>
          </form>
        </div>
      )}
    </div>
  )
}

function Chat({ sent, mirror, typing, endRef }: { sent: string[]; mirror: string[]; typing: string; endRef?: RefObject<HTMLDivElement | null> }) {
  return (
    <div className="flex h-full flex-col bg-[#f2f2f2] text-night">
      <div className="flex items-center gap-[0.5em] border-b border-black/5 px-[0.8em] pt-[2.4em] pb-[0.6em]">
        <Avatar letter="P" className="h-[1.9em] w-[1.9em] text-[0.75em]" />
        <span className="text-[0.95em] font-semibold">Priya</span>
      </div>
      <div className="flex flex-1 flex-col justify-end gap-[0.45em] px-[0.7em] pb-[0.6em] text-[0.82em] leading-snug">
        <p className="max-w-[82%] self-start rounded-[1em] rounded-bl-[0.3em] bg-white px-[0.8em] py-[0.5em]">Running a bit late, start without me?</p>
        {[...sent, ...mirror].map((m, i) => (
          <motion.p key={`${i}${m}`} initial={{ opacity: 0, y: 8, scale: 0.95 }} animate={{ opacity: 1, y: 0, scale: 1 }} className="max-w-[82%] self-end rounded-[1em] rounded-br-[0.3em] bg-pink px-[0.8em] py-[0.5em] text-night">
            {m}
          </motion.p>
        ))}
        <div ref={endRef} className="h-px" />
      </div>
      <div className="mx-[0.7em] mb-[1.4em] truncate rounded-full bg-white px-[0.9em] py-[0.55em] text-[0.78em]">
        {typing ? <span>{typing}<span className="ml-px inline-block h-[1em] w-px translate-y-[0.15em] animate-pulse bg-night" /></span> : <span className="text-black/35">Message</span>}
      </div>
    </div>
  )
}

function PhoneScreen({
  scene,
  s,
  refs,
  pulse,
  took,
  sendPhotos,
  clock,
  stage,
  fly,
  setS,
  bump,
  drag,
  setDrag,
}: {
  scene: Scene
  s: StageState
  set: (p: Partial<StageState>) => void
  refs: Refs
  pulse: Record<string, number>
  took: RefObject<boolean>
  sendPhotos: () => void
  clock: string
  stage: RefObject<HTMLDivElement | null>
  fly: (from: Element | null | undefined, to: Element | null | undefined, body: ReactNode, start?: Point) => Promise<void>
  setS: React.Dispatch<React.SetStateAction<StageState>>
  bump: (k: string) => void
  drag: Drag
  setDrag: (d: Drag) => void
}) {
  // Drag a photo out of the phone and onto the Mac's Downloads window.
  const startDrag = (kind: Kind, e: React.PointerEvent) => {
    if (s.received.includes(kind)) return
    took.current = true
    const st = stage.current!.getBoundingClientRect()
    const origin = { x: e.clientX, y: e.clientY }
    let moved = false
    const over = (x: number, y: number) => {
      const r = refs.finder.current?.getBoundingClientRect()
      return !!r && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom
    }
    const move = (ev: PointerEvent) => {
      if (!moved && Math.hypot(ev.clientX - origin.x, ev.clientY - origin.y) < 6) return
      moved = true
      setDrag({ kind, p: { x: ev.clientX - st.left, y: ev.clientY - st.top }, over: over(ev.clientX, ev.clientY) })
    }
    const up = async (ev: PointerEvent) => {
      window.removeEventListener("pointermove", move)
      window.removeEventListener("pointerup", up)
      setDrag(null)
      const add = () => {
        setS((v) => ({ ...v, received: v.received.includes(kind) ? v.received : [...v.received, kind] }))
        bump("finder")
      }
      if (!moved) {
        await fly(refs.thumbs.current?.[kind], refs.finder.current, <Photo kind={kind} className="h-[4em] w-[4em] rounded-[0.5em] ring-2 ring-white" />)
        return add()
      }
      if (over(ev.clientX, ev.clientY)) add()
    }
    window.addEventListener("pointermove", move)
    window.addEventListener("pointerup", up)
  }

  return (
    <Pulse k="phone" pulse={pulse} className="absolute inset-0">
      <div className="absolute inset-x-0 top-0 z-30 flex justify-between px-[1.4em] pt-[0.7em] text-[0.68em] font-semibold text-night">
        <span className={scene === "code" || scene === "call" ? "text-white" : ""}>{times[scene]}</span>
        <span className={scene === "code" || scene === "call" ? "text-white" : ""}>82%</span>
      </div>

      {(scene === "message" || scene === "full") && (
        <div className="absolute inset-0">
          <Chat sent={s.sent ? [s.sent] : []} mirror={scene === "full" ? s.mirror : []} typing={scene === "full" ? s.typing : ""} endRef={refs.phoneChatEnd} />
        </div>
      )}

      {scene === "code" && (
        <div className="absolute inset-0 bg-[#0b0b0b] text-mist">
          <p className="mt-[3.4em] text-center font-display text-[2.6em] leading-none font-semibold tracking-[-0.04em]">{times.code}</p>
          <p className="mt-[0.4em] text-center text-[0.72em] text-white/55">Tuesday 4 November</p>
        </div>
      )}

      {(scene === "message" || scene === "code") && (
        <AnimatePresence>
          {s.phoneNotif && (
            <motion.div
              ref={refs.phoneNotif}
              initial={{ y: "-120%", opacity: 0 }}
              animate={s.macBanner ? { y: "-130%", opacity: 0 } : { y: 0, opacity: 1 }}
              transition={s.macBanner ? { delay: 0.5, duration: 0.4 } : { type: "spring", stiffness: 380, damping: 30 }}
              className="absolute inset-x-[0.6em] top-[2.2em] z-20 rounded-[1em] bg-white p-[0.7em] text-night shadow-[0_0.6em_1.4em_-0.4em_rgba(0,0,0,0.35)]"
            >
              <div className="flex items-center gap-[0.5em]">
                <Avatar letter={scene === "message" ? "P" : "K"} className="h-[1.7em] w-[1.7em] text-[0.7em]" />
                <span className="text-[0.75em] font-semibold">{scene === "message" ? "Priya" : "Kestrel Bank"}</span>
              </div>
              <p className="mt-[0.3em] text-[0.72em] leading-snug text-black/70">
                {s.macBanner ? "Also on your Mac" : scene === "message" ? "Running a bit late, start without me?" : "Your sign-in code is 482913"}
              </p>
            </motion.div>
          )}
        </AnimatePresence>
      )}

      {scene === "call" && (
        <div className="absolute inset-0 flex flex-col items-center bg-[#0b0b0b] pt-[5em] text-mist">
          <span className="relative">
            {s.call === "ringing" && <span className="absolute inset-0 animate-ping rounded-full bg-lime/40" />}
            <Avatar letter="P" className="relative h-[4em] w-[4em] text-[1.2em]" />
          </span>
          <p className="mt-[0.8em] font-display text-[1.2em] font-semibold">Priya</p>
          <p className="text-[0.72em] text-white/55">
            {s.call === "ringing" ? "Incoming call" : s.call === "live" ? `${clock}, answered on the Mac` : "Call ended"}
          </p>
          {s.call === "live" && (
            <p className="mt-[2em] flex items-center gap-[0.4em] rounded-full bg-white/10 px-[0.8em] py-[0.3em] text-[0.68em]">
              <IconVolume size={11} aria-hidden="true" /> Audio stays here
            </p>
          )}
        </div>
      )}

      {scene === "photos" && (
        <div className="absolute inset-0 flex flex-col bg-[#f2f2f2] px-[0.8em] pt-[2.6em] text-night">
          <p className="text-[0.85em] font-semibold">Share 3 photos</p>
          <div className="mt-[0.7em] grid grid-cols-2 gap-[0.4em]">
            {(["ferry", "dumplings", "cliffs"] as Kind[]).map((k) => {
              const gone = s.received.includes(k) || drag?.kind === k
              return (
                <div
                  key={k}
                  ref={(el) => {
                    if (refs.thumbs.current) refs.thumbs.current[k] = el
                  }}
                  onPointerDown={(e) => startDrag(k, e)}
                  role="button"
                  tabIndex={gone ? -1 : 0}
                  aria-label="Send this photo to the Mac"
                  className={cn("aspect-square touch-none overflow-hidden rounded-[0.5em] ring-2 transition-opacity", gone ? "opacity-25 ring-transparent" : "cursor-grab ring-pink")}
                >
                  <Photo kind={k} className="pointer-events-none h-full w-full" />
                </div>
              )
            })}
          </div>
          <button
            type="button"
            onClick={() => {
              took.current = true
              sendPhotos()
            }}
            disabled={s.sending || s.received.length === 3}
            className={cn("mt-auto mb-[1.6em] rounded-full py-[0.6em] text-[0.8em] font-semibold transition-colors", s.received.length === 3 ? "bg-black/10 text-black/45" : "bg-pink text-night")}
          >
            {s.received.length === 3 ? "Sent to Mac" : "Send to Mac"}
          </button>
        </div>
      )}
    </Pulse>
  )
}
