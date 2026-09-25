# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

A Mac user who writes all day in other apps (chat, mail, documents, Copilot and
other AI tools, code editors) and wants to speak instead of type without sending
audio to a cloud service. They use bigvoice mostly through a global shortcut and
the floating capsule; the main window is for setup and model management.

## Product Purpose

bigvoice turns speech into text inside whatever app has focus, entirely on the
Mac, using small local models. Success is a dictation that lands in the right
field, with no account, no network, and no duplicated model downloads.

## Positioning

It reuses speech models already on the Mac, including the GitHub Copilot app's
Nemotron model, instead of downloading its own copies, and runs two local engines
(whisper.cpp and ONNX Runtime GenAI) behind one interface with live transcripts.

## Capabilities and Constraints

- Push-to-talk and hands-free shortcuts, customizable; Esc cancels.
- Input device selection; start and stop cues; optional automatic Return, off by
  default and gated on verified insertion; clipboard restoration.
- Discovery of compatible models on disk; one-click install of five small
  MIT-licensed Whisper models with pinned SHA-256 verification.
- Runs from the menu bar with a floating, non-focusing capsule.
- macOS 14+, Apple Silicon. Not sandboxed (Accessibility insertion and model
  reuse). The release build is signed but not notarized.

## Brand Commitments

The name is **bigvoice** (lowercase). The interface follows the provided brand &
interface system V2 (`design/brand-v2`): warm dark, Signal orange reserved for
sound, Bricolage Grotesque / Geist / Geist Mono, one five-bar mark for every
state. Tagline: "A small model. A big voice." Voice: plain, warm, brief.

## Product Principles

1. Private by construction: audio never leaves the Mac.
2. Reuse before download; never copy or modify other apps' models.
3. Never type into the wrong place: verify focus and insertion before acting.
4. Motion means sound: nothing animates unless something is listening or working.
5. Explain every failure in plain language, with the recovery.

## Accessibility & Inclusion

Honor Reduce Motion; keep text contrast at or above WCAG AA; label every control
for VoiceOver, including custom toggles and keycaps.

<!-- Platform is recorded as web because the Impeccable schema offers web/ios/android/adaptive;
     bigvoice is a native macOS app, which none of those values describe exactly. -->
