// One heading pattern for every section, so the page keeps a single rhythm: the title on the
// left and the lede on the right on wide screens, or both centred.
import type { ReactNode } from "react"
import { cn } from "@/lib/utils"

export function SectionHead({ id, title, lede, center, className }: { id: string; title: ReactNode; lede?: ReactNode; center?: boolean; className?: string }) {
  return (
    <header
      className={cn(
        center ? "mx-auto max-w-[46rem] text-center" : "grid items-end gap-6 lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)] lg:gap-16",
        className,
      )}
    >
      <h2 id={id} className="display text-[clamp(2.4rem,5.4vw,4.4rem)]">
        {title}
      </h2>
      {lede && <p className={cn("text-[1.125rem] leading-relaxed text-haze", center ? "mx-auto mt-6 max-w-[34rem]" : "max-w-[30rem] lg:justify-self-end")}>{lede}</p>}
    </header>
  )
}

/** Vertical rhythm shared by every section after the hero. */
export const sectionPad = "py-28 lg:py-40"
