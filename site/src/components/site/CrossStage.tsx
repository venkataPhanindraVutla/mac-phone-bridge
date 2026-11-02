// The phone and the Mac side by side, with things crossing between them: a message, a photo
// (tap it or drag it onto Downloads), copied text, a call that rings both, and Find my phone.
// Nothing moves until the visitor presses something.
import { useEffect, useRef, useState, type ReactNode } from "react"
import { AnimatePresence, motion, useReducedMotion } from "motion/react"
import {
  IconCheck,
  IconClipboard,
  IconCopy,
  IconDeviceMobile,
  IconMessage,
  IconPhone,
  IconPhoneOff,
  IconPhoto,
  IconVolume,
} from "@tabler/icons-react"
import { cn } from "@/lib/utils"
import { Avatar, Photo, TrafficLights, Wallpaper } from "./parts"

type Kind = "ferry" | "dumplings" | "cliffs"
type Point = { x: number; y: number }
type Flight = { id: number; from: Point; to: Point; body: ReactNode; done: () => void }

const messages = [
  { who: "Priya", text: "Running a bit late, start without me?" },
  { who: "Dev", text: "Pushed the fix, can you check?" },
  { who: "Mum", text: "Call me when you're free" },
]
const photos: Kind[] = ["ferry", "dumplings", "cliffs"]
const note = "Gate 14, boarding 18:40"

export function CrossStage() {
  const reduce = useReducedMotion()
  const stage = useRef<HTMLDivElement>(null)
  const phoneNote = useRef<HTMLDivElement>(null)
  const macBanner = useRef<HTMLDivElement>(null)
  const downloads = useRef<HTMLDivElement>(null)
  const copyBtn = useRef<HTMLButtonElement>(null)
  const phoneField = useRef<HTMLDivElement>(null)
  const macPhoneIcon = useRef<HTMLSpanElement>(null)
  const phoneBody = useRef<HTMLDivElement>(null)
  const thumbs = useRef<Partial<Record<Kind, HTMLDivElement | null>>>({})

  const [flights, setFlights] = useState<Flight[]>([])
  const [msgIndex, setMsgIndex] = useState(-1)
  const [onPhone, setOnPhone] = useState<number | null>(null)
  const [onMac, setOnMac] = useState<number | null>(null)
  const [received, setReceived] = useState<Kind[]>([])
  const [inFlight, setInFlight] = useState<Kind[]>([])
  const [pasted, setPasted] = useState(false)
  const [call, setCall] = useState<"none" | "ringing" | "live">("none")
  const [secs, setSecs] = useState(0)
  const [ringing, setRinging] = useState(false)
  const [drag, setDrag] = useState<{ kind: Kind; p: Point; over: boolean } | null>(null)
  const nextId = useRef(0)

  const at = (el: Element | null | undefined): Point => {
    const s = stage.current!.getBoundingClientRect()
    const r = el!.getBoundingClientRect()
    return { x: r.left - s.left + r.width / 2, y: r.top - s.top + r.height / 2 }
  }
  const fly = (from: Element | null | undefined, to: Element | null | undefined, body: ReactNode, done: () => void, start?: Point) => {
    if (!stage.current || !from || !to) return done()
    if (reduce) return done()
    const id = nextId.current++
    setFlights((f) => [...f, { id, from: start ?? at(from), to: at(to), body, done }])
  }
  const land = (f: Flight) => {
    f.done()
    setFlights((all) => all.filter((x) => x.id !== f.id))
  }

  useEffect(() => {
    if (call !== "live") return
    const t = setInterval(() => setSecs((s) => s + 1), 1000)
    return () => clearInterval(t)
  }, [call])
  useEffect(() => {
    if (!ringing) return
    const t = setTimeout(() => setRinging(false), 3500)
    return () => clearTimeout(t)
  }, [ringing])

  const message = () => {
    const i = (msgIndex + 1) % messages.length
    setMsgIndex(i)
    setOnPhone(i)
    setOnMac(null)
    setTimeout(() => {
      fly(phoneNote.current, macBanner.current, <MiniNote i={i} />, () => setOnMac(i))
    }, 450)
  }

  const sendPhoto = (kind?: Kind, start?: Point) => {
    const k = kind ?? photos.find((p) => !received.includes(p) && !inFlight.includes(p))
    if (!k) {
      setReceived([])
      return
    }
    if (received.includes(k) || inFlight.includes(k)) return
    setInFlight((f) => [...f, k])
    fly(thumbs.current[k], downloads.current, <Photo kind={k} className="h-12 w-12 rounded-md ring-2 ring-white" />, () => {
      setInFlight((f) => f.filter((x) => x !== k))
      setReceived((r) => (r.includes(k) ? r : [...r, k]))
    }, start)
  }

  const copy = () => {
    navigator.clipboard?.writeText(note).catch(() => {})
    setPasted(false)
    fly(copyBtn.current, phoneField.current, <span className="rounded-full bg-lime px-3 py-1 text-[0.75rem] font-semibold whitespace-nowrap text-night">{note}</span>, () => setPasted(true))
  }

  const ring = () => {
    setRinging(false)
    fly(macPhoneIcon.current, phoneBody.current, <span className="block h-5 w-5 rounded-full bg-pink ring-4 ring-pink/30" />, () => setRinging(true))
  }

  const startCall = () => {
    setRinging(false)
    setSecs(0)
    setCall("ringing")
  }

  // Dragging a photo out of the phone: a floating copy follows the pointer across the stage.
  const startDrag = (kind: Kind, e: React.PointerEvent) => {
    if (received.includes(kind) || inFlight.includes(kind)) return
    const s = stage.current!.getBoundingClientRect()
    const origin = { x: e.clientX, y: e.clientY }
    let moved = false
    const overTarget = (x: number, y: number) => {
      const r = downloads.current!.getBoundingClientRect()
      return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom
    }
    const move = (ev: PointerEvent) => {
      if (!moved && Math.hypot(ev.clientX - origin.x, ev.clientY - origin.y) < 6) return
      moved = true
      setDrag({ kind, p: { x: ev.clientX - s.left, y: ev.clientY - s.top }, over: overTarget(ev.clientX, ev.clientY) })
    }
    const up = (ev: PointerEvent) => {
      window.removeEventListener("pointermove", move)
      window.removeEventListener("pointerup", up)
      setDrag(null)
      if (!moved) return sendPhoto(kind)
      if (overTarget(ev.clientX, ev.clientY)) {
        setReceived((r) => (r.includes(kind) ? r : [...r, kind]))
      } else {
        // Dropped elsewhere: it goes back to the phone.
        fly(downloads.current, thumbs.current[kind], <Photo kind={kind} className="h-12 w-12 rounded-md ring-2 ring-white" />, () => {}, { x: ev.clientX - s.left, y: ev.clientY - s.top })
      }
    }
    window.addEventListener("pointermove", move)
    window.addEventListener("pointerup", up)
  }

  const clock = `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, "0")}`

  return (
    <div className="mt-14">
      <div ref={stage} className="relative isolate select-none">
        <div className="grid items-center gap-6 md:grid-cols-[minmax(0,12.5rem)_minmax(0,1fr)] md:gap-14 lg:gap-24">
          {/* Phone */}
          <div className="mx-auto w-[10.5rem] md:w-full">
            <motion.div
              animate={ringing ? { rotate: [0, -3, 3, -3, 3, 0] } : { rotate: 0 }}
              transition={{ duration: 0.45, repeat: ringing ? Infinity : 0, repeatDelay: 0.25 }}
              className="relative aspect-[9/19] rounded-[2.2rem] bg-[#111] p-2 shadow-[0_30px_70px_-25px_rgba(0,0,0,0.9)] ring-1 ring-white/10"
            >
              <div ref={phoneBody} className="relative h-full overflow-hidden rounded-[1.8rem] bg-[#f2f2f2] text-night">
                <span className="absolute top-2 left-1/2 z-20 h-2.5 w-2.5 -translate-x-1/2 rounded-full bg-black" aria-hidden="true" />
                <div className="flex justify-between px-5 pt-2 text-[0.62rem] font-medium">
                  <span>10:24</span>
                  <span>82%</span>
                </div>
                <p className="mt-5 text-center font-display text-[2.6rem] leading-none font-semibold tracking-[-0.04em]">10:24</p>
                <p className="mt-1 text-center text-[0.7rem] text-black/50">Tuesday 4 November</p>

                <div className="mx-3 mt-4 h-[4.2rem]">
                  <AnimatePresence mode="popLayout">
                    {onPhone !== null && (
                      <motion.div
                        key={onPhone}
                        ref={phoneNote}
                        initial={{ opacity: 0, y: -16 }}
                        animate={{ opacity: onMac === onPhone ? 0.45 : 1, y: 0 }}
                        exit={{ opacity: 0, y: 10 }}
                        className="rounded-2xl bg-white p-2.5 shadow-sm"
                      >
                        <div className="flex items-center gap-2">
                          <Avatar letter={messages[onPhone].who[0]} className="h-6 w-6 text-[0.65rem]" />
                          <span className="text-[0.72rem] font-semibold">{messages[onPhone].who}</span>
                        </div>
                        <p className="mt-1 truncate text-[0.7rem] text-black/70">
                          {onMac === onPhone ? "Shown on your Mac" : messages[onPhone].text}
                        </p>
                      </motion.div>
                    )}
                  </AnimatePresence>
                </div>

                <div ref={phoneField} className="mx-3 mt-2 rounded-xl bg-white px-2.5 py-2 text-[0.7rem]">
                  <p className="text-black/40">Notes</p>
                  <AnimatePresence mode="wait">
                    <motion.p key={String(pasted)} initial={{ opacity: 0 }} animate={{ opacity: 1 }} className={cn("mt-0.5 truncate", !pasted && "text-black/30")}>
                      {pasted ? note : "Paste here"}
                    </motion.p>
                  </AnimatePresence>
                </div>

                <div className="absolute inset-x-3 bottom-4">
                  <p className="mb-1.5 text-[0.65rem] font-medium text-black/50">Recent photos</p>
                  <div className="grid grid-cols-3 gap-1.5">
                    {photos.map((k) => {
                      const gone = received.includes(k) || inFlight.includes(k) || drag?.kind === k
                      return (
                        <div
                          key={k}
                          ref={(el) => {
                            thumbs.current[k] = el
                          }}
                          onPointerDown={(e) => startDrag(k, e)}
                          className={cn("aspect-square touch-none overflow-hidden rounded-lg transition-opacity", gone ? "opacity-20" : "cursor-grab")}
                          role="button"
                          tabIndex={gone ? -1 : 0}
                          aria-label={`Send photo ${photos.indexOf(k) + 1} to the Mac`}
                          onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && (e.preventDefault(), sendPhoto(k))}
                        >
                          <Photo kind={k} className="pointer-events-none h-full w-full" />
                        </div>
                      )
                    })}
                  </div>
                </div>

                {/* Incoming call, full screen on the phone */}
                <AnimatePresence>
                  {call !== "none" && (
                    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="absolute inset-0 z-10 flex flex-col items-center bg-[#0b0b0b] pt-14 text-mist">
                      <span className="relative">
                        {call === "ringing" && <span className="absolute inset-0 animate-ping rounded-full bg-lime/40" aria-hidden="true" />}
                        <Avatar letter="P" className="relative h-16 w-16 text-xl" />
                      </span>
                      <p className="mt-3 font-display text-lg font-semibold">Priya</p>
                      <p className="text-[0.72rem] text-white/55">{call === "ringing" ? "Incoming call" : `${clock}, answered on the Mac`}</p>
                      {call === "live" && (
                        <p className="mt-6 flex items-center gap-1.5 rounded-full bg-white/10 px-3 py-1 text-[0.68rem]">
                          <IconVolume size={13} aria-hidden="true" /> Audio stays on the phone
                        </p>
                      )}
                    </motion.div>
                  )}
                </AnimatePresence>

                {/* Find my phone */}
                <AnimatePresence>
                  {ringing && (
                    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="absolute inset-0 z-10 flex flex-col items-center justify-center bg-pink text-night">
                      {[0, 0.5].map((d) => (
                        <motion.span key={d} className="absolute h-24 w-24 rounded-full ring-2 ring-night/40" initial={{ scale: 0.6, opacity: 1 }} animate={{ scale: 2.2, opacity: 0 }} transition={{ duration: 1.2, delay: d, repeat: Infinity }} aria-hidden="true" />
                      ))}
                      <IconVolume size={34} aria-hidden="true" />
                      <p className="mt-3 font-display text-lg font-semibold">Ringing</p>
                      <p className="text-[0.72rem]">From your Mac, at full volume</p>
                      <button type="button" onClick={() => setRinging(false)} className="mt-5 rounded-full bg-night px-4 py-1.5 text-[0.75rem] font-medium text-mist">
                        Stop
                      </button>
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            </motion.div>
          </div>

          {/* Mac */}
          <div className="rounded-[1.4rem] bg-[#1a1a1a] p-2 shadow-[0_30px_70px_-25px_rgba(0,0,0,0.9)] ring-1 ring-white/10">
            <div className="relative aspect-[16/11] overflow-hidden rounded-[1rem] sm:aspect-[16/10]">
              <Wallpaper />
              <div className="relative z-10 flex h-6 items-center justify-between bg-black/40 px-3 text-[0.68rem] font-medium whitespace-nowrap text-white backdrop-blur-md">
                <span className="flex gap-3">
                  <span className="font-semibold">Finder</span>
                  <span className="hidden sm:inline">File</span>
                  <span className="hidden sm:inline">Edit</span>
                </span>
                <span className="flex items-center gap-3">
                  <span ref={macPhoneIcon} className="flex items-center gap-1 rounded bg-white/15 px-1.5 py-0.5">
                    <IconDeviceMobile size={12} aria-hidden="true" /> 82%
                  </span>
                  <span>Tue 10:24</span>
                </span>
              </div>

              {/* Notes window, with text to copy */}
              <div className="absolute top-[14%] left-[4%] w-[46%] rounded-xl bg-[#f2f2f2] p-3 text-night shadow-[0_16px_40px_-12px_rgba(0,0,0,0.7)]">
                <div className="flex items-center gap-2 text-[0.7rem]">
                  <TrafficLights />
                  <span className="font-semibold">Notes</span>
                </div>
                <p className="mt-2 truncate text-[0.82rem] font-medium">{note}</p>
                <button ref={copyBtn} type="button" onClick={copy} className="mt-2 inline-flex items-center gap-1 rounded-md bg-night px-2 py-1 text-[0.68rem] font-medium text-mist">
                  <IconCopy size={12} aria-hidden="true" /> Copy
                </button>
              </div>

              {/* Where notifications land */}
              <div ref={macBanner} className="absolute top-[12%] right-[3%] h-[3.6rem] w-[min(16rem,46%)]">
                <AnimatePresence>
                  {onMac !== null && (
                    <motion.div key={onMac} initial={{ opacity: 0, scale: 0.9 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, x: 30 }} className="rounded-xl bg-[#1c1c1c]/90 p-2.5 text-white ring-1 ring-white/15 backdrop-blur">
                      <div className="flex gap-2">
                        <Avatar letter={messages[onMac].who[0]} className="h-7 w-7 text-[0.7rem]" />
                        <div className="min-w-0 leading-tight">
                          <p className="text-[0.75rem] font-semibold">{messages[onMac].who}</p>
                          <p className="truncate text-[0.7rem] text-white/75">{messages[onMac].text}</p>
                        </div>
                      </div>
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>

              {/* Call banner */}
              <AnimatePresence>
                {call !== "none" && (
                  <motion.div initial={{ opacity: 0, y: -12 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -12 }} className="absolute top-[34%] right-[3%] z-20 w-[min(16rem,46%)] rounded-xl bg-[#1c1c1c]/95 p-2.5 text-white ring-1 ring-white/15 backdrop-blur">
                    <div className="flex items-center gap-2">
                      <Avatar letter="P" className="h-8 w-8 text-xs" />
                      <div className="min-w-0 flex-1 leading-tight">
                        <p className="text-[0.75rem] font-semibold">Priya</p>
                        <p className="text-[0.68rem] text-white/60">{call === "ringing" ? "Calling your phone" : clock}</p>
                      </div>
                    </div>
                    <div className="mt-2 flex gap-1.5">
                      {call === "ringing" ? (
                        <>
                          <button type="button" onClick={() => setCall("none")} className="flex flex-1 items-center justify-center gap-1 rounded-md bg-[#ff5a52] py-1 text-[0.68rem] font-medium">
                            <IconPhoneOff size={12} aria-hidden="true" /> Decline
                          </button>
                          <button type="button" onClick={() => setCall("live")} className="flex flex-1 items-center justify-center gap-1 rounded-md bg-[#30d158] py-1 text-[0.68rem] font-medium text-[#06210f]">
                            <IconPhone size={12} aria-hidden="true" /> Answer
                          </button>
                        </>
                      ) : (
                        <button type="button" onClick={() => setCall("none")} className="flex flex-1 items-center justify-center gap-1 rounded-md bg-[#ff5a52] py-1 text-[0.68rem] font-medium">
                          <IconPhoneOff size={12} aria-hidden="true" /> Hang up
                        </button>
                      )}
                    </div>
                  </motion.div>
                )}
              </AnimatePresence>

              {/* Downloads, the drop target */}
              <div
                ref={downloads}
                className={cn(
                  "absolute right-[3%] bottom-[5%] w-[min(17rem,52%)] rounded-xl bg-[#f2f2f2] p-2.5 text-night shadow-[0_16px_40px_-12px_rgba(0,0,0,0.7)] ring-2 transition-[box-shadow] ring-inset",
                  drag?.over ? "ring-lime" : "ring-transparent",
                )}
              >
                <div className="flex items-center gap-2 text-[0.7rem]">
                  <TrafficLights />
                  <span className="font-semibold">Downloads</span>
                </div>
                <div className="mt-2 grid min-h-[3.25rem] grid-cols-3 gap-1.5">
                  {received.map((k) => (
                    <motion.div key={k} initial={{ scale: 0.6, opacity: 0 }} animate={{ scale: 1, opacity: 1 }} className="overflow-hidden rounded-md">
                      <Photo kind={k} className="block aspect-square w-full" />
                    </motion.div>
                  ))}
                  {!received.length && <p className="col-span-3 self-center text-center text-[0.68rem] text-black/45">Drop photos here</p>}
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Things in the air between the two */}
        <div className="pointer-events-none absolute inset-0 z-30" aria-hidden="true">
          {flights.map((f) => {
            const lift = Math.min(160, Math.abs(f.to.x - f.from.x) * 0.25 + 60)
            const midY = Math.min(f.from.y, f.to.y) - lift
            return (
              <motion.div
                key={f.id}
                className="absolute top-0 left-0"
                initial={{ x: f.from.x, y: f.from.y, scale: 0.9 }}
                animate={{ x: [f.from.x, (f.from.x + f.to.x) / 2, f.to.x], y: [f.from.y, midY, f.to.y], scale: [0.9, 1.08, 0.9] }}
                transition={{ duration: 0.95, ease: [0.45, 0, 0.2, 1] }}
                onAnimationComplete={() => land(f)}
              >
                <div className="-translate-x-1/2 -translate-y-1/2">{f.body}</div>
              </motion.div>
            )
          })}
          {drag && (
            <div className="absolute top-0 left-0" style={{ transform: `translate(${drag.p.x}px, ${drag.p.y}px)` }}>
              <div className="-translate-x-1/2 -translate-y-1/2 rotate-[-4deg]">
                <Photo kind={drag.kind} className="h-16 w-16 rounded-lg shadow-2xl ring-2 ring-white" />
              </div>
            </div>
          )}
        </div>
      </div>

      <div className="mt-8 flex flex-wrap justify-center gap-2" role="group" aria-label="Try it">
        <Action onClick={message} icon={<IconMessage size={17} />}>Get a message</Action>
        <Action onClick={() => sendPhoto()} icon={<IconPhoto size={17} />}>Send a photo</Action>
        <Action onClick={copy} icon={<IconClipboard size={17} />}>Copy on the Mac</Action>
        <Action onClick={startCall} icon={<IconPhone size={17} />} active={call !== "none"}>
          Incoming call
        </Action>
        <Action onClick={ring} icon={<IconDeviceMobile size={17} />} active={ringing}>
          Ring the phone
        </Action>
      </div>
      <p className="mt-4 text-center text-[0.9rem] text-haze">Or drag a photo from the phone onto the Mac's Downloads.</p>
      <p className="sr-only" aria-live="polite">
        {onMac !== null ? `Message from ${messages[onMac].who} shown on the Mac.` : ""} {pasted ? "Text pasted on the phone." : ""} {received.length ? `${received.length} photos in Downloads.` : ""}
      </p>
    </div>
  )
}

function MiniNote({ i }: { i: number }) {
  return (
    <div className="flex w-44 items-center gap-2 rounded-xl bg-white p-2 text-night shadow-xl">
      <Avatar letter={messages[i].who[0]} className="h-6 w-6 text-[0.65rem]" />
      <p className="truncate text-[0.7rem]">{messages[i].text}</p>
    </div>
  )
}

function Action({ children, icon, onClick, active }: { children: ReactNode; icon: ReactNode; onClick: () => void; active?: boolean }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "inline-flex h-11 items-center gap-2 rounded-full px-4 text-[0.92rem] font-medium ring-1 transition-[background-color,transform] ring-inset active:scale-[0.97]",
        active ? "bg-lime text-night ring-lime" : "bg-white/[0.04] text-mist ring-line hover:bg-white/[0.08]",
      )}
    >
      <span aria-hidden="true">{active ? <IconCheck size={17} /> : icon}</span>
      {children}
    </button>
  )
}

