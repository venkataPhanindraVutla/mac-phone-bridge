// The working scenes of the day story. Each one behaves like the real feature: type a reply,
// copy a code, take a call, send photos, use the phone in a Mac window.
import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react"
import { AnimatePresence, LayoutGroup, motion } from "motion/react"
import {
  IconArrowBackUp,
  IconCheck,
  IconCircle,
  IconCopy,
  IconMicrophoneOff,
  IconMicrophone,
  IconPhone,
  IconPhoneOff,
  IconRotateClockwise2,
  IconSend2,
  IconSquare,
  IconVolume,
} from "@tabler/icons-react"
import { cn } from "@/lib/utils"
import { Avatar, ChatScreen, MenuBar, PhoneFrame, Photo, TrafficLights, Wallpaper } from "./parts"

const spring = { type: "spring", stiffness: 380, damping: 32 } as const

/** A Mac desktop the scenes sit on. */
export function Stage({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div
      className={cn(
        "relative isolate aspect-[4/4.3] w-full overflow-hidden rounded-[1.4rem] bg-[#151b45] shadow-[0_40px_120px_-40px_rgba(169,155,255,0.35)] ring-1 ring-white/10 sm:aspect-[5/4]",
        className,
      )}
    >
      <Wallpaper />
      <div className="[zoom:1.2] sm:[zoom:1.55]">
        <MenuBar />
      </div>
      <div className="absolute inset-0 top-[22px]">{children}</div>
    </div>
  )
}

function Glass({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cn("rounded-2xl bg-[#262a44]/75 text-white shadow-[0_18px_50px_-14px_rgba(0,0,0,0.65)] ring-1 ring-white/15 backdrop-blur-xl", className)}>
      {children}
    </div>
  )
}

function Hint({ children }: { children: ReactNode }) {
  return <p className="text-[0.78rem] text-white/60">{children}</p>
}

/* 9:02 — a message, answered from the Mac */
export function MessageScene() {
  const [draft, setDraft] = useState("")
  const [sent, setSent] = useState<string | null>(null)
  const send = (e: FormEvent) => {
    e.preventDefault()
    setSent(draft.trim() || "Sure, I'll order for you too")
    setDraft("")
  }
  return (
    <Stage>
      <PhoneFrame className="absolute bottom-[5%] left-[6%] h-[76%] w-[38%] text-[clamp(8px,1.5vw,12px)] sm:w-[30%]">
        <ChatScreen
          extra={
            <AnimatePresence>
              {sent && (
                <motion.p
                  initial={{ opacity: 0, y: 8, scale: 0.96 }}
                  animate={{ opacity: 1, y: 0, scale: 1 }}
                  className="max-w-[80%] self-end rounded-[1em] rounded-br-[0.3em] bg-[#5b4fd6] px-[0.8em] py-[0.5em] text-white"
                >
                  {sent}
                </motion.p>
              )}
            </AnimatePresence>
          }
        />
      </PhoneFrame>
      <motion.div layout transition={spring} className="absolute top-[5%] right-[4%] w-[min(22rem,62%)]">
        <Glass className="p-3.5">
          <div className="flex gap-3">
            <Avatar letter="P" className="h-9 w-9 text-sm" />
            <div className="min-w-0 flex-1 leading-snug">
              <div className="flex items-baseline justify-between gap-2 text-[0.9rem]">
                <span className="font-semibold">Priya</span>
                <span className="text-[0.75rem] text-white/50">now</span>
              </div>
              <Hint>Messages, on Asha's phone</Hint>
              <p className="mt-1 text-[0.88rem] text-white/90">Running a bit late, start without me?</p>
            </div>
          </div>
          <AnimatePresence mode="wait" initial={false}>
            {sent ? (
              <motion.p key="sent" initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="mt-3 flex items-center gap-1.5 text-[0.82rem] text-teal">
                <IconCheck size={16} aria-hidden="true" /> Sent from Asha's phone
              </motion.p>
            ) : (
              <motion.form key="form" exit={{ opacity: 0 }} onSubmit={send} className="mt-3 flex gap-2">
                <label className="sr-only" htmlFor="reply">
                  Reply to Priya
                </label>
                <input
                  id="reply"
                  value={draft}
                  onChange={(e) => setDraft(e.target.value)}
                  placeholder="Reply"
                  autoComplete="off"
                  className="h-9 min-w-0 flex-1 rounded-lg bg-white/10 px-3 text-[0.88rem] text-white placeholder:text-white/45 focus:bg-white/15 focus:outline-none"
                />
                <button type="submit" className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-iris text-night transition-transform active:scale-95" aria-label="Send reply">
                  <IconSend2 size={17} aria-hidden="true" />
                </button>
              </motion.form>
            )}
          </AnimatePresence>
        </Glass>
      </motion.div>
      {sent && (
        <button type="button" onClick={() => setSent(null)} className="absolute right-[4%] bottom-[5%] rounded-full bg-black/30 px-3 py-1.5 text-[0.8rem] text-white/80 backdrop-blur hover:bg-black/45">
          Reset
        </button>
      )}
    </Stage>
  )
}

/* 9:40 — a sign-in code */
export function CodeScene() {
  const code = "482913"
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(code)
    } catch {
      // Clipboard can be blocked (an iframe, an old browser); the scene still shows the paste.
    }
    setCopied(true)
  }
  return (
    <Stage>
      <div className="absolute inset-x-[6%] top-[40%] overflow-hidden rounded-xl bg-[#f5f5f7] text-[#1d1d1f] shadow-[0_20px_50px_-16px_rgba(0,0,0,0.6)] sm:inset-x-[14%]">
        <div className="flex items-center gap-3 border-b border-black/5 px-3 py-2.5">
          <TrafficLights />
          <span className="flex-1 truncate rounded-md bg-black/5 px-2 py-1 text-center text-[0.75rem] text-black/55">kestrelbank.example/sign-in</span>
        </div>
        <div className="px-5 py-5 sm:px-8">
          <p className="font-display text-[1.15rem] font-semibold">Enter your sign-in code</p>
          <div className="mt-4 grid grid-cols-6 gap-1.5 sm:gap-2">
            {code.split("").map((d, i) => (
              <span key={i} className={cn("grid aspect-[4/5] place-items-center rounded-lg text-[1.25rem] font-semibold ring-1", copied ? "bg-white ring-[#5b4fd6]/40" : "bg-white/60 ring-black/10")}>
                <AnimatePresence>
                  {copied && (
                    <motion.span initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.25 + i * 0.05 }}>
                      {d}
                    </motion.span>
                  )}
                </AnimatePresence>
              </span>
            ))}
          </div>
        </div>
      </div>
      <div className="absolute top-[5%] right-[4%] w-[min(22rem,88%)]">
        <Glass className="p-3.5">
          <div className="flex gap-3">
            <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-gradient-to-br from-[#3a7bd5] to-[#1f3f8f] text-sm font-bold">K</span>
            <div className="min-w-0 flex-1 leading-snug">
              <div className="flex items-baseline justify-between text-[0.9rem]">
                <span className="font-semibold">Kestrel Bank</span>
                <span className="text-[0.75rem] text-white/50">now</span>
              </div>
              <p className="mt-0.5 text-[0.88rem] text-white/90">Your sign-in code is {code}. It expires in 10 minutes.</p>
            </div>
          </div>
          <button
            type="button"
            onClick={copied ? () => setCopied(false) : copy}
            className="mt-3 flex h-9 w-full items-center justify-center gap-2 rounded-lg bg-white/15 text-[0.88rem] font-medium transition-colors hover:bg-white/20"
          >
            {copied ? <IconCheck size={16} aria-hidden="true" /> : <IconCopy size={16} aria-hidden="true" />}
            {copied ? "Copied" : "Copy code"}
          </button>
        </Glass>
      </div>
    </Stage>
  )
}

/* 11:15 — a call */
export function CallScene() {
  const [state, setState] = useState<"ringing" | "live" | "declined">("ringing")
  const [secs, setSecs] = useState(0)
  const [muted, setMuted] = useState(false)
  useEffect(() => {
    if (state !== "live") return
    const t = setInterval(() => setSecs((s) => s + 1), 1000)
    return () => clearInterval(t)
  }, [state])
  const reset = () => {
    setState("ringing")
    setSecs(0)
    setMuted(false)
  }
  const clock = `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, "0")}`
  return (
    <Stage>
      <div className="absolute inset-0 grid place-items-center px-[6%]">
        <Glass className="w-[min(21rem,100%)] p-5 text-center">
          <div className="relative mx-auto h-16 w-16">
            {state === "ringing" && <span className="absolute inset-0 animate-ping rounded-full bg-teal/30" aria-hidden="true" />}
            <Avatar letter="P" className="relative h-16 w-16 text-2xl" />
          </div>
          <p className="mt-3 font-display text-xl font-semibold">Priya</p>
          <p className="text-[0.85rem] text-white/60" aria-live="polite">
            {state === "ringing" && "Calling your phone, mobile"}
            {state === "live" && `${clock}, audio on Asha's phone`}
            {state === "declined" && "Declined. The call goes to voicemail."}
          </p>
          <div className="mt-5 flex justify-center gap-3">
            {state === "ringing" && (
              <>
                <CallButton tone="red" onClick={() => setState("declined")} icon={<IconPhoneOff size={20} />} label="Decline" />
                <CallButton tone="green" onClick={() => setState("live")} icon={<IconPhone size={20} />} label="Answer" />
              </>
            )}
            {state === "live" && (
              <>
                <CallButton tone="glass" onClick={() => setMuted((m) => !m)} icon={muted ? <IconMicrophoneOff size={20} /> : <IconMicrophone size={20} />} label={muted ? "Unmute" : "Mute"} pressed={muted} />
                <CallButton tone="red" onClick={() => setState("declined")} icon={<IconPhoneOff size={20} />} label="Hang up" />
              </>
            )}
            {state === "declined" && <CallButton tone="glass" onClick={reset} icon={<IconPhone size={20} />} label="Ring again" />}
          </div>
        </Glass>
      </div>
    </Stage>
  )
}

function CallButton({ tone, onClick, icon, label, pressed }: { tone: "red" | "green" | "glass"; onClick: () => void; icon: ReactNode; label: string; pressed?: boolean }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={pressed}
      className={cn(
        "flex h-11 items-center gap-2 rounded-full px-5 text-[0.9rem] font-medium transition-transform active:scale-95",
        tone === "red" && "bg-[#ff5a52] text-white",
        tone === "green" && "bg-[#30d158] text-[#06210f]",
        tone === "glass" && "bg-white/15 text-white hover:bg-white/20",
      )}
    >
      <span aria-hidden="true">{icon}</span>
      {label}
    </button>
  )
}

/* 14:30 — photos from Sunday */
const photos = [
  { kind: "ferry", name: "IMG_2041.jpg" },
  { kind: "dumplings", name: "IMG_2042.jpg" },
  { kind: "cliffs", name: "IMG_2043.jpg" },
] as const

export function PhotosScene() {
  const [sent, setSent] = useState(false)
  return (
    <Stage>
      <LayoutGroup>
        <PhoneFrame className="absolute bottom-[5%] left-[6%] h-[78%] w-[40%] sm:w-[32%]">
          <div className="flex h-full flex-col bg-[#f4f1fa] px-[8%] pt-[18%] text-[#1c1b22]">
            <p className="text-[0.85rem] font-semibold">Share 3 photos</p>
            <div className="mt-3 grid grid-cols-3 gap-1">
              {photos.map((p) =>
                sent ? (
                  <span key={p.kind} className="aspect-square rounded-md bg-black/5" />
                ) : (
                  <motion.div key={p.kind} layoutId={`photo-${p.kind}`} transition={spring} className="overflow-hidden rounded-md ring-2 ring-[#5b4fd6]">
                    <Photo kind={p.kind} className="block aspect-square w-full" />
                  </motion.div>
                ),
              )}
            </div>
            <button
              type="button"
              onClick={() => setSent((s) => !s)}
              className="mt-4 flex items-center justify-center gap-1.5 rounded-full bg-[#5b4fd6] py-2 text-[0.8rem] font-medium text-white transition-transform active:scale-95"
            >
              {sent ? <IconArrowBackUp size={15} aria-hidden="true" /> : <IconSend2 size={15} aria-hidden="true" />}
              {sent ? "Undo" : "Send to Mac"}
            </button>
          </div>
        </PhoneFrame>
        <div className="absolute top-[6%] right-[4%] w-[min(20rem,52%)] rounded-xl bg-[#f5f5f7]/95 p-3 text-[#1d1d1f] shadow-[0_20px_50px_-16px_rgba(0,0,0,0.6)]">
          <div className="mb-2.5 flex items-center gap-2.5 text-[0.82rem]">
            <TrafficLights />
            <span className="font-semibold">Downloads</span>
          </div>
          <div className="grid min-h-[5.5rem] grid-cols-2 gap-2 sm:grid-cols-3">
            {sent ? (
              photos.map((p) => (
                <div key={p.kind}>
                  <motion.div layoutId={`photo-${p.kind}`} transition={spring} className="overflow-hidden rounded-md">
                    <Photo kind={p.kind} className="block aspect-square w-full" />
                  </motion.div>
                  <p className="mt-1 truncate text-[0.68rem] text-black/55">{p.name}</p>
                </div>
              ))
            ) : (
              <p className="col-span-full self-center text-center text-[0.78rem] text-black/45">Photos you send land here</p>
            )}
          </div>
        </div>
      </LayoutGroup>
    </Stage>
  )
}

/* 16:00 — the whole phone */
export function FullModeScene() {
  const [typed, setTyped] = useState("")
  const [msgs, setMsgs] = useState<string[]>([])
  const input = useRef<HTMLInputElement>(null)
  const send = (e: FormEvent) => {
    e.preventDefault()
    if (!typed.trim()) return
    setMsgs((m) => [...m, typed.trim()].slice(-2))
    setTyped("")
  }
  return (
    <Stage>
      <div className="absolute inset-0 flex items-center justify-center gap-[4%] px-[5%] pb-[3%]">
        <div className="flex h-[92%] flex-col overflow-hidden rounded-xl bg-[#1e2033]/90 shadow-[0_24px_60px_-16px_rgba(0,0,0,0.7)] ring-1 ring-white/15 backdrop-blur" style={{ aspectRatio: "9 / 17" }}>
          <div className="flex items-center justify-between px-3 py-2 text-[0.72rem] text-white/80">
            <TrafficLights />
            <span className="font-medium">Asha's phone</span>
            <span className="w-6" />
          </div>
          <div className="mx-2 flex-1 overflow-hidden rounded-[0.9rem] text-[clamp(8px,1.35vw,11px)]" onClick={() => input.current?.focus()}>
            <ChatScreen
              extra={msgs.map((m, i) => (
                <motion.p key={`${i}-${m}`} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} className="max-w-[80%] self-end rounded-[1em] rounded-br-[0.3em] bg-[#5b4fd6] px-[0.8em] py-[0.5em] text-white">
                  {m}
                </motion.p>
              ))}
            />
          </div>
          <div className="flex justify-around px-2 py-2 text-white/75" aria-label="Phone controls">
            {[
              [IconArrowBackUp, "Back"],
              [IconCircle, "Home"],
              [IconSquare, "Recents"],
              [IconRotateClockwise2, "Rotate"],
              [IconVolume, "Volume"],
            ].map(([Icon, label]) => {
              const I = Icon as typeof IconCircle
              return (
                <span key={label as string} title={label as string} className="grid h-6 w-6 place-items-center rounded-md hover:bg-white/10">
                  <I size={14} aria-hidden="true" />
                </span>
              )
            })}
          </div>
        </div>
        <form onSubmit={send} className="hidden w-[38%] sm:block">
          <Glass className="p-4">
            <label htmlFor="fm-type" className="text-[0.85rem] font-medium">
              Type with the Mac's keyboard
            </label>
            <div className="mt-2.5 flex gap-2">
              <input
                ref={input}
                id="fm-type"
                value={typed}
                onChange={(e) => setTyped(e.target.value)}
                placeholder="Emoji work too 🥟"
                autoComplete="off"
                className="h-9 min-w-0 flex-1 rounded-lg bg-white/10 px-3 text-[0.88rem] text-white placeholder:text-white/45 focus:bg-white/15 focus:outline-none"
              />
              <button type="submit" className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-iris text-night" aria-label="Send to the phone">
                <IconSend2 size={17} aria-hidden="true" />
              </button>
            </div>
            <Hint>It goes into the phone's chat, as if you typed it there.</Hint>
          </Glass>
        </form>
      </div>
    </Stage>
  )
}
