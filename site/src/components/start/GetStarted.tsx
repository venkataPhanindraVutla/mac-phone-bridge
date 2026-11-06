// The Get started page: downloads, then the setup in plain steps, with drawn pictures of the
// screens people stop at (macOS blocking the app, Android's install warnings, the pairing code).
// The same steps live in docs/quick-start.md for GitHub.
import { useEffect, useMemo, useState, type ReactNode } from "react"
import qrcode from "qrcode-generator"
import { IconAlertTriangle, IconBrandApple, IconBrandAndroid, IconBrandGithub, IconCheck, IconCopy, IconDownload, IconShieldCheck, IconShieldX, IconX } from "@tabler/icons-react"
import { cn } from "@/lib/utils"
import { BRAND, REPO, RELEASE, docs, INSTALL_OVER_USB } from "@/config"
import { AndroidPhone, MacBook } from "../site/devices"
import { LogoMark, Wallpaper } from "../site/parts"
import { Footer } from "../site/More"
import { Nav } from "../site/Nav"

const steps = [
  { id: "mac", title: "Install on your Mac" },
  { id: "phone", title: "Install on your phone" },
  { id: "pair", title: "Pair them" },
  { id: "features", title: "Turn on what you want" },
  { id: "locked", title: "Stay connected when locked" },
  { id: "full", title: "Full mode (optional)" },
]

export function GetStarted() {
  return (
    <>
      <a href="#main" className="sr-only focus:not-sr-only focus:fixed focus:top-3 focus:left-3 focus:z-[60] focus:rounded-full focus:bg-mist focus:px-4 focus:py-2 focus:text-night">
        Skip to content
      </a>
      <Nav home={false} />
      <main id="main">
        <Downloads />
        <Guide />
        <Trouble />
        <Checklist />
      </main>
      <Footer />
    </>
  )
}

/* ------------------------------------------------------------ downloads */

function Qr({ text, className }: { text: string; className?: string }) {
  const d = useMemo(() => {
    const qr = qrcode(0, "M")
    qr.addData(text)
    qr.make()
    const n = qr.getModuleCount()
    let path = ""
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) path += `M${c} ${r}h1v1h-1z`
    return { path, n }
  }, [text])
  return (
    <svg viewBox={`-2 -2 ${d.n + 4} ${d.n + 4}`} className={className} role="img" aria-label="QR code that opens the Android download on your phone">
      <rect x="-2" y="-2" width={d.n + 4} height={d.n + 4} fill="#f2f2f2" />
      <path d={d.path} fill="#0b0b0b" />
    </svg>
  )
}

function Downloads() {
  return (
    <section aria-labelledby="start-h" className="relative pt-32 pb-20 sm:pt-40">
      <div className="wrap">
        <p className="inline-flex items-center gap-2 rounded-full bg-lime/10 px-3 py-1 text-[0.9rem] font-medium text-lime ring-1 ring-lime/30 ring-inset">
          Public beta, version {RELEASE.version}
        </p>
        <h1 id="start-h" className="display mt-6 max-w-[16ch] text-[clamp(2.6rem,7vw,5.2rem)]">
          Set it up in about ten minutes.
        </h1>
        <p className="mt-6 max-w-[38rem] text-[1.15rem] leading-relaxed text-haze">
          Download one app for your Mac and one for your phone, then follow the steps below. You don't need to be technical, and there's no account to make.
        </p>

        <div className="mt-14 grid gap-4 lg:grid-cols-2">
          <div className="flex flex-col rounded-[1.5rem] bg-deep p-7 ring-1 ring-line sm:p-8">
            <div className="flex items-start justify-between gap-6">
              <div>
                <p className="flex items-center gap-2 text-haze">
                  <IconBrandApple size={18} aria-hidden="true" /> For your Mac
                </p>
                <h2 className="mt-2 font-display text-[1.7rem] font-semibold tracking-tight">{BRAND} for Mac</h2>
                <p className="mt-2 text-[0.95rem] text-haze">macOS 14 Sonoma or later. Apple silicon and Intel.</p>
              </div>
              <div aria-hidden="true" className="hidden shrink-0 text-[3.4px] sm:block">
                <MacBook className="w-[36em]">
                  <div className="absolute inset-0">
                    <Wallpaper />
                  </div>
                </MacBook>
              </div>
            </div>
            <a href={RELEASE.dmg.url} className="mt-8 inline-flex h-12 items-center justify-center gap-2 self-start rounded-full bg-lime px-6 font-semibold text-night transition-colors hover:bg-[#e2ff7a]">
              <IconDownload size={19} aria-hidden="true" /> Download for Mac
            </a>
            <p className="mt-3 text-[0.85rem] text-haze">MacPhoneBridge-0.9.0-beta.1.dmg, {RELEASE.dmg.size}</p>
          </div>

          <div className="flex flex-col rounded-[1.5rem] bg-deep p-7 ring-1 ring-line sm:p-8">
            <div className="flex items-start justify-between gap-6">
              <div>
                <p className="flex items-center gap-2 text-haze">
                  <IconBrandAndroid size={18} aria-hidden="true" /> For your phone
                </p>
                <h2 className="mt-2 font-display text-[1.7rem] font-semibold tracking-tight">{BRAND} for Android</h2>
                <p className="mt-2 text-[0.95rem] text-haze">Android 10 or later. Full mode needs Android 11.</p>
              </div>
              <div className="hidden shrink-0 text-center sm:block">
                <Qr text={RELEASE.apk.url} className="h-28 w-28 rounded-xl" />
                <p className="mt-2 max-w-[7rem] text-[0.75rem] leading-tight text-haze">Scan with your phone's camera</p>
              </div>
            </div>
            <a href={RELEASE.apk.url} className="mt-8 inline-flex h-12 items-center justify-center gap-2 self-start rounded-full bg-pink px-6 font-semibold text-night transition-colors hover:bg-[#ff5cbf]">
              <IconDownload size={19} aria-hidden="true" /> Download for Android
            </a>
            <p className="mt-3 text-[0.85rem] text-haze">MacPhoneBridge-0.9.0-beta.1.apk, {RELEASE.apk.size}. On a Mac, scan the code instead.</p>
          </div>
        </div>

        <p className="mt-6 flex flex-wrap items-center gap-x-2 text-[0.95rem] text-haze">
          <IconShieldCheck size={17} className="text-lime" aria-hidden="true" />
          Both are free and open source. Every file is on the{" "}
          <a href={RELEASE.page} className="text-mist underline decoration-line underline-offset-4 hover:decoration-lime">
            GitHub release page
          </a>
          , with checksums.
        </p>
      </div>
    </section>
  )
}

/* ------------------------------------------------------------ drawn screens */

/** A chartreuse ring around the button to press. */
function Callout() {
  return <span className="pointer-events-none absolute -inset-1.5 rounded-[inherit] ring-2 ring-lime" aria-hidden="true" />
}

function Figure({ children, caption }: { children: ReactNode; caption: string }) {
  return (
    <figure className="my-6">
      <div className="rounded-[1.2rem] bg-[#141414] p-5 ring-1 ring-line sm:p-7">{children}</div>
      <figcaption className="mt-2 text-[0.85rem] text-haze">{caption}</figcaption>
    </figure>
  )
}

function MacBlocked() {
  return (
    <Figure caption="macOS 15 and later: click Done here.">
      <div aria-hidden="true" className="mx-auto w-full max-w-[19rem] rounded-2xl bg-[#2a2a2c] p-5 text-center text-[0.85rem] text-white shadow-2xl ring-1 ring-white/10">
        <span className="mx-auto grid h-12 w-12 place-items-center rounded-xl bg-pink text-night">
          <LogoMark className="h-8 w-8" />
        </span>
        <p className="mt-3 font-semibold">“{BRAND}” Not Opened</p>
        <p className="mt-1.5 text-[0.78rem] leading-snug text-white/70">Apple could not verify “{BRAND}” is free of malware that may harm your Mac or compromise your privacy.</p>
        <span className="relative mt-4 block rounded-md bg-[#0a84ff] py-1.5 font-medium">
          Done
          <Callout />
        </span>
        <span className="mt-2 block rounded-md bg-white/10 py-1.5">Move to Trash</span>
      </div>
    </Figure>
  )
}

function OpenAnyway() {
  return (
    <Figure caption="Then in System Settings › Privacy & Security, scroll down and click Open Anyway.">
      <div aria-hidden="true" className="mx-auto w-full max-w-[28rem] rounded-xl bg-[#1e1e20] p-4 text-[0.82rem] text-white ring-1 ring-white/10">
        <p className="text-[0.95rem] font-semibold">Security</p>
        <div className="mt-3 flex items-center justify-between gap-4 rounded-lg bg-white/[0.06] p-3">
          <p className="leading-snug text-white/80">“{BRAND}” was blocked to protect your Mac.</p>
          <span className="relative shrink-0 rounded-md bg-white/15 px-3 py-1 font-medium">
            Open Anyway
            <Callout />
          </span>
        </div>
      </div>
    </Figure>
  )
}

function UnknownSources() {
  return (
    <Figure caption="If the phone asks, allow installs from your browser, then go back and tap Install.">
      <div aria-hidden="true" className="mx-auto w-full max-w-[18rem] rounded-2xl bg-[#f2f2f2] p-4 text-[0.85rem] text-night">
        <p className="text-[1.05rem] font-semibold">Install unknown apps</p>
        <p className="mt-3 text-black/55">Chrome</p>
        <div className="relative mt-2 flex items-center justify-between rounded-xl bg-white p-3">
          <span>Allow from this source</span>
          <span className="flex h-6 w-11 items-center rounded-full bg-[#1a73e8] p-0.5">
            <span className="ml-auto h-5 w-5 rounded-full bg-white" />
          </span>
          <Callout />
        </div>
      </div>
    </Figure>
  )
}

function PlayProtect() {
  return (
    <Figure caption="If Google Play Protect only warns you, tap More details, then Install anyway.">
      <div aria-hidden="true" className="mx-auto w-full max-w-[18rem] rounded-2xl bg-[#f2f2f2] p-4 text-[0.85rem] text-night">
        <p className="flex items-center gap-2 font-semibold">
          <IconShieldCheck size={18} className="text-[#1a73e8]" /> Google Play Protect
        </p>
        <p className="mt-2 leading-snug text-black/65">This app isn't from the Play Store. Play Protect hasn't seen it before.</p>
        <p className="mt-3 text-[0.8rem] font-medium text-[#1a73e8]">More details ▾</p>
        <div className="mt-3 flex justify-end gap-2">
          <span className="rounded-full px-3 py-1.5 text-[#1a73e8]">Don't install</span>
          <span className="relative rounded-full px-3 py-1.5 font-medium text-[#1a73e8]">
            Install anyway
            <Callout />
          </span>
        </div>
      </div>
    </Figure>
  )
}

/** The one with no way past it: enhanced fraud protection, in India and some other countries. */
function PlayProtectBlocked() {
  return (
    <Figure caption="If it says App blocked to protect your device, with only Got it, see Install it over USB below.">
      <div aria-hidden="true" className="mx-auto w-full max-w-[18rem] rounded-2xl bg-[#efe9e3] p-5 text-center text-[0.85rem] text-night">
        <IconShieldX size={26} className="mx-auto text-black/60" />
        <p className="mt-1 text-[0.75rem] text-black/55">Google Play Protect</p>
        <p className="mt-3 text-[1.15rem] leading-tight">App blocked to protect your device</p>
        <p className="mt-3 text-left leading-snug text-black/65">This app can request access to sensitive data. This can increase the risk of identity theft or financial fraud.</p>
        <span className="mt-4 block rounded-full bg-[#6b6152] py-2 font-medium text-white">Got it</span>
      </div>
    </Figure>
  )
}

/** A command to paste into Terminal, with a copy button. */
function Command({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  const copy = () => {
    navigator.clipboard?.writeText(text).then(
      () => {
        setCopied(true)
        setTimeout(() => setCopied(false), 1800)
      },
      () => undefined,
    )
  }
  return (
    <div className="mt-3 flex items-start gap-3 rounded-xl bg-[#141414] p-3 ring-1 ring-line">
      <code className="min-w-0 flex-1 select-all break-all font-mono text-[0.8rem] leading-relaxed text-mist">{text}</code>
      <button type="button" onClick={copy} className="flex shrink-0 items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-[0.8rem] font-medium text-night bg-lime">
        {copied ? <IconCheck size={15} aria-hidden="true" /> : <IconCopy size={15} aria-hidden="true" />}
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  )
}

function CodesMatch() {
  return (
    <Figure caption="The same 6 digits on both screens means it's your Mac. Tap Confirm.">
      <div aria-hidden="true" className="flex flex-wrap items-center justify-center gap-4">
        <div className="rounded-xl bg-[#1e1e20] px-5 py-4 text-center text-white ring-1 ring-white/10">
          <p className="text-[0.75rem] text-white/55">On your Mac</p>
          <p className="mt-1 font-display text-[1.6rem] font-semibold tracking-[0.1em] tabular-nums">418 027</p>
        </div>
        <span className="grid h-8 w-8 place-items-center rounded-full bg-lime text-night">
          <IconCheck size={18} />
        </span>
        <div className="rounded-xl bg-[#f2f2f2] px-5 py-4 text-center text-night">
          <p className="text-[0.75rem] text-black/50">On your phone</p>
          <p className="mt-1 font-display text-[1.6rem] font-semibold tracking-[0.1em] tabular-nums">418 027</p>
          <span className="relative mt-2 block rounded-full bg-pink py-1 text-[0.85rem] font-semibold">
            Confirm
            <Callout />
          </span>
        </div>
      </div>
    </Figure>
  )
}

/* ------------------------------------------------------------ the steps */

function Ol({ children }: { children: ReactNode }) {
  return <ol className="mt-5 list-decimal space-y-3 pl-6 marker:font-display marker:font-semibold marker:text-lime">{children}</ol>
}
function B({ children }: { children: ReactNode }) {
  return <strong className="font-semibold text-mist">{children}</strong>
}
function Note({ children, tone = "info" }: { children: ReactNode; tone?: "info" | "warn" }) {
  return (
    <div className={cn("mt-6 flex gap-3 rounded-2xl p-4 text-[0.97rem] ring-1", tone === "warn" ? "bg-pink/[0.07] ring-pink/25" : "bg-white/[0.03] ring-line")}>
      {tone === "warn" ? <IconAlertTriangle size={20} className="mt-0.5 shrink-0 text-pink" aria-hidden="true" /> : <IconCheck size={20} className="mt-0.5 shrink-0 text-lime" aria-hidden="true" />}
      <div className="text-haze">{children}</div>
    </div>
  )
}

function Step({ n, id, title, children }: { n: number; id: string; title: string; children: ReactNode }) {
  return (
    <section id={id} aria-labelledby={`${id}-h`} className="scroll-mt-24 border-t border-line py-14 first:border-t-0 first:pt-0">
      <p className="font-display text-[1rem] font-semibold text-lime">Step {n}</p>
      <h2 id={`${id}-h`} className="display mt-2 text-[clamp(1.9rem,4vw,2.8rem)]">
        {title}
      </h2>
      <div className="mt-4 max-w-[40rem] text-[1.05rem] leading-relaxed text-haze">{children}</div>
    </section>
  )
}

function Guide() {
  const [current, setCurrent] = useState(steps[0].id)
  useEffect(() => {
    const observer = new IntersectionObserver((entries) => entries.forEach((e) => e.isIntersecting && setCurrent(e.target.id)), { rootMargin: "-40% 0px -55% 0px" })
    steps.forEach((s) => {
      const el = document.getElementById(s.id)
      if (el) observer.observe(el)
    })
    return () => observer.disconnect()
  }, [])

  return (
    <div className="border-t border-line py-20 lg:py-28">
      <div className="wrap grid gap-12 lg:grid-cols-[minmax(0,3fr)_minmax(0,9fr)] lg:gap-16">
        <nav aria-label="Steps" className="hidden lg:block">
          <ol className="sticky top-28 space-y-1">
            {steps.map((s, i) => (
              <li key={s.id}>
                <a
                  href={`#${s.id}`}
                  aria-current={current === s.id ? "step" : undefined}
                  className={cn("flex items-center gap-3 rounded-xl px-3 py-2 text-[0.95rem] transition-colors", current === s.id ? "bg-white/[0.06] text-mist" : "text-haze hover:text-mist")}
                >
                  <span className={cn("grid h-6 w-6 shrink-0 place-items-center rounded-full text-[0.75rem] font-semibold", current === s.id ? "bg-lime text-night" : "ring-1 ring-line")}>{i + 1}</span>
                  {s.title}
                </a>
              </li>
            ))}
          </ol>
        </nav>

        <div>
          <Note>
            <B>Before you start:</B> put your Mac and your phone on the <B>same Wi-Fi</B>, and turn off any VPN on either while you set up.
          </Note>

          <div className="mt-14">
            <Step n={1} id="mac" title="Install on your Mac">
              <Ol>
                <li>Download the Mac app above and open the downloaded file.</li>
                <li>
                  In the window that opens, drag <B>{BRAND}</B> onto <B>Applications</B>.
                </li>
                <li>
                  Open your Applications folder and double-click <B>{BRAND}</B>.
                </li>
              </Ol>
              <Note tone="warn">
                This beta isn't signed by Apple yet, so your Mac asks you to confirm you trust it. You only do this once.
              </Note>
              <MacBlocked />
              <OpenAnyway />
              <p>
                Enter your Mac password or use Touch ID, then click <B>Open Anyway</B> once more. On macOS 14 Sonoma, Control-click the app in Applications, choose <B>Open</B>, then <B>Open</B> again.
              </p>
              <p className="mt-4">
                A small <B>phone icon</B> appears in the menu bar at the top right of your screen, with a line through it until your phone connects. That's where you use the app. If your Mac asks to let it find devices on your local network, click <B>Allow</B>.
              </p>
            </Step>

            <Step n={2} id="phone" title="Install on your phone">
              <Ol>
                <li>
                  On the phone, open this page and tap <B>Download for Android</B>, or scan the QR code above with the phone's camera.
                </li>
                <li>
                  When the download finishes, tap <B>Open</B>, then <B>Install</B>.
                </li>
              </Ol>
              <UnknownSources />
              <PlayProtect />
              <p>Some phones, like vivo, Xiaomi and OPPO, show one more warning. Choose the option to install anyway. The warnings appear because the app isn't from the Play Store yet.</p>
              <PlayProtectBlocked />
              <Note tone="warn">
                In some countries, India among them, Play Protect blocks the install instead of warning you. It does this to every app that can read notifications, which {BRAND} needs, when the app comes from a browser or a file manager. There's no button to get past it, so please don't turn Play Protect off. An install over a USB cable from a Mac isn't blocked.
              </Note>

              <div id="usb" className="mt-10 scroll-mt-24">
                <h3 className="font-display text-[1.35rem] font-semibold text-mist">Install it over USB instead</h3>
                <p className="mt-2">It takes about five minutes, on any Mac with internet. You'll need a USB cable that carries data, not just charge.</p>
                <Ol>
                  <li>
                    On the phone, open <B>Settings › About phone</B> and tap <B>Build number</B> seven times, until it says you're a developer. On some phones it's under Software information.
                  </li>
                  <li>
                    Go back to Settings, open <B>Developer options</B> (on Pixel it's in <B>System</B>) and turn on <B>USB debugging</B>. On Xiaomi, Redmi and POCO, also turn on <B>Install via USB</B>.
                  </li>
                  <li>
                    On the Mac, open <B>Terminal</B> (press Command-Space, type Terminal, press Return), paste this and press Return:
                    <Command text={INSTALL_OVER_USB} />
                  </li>
                  <li>
                    Plug the phone in. When it asks <B>Allow USB debugging?</B>, tick <B>Always allow from this computer</B> and tap <B>Allow</B>.
                  </li>
                  <li>
                    When Terminal says <B>Installed</B>, unplug the phone and carry on with step 3. You can turn USB debugging off again.
                  </li>
                </Ol>
                <p className="mt-4 text-[0.95rem]">
                  The command downloads the beta from GitHub, checks it against the release's checksums, and installs it with Google's own Android tools. It changes no settings. You can{" "}
                  <a href={docs("scripts/install-phone.sh")} className="text-mist underline decoration-line underline-offset-4 hover:decoration-lime">
                    read the script
                  </a>{" "}
                  first.
                </p>
              </div>
            </Step>

            <Step n={3} id="pair" title="Pair them">
              <Ol>
                <li>
                  On your Mac, click the phone icon in the menu bar and choose <B>Pair a phone…</B>. A QR code appears.
                </li>
                <li>
                  On your phone, open <B>{BRAND}</B>, tap <B>Pair with your Mac</B>, then <B>Scan the code</B>. Allow the camera.
                </li>
                <li>Point the phone at the code on your Mac.</li>
              </Ol>
              <CodesMatch />
              <p>
                The phone says <B>Paired with</B> your Mac's name. You only pair once: from now on they connect by themselves whenever they're on the same Wi-Fi.
              </p>
            </Step>

            <Step n={4} id="features" title="Turn on what you want">
              <p>
                The phone app's home screen has a switch for each feature. Turn on the ones you want, and allow what the phone asks for the first time. For notifications, tap <B>Allow notification access</B> and turn on {BRAND} in the list.
              </p>
              <p className="mt-4">
                On the Mac, allow notifications when it asks. To use the phone as a trackpad or presentation remote, allow {BRAND} in <B>System Settings › Privacy & Security › Accessibility</B>.
              </p>
            </Step>

            <Step n={5} id="locked" title="Stay connected when locked">
              <p>
                To save battery, Android can stop apps while the screen is off. When the phone app shows <B>Stay connected when the phone is locked</B>, tap <B>Allow in the background</B>. If it names one more setting for your phone, tap <B>Open app settings</B> and turn it on:
              </p>
              <dl className="mt-5 divide-y divide-line rounded-2xl ring-1 ring-line">
                {[
                  ["Samsung", "Settings › Battery › Background usage limits › Never sleeping apps › add " + BRAND],
                  ["Xiaomi, Redmi, POCO", `Settings › Apps › Manage apps › ${BRAND} › Autostart on, and Battery saver › No restrictions`],
                  ["vivo, iQOO", `Settings › Battery › Background power consumption management › ${BRAND} › Allow`],
                  ["OPPO, OnePlus, realme", `Settings › Apps › App management › ${BRAND} › Battery usage › Allow background activity`],
                ].map(([maker, path]) => (
                  <div key={maker} className="grid gap-1 p-4 sm:grid-cols-[10rem_1fr] sm:gap-4">
                    <dt className="font-medium text-mist">{maker}</dt>
                    <dd className="text-[0.95rem]">{path}</dd>
                  </div>
                ))}
              </dl>
            </Step>

            <Step n={6} id="full" title="Full mode (optional)">
              <p>
                Full mode shows the phone's screen in a Mac window, with its sound, and lets you use it with your mouse and keyboard. It needs Android 11 or later and a one-time setup. The phone app walks you through it:
              </p>
              <Ol>
                <li>
                  In the phone app, under <B>Allow your Mac to show this screen</B>, tap <B>Set up Full mode</B>.
                </li>
                <li>
                  Turn on Developer options: open <B>Settings › About phone</B> and tap <B>Build number</B> seven times. On some phones it's under Software information.
                </li>
                <li>
                  In <B>Developer options</B>, turn on <B>Wireless debugging</B> and allow it on this network.
                </li>
                <li>
                  Tap <B>Pair device with pairing code</B> and keep that screen open.
                </li>
                <li>Pull down the notification from {BRAND} and type the code from that screen into it.</li>
                <li>
                  When the phone says <B>Full mode is ready.</B>, choose <B>Show Phone Screen</B> from the phone icon on your Mac.
                </li>
              </Ol>
              <Note tone="warn">
                On Xiaomi, Redmi and POCO, also turn on <B>USB debugging (Security settings)</B> in Developer options. On vivo, iQOO, OPPO and OnePlus, turn on <B>Disable permission monitoring</B>. The phone app tells you if yours needs it.
              </Note>
              <div aria-hidden="true" className="mt-8 flex items-end justify-center gap-[2%] text-[5px] sm:text-[7px]">
                <MacBook className="w-[44em]">
                  <div className="absolute inset-0">
                    <Wallpaper />
                  </div>
                </MacBook>
                <AndroidPhone className="w-[12em]">
                  <div className="grid h-full place-items-center bg-lime text-night">
                    <LogoMark className="h-[5em] w-[5em]" />
                  </div>
                </AndroidPhone>
              </div>
              <p className="mt-8">
                After the phone restarts or joins another Wi-Fi network, tap <B>Re-enable Full mode</B>. To turn it off, turn off Wireless debugging.
              </p>
            </Step>
          </div>
        </div>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------ troubleshooting */

const problems: [string, ReactNode][] = [
  ["Play Protect says App blocked to protect your device", <>In some countries Android blocks apps that can read notifications when they're downloaded in a browser. Install it over a USB cable from a Mac instead: see <a href="#usb" className="text-mist underline decoration-line underline-offset-4 hover:decoration-lime">Install it over USB</a> in step 2.</>],
  ["The phone can't find the Mac", "Check that both are on the same Wi-Fi and no VPN is on. Guest and some office networks stop devices from seeing each other: try your home Wi-Fi or your phone's hotspot."],
  ["My Mac asks to allow access to a Keychain item", <>Click <B>Always Allow</B>. This beta asks again after each update. If a message mentions exporting a key, click Deny and tell us.</>],
  ["Notifications stop when the phone is locked", "Go through step 5 again for your phone's brand."],
  ["It says my Mac doesn't recognise this phone any more", "Pair again, as in step 3."],
  ["Full mode stopped working", <>Tap <B>Re-enable Full mode</B> in the phone app.</>],
  ["How do I update?", "Download the new versions from this page and install them the same way. Your pairing is kept."],
  ["How do I remove it?", <>On the Mac, choose <B>Forget</B> your phone from the phone icon, quit the app and move it to the Trash. On the phone, uninstall it like any app. When 1.0 comes out, uninstall this beta from the phone first, then pair again.</>],
]

function Trouble() {
  const [open, setOpen] = useState<number>(-1)
  return (
    <section aria-labelledby="trouble-h" className="border-t border-line py-20 lg:py-28">
      <div className="wrap grid gap-10 lg:grid-cols-[minmax(0,4fr)_minmax(0,8fr)] lg:gap-16">
        <h2 id="trouble-h" className="display text-[clamp(2.2rem,5vw,3.6rem)]">
          If something isn't working
        </h2>
        <div className="space-y-1">
          {problems.map(([q, a], i) => (
            <div key={q} className={cn("rounded-2xl ring-1 transition-colors", open === i ? "bg-deep ring-line" : "ring-transparent hover:bg-white/[0.02]")}>
              <h3>
                <button type="button" aria-expanded={open === i} aria-controls={`trouble-${i}`} onClick={() => setOpen(open === i ? -1 : i)} className="flex w-full items-center justify-between gap-6 px-5 py-5 text-left text-[1.05rem] font-medium">
                  {q}
                  <span className={cn("grid h-8 w-8 shrink-0 place-items-center rounded-full text-[1.1rem] ring-1 transition-transform", open === i ? "rotate-45 bg-pink text-night ring-pink" : "text-haze ring-line")} aria-hidden="true">
                    +
                  </span>
                </button>
              </h3>
              {open === i && (
                <p id={`trouble-${i}`} className="max-w-[44rem] px-5 pb-6 text-haze">
                  {a}
                </p>
              )}
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}

/* ------------------------------------------------------------ feature checklist */

const checks = [
  "The Mac app opens and shows its menu bar icon",
  "The phone app installs and pairs with the Mac",
  "A phone notification shows on the Mac, and replying works",
  "A one-time code shows Copy code on the Mac",
  "An incoming call shows on the Mac; answer, decline and hang up work",
  "Copied text pastes on the other device, both ways",
  "Files go both ways (drag onto the Phone window, Send to Mac)",
  "A phone screenshot appears on the Mac",
  "Music on the phone pauses and skips from the Mac",
  "Find my phone rings it, even on silent",
  "Battery and signal show in the Mac's menu bar",
  "It stays connected for an hour with the phone locked",
  "Full mode shows the screen, and clicks and typing work",
]
type Result = "yes" | "no" | undefined
const storeKey = "mpb-checklist-v1"

function Checklist() {
  const [results, setResults] = useState<Result[]>(() => {
    try {
      const saved = JSON.parse(localStorage.getItem(storeKey) ?? "null")
      if (saved && Array.isArray(saved.results)) return saved.results
    } catch {
      // Storage can be unavailable (private windows); the list then starts empty.
    }
    return []
  })
  const [devices, setDevices] = useState<{ phone: string; mac: string }>(() => {
    try {
      const saved = JSON.parse(localStorage.getItem(storeKey) ?? "null")
      if (saved?.devices) return saved.devices
    } catch {
      // As above.
    }
    return { phone: "", mac: "" }
  })
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    try {
      localStorage.setItem(storeKey, JSON.stringify({ results, devices }))
    } catch {
      // Nothing to do: the checklist still works for this visit.
    }
  }, [results, devices])

  const set = (i: number, r: Result) => setResults((prev) => checks.map((_, j) => (j === i ? (prev[j] === r ? undefined : r) : prev[j])))
  const report = [
    `${BRAND} ${RELEASE.version} test results`,
    `Phone: ${devices.phone || "(not given)"}`,
    `Mac: ${devices.mac || "(not given)"}`,
    "",
    ...checks.map((c, i) => `${results[i] === "yes" ? "✅" : results[i] === "no" ? "❌" : "⬜"} ${c}`),
  ].join("\n")
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(report)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      setCopied(false)
    }
  }
  const done = results.filter(Boolean).length

  return (
    <section id="checklist" aria-labelledby="checklist-h" className="border-t border-line py-20 lg:py-28">
      <div className="wrap">
        <div className="grid items-end gap-6 lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)] lg:gap-16">
          <h2 id="checklist-h" className="display text-[clamp(2.2rem,5vw,3.6rem)]">
            Feature checklist
          </h2>
          <p className="max-w-[30rem] text-[1.1rem] leading-relaxed text-haze lg:justify-self-end">
            Try each one and mark it. Then copy your results and send them on WhatsApp or GitHub. Your answers stay in this browser.
          </p>
        </div>

        <div className="mt-12 grid gap-4 sm:grid-cols-2">
          <label className="block">
            <span className="text-[0.92rem] text-haze">Your phone (make, model, Android version)</span>
            <input value={devices.phone} onChange={(e) => setDevices({ ...devices, phone: e.target.value })} placeholder="Pixel 10a, Android 17" className="mt-2 h-12 w-full rounded-xl bg-deep px-4 text-mist ring-1 ring-line placeholder:text-haze/50 focus:ring-lime focus:outline-none" />
          </label>
          <label className="block">
            <span className="text-[0.92rem] text-haze">Your Mac (model, macOS version)</span>
            <input value={devices.mac} onChange={(e) => setDevices({ ...devices, mac: e.target.value })} placeholder="MacBook Air M2, macOS 26" className="mt-2 h-12 w-full rounded-xl bg-deep px-4 text-mist ring-1 ring-line placeholder:text-haze/50 focus:ring-lime focus:outline-none" />
          </label>
        </div>

        <ul className="mt-8 divide-y divide-line rounded-[1.4rem] ring-1 ring-line">
          {checks.map((c, i) => (
            <li key={c} className="flex flex-wrap items-center justify-between gap-3 px-5 py-4">
              <span className={cn("text-[1rem]", results[i] ? "text-mist" : "text-haze")}>{c}</span>
              <span className="flex gap-2" role="group" aria-label={c}>
                <button type="button" aria-pressed={results[i] === "yes"} onClick={() => set(i, "yes")} className={cn("inline-flex h-9 items-center gap-1.5 rounded-full px-3.5 text-[0.88rem] font-medium ring-1 transition-colors ring-inset", results[i] === "yes" ? "bg-lime text-night ring-lime" : "text-haze ring-line hover:text-mist")}>
                  <IconCheck size={15} aria-hidden="true" /> Works
                </button>
                <button type="button" aria-pressed={results[i] === "no"} onClick={() => set(i, "no")} className={cn("inline-flex h-9 items-center gap-1.5 rounded-full px-3.5 text-[0.88rem] font-medium ring-1 transition-colors ring-inset", results[i] === "no" ? "bg-pink text-night ring-pink" : "text-haze ring-line hover:text-mist")}>
                  <IconX size={15} aria-hidden="true" /> Doesn't
                </button>
              </span>
            </li>
          ))}
        </ul>

        <div className="mt-8 flex flex-wrap items-center gap-3">
          <button type="button" onClick={copy} className="inline-flex h-12 items-center gap-2 rounded-full bg-lime px-6 font-semibold text-night hover:bg-[#e2ff7a]">
            {copied ? <IconCheck size={18} aria-hidden="true" /> : <IconCopy size={18} aria-hidden="true" />}
            {copied ? "Copied, now paste it" : "Copy my results"}
          </button>
          <a href={`${REPO}/issues/new`} className="inline-flex h-12 items-center gap-2 rounded-full px-5 font-medium ring-1 ring-line ring-inset hover:bg-white/5">
            <IconBrandGithub size={18} aria-hidden="true" /> Report on GitHub
          </a>
          <span className="text-[0.9rem] text-haze" aria-live="polite">
            {done} of {checks.length} marked
          </span>
        </div>
        <p className="mt-6 text-[0.9rem] text-haze">
          The same guide is on GitHub as{" "}
          <a href={docs("docs/quick-start.md")} className="text-mist underline decoration-line underline-offset-4 hover:decoration-lime">
            Quick Start
          </a>
          .
        </p>
      </div>
    </section>
  )
}
