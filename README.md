# SwipeSay

A native macOS app for translating selected text or screenshots, understanding sentences in context, and saving useful expressions.

## Getting started

Open `SwipeSay.xcodeproj` in Xcode, select the SwipeSay scheme and My Mac, and run. The deployment target is macOS 14. The app is currently a SwiftUI starter; capture, OCR, translation providers, and vocabulary features are not implemented.

The shared project is generated from `project.yml`. After editing the spec, regenerate it with `xcodegen generate`.

## Planned workflow

- Translate a selection using surrounding context when the source app exposes it.
- Use on-device OCR for a user-selected screenshot region.
- Reveal useful phrases and sentence explanations on demand and save vocabulary.
- Support multiple model providers; investigate optional ChatGPT plan sign-in separately.
