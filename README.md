# Drill

A flashcard app for Mac with a "learn" mode that climbs each card from multiple choice to written recall, plus optional AI that grades answers by meaning, explains mistakes, writes memory hooks and turns your notes into sets.

Works fully offline without AI. Your sets stay on your Mac.

A **Schedule** tab plans your day: drag out focus blocks, the gaps become breaks, and a timer counts down whichever one is now. Blocks take the usual keys: ⌘A, ⌘C, ⌘X, ⌘V, ⌘D, Delete, arrow keys to move, Shift-arrows to resize, Return to rename and ⌘Z to undo.

![Drill's home screen: the next set to study, a day streak, and every set with its progress](screenshot.png)

## Install

Needs macOS 13.3 (Ventura) or later, on Apple Silicon or Intel. On macOS 26 and later it uses Liquid Glass throughout. Updating from Drill 1.x brings your sets, streak and schedule over on first launch.

### Easiest: one line in Terminal (no security pop-ups)

1. Open **Terminal** (press ⌘ Space, type `Terminal`, press Return).
2. Paste this line and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/rishaank/drill/main/install.sh | bash
```

Drill installs into Applications and opens. Run the same line again any time to update; your sets are kept.

### Or: download the app

1. Download **Drill.dmg** from the [latest release](https://github.com/rishaank/drill/releases/latest).
2. Open it and drag **Drill** into **Applications**.
3. Double-click Drill. macOS says it "could not verify" Drill, because I don't pay Apple $99 a year to sign it. Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to Drill, and enter your Mac password.

You only do steps 3–4 once.

## AI (optional)

On a Mac with Apple Intelligence, AI is on from the start and runs privately on your Mac: free, offline, no account. Otherwise turn it on in the welcome screen or in **Drill → Settings…** (⌘,) and pick a provider:

| Provider | Tag | What you need |
|---|---|---|
| Apple Intelligence | Free · On This Mac | macOS 26 or later with Apple Intelligence turned on |
| Claude Code | Your Claude plan | The [Claude Code](https://claude.com/claude-code) app, logged in. Counts toward your plan's limits. |
| Google Gemini | Free Online | A free key from [Google AI Studio](https://aistudio.google.com/apikey) |
| Groq | Free Online | A free key from [Groq](https://console.groq.com/keys) |
| OpenRouter | Free Online | A free key from [OpenRouter](https://openrouter.ai/keys) (models ending in `:free`) |
| Ollama | Free Local | [Ollama](https://ollama.com/download) plus a model, e.g. `ollama pull gemma3` |
| LM Studio | Free Local | [LM Studio](https://lmstudio.ai) with its local server running |
| Anthropic API | Paid · API key | An Anthropic API key |
| OpenAI | Paid · API key | An OpenAI API key |
| Other | Any provider | Any OpenAI-compatible server: its URL, key and model |

API keys are saved only on your Mac (`~/Library/Application Support/Drill/keys.json`, readable only by your user) and are sent only to the provider you picked. Free online tiers have rate limits, and some providers may use free-tier prompts to train their models.

## Moving your sets

**File → Export All Sets…** (⇧⌘E) saves every set, with your progress, to one file. **File → Import Sets…** (⌘O) loads it on another Mac, or drop the file onto Drill's window. Drill set files import the same way; a notes or CSV file dropped on the window opens as a new set.

To have a chatbot build a set for you, use **File → Make a Set with a Chatbot**: copy a prompt for any chatbot, or save [`drill-set.skill`](drill-set.skill) to add to Claude. Either turns notes, PDFs or word lists into a ready-to-study Drill set file you paste into **File → New Set** (⌘N) or drop onto the window.

## Build it yourself

```bash
xcode-select --install
./build.sh
```

Drill is a native SwiftUI app (`Sources/`), built with Apple's command line tools from macOS 26 or later (the Liquid Glass SDK); the app itself still runs on macOS 13.3 and up. `build.sh` compiles it for Apple Silicon and Intel and writes `dist/Drill.dmg` and `dist/Drill.zip`. `./test.sh` builds it and runs the app's self-checks in a throwaway copy that can't touch your sets. To publish a release with GitHub's `gh` tool: `gh release create v1.0.0 dist/Drill.dmg dist/Drill.zip`.
