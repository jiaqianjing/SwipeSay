# SwipeSay

A native macOS menu-bar translator: select text or capture a screen region, get a context-aware translation, and learn the expressions worth keeping.

## Features

- **Selection translation (⌥D)** reads the selection *and the paragraph around it* through the Accessibility API (native text views plus WebKit/Chromium text markers). The model uses that context only to resolve ambiguity, so pronouns, polysemous words and terminology come out right. When an app exposes no accessibility text, SwipeSay falls back to ⌘C and restores your clipboard afterwards.
- **Quick button**: select text with the mouse and a small coral button appears next to the cursor. Click it to translate.
- **Screenshot translation (⌥S)** uses the system crosshair, then on-device Vision OCR that rebuilds paragraphs from the line layout.
- **Input translation (⌥A)** opens a Spotlight-style box.
- **Word cards**: selecting a single word or short phrase shows its meaning in context, phonetics, senses, the example sentence and a usage tip.
- **Key expressions capsule (✦ 重点表达)** is collapsed by default. Expanding it extracts the phrases, collocations and words worth learning, chosen for your level (set in Settings → 学习), and highlights them in the source sentence.
- **On-demand sentence analysis**: the capsule also decides whether a sentence deserves analysis. Only genuinely complex sentences, or idiomatic everyday ones, get a **解析句子** button. Pressing it produces the sentence skeleton and meaningful chunks with their roles, or the tone and alternatives for a conversational line, plus key takeaways and a simpler paraphrase.
- **Vocabulary book**: words you look up and key expressions are added automatically, with the source sentence and app. It has search, flashcard review with spaced repetition, and CSV export.
- **Providers**:
  - ChatGPT subscription sign-in (the Codex OAuth flow, or import an existing `~/.codex/auth.json`).
  - OpenAI, Anthropic, Google Gemini and DeepSeek.
  - Any OpenAI-compatible server: OpenRouter, Moonshot, Qwen, Zhipu, Ollama, LM Studio and others.
  - API keys are stored in the login Keychain.

## Build

Requires Xcode 16+ and macOS 14+.

```bash
xcodegen generate
open SwipeSay.xcodeproj
```

The shared project is generated from `project.yml`. Re-run `xcodegen generate` after adding files or editing the spec.

On first launch, grant:

- **Accessibility**, for reading selections and context and for the ⌘C fallback.
- **Screen Recording**, for screenshot translation. You may need to relaunch the app after granting it.

Debug builds are ad-hoc signed, so macOS may ask for these permissions again after a rebuild. If a permission looks granted but doesn't work, remove SwipeSay from the list and add it again.

### Why no App Sandbox

Reading other apps' selections (`AXUIElement`), posting ⌘C, and the localhost OAuth callback are not allowed in the sandbox. Bob and Easydict ship outside the Mac App Store for the same reason. Hardened Runtime stays on.

## Project layout

```
SwipeSay/
  App/AppDelegate.swift          hotkeys, actions, launch flow
  SwipeSayApp.swift              menu bar extra
  Core/
    Capture/                     AX selection + context, quick button, screenshot OCR
    Hotkey/                      Carbon global hotkeys, Shortcut model
    LLM/                         provider configs, Keychain, clients (OpenAI-compatible,
                                 Anthropic, Gemini, ChatGPT/Codex), ChatGPT OAuth
    Translation/                 prompts, response models, language/mode planning
    Vocabulary/                  SwiftData store (~/Library/Application Support/SwipeSay)
    Settings/                    AppSettings (UserDefaults)
  UI/
    Popup/                       floating panel, view model, capsule + analysis views
    Settings/  Vocabulary/  Components/
```

All prompts live in `Core/Translation/Prompts.swift`.

### UI work without an API key (Debug only)

```bash
SwipeSay.app/Contents/MacOS/SwipeSay -SwipeSayMock YES \
  -SwipeSayDemo "No sooner had she set foot in the house than she felt an inexplicable sense of dread." \
  -SwipeSayDemoExpand YES
```

`-SwipeSayMock` swaps in canned responses and an in-memory vocabulary. `-SwipeSayOpen providers|general|shortcuts|learning|vocabulary` opens a window directly.

## Notes

- The ChatGPT sign-in uses the Codex endpoints (`auth.openai.com` OAuth, `chatgpt.com/backend-api/codex/responses`). They are not a documented public API and may change.
- Anthropic requests use low effort and server-side refusal fallbacks on models that support them, to keep translations fast.
