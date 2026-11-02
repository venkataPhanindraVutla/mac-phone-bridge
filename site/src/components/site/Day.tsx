import { useEffect, useRef, useState, type ReactNode } from "react"
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react"
import { cn } from "@/lib/utils"
import { CallScene, CodeScene, FullModeScene, MessageScene, PhotosScene } from "./scenes"

type Moment = { time: string; title: string; body: ReactNode; try: string; scene: () => ReactNode }

const moments: Moment[] = [
  {
    time: "9:02",
    title: "A message, answered from the Mac.",
    body: "Phone notifications show up as real Mac notifications, with their buttons and inline reply. You pick which apps come through. Dismiss one on either device and it's gone on both.",
    try: "Type a reply to Priya and send it.",
    scene: () => <MessageScene />,
  },
  {
    time: "9:40",
    title: "The sign-in code, one click away.",
    body: "When a notification holds a one-time code, the Mac offers Copy code. It reads the notification text only, never your SMS.",
    try: "Copy the code.",
    scene: () => <CodeScene />,
  },
  {
    time: "11:15",
    title: "The call, taken at your desk.",
    body: "See who's calling, then answer, decline, mute or hang up from the Mac. The audio stays on your phone. Caller names come from your contacts, kept encrypted inside the Mac app.",
    try: "Answer, then hang up.",
    scene: () => <CallScene />,
  },
  {
    time: "14:30",
    title: "Sunday's photos, already on the Mac.",
    body: "Send to Mac from the phone's share sheet, or drag files onto the phone from the Mac. Screenshots you take on the phone land on the Mac by themselves, and the clipboard goes both ways.",
    try: "Send the photos to the Mac.",
    scene: () => <PhotosScene />,
  },
  {
    time: "16:00",
    title: "And when you need the whole phone.",
    body: (
      <>
        Full mode puts the phone's screen in a Mac window, with its sound. Click to tap, scroll to scroll, and type into any app with the Mac's keyboard. On 5 GHz Wi‑Fi
        the targets are under 80 ms of delay at 60 frames a second. It needs Android 11 and Wireless debugging, switched on once.
      </>
    ),
    try: "Type a message with your keyboard.",
    scene: () => <FullModeScene />,
  },
]

function useIsDesktop() {
  const [desktop, setDesktop] = useState(() => typeof window !== "undefined" && window.matchMedia("(min-width: 1024px)").matches)
  useEffect(() => {
    const q = window.matchMedia("(min-width: 1024px)")
    const update = () => setDesktop(q.matches)
    q.addEventListener("change", update)
    return () => q.removeEventListener("change", update)
  }, [])
  return desktop
}

function Step({ moment, index, active, onActive, inlineScene }: { moment: Moment; index: number; active: boolean; onActive: (i: number) => void; inlineScene: boolean }) {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { margin: "-45% 0px -45% 0px" })
  useEffect(() => {
    if (inView) onActive(index)
  }, [inView, index, onActive])

  return (
    <div ref={ref} className="py-14 lg:flex lg:min-h-[78vh] lg:flex-col lg:justify-center lg:py-0">
      <p
        className={cn(
          "font-display text-[clamp(3rem,7vw,5.5rem)] leading-none font-medium tracking-[-0.04em] tabular-nums transition-colors duration-500",
          active || inlineScene ? "text-lime" : "text-line",
        )}
      >
        <time>{moment.time}</time>
      </p>
      <h3 className={cn("display mt-5 text-[clamp(1.7rem,3vw,2.4rem)] transition-opacity duration-500", active || inlineScene ? "opacity-100" : "opacity-40")}>{moment.title}</h3>
      <p className={cn("mt-4 max-w-[34rem] text-haze transition-opacity duration-500", active || inlineScene ? "opacity-100" : "opacity-40")}>{moment.body}</p>
      <p className="mt-4 text-[0.95rem] text-pink">{moment.try}</p>
      {inlineScene && <div className="mt-8">{moment.scene()}</div>}
    </div>
  )
}

export function Day() {
  const [active, setActive] = useState(0)
  const desktop = useIsDesktop()
  const reduce = useReducedMotion()

  return (
    <section id="day" aria-labelledby="day-h" className="relative pt-10 pb-24 lg:pb-40">
      <div className="wrap">
        <header className="max-w-[46rem]">
          <h2 id="day-h" className="display text-[clamp(2.4rem,6vw,4.5rem)]">
            Your phone can stay in your bag.
          </h2>
          <p className="mt-6 max-w-[38rem] text-lg text-haze">
            Here's a working day with it. Every screen below behaves like the apps do, so go ahead and use them.
          </p>
        </header>

        <div className="mt-10 lg:mt-16 lg:grid lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:gap-16">
          <div>
            {moments.map((m, i) => (
              <Step key={m.time} moment={m} index={i} active={active === i} onActive={setActive} inlineScene={!desktop} />
            ))}
          </div>
          {desktop && (
            <div className="relative">
              <div className="sticky top-[calc(50vh-min(22rem,40vh))] flex h-[min(44rem,80vh)] items-center">
                <AnimatePresence mode="wait" initial={false}>
                  <motion.div
                    key={active}
                    className="w-full"
                    initial={reduce ? { opacity: 0 } : { opacity: 0, y: 24, scale: 0.98, filter: "blur(6px)" }}
                    animate={{ opacity: 1, y: 0, scale: 1, filter: "blur(0px)" }}
                    exit={reduce ? { opacity: 0 } : { opacity: 0, y: -16, scale: 0.98, filter: "blur(6px)" }}
                    transition={{ duration: 0.45, ease: [0.22, 1, 0.36, 1] }}
                  >
                    {moments[active].scene()}
                  </motion.div>
                </AnimatePresence>
              </div>
            </div>
          )}
        </div>
      </div>
    </section>
  )
}
