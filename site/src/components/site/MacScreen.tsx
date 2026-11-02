// The laptop's screen in the hero: a Mac desktop with the phone open in a window (Full mode),
// a phone notification arriving as a Mac notification, and photos that came across.
import { AppIcon, Avatar, ChatScreen, MenuBar, Photo, TrafficLights, Wallpaper } from "./parts"

export function MacScreen() {
  return (
    <div className="relative h-full w-full overflow-hidden bg-[#151b45] font-sans select-none" aria-hidden="true">
      <Wallpaper />
      <MenuBar />

      {/* The phone, in a Mac window */}
      <div className="absolute top-[34px] left-[46px] w-[150px] overflow-hidden rounded-[9px] bg-[#1e2033]/90 shadow-[0_18px_40px_-10px_rgba(0,0,0,0.6)] ring-1 ring-white/15 backdrop-blur">
        <div className="flex items-center justify-between px-[7px] py-[5px] text-[6.5px] text-white/80">
          <TrafficLights />
          <span className="font-medium">Asha's phone</span>
          <span className="w-[21px]" />
        </div>
        <div className="mx-[6px] h-[236px] overflow-hidden rounded-[10px] text-[9px]">
          <ChatScreen />
        </div>
        <div className="flex justify-center gap-[14px] py-[6px] text-white/70">
          <svg viewBox="0 0 24 24" className="h-[8px] w-[8px]" fill="currentColor"><path d="M16 5.5L7 12l9 6.5z" /></svg>
          <svg viewBox="0 0 24 24" className="h-[8px] w-[8px]" fill="none" stroke="currentColor" strokeWidth="2.6"><circle cx="12" cy="12" r="6.5" /></svg>
          <svg viewBox="0 0 24 24" className="h-[8px] w-[8px]" fill="none" stroke="currentColor" strokeWidth="2.6"><rect x="6" y="6" width="12" height="12" rx="2" /></svg>
        </div>
      </div>

      {/* Phone notification, shown by macOS */}
      <div className="hero-notif absolute top-[22px] right-[10px] w-[176px] rounded-[10px] bg-[#2a2d45]/80 p-[7px] text-white shadow-[0_10px_30px_-8px_rgba(0,0,0,0.6)] ring-1 ring-white/15 backdrop-blur-xl">
        <div className="flex gap-[6px]">
          <Avatar letter="P" className="h-[20px] w-[20px] text-[8px]" />
          <div className="min-w-0 flex-1 leading-tight">
            <div className="flex justify-between text-[7.5px]">
              <span className="font-semibold">Priya</span>
              <span className="text-white/55">now</span>
            </div>
            <p className="text-[7px] text-white/60">Messages, on Asha's phone</p>
            <p className="mt-[2px] text-[7.5px] text-white/90">Running a bit late, start without me?</p>
          </div>
        </div>
        <div className="mt-[6px] grid grid-cols-2 gap-[4px] text-center text-[7px] font-medium">
          <span className="rounded-[5px] bg-white/15 py-[3px]">Reply</span>
          <span className="rounded-[5px] bg-white/15 py-[3px]">Mark as read</span>
        </div>
      </div>

      {/* Photos that arrived from the phone */}
      <div className="absolute right-[18px] bottom-[52px] w-[150px] rounded-[9px] bg-[#f5f5f7]/95 p-[7px] text-[#1d1d1f] shadow-[0_14px_34px_-10px_rgba(0,0,0,0.55)]">
        <div className="mb-[5px] flex items-center gap-[6px] text-[7px]">
          <TrafficLights />
          <span className="font-semibold">Downloads</span>
        </div>
        <div className="grid grid-cols-3 gap-[4px]">
          {(["ferry", "dumplings", "cliffs"] as const).map((k) => (
            <div key={k}>
              <Photo kind={k} className="aspect-square w-full rounded-[4px]" />
              <p className="mt-[2px] truncate text-[5.5px] text-black/55">IMG_{k === "ferry" ? "2041" : k === "dumplings" ? "2042" : "2043"}.jpg</p>
            </div>
          ))}
        </div>
      </div>

      {/* Dock */}
      <div className="absolute inset-x-0 bottom-[6px] flex justify-center">
        <div className="flex items-end gap-[5px] rounded-[9px] bg-white/15 px-[6px] py-[4px] ring-1 ring-white/15 backdrop-blur-md">
          {["#5aa3f0", "#ff9f43", "#34c759", "#af52de", "#ff375f"].map((c) => (
            <span key={c} className="h-[18px] w-[18px] rounded-[5px]" style={{ background: `linear-gradient(160deg, ${c}, color-mix(in oklab, ${c} 60%, black))` }} />
          ))}
          <span className="mx-[1px] h-[16px] w-px bg-white/25" />
          <span className="relative">
            <AppIcon className="h-[18px] w-[18px]" />
            <i className="absolute -bottom-[3px] left-1/2 h-[2px] w-[2px] -translate-x-1/2 rounded-full bg-white/80" />
          </span>
        </div>
      </div>
    </div>
  )
}
