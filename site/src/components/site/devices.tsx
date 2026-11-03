// Realistic hardware for the day story: a MacBook seen from the front and an Android phone.
// Sizes are in em, so the whole set scales with the font size of the stage it sits in.
import { forwardRef, type ReactNode } from "react"
import { motion } from "motion/react"
import { cn } from "@/lib/utils"

/** A MacBook in space black, front on. `children` is the screen. */
export const MacBook = forwardRef<HTMLDivElement, { children: ReactNode; className?: string }>(function MacBook({ children, className }, ref) {
  return (
    <div className={cn("relative", className)}>
      {/* Lid */}
      <div className="relative rounded-t-[1.4em] rounded-b-[0.3em] bg-[#0a0a0a] p-[0.9em] pb-[1.1em] shadow-[inset_0_0_0_0.09em_#3a3a3c,inset_0_0.15em_0.3em_rgba(255,255,255,0.08)]">
        <div ref={ref} className="relative aspect-[16/10] overflow-hidden rounded-[0.35em] bg-black">
          {children}
          {/* Glass: a faint diagonal sheen across the panel */}
          <div aria-hidden="true" className="pointer-events-none absolute inset-0 z-40 bg-[linear-gradient(115deg,rgba(255,255,255,0.07)_0%,rgba(255,255,255,0.02)_28%,transparent_42%)]" />
        </div>
        {/* Camera housing */}
        <span aria-hidden="true" className="absolute top-[0.9em] left-1/2 z-50 h-[0.95em] w-[5.5em] -translate-x-1/2 rounded-b-[0.55em] bg-[#0a0a0a]">
          <i className="absolute top-[0.28em] left-1/2 h-[0.36em] w-[0.36em] -translate-x-1/2 rounded-full bg-[#1d2430] ring-[0.06em] ring-[#2c3340]" />
        </span>
      </div>
      {/* Base: the hinge lip and the front edge */}
      <div aria-hidden="true" className="relative mx-[-6.5%] h-[1.15em] rounded-t-[0.2em] rounded-b-[1.2em_0.9em] bg-[linear-gradient(180deg,#4a4a4d_0%,#2c2c2e_35%,#1b1b1d_70%,#0e0e0f_100%)] shadow-[0_0.1em_0_#5a5a5e_inset]">
        <span className="absolute top-0 left-1/2 h-[0.42em] w-[16%] -translate-x-1/2 rounded-b-[0.5em] bg-[linear-gradient(180deg,#18181a,#262628)]" />
      </div>
      {/* Contact shadow */}
      <div aria-hidden="true" className="absolute right-[-4%] -bottom-[1.6em] left-[-4%] h-[1.6em] rounded-[50%] bg-black/70 blur-[0.6em]" />
    </div>
  )
})

/** An Android phone with a metal rim, side keys and a punch-hole camera. `children` is the screen. */
export const AndroidPhone = forwardRef<HTMLDivElement, { children: ReactNode; className?: string; buzz?: number }>(function AndroidPhone(
  { children, className, buzz = 0 },
  ref,
) {
  return (
    <motion.div
      key={buzz}
      animate={buzz ? { x: [0, -3, 3, -3, 3, -2, 2, 0] } : undefined}
      transition={{ duration: 0.5 }}
      className={cn("relative", className)}
    >
      {/* Side keys */}
      <span aria-hidden="true" className="absolute top-[22%] -right-[0.22em] h-[9%] w-[0.3em] rounded-r-[0.2em] bg-[linear-gradient(90deg,#2a2a2c,#5a5a5e)]" />
      <span aria-hidden="true" className="absolute top-[36%] -right-[0.22em] h-[15%] w-[0.3em] rounded-r-[0.2em] bg-[linear-gradient(90deg,#2a2a2c,#5a5a5e)]" />
      {/* Rim */}
      <div className="relative rounded-[2.1em] bg-[linear-gradient(145deg,#6b6b70_0%,#2b2b2e_22%,#141416_55%,#3c3c40_100%)] p-[0.28em] shadow-[0_2.2em_3em_-1.2em_rgba(0,0,0,0.9),0_0.6em_1.2em_-0.4em_rgba(0,0,0,0.7)]">
        <div className="rounded-[1.85em] bg-black p-[0.38em]">
          <div ref={ref} className="relative aspect-[9/19.5] overflow-hidden rounded-[1.5em] bg-[#f2f2f2]">
            {children}
            <span aria-hidden="true" className="absolute top-[1.6%] left-1/2 z-40 h-[0.7em] w-[0.7em] -translate-x-1/2 rounded-full bg-black ring-[0.08em] ring-[#1b1b1b]" />
            <div aria-hidden="true" className="pointer-events-none absolute inset-0 z-40 bg-[linear-gradient(125deg,rgba(255,255,255,0.18)_0%,rgba(255,255,255,0.04)_30%,transparent_45%)]" />
          </div>
        </div>
      </div>
    </motion.div>
  )
})
