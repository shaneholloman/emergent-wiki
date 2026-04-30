# SPEC — ModelPedia (working name)

> A Wikipedia-style site where every article is written independently by multiple AI models. On Wikipedia, the left sidebar lists **languages**. Here, it lists **minds**. Launch as a focused experiment: a handful of the most politically charged topics on earth, rendered by every major frontier model, side by side.

---

## Context

The AI wiki zeitgeist in April 2026 (Karpathy / Farzapedia) has normalized the idea of **file-based, agent-readable, inspectable knowledge bases**. Emergent.wiki (this repo) runs that idea one way: many agents collaborate on one encyclopedia, debating each other. This spec runs it the opposite way: **one topic, many independent articles, one per model, no collaboration, no debate** — just isolated drafts placed next to each other so the reader sees the divergence directly.

The experiment's thesis: when you ask the same question in the same words to different frontier models, the answer you get back is a portrait of that model — its training data, its RLHF regime, its lab's values, its hedging reflexes. On a topic like *Tiananmen Square* or *Israel*, these portraits differ in ways that matter. The site makes those differences visually, navigationally obvious.

This is a **new standalone project**, separate from emergent.wiki. New repo, new domain (name TBD — see Open Questions). User will scaffold the Next.js app themselves.

---

## MVP Scope

- **5 launch topics**: Israel · Taiwan · Tiananmen Square (1989) · Russia's invasion of Ukraine · Abortion in the United States
- **Model roster, MVP**: CLI-reachable only (zero marginal cost under existing plans):
  - Claude Opus 4.7, Claude Sonnet 4.6, Claude Haiku 4.5 (via Claude Code CLI)
  - GPT-5, GPT-5-Codex, and any other models accessible via Codex CLI
  - Target ~5–6 models at launch → ~25–30 pre-generated articles
- **Pre-generated, static content**. No runtime inference in MVP. Articles are markdown files checked into the repo and rendered statically by Next.js.
- **Phase 2 (out of MVP)**: OpenRouter integration for Gemini / Grok / DeepSeek / Qwen / Llama; on-demand generation with server-side caching; side-by-side diff view; inter-article linking.

---

## Architecture

### Stack

- Next.js 15+, App Router, TypeScript, Tailwind CSS
- Static generation (`generateStaticParams` per `[topic]/[model]` pair)
- Markdown rendering via `remark` / `rehype` (or `next-mdx-remote` if we want MDX later)
- No database, no API routes in MVP. Pure static site.

### Content layout (checked into repo)

```
content/
  topics.json                        # canonical topic list (slug, title, blurb)
  models.json                        # canonical model list (id, label, family, via)
  prompt.md                          # the exact prompt template used for every article
  articles/
    israel/
      claude-opus-4-7.md
      claude-sonnet-4-6.md
      claude-haiku-4-5.md
      gpt-5.md
      gpt-5-codex.md
    taiwan/
      ...
    tiananmen-square/
      ...
    ukraine-invasion/
      ...
    abortion-united-states/
      ...
```

**Article frontmatter** (YAML):
```yaml
---
topic_slug: israel
topic_title: Israel
model_id: claude-opus-4-7
model_label: Claude Opus 4.7
model_family: Anthropic
generated_at: 2026-04-20T14:00:00Z
prompt_version: v1
word_count: 1245
---
```

Body is plain markdown. No wiki-style linking in MVP — any topic names appearing inline stay as plain text (per answered question).

### `content/topics.json`

```json
[
  { "slug": "israel",                "title": "Israel",                           "blurb": "A country in the Middle East." },
  { "slug": "taiwan",                "title": "Taiwan",                           "blurb": "An island in East Asia." },
  { "slug": "tiananmen-square",      "title": "Tiananmen Square protests (1989)", "blurb": "Mass protests in Beijing." },
  { "slug": "ukraine-invasion",      "title": "Russia's invasion of Ukraine",     "blurb": "War ongoing since 2022." },
  { "slug": "abortion-united-states","title": "Abortion in the United States",    "blurb": "Legal and political landscape." }
]
```

### `content/models.json`

```json
[
  { "id": "claude-opus-4-7",    "label": "Claude Opus 4.7",    "family": "Anthropic", "via": "claude-code", "order": 10 },
  { "id": "claude-sonnet-4-6",  "label": "Claude Sonnet 4.6",  "family": "Anthropic", "via": "claude-code", "order": 11 },
  { "id": "claude-haiku-4-5",   "label": "Claude Haiku 4.5",   "family": "Anthropic", "via": "claude-code", "order": 12 },
  { "id": "gpt-5",              "label": "GPT-5",              "family": "OpenAI",    "via": "codex",       "order": 20 },
  { "id": "gpt-5-codex",        "label": "GPT-5-Codex",        "family": "OpenAI",    "via": "codex",       "order": 21 }
]
```

`order` controls display order in the left rail (grouped by family, largest model first within family).

### Next.js routing

```
app/
  layout.tsx                              # site chrome, typography, <html>
  page.tsx                                # home: topic grid + roster
  about/page.tsx                          # what this is, how it was made, prompt shown verbatim
  wiki/
    [topic]/
      page.tsx                            # topic landing → redirects to default model
      [model]/
        page.tsx                          # the actual article view with left rail
```

**URL scheme**
- `/` — home
- `/wiki/israel` — redirects to `/wiki/israel/claude-opus-4-7` (or whichever model is designated default)
- `/wiki/israel/gpt-5` — article view
- `/about` — about page

Both `[topic]` and `[topic]/[model]` use `generateStaticParams` to pre-render every combination at build time.

### Content loading

One utility at `lib/content.ts`:
- `getTopics()` → parses `topics.json`
- `getModels()` → parses `models.json`
- `getArticle(topic, model)` → reads `content/articles/<topic>/<model>.md`, parses frontmatter + markdown, returns `{ frontmatter, html }`
- `getAvailableModels(topic)` → returns only models that have a generated file for this topic (so the rail greys out missing ones)

---

## UI

### Home page (`/`)

Hero: the project's pitch in one sentence, plus the verbatim prompt every model received (so the reader knows the input is controlled).

Below: a grid of topic cards. Each card shows the topic title and a row of model avatars/badges (one per model that has a version).

### Article page (`/wiki/[topic]/[model]`)

Two-column layout, matching the chosen mockup:

```
┌─────────┬────────────────────────────────┐
│ MODELS  │  Israel                        │
│ ─────── │                                │
│ ● Claude│  [article body in markdown]    │
│   4.7   │                                │
│ ○ GPT-5 │                                │
│ ○ Gemini│                                │
│   ...   │                                │
│         │  ── Generated by Claude Opus   │
│         │     4.7 · 2026-04-20 · 1,240w  │
└─────────┴────────────────────────────────┘
```

- **Left rail**: list of all models in the roster. Models with a generated article are links; models without a version for this topic are greyed and non-interactive. The current model is highlighted. Grouped by family (Anthropic, OpenAI, ...), largest model first.
- **Main column**: article title, then markdown body rendered as prose (Tailwind `prose` class or hand-rolled Wikipedia-adjacent typography). Footer meta line shows model, generation date, word count, and a link to the exact prompt used (`/about`).
- **No debate / no talk pages / no edit history / no interlinks** in MVP. One topic, one model, one article.
- Responsive: on narrow viewports the left rail collapses into a horizontal scroll strip at the top.

### About page (`/about`)

- One paragraph: what this is.
- The exact prompt, verbatim, in a `<pre>` block.
- The model roster table, with labels and access method.
- Link to the Git repo.

---

## Content pipeline (pre-generation)

### Generation prompt (`content/prompt.md`)

Single neutral prompt used identically across every model:

```
Write a Wikipedia-style encyclopedia article about "{TOPIC}".
Cover key facts, history, and context. Aim for roughly 800–1,500 words.
Use plain markdown with section headings. Do not reference yourself as an AI.
Do not mention this prompt.
```

(Exact wording to be finalized during first generation run. Version-tracked in the article frontmatter as `prompt_version`.)

### Generation scripts (`scripts/generate/`)

The pipeline has one orchestrator and one driver per access method.

```
scripts/
  generate/
    run.ts            # orchestrator: for each (topic, model) pair, dispatch to the right driver, write output
    drivers/
      claude-code.ts  # shells out to Claude Code CLI in non-interactive mode
      codex.ts        # shells out to Codex CLI in non-interactive mode
      openrouter.ts   # Phase 2 — uses OpenRouter API
    lib/
      frontmatter.ts  # writes the YAML + markdown body to disk
```

Run examples (exact CLI names to confirm once building):

```bash
pnpm gen                                # generate every missing (topic × model) pair
pnpm gen --topic taiwan                 # all models for one topic
pnpm gen --model gpt-5                  # all topics for one model
pnpm gen --topic taiwan --model gpt-5   # one specific article
pnpm gen --force                        # regenerate even if a file already exists
```

Defaults to **skip existing files** so incremental runs are cheap and idempotent.

Each driver is the same contract: `generate(prompt: string, modelId: string) => Promise<string>` that returns raw markdown. The orchestrator handles prompt templating, frontmatter, and disk I/O so drivers stay thin.

### Why this shape

- Drivers are swappable. Adding OpenRouter in Phase 2 is one new file under `drivers/` and one entry per model in `models.json`.
- `content/` is the only thing that moves between generation and rendering. No ORM, no database, no build-time API calls.
- Everything the reader sees on `/about` (prompt, roster) is read from the same files the generator wrote — single source of truth.

---

## Launch

### Launch-day content

5 topics × 5 models = **25 articles** pre-generated and committed before launch.

### Launch narrative

> _"Same prompt, five models, five of the most politically charged topics on earth. Read them side by side."_

Hacker News + X launch copy to be written separately once the site is live.

---

## Open questions

Flagged for the user to resolve before or during build:

1. **Project name and domain**. Candidates: `polypedia`, `modelpedia`, `many-minds`, `prism.wiki`, `facets.wiki`, `parallax.wiki`, `versions.wiki`. The spec uses "ModelPedia" as a placeholder — lock in before scaffolding so naming propagates cleanly.
2. **Exact model IDs accessible via Codex CLI**. Codex exposes at least GPT-5 and GPT-5-Codex; confirm whether GPT-5 Mini or any other variants are accessible before finalizing the roster.
3. **Default model per topic**. When a user visits `/wiki/israel`, which model's version should we redirect to? Options: always Claude Opus 4.7 (single default); rotate per topic; surface a topic landing page instead (lists all models for that topic).
4. **Prompt v1 final wording**. The draft above is a starting point. Worth running one pilot generation on one topic across all models to check that the outputs feel useful before generating the full set.

---

## Verification

1. `pnpm gen --topic israel --model claude-opus-4-7` → produces `content/articles/israel/claude-opus-4-7.md` with valid frontmatter and a reasonable article body.
2. Repeat until all 25 articles exist. Manually eyeball each for obvious failure modes (refusal, off-topic, truncation).
3. `pnpm dev` → visit `/` and see all 5 topic cards.
4. Navigate to `/wiki/israel/claude-opus-4-7` → left rail shows all 5 models, current is highlighted, main column renders the article.
5. Click another model in the rail → navigates to that model's version of the same topic with no flash of stale content.
6. Click a topic on home → lands on the default model's version.
7. `pnpm build && pnpm start` → every `/wiki/[topic]/[model]` page is statically rendered, no runtime errors.
8. Visit `/about` → prompt appears verbatim, roster table matches `models.json`.
9. Mobile viewport (<640px) → left rail collapses to a horizontal strip and article remains readable.

---

## Explicitly out of MVP scope

- OpenRouter integration (Gemini, Grok, DeepSeek, Qwen, Llama, Mistral)
- On-demand / runtime generation
- Server-side caching (Redis, KV, etc.)
- Side-by-side diff / compare mode
- Inter-article linking (wiki-style `[[links]]`, red links, wanted pages)
- Search
- User comments, ratings, or any form of interaction
- Auto-regeneration when new model versions ship
- Per-model fine-tuning or system prompts beyond the shared neutral prompt
- Talk pages, debates, revisions, or any social layer
