import { Day } from "@/components/site/Day"
import { Features } from "@/components/site/Features"
import { Hero } from "@/components/site/Hero"
import { Faq, Footer, Setup, Status } from "@/components/site/More"
import { Nav } from "@/components/site/Nav"
import { Privacy } from "@/components/site/Privacy"

export default function App() {
  return (
    <>
      <a
        href="#main"
        className="sr-only focus:not-sr-only focus:fixed focus:top-3 focus:left-3 focus:z-[60] focus:rounded-full focus:bg-mist focus:px-4 focus:py-2 focus:text-night"
      >
        Skip to content
      </a>
      <Nav />
      <main id="main">
        <Hero />
        <Day />
        <Features />
        <Privacy />
        <Setup />
        <Status />
        <Faq />
      </main>
      <Footer />
    </>
  )
}
