import { useState } from "react"
import { IconCheck, IconChevronDown, IconCopy } from "@tabler/icons-react"
import { cn } from "@/lib/utils"
import { BRAND, REPO, docs } from "@/config"
import { LogoMark } from "./parts"

const cloneCommand = `git clone ${REPO}.git\ncd mac-phone-bridge\n# then follow "Build it" in README.md`

function Spec({ title, rows }: { title: string; rows: [string, string][] }) {
  return (
    <div>
      <h3 className="font-display text-[1.35rem] font-semibold tracking-tight">{title}</h3>
      <dl className="mt-5 divide-y divide-line border-y border-line">
        {rows.map(([k, v]) => (
          <div key={k} className="grid grid-cols-[8.5rem_1fr] gap-4 py-3.5 text-[0.97rem]">
            <dt className="text-haze">{k}</dt>
            <dd>{v}</dd>
          </div>
        ))}
      </dl>
    </div>
  )
}

export function Setup() {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(cloneCommand.split("\n").slice(0, 2).join("\n"))
      setCopied(true)
      setTimeout(() => setCopied(false), 1800)
    } catch {
      setCopied(false)
    }
  }
  return (
    <section id="setup" aria-labelledby="setup-h" className="py-24 lg:py-36">
      <div className="wrap">
        <h2 id="setup-h" className="display text-[clamp(2.2rem,5vw,4rem)]">
          What you need.
        </h2>
        <p className="mt-6 max-w-[36rem] text-lg text-haze">One Mac and one Android phone on the same network. A 5 GHz Wi-Fi network gives Full mode its best picture.</p>

        <div className="mt-14 grid gap-12 md:grid-cols-2">
          <Spec
            title="Mac"
            rows={[
              ["System", "macOS 14 Sonoma or later"],
              ["Chip", "Apple silicon. Intel builds, but is untested."],
              ["Permissions", "Accessibility, only if you use the trackpad or remote"],
            ]}
          />
          <Spec
            title="Android phone"
            rows={[
              ["Most features", "Android 10 or later"],
              ["Full mode", "Android 11 or later"],
              ["Setup", "Install the app and scan a QR code. Each permission is asked for when you first use the feature."],
            ]}
          />
        </div>

        <div className="mt-20 grid items-start gap-10 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]">
          <div>
            <h3 className="font-display text-[1.6rem] font-semibold tracking-tight">Build from source</h3>
            <p className="mt-3 text-haze">There's no download yet. To try it today, build both apps on a Mac.</p>
            <p className="mt-3 text-[0.95rem] text-haze">
              You'll need Xcode, xcodegen, protoc, JDK 21 and the Android SDK. The README's{" "}
              <a className="text-mist underline decoration-line underline-offset-4 hover:decoration-iris" href={`${REPO}#build-it`}>
                Build it
              </a>{" "}
              section has the exact versions and commands.
            </p>
          </div>
          <figure className="overflow-hidden rounded-2xl bg-[#060912] ring-1 ring-line">
            <figcaption className="flex items-center justify-between border-b border-line px-4 py-2.5 text-[0.85rem] text-haze">
              <span>Terminal, on your Mac</span>
              <button type="button" onClick={copy} className="inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-mist hover:bg-white/5">
                {copied ? <IconCheck size={15} aria-hidden="true" /> : <IconCopy size={15} aria-hidden="true" />}
                {copied ? "Copied" : "Copy"}
              </button>
            </figcaption>
            <pre className="overflow-x-auto px-5 py-5 font-mono text-[0.88rem] leading-7">
              <code>
                {cloneCommand.split("\n").map((line) => (
                  <span key={line} className={cn("block", line.startsWith("#") ? "text-haze/70" : "text-mist")}>
                    {!line.startsWith("#") && <span className="text-teal select-none">$ </span>}
                    {line}
                  </span>
                ))}
              </code>
            </pre>
          </figure>
        </div>
      </div>
    </section>
  )
}

const milestones = [
  {
    tag: "0.1 to 0.5",
    title: "Built, in testing",
    text: "Pairing and the secure connection, phone status, find my phone. Notifications, one-time codes, contacts and calls. Clipboard, files, screenshots and photos. Music, Focus sync, auto-lock, trackpad and remote. Full mode.",
    state: "done",
  },
  {
    tag: "Beta",
    title: "Private beta, now",
    text: "Hardening across phone makers and Android versions, battery use under 4% a day when idle, VoiceOver and TalkBack, and a security review.",
    state: "now",
  },
  { tag: "1.0", title: "Public release", text: "The Mac app and the Android app on GitHub Releases, and the Android app on F-Droid.", state: "next" },
  { tag: "2.0", title: "Later", text: "The phone as your Mac's webcam and microphone, and a one-click hotspot.", state: "next" },
] as const

export function Status() {
  return (
    <section id="status" aria-labelledby="status-h" className="py-24 lg:py-36">
      <div className="wrap">
        <h2 id="status-h" className="display text-[clamp(2.2rem,5vw,4rem)]">
          Where it's at.
        </h2>
        <p className="mt-6 max-w-[38rem] text-lg text-haze">
          Not released yet. All five milestones are built and being tested in a private beta, with testers on several phone models. The public release follows the beta.
        </p>

        <ol className="relative mt-16 grid gap-10 md:grid-cols-4 md:gap-8">
          <span aria-hidden="true" className="absolute top-[7px] right-0 left-0 hidden h-px bg-line md:block" />
          <span aria-hidden="true" className="absolute top-[7px] left-0 hidden h-px w-[37.5%] bg-gradient-to-r from-teal to-iris md:block" />
          {milestones.map((m) => (
            <li key={m.tag} className="relative pl-8 md:pl-0">
              <span aria-hidden="true" className="absolute top-[7px] bottom-[-2.5rem] left-[7px] w-px bg-line md:hidden" />
              <span
                aria-hidden="true"
                className={cn(
                  "absolute top-0 left-0 h-[15px] w-[15px] rounded-full ring-4 ring-night md:relative md:block",
                  m.state === "done" && "bg-teal",
                  m.state === "now" && "bg-iris shadow-[0_0_0_6px_rgba(169,155,255,0.18)]",
                  m.state === "next" && "bg-line",
                )}
              />
              <p className={cn("font-display text-[1.6rem] font-semibold tracking-tight md:mt-6", m.state === "next" && "text-haze")}>{m.tag}</p>
              <p className="mt-1 font-medium">{m.title}</p>
              <p className="mt-2 text-[0.95rem] leading-relaxed text-haze">{m.text}</p>
            </li>
          ))}
        </ol>

        <div className="mt-14 flex flex-wrap gap-3">
          <a href={`${REPO}/releases`} className="inline-flex h-11 items-center rounded-full bg-mist px-5 font-medium text-night hover:bg-white">
            Watch releases on GitHub
          </a>
          <a href={docs("docs/ROADMAP.md")} className="inline-flex h-11 items-center rounded-full px-5 font-medium ring-1 ring-line ring-inset hover:bg-white/5">
            Read the roadmap
          </a>
        </div>
      </div>
    </section>
  )
}

const faqs: [string, string][] = [
  ["Is it free?", "Yes. It's free and open source under the Apache-2.0 licence. There's nothing to buy and no paid tier."],
  ["Do I need an account?", "No. There is no account and no server. You pair your phone and your Mac once with a QR code, and they talk to each other directly."],
  [
    "Which phones does it work with?",
    "Android 10 or later for everything except Full mode, which needs Android 11 or later. The beta has testers on several phone models, and the test plan covers Pixel, Samsung, Xiaomi, OnePlus and Motorola phones. Some makers add an extra developer switch for Full mode; the phone app tells you when yours does.",
  ],
  [
    "Does it read my messages?",
    "It never asks for SMS permission, so it can't read your text messages. It shows the notifications you allow, from the apps you choose, and one-time codes are found in that notification text only.",
  ],
  [
    "Why isn't it on the Play Store or the App Store yet?",
    "It isn't released yet. The plan for 1.0 is GitHub Releases for both apps and F-Droid for the Android app, with Google Play later. The Mac app won't be on the Mac App Store: controlling the pointer and keyboard doesn't fit the App Store's sandbox, so it will be downloaded directly.",
  ],
  [
    "Is it safe?",
    "Pairing uses a QR code and a 6-digit code you confirm on both devices. After that, every connection is mutual TLS 1.3 with certificates pinned at pairing, so an unpaired device can't connect. Nothing leaves your local network. Full mode's helper runs only while the Mac shows the phone's screen and accepts commands only from your paired Mac. The code is open for anyone to review.",
  ],
  ["Does it work when my phone and Mac are on different networks?", "Not in version 1. Both need to be on the same local network."],
  ["Are the screens on this page real?", "They're drawn for this page from the apps' real layouts and wording, with made-up names and messages."],
]

export function Faq() {
  return (
    <section id="faq" aria-labelledby="faq-h" className="py-24 lg:py-36">
      <div className="wrap grid gap-12 lg:grid-cols-[minmax(0,4fr)_minmax(0,8fr)]">
        <div>
          <h2 id="faq-h" className="display text-[clamp(2.2rem,5vw,4rem)]">
            Questions.
          </h2>
          <p className="mt-6 text-lg text-haze">
            Something missing? Ask on{" "}
            <a className="text-mist underline decoration-line underline-offset-4 hover:decoration-iris" href={`${REPO}/issues`}>
              GitHub issues
            </a>
            .
          </p>
        </div>
        <div className="divide-y divide-line border-y border-line">
          {faqs.map(([q, a]) => (
            <details key={q} className="group">
              <summary className="flex cursor-pointer list-none items-center justify-between gap-6 py-5 text-[1.08rem] font-medium [&::-webkit-details-marker]:hidden">
                {q}
                <IconChevronDown size={20} className="shrink-0 text-haze transition-transform duration-300 group-open:rotate-180" aria-hidden="true" />
              </summary>
              <p className="max-w-[44rem] pb-6 text-haze">{a}</p>
            </details>
          ))}
        </div>
      </div>
    </section>
  )
}

export function Footer() {
  return (
    <footer className="relative overflow-hidden border-t border-line pt-16 pb-10">
      <div className="wrap">
        <div className="grid gap-10 md:grid-cols-[minmax(0,6fr)_minmax(0,3fr)_minmax(0,3fr)]">
          <div>
            <p className="flex items-center gap-2.5 font-display text-lg font-semibold">
              <LogoMark className="h-7 w-7" />
              {BRAND}
            </p>
            <p className="mt-4 max-w-[26rem] text-[0.95rem] text-haze">
              Free and open source under the{" "}
              <a className="text-mist underline decoration-line underline-offset-4 hover:decoration-iris" href={docs("LICENSE")}>
                Apache-2.0 licence
              </a>
              .
            </p>
          </div>
          <nav aria-label="Project" className="flex flex-col gap-2.5 text-[0.95rem]">
            <h2 className="mb-1 font-medium">Project</h2>
            <a className="text-haze hover:text-mist" href={REPO}>Source on GitHub</a>
            <a className="text-haze hover:text-mist" href={`${REPO}/issues`}>Report an issue</a>
            <a className="text-haze hover:text-mist" href={`${REPO}/releases`}>Releases</a>
          </nav>
          <nav aria-label="Docs" className="flex flex-col gap-2.5 text-[0.95rem]">
            <h2 className="mb-1 font-medium">Docs</h2>
            <a className="text-haze hover:text-mist" href={docs("docs/PRD.md")}>Product requirements</a>
            <a className="text-haze hover:text-mist" href={docs("docs/ARCHITECTURE.md")}>Architecture</a>
            <a className="text-haze hover:text-mist" href={docs("docs/ROADMAP.md")}>Roadmap</a>
          </nav>
        </div>
        <p className="mt-14 text-[0.82rem] text-haze/70">
          Not affiliated with Apple or Google. Mac and macOS are trademarks of Apple Inc. Android is a trademark of Google LLC.
        </p>
      </div>
      <p aria-hidden="true" className="display pointer-events-none mt-10 text-center text-[clamp(3rem,13vw,12rem)] leading-[0.8] text-white/[0.035] select-none">
        {BRAND}
      </p>
    </footer>
  )
}
