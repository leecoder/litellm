# LiteLLM Usage Menu Bar Design System

## 0. References
- Apple platform reference: SwiftUI `MenuBarExtra` window style, available on macOS 13+

## 1. Atmosphere & Identity

A quiet glanceable utility. The signature is a single signal, the quota percentage for the selected scope, supported by a small amount of operational detail when the menu opens

## 2. Color

| Role | Token | Value | Usage |
|------|------|------|------|
| Surface | surface | system background | Menu popover |
| Text | text | primary | Main labels |
| Muted | muted | secondary | Supporting facts |
| Accent | accent | system blue | Refresh and settings actions |
| Success | success | system green | Healthy quota state |
| Warning | warning | system orange | High quota state |
| Error | error | system red | Failure state |

## 3. Typography

Primary: macOS system font. Mono: system monospaced font for amounts and percentages. Body text is at least 13pt

## 4. Spacing & Layout

Spacing derives from a 4pt base. The popover uses a 320pt width, 16pt outer padding, 12pt section gaps, and 8pt inline gaps

## 5. Components

### Menu bar status
- Structure: compact text label with percentage
- Variants: loading, healthy, warning, error, no quota
- States: default, disabled while loading
- Accessibility: label includes the full percentage and state

### App icon
- Motif: the official LiteLLM logo aligned with the menu bar's 🚅 identity
- Source: the official square `assets/litellm_logo.jpg` mark with its sky-blue background extended across the canvas, generated into a standard macOS `.icns` bundle resource

### Usage popover
- Structure: title, usage scope picker, quota signal, usage facts, monthly cumulative usage chart, status line, action row
- Variants: configured, needs key, loading, success, failure, unavailable quota
- States: default, loading, error
- Accessibility: buttons have labels and visible text; color is never the only status signal

### Monthly usage chart
- Structure: cumulative daily spend, projected month-end spend, monthly budget rule, and a text legend
- Style: blue actual line with a light area, orange dashed forecast, red dashed budget limit
- Plot height: 112pt within the existing 320pt-wide popover
- Forecast: current month-to-date daily average projected through the last calendar day
- Accessibility: actual, forecast, and limit are each named in visible text and the chart has an accessible label

### Settings form
 - Structure: auto-refresh picker, gateway URL field, username field, secure password field, explanatory label, save action
- Variants: empty, configured
- States: focused, saving, saved; successful save dismisses the settings window
- Accessibility: secure text entry and explicit save action

### Settings window
 - Size: 380pt wide by 360pt high so the refresh picker, gateway URL, fields, explanation, and save action remain visible
- Presentation: a single independent window opened explicitly by the usage popover's settings action, never a sheet attached to the menu bar
- Focus: opening settings activates the app for keyboard input; closing the popover must not close settings
- Storage: username and password share one Keychain item; session tokens remain in memory for the running app

### Usage scope picker
- Placement: top of the usage popover, above the quota signal
- Options: team total plus the authenticated user's named keys
- Fallback: a key without its own budget uses the team's monthly budget as its limit

### Auto refresh
- Options: off, adaptive, 1 minute, 5 minutes, 15 minutes, 30 minutes, or 1 hour
- Default: adaptive
- Adaptive behavior: uses current utilization, recent spend rate, estimated time to limit, and reset time
- Behavior: refreshes the selected team or key budget while the menu bar app is running

## 6. Motion & Interaction

No decorative animation. Native popover transitions and button press feedback are retained. Refresh is explicit and periodic refresh does not steal focus

## 7. Depth & Surface

Use native macOS popover materials and tonal hierarchy. Do not add custom shadows or gradients

## 8. Accessibility Constraints & Accepted Debt

Percentage text remains readable without color. The chart uses visible labels as well as color to distinguish actual usage, forecast, and limit. The app does not expose a notification surface
