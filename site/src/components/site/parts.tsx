// Drawn pieces of the two apps, shared by the hero laptop and the day story. Names and
// messages are made up; the layouts and wording follow the real apps.
import { type ReactNode } from "react"
import { cn } from "@/lib/utils"

export function LogoMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 32 32" aria-hidden="true" className={className}>
      <rect x="4.5" y="8.5" width="8" height="15" rx="2.2" fill="none" stroke="currentColor" strokeWidth="2" />
      <rect x="17.5" y="8.5" width="11" height="9" rx="1.6" fill="none" stroke="currentColor" strokeWidth="2" />
      <path d="M21 22.5h4" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
      <path d="M12.5 15.5h5" stroke="#d4ff3f" strokeWidth="3" />
    </svg>
  )
}

export function AppIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 32 32" aria-hidden="true" className={className}>
      <rect width="32" height="32" rx="7.5" fill="#ff2dab" />
      <rect x="5.5" y="9" width="7.5" height="14" rx="2" fill="none" stroke="#0b0b0b" strokeWidth="1.8" />
      <rect x="17.5" y="9" width="10" height="8.5" rx="1.5" fill="none" stroke="#0b0b0b" strokeWidth="1.8" />
      <path d="M20.5 22.5h4" stroke="#0b0b0b" strokeWidth="1.8" strokeLinecap="round" />
      <path d="M13 15.5h4.5" stroke="#0b0b0b" strokeWidth="2.4" strokeLinecap="round" />
    </svg>
  )
}

/** A flat, poster-like desktop picture in the site's colours. */
export function Wallpaper({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 400 300" preserveAspectRatio="xMidYMid slice" aria-hidden="true" className={cn("absolute inset-0 h-full w-full", className)}>
      <rect width="400" height="300" fill="#141414" />
      <circle cx="285" cy="150" r="92" fill="#ff2dab" />
      <path d="M0 205 C90 170 170 175 250 200 S360 185 400 192 V300 H0Z" fill="#d4ff3f" />
      <path d="M0 238 C100 214 190 222 270 238 S370 226 400 230 V300 H0Z" fill="#0b0b0b" />
      <path d="M40 60h70M40 72h44" stroke="#2a2a2a" strokeWidth="4" strokeLinecap="round" />
    </svg>
  )
}

export function MenuBar({ className }: { className?: string }) {
  return (
    <div className={cn("relative z-10 flex h-[14px] items-center justify-between bg-black/25 px-2 whitespace-nowrap text-[7px] font-medium text-white backdrop-blur-md", className)}>
      <div className="flex items-center gap-2">
        <LogoMark className="h-[9px] w-[9px] text-white" />
        <span className="font-semibold">Finder</span>
        <span>File</span>
        <span>Edit</span>
        <span>View</span>
        <span>Window</span>
      </div>
      <div className="flex items-center gap-2">
        <span className="flex items-center gap-[3px]">
          <svg viewBox="0 0 24 24" className="h-[8px] w-[8px]" fill="none" stroke="currentColor" strokeWidth="2.4">
            <rect x="7" y="2.5" width="10" height="19" rx="2.2" />
          </svg>
          82%
        </span>
        <svg viewBox="0 0 24 24" className="h-[8px] w-[8px]" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round">
          <path d="M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.5 16a5 5 0 0 1 7 0" />
        </svg>
        <span>Tue 10:24</span>
      </div>
    </div>
  )
}

export function TrafficLights() {
  return (
    <span className="flex gap-[3px]" aria-hidden="true">
      <i className="h-[5px] w-[5px] rounded-full bg-[#ff5f57]" />
      <i className="h-[5px] w-[5px] rounded-full bg-[#febc2e]" />
      <i className="h-[5px] w-[5px] rounded-full bg-[#28c840]" />
    </span>
  )
}

export function Avatar({ letter, className }: { letter: string; className?: string }) {
  return (
    <span className={cn("grid shrink-0 place-items-center rounded-full bg-lime font-semibold text-night", className)}>
      {letter}
    </span>
  )
}

/** An Android chat screen: header, a few bubbles, a compose bar. Sized by its container. */
export function ChatScreen({ extra, className }: { extra?: ReactNode; className?: string }) {
  return (
    <div className={cn("flex h-full flex-col bg-[#f2f2f2] text-[#1c1b22]", className)}>
      <div className="flex items-center justify-between px-[8%] pt-[6%] text-[0.55em] font-medium">
        <span>10:24</span>
        <span>82%</span>
      </div>
      <div className="flex items-center gap-[0.5em] border-b border-black/5 px-[7%] py-[5%]">
        <Avatar letter="P" className="h-[1.9em] w-[1.9em] text-[0.7em]" />
        <span className="text-[0.85em] font-semibold">Priya</span>
      </div>
      <div className="flex flex-1 flex-col justify-end gap-[0.45em] px-[6%] pb-[5%] text-[0.72em] leading-snug">
        <p className="max-w-[80%] self-start rounded-[1em] rounded-bl-[0.3em] bg-white px-[0.8em] py-[0.5em] shadow-sm">Running a bit late, start without me?</p>
        <p className="max-w-[80%] self-end rounded-[1em] rounded-br-[0.3em] bg-[#ff2dab] px-[0.8em] py-[0.5em] text-[#0b0b0b]">No rush, see you there</p>
        <p className="max-w-[80%] self-start rounded-[1em] rounded-bl-[0.3em] bg-white px-[0.8em] py-[0.5em] shadow-sm">Ordering the dumplings now</p>
        {extra}
      </div>
      <div className="mx-[6%] mb-[7%] rounded-full bg-white px-[0.9em] py-[0.55em] text-[0.7em] text-black/40">Message</div>
    </div>
  )
}

export function PhoneFrame({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cn("relative rounded-[1.6em] bg-[#101014] p-[0.35em] shadow-[0_24px_60px_-18px_rgba(0,0,0,0.75)] ring-1 ring-white/10", className)}>
      <div className="relative h-full overflow-hidden rounded-[1.3em]">
        <span className="absolute top-[1.6%] left-1/2 z-10 h-[0.5em] w-[0.5em] -translate-x-1/2 rounded-full bg-black" aria-hidden="true" />
        {children}
      </div>
    </div>
  )
}

/* Fictional photos, drawn as flat SVG. */
export function Photo({ kind, className }: { kind: "ferry" | "dumplings" | "cliffs"; className?: string }) {
  return (
    <svg viewBox="0 0 120 120" aria-hidden="true" className={className}>
      {kind === "ferry" && (
        <>
          <rect width="120" height="120" fill="#f6b48f" />
          <rect width="120" height="44" fill="#f39a6b" />
          <circle cx="84" cy="54" r="20" fill="#ffe1a6" />
          <rect y="66" width="120" height="54" fill="#2b3f8f" />
          <path d="M0 74h120M0 84h120M0 96h120" stroke="#4b63b8" strokeWidth="3" />
          <path d="M22 66l6-12h40l8 12z" fill="#151820" />
          <rect x="36" y="44" width="22" height="10" fill="#151820" />
        </>
      )}
      {kind === "dumplings" && (
        <>
          <rect width="120" height="120" fill="#1d2a24" />
          <circle cx="60" cy="62" r="46" fill="#e9e3d3" />
          <circle cx="60" cy="62" r="38" fill="#f5f1e6" />
          <path d="M34 64c6-14 22-14 26 0zM58 52c6-14 22-14 26 0zM48 80c6-14 22-14 26 0z" fill="#f2d7a4" stroke="#c99a5a" strokeWidth="2" />
          <path d="M8 18l40 22M14 10l40 22" stroke="#7b4a26" strokeWidth="4" strokeLinecap="round" />
        </>
      )}
      {kind === "cliffs" && (
        <>
          <rect width="120" height="120" fill="#bfe3f2" />
          <path d="M0 120V64l26-20 18 10 22-24 24 30 30-14v74z" fill="#3f6b3a" />
          <path d="M0 120V90l40-12 30 10 50-8v40z" fill="#264a2c" />
          <circle cx="26" cy="24" r="10" fill="#fff6c9" />
        </>
      )}
    </svg>
  )
}
