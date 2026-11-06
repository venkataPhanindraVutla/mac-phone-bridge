import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import "./index.css"
import { GetStarted } from "./components/start/GetStarted"

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <GetStarted />
  </StrictMode>,
)
