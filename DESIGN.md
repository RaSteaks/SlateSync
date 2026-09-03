---
version: alpha
colors:
  canvas-dark: "#0D121A"
  surface-dark: "#151D29"
  raised-dark: "#1C2735"
  ink-dark: "#F4F7FB"
  muted-dark: "#B8C2CF"
  canvas-light: "#F1F4F7"
  surface-light: "#FBFCFD"
  ink-light: "#182330"
  muted-light: "#506074"
  accent: "#5E6EE8"
  accent-soft: "#8C9CFF"
  success: "#18794E"
  warning: "#865B0A"
  danger: "#B33A32"
typography:
  body:
    fontFamily: ".AppleSystemUIFont, PingFang SC, sans-serif"
  display:
    fontFamily: ".AppleSystemUIFont, PingFang SC, sans-serif"
  data:
    fontFamily: "SFMono-Regular, Menlo, monospace"
rounded:
  small: "6px"
  control: "8px"
  panel: "12px"
  large: "16px"
spacing:
  compact: "8px"
  control: "12px"
  section: "16px"
  panel: "20px"
components:
  sidebar:
    appearance: "native source list"
  project-card:
    signature: "single restrained slate-stripe edge"
  data-table:
    appearance: "dense native grid with stable headers"
---

# SlateSync Design

## Overview

SlateSync is a professional film-production utility used for long, detail-heavy
sessions. Its visual North Star is a calibrated post-production workstation:
native macOS structure, graphite instruments, paper-like evidence surfaces and
one restrained indigo signal color. The signature is a subtle slate-stripe edge
on project identity surfaces; decoration elsewhere stays quiet.

The product must never resemble a marketing dashboard, neon gaming UI, generic
rounded-card SaaS template, or touch-first iOS port. Dense information remains
legible through alignment, typography and native split-view hierarchy rather
than stacked ornament.

## Colors

The existing React token system remains the evidence source during migration.
`SlateSyncTheme` maps these accepted semantic roles to adaptive SwiftUI colors;
feature views consume semantic roles, never raw RGB literals. Native sidebar and
window materials remain system-owned. Accent is reserved for current selection,
focus and the primary safe action. Warning and danger remain distinct.

## Typography

Use San Francisco with PingFang SC fallback for Chinese product text. SF Mono is
limited to clips, identifiers, model IDs, CSV data and technical status. Native
Dynamic Type metrics and accessibility sizes override fixed visual ambitions.

## Layout

Use `WindowGroup` with a stable `NavigationSplitView`: source-list sidebar,
task-focused detail, and an inspector/supplementary column only where it reduces
modal switching. Default window size is 1440×900 and minimum is 960×600.
Comfortable and compact density share the same hierarchy.

## Elevation & Depth

Prefer native materials and separators. Static panels are mostly flat; shadows
are reserved for temporary overlays and raised evidence previews. Avoid opaque
custom fills over a native sidebar.

## Shapes

Controls use 8px visual rounding when the native control does not own geometry;
panels use 12px. Pills are reserved for short status badges, never general
buttons or containers.

## Components

Buttons combine safe/danger intent with native emphasis. Forms keep visible
labels and inline recovery. Project rows/cards expose one primary open action and
separate contextual actions. The editable CSV surface is an NSTableView bridge
with stable columns, native selection, IME-safe editing and bounded scrolling.

## Do's and Don'ts

- Do use system commands, toolbars, focus, accessibility labels and reduced motion.
- Do keep action and feedback vocabulary short, direct and consistent in Chinese.
- Do reserve layout space for progress, errors and asynchronous results.
- Don't add gradients, oversized promotional headings or screen-local colors.
- Don't hide actions behind hover or gestures without keyboard/menu equivalents.
- Don't use emoji as functional icons; use SF Symbols.
