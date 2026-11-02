import {
  IconBell,
  IconClipboard,
  IconDeviceMobileVibration,
  IconFocus2,
  IconHandFinger,
  IconLock,
  IconMusic,
  IconPhoneCall,
  IconPhoto,
  IconScreenshot,
  IconShieldLock,
  IconStatusChange,
  IconTransfer,
  IconUserCircle,
  type Icon,
} from "@tabler/icons-react"

type Feature = { icon: Icon; name: string; text: string }

const groups: { title: string; items: Feature[] }[] = [
  {
    title: "On your Mac, as it happens",
    items: [
      { icon: IconBell, name: "Notifications with actions", text: "Real Mac notifications, with their buttons and inline reply. Pick which apps come through." },
      { icon: IconShieldLock, name: "One-time codes", text: "Copy code, straight from the notification. It never reads your SMS." },
      { icon: IconPhoneCall, name: "Calls", text: "Answer, decline, mute or hang up from the Mac. The audio stays on the phone." },
      { icon: IconUserCircle, name: "Caller ID", text: "Contacts sync to an encrypted store in the Mac app. One switch turns it off and wipes it." },
    ],
  },
  {
    title: "Moving things across",
    items: [
      { icon: IconClipboard, name: "Shared clipboard", text: "Copy on the Mac, paste on the phone, and back. Text a password manager marks as secret is not sent." },
      { icon: IconTransfer, name: "Files both ways", text: "Drag onto the Phone window, use the Share menu, or Send to Mac. Browse the phone's files from the Mac." },
      { icon: IconScreenshot, name: "Instant screenshots", text: "Take one on the phone and it lands on the Desktop, in Downloads or on the clipboard." },
      { icon: IconPhoto, name: "Recent photos", text: "The newest photos and videos as thumbnails. Drag them out into any app." },
    ],
  },
  {
    title: "Control and context",
    items: [
      { icon: IconMusic, name: "Music controller", text: "Track, artist and artwork, with play, pause, skip and volume." },
      { icon: IconFocus2, name: "Do Not Disturb and Focus", text: "A Focus on the Mac turns on Do Not Disturb on the phone, and the other way round." },
      { icon: IconDeviceMobileVibration, name: "Find my phone", text: "Ring it at full volume from the Mac, even when it's on silent." },
      { icon: IconStatusChange, name: "Phone status in the menu bar", text: "Battery, signal, Wi-Fi or mobile data, and whether it's connected." },
      { icon: IconLock, name: "Auto-lock when you walk away", text: "Opt-in. The Mac locks when the phone's Bluetooth signal stays away. It never unlocks it." },
      { icon: IconHandFinger, name: "Trackpad and presentation remote", text: "Move the Mac's pointer from the phone, or change slides with a laser dot." },
    ],
  },
]

export function Features() {
  return (
    <section id="features" aria-labelledby="features-h" className="relative py-24 lg:py-36">
      <div className="wrap">
        <h2 id="features-h" className="display max-w-[18ch] text-[clamp(2.2rem,5vw,4rem)]">
          Everything your phone does, on the Mac you're already using.
        </h2>
        <p className="mt-6 max-w-[38rem] text-lg text-haze">
          Every feature here is built and in testing. None of them needs developer settings on the phone, except Full mode.
        </p>

        <div className="mt-16 grid gap-x-12 gap-y-14 md:grid-cols-2 lg:grid-cols-3">
          {groups.map((g) => (
            <div key={g.title} className="border-t border-line pt-6">
              <h3 className="font-display text-[1.3rem] font-semibold tracking-tight">{g.title}</h3>
              <ul className="mt-6 space-y-6">
                {g.items.map(({ icon: I, name, text }) => (
                  <li key={name} className="group flex gap-4">
                    <span className="mt-0.5 grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-white/[0.04] text-teal ring-1 ring-white/[0.07] transition-colors group-hover:bg-teal/10">
                      <I size={19} stroke={1.6} aria-hidden="true" />
                    </span>
                    <div>
                      <p className="font-medium text-mist">{name}</p>
                      <p className="mt-1 text-[0.95rem] leading-relaxed text-haze">{text}</p>
                    </div>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
