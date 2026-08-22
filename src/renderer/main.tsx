import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";

// The modern root owns only composition and view state. All machine/project
// effects still cross the frozen typed Preload gateway or a bounded Worker;
// no feature can reach Electron channels or filesystem APIs from this file.
const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Modern renderer root is missing");
}

createRoot(rootElement).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
