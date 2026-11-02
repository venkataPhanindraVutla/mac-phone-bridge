import { motion, useReducedMotion } from "motion/react"
import { IconCloudOff, IconDeviceLaptop, IconDeviceMobile } from "@tabler/icons-react"

const path = "M 92 120 C 220 40, 380 40, 508 120"

function Bridge() {
  const reduce = useReducedMotion()
  return (
    <div className="relative mx-auto w-full max-w-[40rem]">
      <svg viewBox="0 0 600 200" className="w-full" aria-hidden="true">
        <defs>
          <linearGradient id="bridge-line" x1="92" x2="508" y1="0" y2="0" gradientUnits="userSpaceOnUse">
            <stop stopColor="#6fe3c1" />
            <stop offset="1" stopColor="#a99bff" />
          </linearGradient>
          <filter id="bridge-glow" x="-20%" y="-50%" width="140%" height="200%">
            <feGaussianBlur stdDeviation="6" />
          </filter>
        </defs>
        {/* The route data never takes: up to a server and back. */}
        <path d="M 92 120 L 300 22 L 508 120" fill="none" stroke="#3a4570" strokeWidth="1.5" strokeDasharray="4 7" />
        <path d={path} fill="none" stroke="url(#bridge-line)" strokeWidth="10" opacity="0.35" filter="url(#bridge-glow)" />
        <path d={path} fill="none" stroke="url(#bridge-line)" strokeWidth="2.5" strokeLinecap="round" />
        {!reduce &&
          [0, 1.4].map((delay) => (
            <motion.circle
              key={delay}
              r="5"
              fill="#fff"
              style={{ offsetPath: `path("${path}")`, filter: "drop-shadow(0 0 6px #fff)" }}
              initial={{ offsetDistance: "0%", opacity: 0 }}
              animate={{ offsetDistance: ["0%", "100%"], opacity: [0, 1, 1, 0] }}
              transition={{ duration: 2.8, delay, repeat: Infinity, ease: "easeInOut" }}
            />
          ))}
      </svg>
      <div className="absolute top-[64%] left-[15.3%] -translate-x-1/2 -translate-y-1/2 text-center">
        <span className="grid h-14 w-14 place-items-center rounded-2xl bg-deep text-teal ring-1 ring-teal/30 sm:h-16 sm:w-16">
          <IconDeviceMobile size={28} stroke={1.5} aria-hidden="true" />
        </span>
        <p className="mt-2 text-sm whitespace-nowrap text-haze">Your phone</p>
      </div>
      <div className="absolute top-[64%] left-[84.7%] -translate-x-1/2 -translate-y-1/2 text-center">
        <span className="grid h-14 w-14 place-items-center rounded-2xl bg-deep text-iris ring-1 ring-iris/30 sm:h-16 sm:w-16">
          <IconDeviceLaptop size={28} stroke={1.5} aria-hidden="true" />
        </span>
        <p className="mt-2 text-sm whitespace-nowrap text-haze">Your Mac</p>
      </div>
      <div className="absolute top-[11%] left-1/2 -translate-x-1/2 -translate-y-1/2 text-center text-haze/60">
        <span className="mx-auto grid h-10 w-10 place-items-center rounded-full bg-night ring-1 ring-line">
          <IconCloudOff size={20} stroke={1.5} aria-hidden="true" />
        </span>
      </div>
      <p className="mt-6 text-center text-sm text-haze sm:mt-2">Mutual TLS 1.3, on your own network. No server in between.</p>
    </div>
  )
}

const steps = [
  ["Pair once", "The Mac shows a QR code. Scan it with the phone, then check that the same 6-digit code shows on both screens."],
  ["Connect directly", "From then on they find each other on the same network and connect with certificates pinned at pairing. An unpaired device can't connect."],
  ["Stay on your devices", "Nothing is relayed through a server. Remove the pairing from either side whenever you like."],
] as const

const promises = [
  ["No account.", "Nothing to sign up for, nothing to sign in to."],
  ["No cloud.", "Your data stays on your two devices."],
  ["No telemetry.", "No analytics. If crash reporting is ever added, it will be opt-in."],
  ["Never reads SMS.", "The Android app asks for no SMS permission."],
  ["Encrypted at rest.", "Synced contacts are stored encrypted on the Mac, and wiped when you turn caller ID off or unpair."],
  ["Open source.", "Every line is on GitHub under Apache-2.0, for anyone to read."],
] as const

export function Privacy() {
  return (
    <section id="privacy" aria-labelledby="privacy-h" className="relative overflow-x-clip py-24 lg:py-36">
      <div aria-hidden="true" className="pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-line to-transparent" />
      <div className="wrap">
        <div className="mx-auto max-w-[44rem] text-center">
          <h2 id="privacy-h" className="display text-[clamp(2.2rem,5vw,4rem)]">
            Phone to Mac, and nothing in between.
          </h2>
          <p className="mx-auto mt-6 max-w-[34rem] text-lg text-haze">
            The two apps find each other on your local network and talk directly. There is no server, so there's nothing to sign in to.
          </p>
        </div>

        <div className="mt-14">
          <Bridge />
        </div>

        <ol className="mx-auto mt-16 grid max-w-[64rem] gap-10 md:grid-cols-3">
          {steps.map(([title, text]) => (
            <li key={title}>
              <h3 className="font-display text-[1.25rem] font-semibold tracking-tight">{title}</h3>
              <p className="mt-2 text-[0.97rem] leading-relaxed text-haze">{text}</p>
            </li>
          ))}
        </ol>

        <div className="mx-auto mt-20 max-w-[64rem] rounded-[1.75rem] bg-gradient-to-br from-teal/[0.07] via-transparent to-iris/[0.09] p-px">
          <div className="rounded-[calc(1.75rem-1px)] bg-deep/80 px-6 py-10 sm:px-10">
            <h3 className="font-display text-[1.6rem] font-semibold tracking-tight">Private by design</h3>
            <dl className="mt-8 grid gap-x-10 gap-y-6 sm:grid-cols-2 lg:grid-cols-3">
              {promises.map(([term, text]) => (
                <div key={term}>
                  <dt className="font-medium text-mist">{term}</dt>
                  <dd className="mt-1 text-[0.95rem] leading-relaxed text-haze">{text}</dd>
                </div>
              ))}
            </dl>
          </div>
        </div>
      </div>
    </section>
  )
}
