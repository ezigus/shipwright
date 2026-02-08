# Shipwright Design System

Version 2.0 — February 2026

---

## 1. Brand Mission & Vision

### Mission

Shipwright orchestrates fully autonomous Claude Code agent teams. It takes a GitHub issue and delivers a production-ready PR — planning, building, testing, reviewing, and deploying without human intervention. One command replaces an entire sprint.

### Vision

Engineering teams that ship 10x with AI crews. A future where every developer commands a fleet of specialized agents, where "ready to build" is the last label a human ever applies, and where DORA metrics hit Elite not because of heroics but because the machines never sleep.

### Brand Personality

**The Authoritative Captain meets the Fun Crew.** Shipwright is the master shipbuilder who knows every plank and rivet — confident, precise, deeply technical. But the crew brings energy. The tone is direct and engaging, never corporate. Think "senior engineer who actually enjoys their work" — not a sales deck, not a tutorial for beginners.

The nautical metaphor is foundational, not decorative. Shipwright literally means "master ship builder." The "ship right" pun reinforces the quality promise. Lean into the metaphor where it clarifies (pipelines as voyages, templates as crew manifests, repos as fleet vessels) but never force it where plain language works better.

### Brand Pillars

- **Autonomy** — Zero human intervention from issue to PR
- **Quality** — Compound quality loops, self-healing builds, automated review
- **Scale** — One daemon, one fleet, one org — the architecture grows with you
- **Intelligence** — Persistent memory, adaptive templates, self-optimizing metrics

---

## 2. Color Palette

### Ocean Depths — Primary Backgrounds

The background palette moves through literal ocean depth zones, from the abyssal plain to the surface. Every background in the system draws from these five values.

| Token        | Hex       | Usage                                      |
|--------------|-----------|---------------------------------------------|
| `--abyss`    | `#060a14` | Page background, deepest layer, canvas fill |
| `--deep`     | `#0a1628` | Card backgrounds, nav backdrop, terminal bg |
| `--ocean`    | `#0d1f3c` | Elevated surfaces, hover states, borders    |
| `--surface`  | `#132d56` | Active card backgrounds, input fields       |
| `--foam`     | `#1a3a6a` | Highest elevation, tooltips, dropdowns      |

### Accent Spectrum

| Token            | Hex                          | Usage                                     |
|------------------|------------------------------|-------------------------------------------|
| `--cyan`         | `#00d4ff`                    | Primary accent, CTAs, active states, links |
| `--cyan-glow`    | `rgba(0, 212, 255, 0.15)`   | Glow effects, hover halos, card highlights |
| `--cyan-dim`     | `rgba(0, 212, 255, 0.4)`    | Borders, scrollbar thumbs, dividers       |
| `--purple`       | `#7c3aed`                    | Secondary accent, gradients, stage labels  |
| `--purple-glow`  | `rgba(124, 58, 237, 0.15)`  | Purple hover halos, icon backgrounds      |
| `--blue`         | `#0066ff`                    | Tertiary accent, gradient endpoints        |

### Status Colors

| Token      | Hex       | Usage                              |
|------------|-----------|-------------------------------------|
| `--green`  | `#4ade80` | Success states, completed stages, passing tests |
| `--amber`  | `#fbbf24` | Warnings, in-progress stages, agent names       |
| `--rose`   | `#f43f5e` | Errors, failed stages, critical alerts          |

### Text Hierarchy

| Token              | Hex       | Usage                                    |
|--------------------|-----------|-------------------------------------------|
| `--text-primary`   | `#e8ecf4` | Headlines, body text, primary content     |
| `--text-secondary` | `#8899b8` | Descriptions, subtitles, supporting copy  |
| `--text-muted`     | `#5a6d8a` | Labels, timestamps, disabled states       |

### Gradient Recipes

**Primary CTA gradient:**
```css
background: linear-gradient(135deg, var(--cyan), var(--blue));
```

**Hero headline shimmer:**
```css
background: linear-gradient(135deg, var(--cyan) 0%, var(--purple) 50%, var(--cyan) 100%);
background-size: 200% 100%;
animation: shimmer 6s ease-in-out infinite;
```

**Stat/number gradient text:**
```css
background: linear-gradient(135deg, var(--cyan), var(--purple));
-webkit-background-clip: text;
-webkit-text-fill-color: transparent;
```

**Card top-edge reveal on hover:**
```css
background: linear-gradient(90deg, transparent, var(--cyan), transparent);
/* Animate opacity from 0 to 0.5 */
```

### Selection Color

```css
::selection {
  background: var(--cyan);
  color: var(--abyss);
}
```

### Usage Rules

1. Never use pure white (`#ffffff`) or pure black (`#000000`) anywhere
2. `--abyss` is the only full-page background
3. Cyan is the single dominant accent — purple and blue support it but never compete
4. Status colors (green/amber/rose) are reserved for semantic meaning only
5. All transparency uses the CSS custom property values, not hardcoded rgba

---

## 3. Typography

### Font Stack

| Role    | Family                                         | Token            |
|---------|-------------------------------------------------|------------------|
| Display | `'Instrument Serif', Georgia, serif`            | `--font-display` |
| Body    | `'Plus Jakarta Sans', system-ui, sans-serif`    | `--font-body`    |
| Code    | `'JetBrains Mono', 'SF Mono', monospace`        | `--font-mono`    |

All three families are loaded via Google Fonts with `display=swap` to prevent FOIT:

```html
<link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=JetBrains+Mono:wght@400;500;700&family=Plus+Jakarta+Sans:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">
```

### Instrument Serif — Display

The editorial serif that gives Shipwright its personality. Used exclusively for large-scale type.

| Use Case             | Size                          | Weight | Style  | Letter-spacing |
|----------------------|-------------------------------|--------|--------|----------------|
| Hero headline        | `clamp(3.5rem, 10vw, 8rem)`  | 400    | normal | `-0.02em`      |
| Hero italic line     | `clamp(3.5rem, 10vw, 8rem)`  | 400    | italic | `-0.02em`      |
| Section titles       | `clamp(2.2rem, 5vw, 3.5rem)` | 400    | normal | `-0.02em`      |
| CTA headlines        | `clamp(2.5rem, 6vw, 4rem)`   | 400    | normal | `-0.02em`      |
| Scale numbers        | `clamp(3rem, 6vw, 4.5rem)`   | 400    | normal | `0`            |
| Stat values          | `2.5rem`                      | 400    | normal | `0`            |
| Voyage step numbers  | `3.5rem`                      | 400    | normal | `0`            |
| Scale unit labels    | `1.2rem`                      | 400    | italic | `0`            |
| Nav logo text        | `1.5rem`                      | 400    | normal | `0.02em`       |
| Footer brand         | `1.1rem`                      | 400    | normal | `0`            |

### Plus Jakarta Sans — Body

Clean geometric sans-serif for all readable content. Load weights 300 through 800.

| Use Case             | Size                          | Weight | Letter-spacing |
|----------------------|-------------------------------|--------|----------------|
| Hero subtitle        | `clamp(1.1rem, 2.5vw, 1.35rem)` | 300 | `0`            |
| Section descriptions | `1.1rem`                      | 300    | `0`            |
| Body paragraphs      | `0.9rem`                      | 400    | `0`            |
| Card titles          | `1.05–1.1rem`                 | 700    | `0`            |
| Card descriptions    | `0.82–0.88rem`                | 400    | `0`            |
| Nav links            | `0.85rem`                     | 500    | `0.04em`       |
| Button text          | `0.95rem`                     | 700    | `0.02em`       |
| Nav CTA              | `0.8rem`                      | 700    | `0.06em`       |
| Testimonial text     | `0.95rem`                     | 400    | `0`            |
| Testimonial name     | `0.85rem`                     | 600    | `0`            |

### JetBrains Mono — Code

Monospace for anything that represents commands, code, or system output.

| Use Case             | Size       | Weight | Letter-spacing |
|----------------------|------------|--------|----------------|
| Hero badge           | `0.75rem`  | 400    | `0.06em`       |
| Section labels       | `0.7rem`   | 700    | `0.2em`        |
| Feature tags         | `0.65rem`  | 400    | `0.04em`       |
| Template name        | `0.85rem`  | 700    | `0`            |
| Template agent count | `0.65rem`  | 400    | `0`            |
| Install commands     | `0.9rem`   | 400    | `0`            |
| Terminal body        | `0.82rem`  | 400    | `0`            |
| Pipeline labels      | `0.65rem`  | 400    | `0.08em`       |
| Install method label | `0.7rem`   | 700    | `0.1em`        |
| Footer links         | `0.8rem`   | 400    | `0`            |

### Global Type Settings

```css
html {
  font-size: 16px;
  -webkit-font-smoothing: antialiased;
}
body {
  font-family: var(--font-body);
  line-height: 1.7;
  color: var(--text-primary);
}
```

### Text Transform Rules

- Section labels: `text-transform: uppercase`
- Nav links: `text-transform: uppercase`
- Stat labels: `text-transform: uppercase`
- Social bar text: `text-transform: uppercase`
- Install method labels: `text-transform: uppercase`
- Everything else: sentence case

---

## 4. Spacing Scale

Based on a 4px base unit. All spacing values derive from this scale.

| Token   | Value   | Common Use                                |
|---------|---------|-------------------------------------------|
| `xs`    | `4px`   | Inline gaps, icon padding                 |
| `sm`    | `8px`   | Tight element gaps, badge padding         |
| `md`    | `16px`  | Standard element spacing, card gaps       |
| `lg`    | `24px`  | Section label lines, icon container size  |
| `xl`    | `32px`  | Card padding, nav padding                 |
| `2xl`   | `48px`  | Large card padding, section header gaps   |
| `3xl`   | `64px`  | Grid gaps between sections                |
| `4xl`   | `96px`  | Minimum section vertical padding          |
| `5xl`   | `160px` | Maximum section vertical padding          |

### Section Gaps

```css
--section-gap: clamp(6rem, 12vw, 10rem);
/* 96px minimum, scales with viewport, 160px max */
```

### Component Spacing Patterns

| Component         | Padding / Gap                   |
|-------------------|---------------------------------|
| Nav               | `1rem 2rem` (16px 32px)         |
| Hero              | `6rem 2rem 4rem`                |
| Section           | `var(--section-gap) 2rem`       |
| Container         | `max-width: 1200px; margin: 0 auto` |
| Voyage card       | `2.5rem` (40px)                 |
| Feature card      | `2.25rem` (36px)                |
| Template card     | `1.5rem` (24px)                 |
| Testimonial card  | `2rem` (32px)                   |
| Terminal body     | `1.5rem` (24px)                 |
| Install command   | `0.75rem 1.5rem` (12px 24px)   |
| Button primary    | `0.85rem 2rem` (14px 32px)     |
| Button secondary  | `0.85rem 2rem` (14px 32px)     |
| Footer            | `3rem 2rem` (48px 32px)        |

### Grid Gaps

| Grid              | Gap                             |
|-------------------|---------------------------------|
| Voyage grid       | `1px` (separator style)         |
| Features grid     | `1px` (separator style)         |
| Templates grid    | `1rem` (16px)                   |
| Testimonials grid | `1.5rem` (24px)                 |
| Scale grid        | `2rem` (32px)                   |
| Stats row         | `3rem` (48px)                   |
| Nav links         | `2rem` (32px)                   |
| Hero actions      | `1rem` (16px)                   |

### Border Radius Scale

| Use Case           | Radius   |
|--------------------|----------|
| Pill / badge       | `100px`  |
| Large card / grid  | `16px`   |
| Card / terminal    | `12px`   |
| Icon container     | `12px`   |
| Button / input     | `8px`    |
| CTA button (nav)   | `6px`    |
| Tag / small badge  | `4px`    |
| Dot / circle       | `50%`    |

---

## 5. SVG Icon Design Specs

### Style Guidelines

All icons follow a consistent design language:

- **Grid:** 24x24 viewBox (`viewBox="0 0 24 24"`)
- **Stroke width:** 1.5px default, 2px for emphasis
- **Stroke caps:** Round (`stroke-linecap="round"`)
- **Stroke joins:** Round (`stroke-linejoin="round"`)
- **Fill:** `none` by default (line art style)
- **Color:** `currentColor` for all strokes, enabling CSS color theming
- **Alignment:** Center-aligned within the 24x24 grid
- **Padding:** 2px visual padding from edge (content within 20x20 area)
- **Corners:** Rounded where natural, sharp only for technical/geometric shapes

### Nav Logo — Ship Icon (32x32)

The nav logo uses a 32x32 viewBox. It depicts a stylized ship hull with a mast and sail rigging:

```svg
<svg viewBox="0 0 32 32" fill="none">
  <path d="M16 2L4 12l4 16h16l4-16L16 2z" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.6"/>
  <path d="M16 2v26" stroke="url(#mast)" stroke-width="1.5"/>
  <path d="M16 8l10 6" stroke="currentColor" stroke-width="1" opacity="0.4"/>
  <path d="M16 8l-10 6" stroke="currentColor" stroke-width="1" opacity="0.4"/>
  <path d="M16 14l8 4" stroke="currentColor" stroke-width="1" opacity="0.3"/>
  <path d="M16 14l-8 4" stroke="currentColor" stroke-width="1" opacity="0.3"/>
  <circle cx="16" cy="6" r="2" fill="url(#mast)"/>
  <defs>
    <linearGradient id="mast" x1="16" y1="2" x2="16" y2="28">
      <stop offset="0%" stop-color="#00d4ff"/>
      <stop offset="100%" stop-color="#7c3aed"/>
    </linearGradient>
  </defs>
</svg>
```

The logo is the one place where a cyan-to-purple gradient is applied directly to SVG strokes.

### Icon Categories

**Navigation Icons (16x16 viewBox for inline use):**

| Icon       | Purpose                   | Notes                              |
|------------|---------------------------|------------------------------------|
| Arrow up   | Install CTA, scroll       | Filled circle with upward arrow    |
| Play       | Watch Demo button         | Simple triangle                    |
| GitHub     | View on GitHub CTA        | GitHub octocat mark                |
| Copy       | Copy-to-clipboard action  | Text label, not an icon            |
| External   | External link indicator   | Arrow pointing upper-right         |

**Pipeline Stage Icons:**

Currently using emoji characters for pipeline stages. For V2, these should be replaced with custom SVG icons following the 24x24 spec:

| Stage     | Concept                   | Visual Direction                   |
|-----------|---------------------------|------------------------------------|
| intake    | Incoming signal           | Inbox/tray with downward arrow     |
| plan      | Charting course           | Compass or map with route          |
| design    | Blueprint                 | Drafting angle / protractor        |
| build     | Construction              | Hammer or wrench                   |
| test      | Verification              | Flask / beaker                     |
| review    | Inspection                | Magnifying glass with checkmark    |
| quality   | Seal of approval          | Shield with check                  |
| pr        | Outbound delivery         | Outbox with upward arrow           |
| merge     | Convergence               | Git merge / branching paths        |
| deploy    | Launch                    | Rocket or ship leaving port        |
| validate  | Confirmation              | Flag / finish line                 |
| monitor   | Observation               | Satellite dish / telescope         |

**Feature Icons:**

Currently using emoji characters. For V2, replace with custom SVGs:

| Feature          | Concept         | Visual Direction                   |
|------------------|------------------|------------------------------------|
| Daemon           | Watchful eye     | Eye with signal waves              |
| Fleet            | Ship formation   | Multiple vessels / stacked ships   |
| Auto-scale       | Dynamic growth   | Ascending bar chart with arrows    |
| DORA metrics     | Dashboard        | Chart/graph with trend line        |
| Compound quality | Iterative cycle  | Circular arrows / refresh loop     |
| Worktree         | Branch isolation  | Tree with separate branches        |

**Voyage Step Icons:**

| Step               | Concept              | Visual Direction                |
|--------------------|----------------------|---------------------------------|
| Chart the Course   | Planning/navigation  | Clipboard with compass rose     |
| Assemble the Crew  | Team formation       | Anchor with radiating lines     |
| Set Sail           | Active building      | Sailboat with wind              |
| Navigate Waters    | Quality/review       | Ship wheel / compass            |
| Make Port          | Delivery             | Flag on a dock                  |
| Watch the Horizon  | Monitoring           | Telescope / spyglass            |

**Template Category Icons:**

These can be simpler 20x20 icons used inside template cards:

| Template       | Icon Concept                      |
|----------------|-----------------------------------|
| feature-dev    | Crane / construction              |
| code-review    | Magnifying glass                  |
| security-audit | Shield with lock                  |
| bug-fix        | Bug with X mark                   |
| testing        | Flask / test tube                 |
| migration      | Database with arrow               |
| architecture   | Columns / building                |
| devops         | Gear with circular arrow          |
| documentation  | Open book / scroll                |
| refactor       | Shuffle / rearrange arrows        |
| exploration    | Binoculars / compass              |
| full-stack     | Stacked layers                    |

### Icon Container Styling

Icons sit inside styled containers with gradient backgrounds:

```css
.icon-container {
  width: 48px;     /* Voyage: 48px, Feature: 40px */
  height: 48px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 12px;
  background: linear-gradient(135deg, rgba(0, 212, 255, 0.1), rgba(124, 58, 237, 0.1));
  border: 1px solid rgba(0, 212, 255, 0.15);
}
```

Feature icons use semantic color variants:
- Daemon: green-to-cyan gradient
- Fleet: blue-to-cyan gradient
- Scale: purple-to-cyan gradient
- DORA: amber-to-cyan gradient
- Quality: rose-to-cyan gradient
- Worktree: cyan-to-purple gradient

---

## 6. Animation Principles

### Philosophy

Animations serve three purposes: (1) communicate state transitions, (2) guide attention through content hierarchy, and (3) reinforce the nautical atmosphere of depth and movement. Every animation should feel like it belongs underwater — smooth, flowing, slightly weighted by the current.

### Scroll-Triggered Reveals

The primary entrance animation for all content blocks:

```css
.reveal {
  opacity: 0;
  transform: translateY(30px);
  transition: opacity 0.8s ease-out, transform 0.8s ease-out;
}
.reveal.visible {
  opacity: 1;
  transform: translateY(0);
}
```

Triggered via IntersectionObserver at `threshold: 0.1` with `rootMargin: '0px 0px -50px 0px'`.

**GSAP upgrade path (V2):** Replace CSS transitions with GSAP ScrollTrigger for staggered grid reveals:

```js
gsap.utils.toArray('.feature-card').forEach((card, i) => {
  gsap.from(card, {
    scrollTrigger: { trigger: card, start: 'top 85%' },
    opacity: 0,
    y: 40,
    duration: 0.6,
    delay: i * 0.08,
    ease: 'power2.out'
  });
});
```

### Hero Entrance Sequence

Staggered `fadeInUp` animations with increasing delays:

| Element         | Delay  |
|-----------------|--------|
| Hero badge      | 0.2s   |
| Hero title      | 0.4s   |
| Hero subtitle   | 0.6s   |
| Action buttons  | 0.8s   |
| Install command | 1.0s   |
| Scroll indicator| 1.2s   |

```css
@keyframes fadeInUp {
  from { opacity: 0; transform: translateY(20px); }
  to { opacity: 1; transform: translateY(0); }
}
```

### Headline Shimmer

The italic hero line uses a background-position animation to create a slow color-shifting shimmer:

```css
@keyframes shimmer {
  0%, 100% { background-position: 0% 50%; }
  50% { background-position: 100% 50%; }
}
/* Duration: 6s, ease-in-out, infinite */
```

### Particle Ocean (Background Canvas)

A persistent canvas layer behind all content. 120 particles with:

- Subtle drift (`vx/vy` at 0.4 max velocity)
- Mouse-responsive repulsion (200px radius, 0.02 force)
- Connection lines between nearby particles (150px threshold, 0.08 max alpha)
- Bright accent particles (15% chance) with cyan glow halos
- Deep ocean gradient background (abyss to deep to ocean, back to abyss)
- Subtle nebula radial glow (cyan center fading to purple)

**V2 enhancement:** Add parallax wave layers using SVG path animations or GSAP-driven sine waves layered between content sections.

### Terminal Typewriter

Lines appear sequentially with increasing delays, simulating a real pipeline execution:

- Each line starts hidden (`opacity: 0; transform: translateY(4px)`)
- Lines transition in with `transition: all 0.3s ease-out`
- A blinking cursor appears after the final line
- Animation is triggered once by IntersectionObserver at `threshold: 0.3`

**V2 upgrade:** Use GSAP timeline for precise typewriter character-by-character rendering of the command line, with instant reveals for output lines.

### Counter Animation

Scale numbers count up from 0 to their target value:
- Step size: `Math.ceil(target / 30)`
- Interval: 40ms
- Triggered once by IntersectionObserver at `threshold: 0.5`

### Micro-Interactions

| Element           | Trigger | Effect                                   |
|-------------------|---------|------------------------------------------|
| Primary button    | hover   | `translateY(-2px)` + cyan box-shadow     |
| Secondary button  | hover   | Border color shift to cyan, text to cyan |
| Nav CTA           | hover   | `translateY(-1px)` + subtle box-shadow   |
| Feature card      | hover   | Background brightens + top-edge gradient |
| Template card     | hover   | Border cyan + `translateY(-2px)`         |
| Pipeline dot      | hover   | `scale(1.15)`                            |
| Pipeline label    | hover   | Color shift to cyan                      |
| Voyage step       | hover   | Background brightens subtly              |
| Install command   | hover   | Border + background shift                |
| Install command   | click   | Copy text changes to "Copied!"           |

### Persistent Animations

| Element         | Keyframes      | Duration | Easing          |
|-----------------|----------------|----------|-----------------|
| Status dot      | `pulse`        | 2s       | ease-in-out     |
| Scroll wheel    | `scrollWheel`  | 2s       | ease-in-out     |
| Terminal cursor | `terminalBlink`| 1s       | step-end        |
| Hero shimmer    | `shimmer`      | 6s       | ease-in-out     |

### Performance Guidelines

1. Use `transform` and `opacity` exclusively for animations — never animate `width`, `height`, `top`, `left`, or `margin`
2. Apply `will-change: transform, opacity` only on elements that are actively animating, remove after
3. The particle canvas uses `requestAnimationFrame` — throttle or pause when tab is not visible
4. On mobile (under 768px): reduce particle count to 60, disable mouse repulsion, simplify connection drawing
5. Prefer CSS transitions for simple hover effects; reserve GSAP for complex sequenced animations
6. `prefers-reduced-motion: reduce` should disable all keyframe animations and set transitions to 0s

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
  }
}
```

---

## 7. Tone of Voice

### Core Principles

**Direct.** Say what Shipwright does. Don't hedge with "helps you" or "enables teams to." The daemon watches GitHub. The pipeline delivers PRs. Agents build code. Active voice, present tense, concrete subjects.

**Confident.** Shipwright is good and we know it. No "we believe" or "we think." State facts. Show numbers. Let the terminal demo speak for itself. Confidence is earned by the compound quality loops, the DORA metrics, the self-healing builds.

**Technical.** The audience is engineers. They know what DORA metrics are. They know what a tmux pane is. They know what CI means. Don't explain the basics. Do explain what makes Shipwright's approach different.

**Engaging.** This is not enterprise middleware documentation. Short sentences have punch. Longer sentences have rhythm. Vary the cadence. A good section title makes you want to read the section.

### Nautical Metaphors — When and How

The nautical vocabulary is a strength when used deliberately:

**Do use:**
- "Voyage" for the pipeline journey (issue to PR)
- "Fleet" for multi-repo operations
- "Crew" for agent teams
- "Chart the course" for planning
- "Set sail" for build kickoff
- "Make port" for delivery/deploy
- "Seaworthy" for code that passes quality gates
- "Captain" for the engineer commanding the fleet

**Don't use:**
- Forced metaphors that obscure meaning ("barnacle-free codebase")
- Maritime jargon nobody knows ("abaft the beam")
- Metaphors that contradict technical accuracy
- Nautical terms where a plain word is clearer

### Headline Patterns

Section labels are short, uppercase mono — a category tag:
> THE VOYAGE / CAPABILITIES / LIVE PIPELINE / FLEET SCALE / CREW MANIFESTS

Section titles are Instrument Serif, personal, sometimes questions:
> "From issue to production. Fully autonomous."
> "Everything you need to command the fleet."
> "Built for the scale of real engineering."
> "12 specialized crews. Every mission covered."
> "Ready to command the fleet?"

### Copy Patterns

**Feature descriptions** are two sentences max. First sentence states what it does. Second sentence states why it matters or how it works differently.

> "Watches GitHub for labeled issues, triages by priority, and spawns delivery pipelines automatically. Sleeps when idle, wakes when needed."

**Voyage descriptions** are three sentences max. Context, mechanism, outcome.

> "The daemon spots a labeled GitHub issue, triages priority, and plots the delivery strategy. Context from past voyages is loaded automatically."

**Terminal output** is authentic. It mirrors real Shipwright output formatting — box-drawing characters, stage prefixes in brackets, check marks for completion, timing and cost at the end. Never fake or simplify the CLI output.

### Words We Use

| Instead of...           | We say...                    |
|-------------------------|------------------------------|
| helps you ship code     | ships code                   |
| AI-powered solution     | autonomous agents            |
| leverage                | use                          |
| utilize                 | use                          |
| innovative              | (just describe what it does) |
| seamless                | automatic                    |
| cutting-edge            | (just describe what it does) |
| end-to-end              | from issue to PR             |
| paradigm shift          | (never)                      |
| synergy                 | (never)                      |

### What We Never Do

- Use emoji in any text content (icons are SVG, not emoji — V1 uses emoji as placeholders only)
- Exclamation marks in body copy (headlines may occasionally, but sparingly)
- Rhetorical questions that feel like sales copy ("Tired of slow deployments?")
- Buzzword-heavy sentences ("AI-first cloud-native DevOps platform")
- Passive voice when active voice is possible
- Gendered language or assumptions about the user
- Promise specific performance numbers we can't back up (the testimonials are illustrative)

---

## 8. Component Reference

### Buttons

**Primary (CTA):**
```css
display: inline-flex;
align-items: center;
gap: 0.5rem;
padding: 0.85rem 2rem;
background: linear-gradient(135deg, var(--cyan), var(--blue));
color: var(--abyss);
font-weight: 700;
font-size: 0.95rem;
border-radius: 8px;
letter-spacing: 0.02em;
```

**Secondary (Ghost):**
```css
display: inline-flex;
align-items: center;
gap: 0.5rem;
padding: 0.85rem 2rem;
background: rgba(255, 255, 255, 0.04);
color: var(--text-primary);
font-weight: 600;
font-size: 0.95rem;
border-radius: 8px;
border: 1px solid rgba(255, 255, 255, 0.1);
```

### Cards

**Grid-style (Voyage, Features):** 1px gap grid with separator aesthetic. Cards have `rgba(6, 10, 20, 0.8–0.85)` background. Hover brightens to `rgba(0, 212, 255, 0.02–0.03)`. Outer wrapper has `border-radius: 16px` and `overflow: hidden`.

**Standalone (Templates, Testimonials):** Individual cards with visible borders (`rgba(0, 212, 255, 0.06–0.08)`) and `border-radius: 12px`. Hover lifts with `translateY(-2px)` and strengthens border color.

### Tags

```css
display: inline-block;
padding: 0.15rem 0.5rem;
background: rgba(0, 212, 255, 0.08);
border: 1px solid rgba(0, 212, 255, 0.15);
border-radius: 4px;
font-family: var(--font-mono);
font-size: 0.65rem;
color: var(--cyan);
letter-spacing: 0.04em;
```

### Terminal Window

```css
border-radius: 12px;
border: 1px solid rgba(0, 212, 255, 0.12);
box-shadow:
  0 0 60px rgba(0, 212, 255, 0.06),
  0 20px 60px rgba(0, 0, 0, 0.4);
```

Titlebar: Three dots (red `#ff5f57`, yellow `#febc2e`, green `#28c840`), title in muted mono text, `rgba(13, 31, 60, 0.9)` background.

Body: `rgba(6, 10, 20, 0.95)` background, JetBrains Mono at `0.82rem`, line-height `1.8`.

Terminal syntax colors:
| Class        | Color              | Usage                    |
|--------------|--------------------|--------------------------|
| `.t-prompt`  | `var(--cyan)`      | `$` prompt character     |
| `.t-cmd`     | `var(--text-primary)` + bold | Command names   |
| `.t-flag`    | `var(--purple)`    | CLI flags                |
| `.t-string`  | `var(--green)`     | String arguments         |
| `.t-dim`     | `var(--text-muted)`| Stage prefixes, metadata |
| `.t-info`    | `var(--cyan)`      | Info messages            |
| `.t-success` | `var(--green)`     | Success indicators       |
| `.t-warn`    | `var(--amber)`     | Agent names, warnings    |
| `.t-stage`   | `var(--purple)`    | Stage announcements      |
| `.t-box`     | `rgba(0, 212, 255, 0.4)` | Box-drawing chars |

### Nav

Fixed position, transparent on load, frosted glass on scroll:

```css
nav.scrolled {
  background: rgba(6, 10, 20, 0.85);
  backdrop-filter: blur(20px) saturate(1.5);
  border-bottom: 1px solid rgba(0, 212, 255, 0.08);
}
```

### Scrollbar

```css
scrollbar-width: thin;
scrollbar-color: var(--cyan-dim) var(--deep);
```

---

## 9. Responsive Breakpoints

| Breakpoint | Width     | Changes                                     |
|------------|-----------|----------------------------------------------|
| Desktop    | > 900px   | Full layout — 3-col features, 4-col scale    |
| Tablet     | <= 900px  | 2-col features, 2-col scale, nav links hidden, install options stack |
| Mobile     | <= 600px  | 1-col everything, vertical hero actions, vertical stats |

### Mobile-Specific Adjustments

- Nav links collapse (hamburger menu in V2)
- Hero actions stack vertically
- Stats row becomes vertical
- Install options drop min-width and stack label + command
- Particle count drops to 60
- Scale card dividers hidden
- Grid separator borders remain (single column reads like a list)

---

## 10. Asset Checklist

### Fonts (Google Fonts CDN)
- [x] Instrument Serif (normal + italic)
- [x] Plus Jakarta Sans (300, 400, 500, 600, 700, 800)
- [x] JetBrains Mono (400, 500, 700)

### Icons Needed (V2 Custom SVG)
- [ ] Nav logo (ship) — 32x32 (exists, may refine)
- [ ] Pipeline stage icons x12 — 24x24
- [ ] Feature icons x6 — 24x24
- [ ] Voyage step icons x6 — 24x24
- [ ] Template category icons x12 — 20x20
- [ ] UI icons: arrow-up, play, github, external-link, copy, menu — 16x16

### External Libraries (V2)
- [ ] GSAP + ScrollTrigger (for advanced animations)
- [ ] Optional: Lottie for complex SVG animations

### Images
- [ ] Open Graph image (1200x630) for social sharing
- [ ] Favicon set (16, 32, 180, 192, 512) — ship silhouette on abyss background

---

## Appendix: CSS Custom Properties (Complete)

```css
:root {
  /* Ocean depths palette */
  --abyss: #060a14;
  --deep: #0a1628;
  --ocean: #0d1f3c;
  --surface: #132d56;
  --foam: #1a3a6a;

  /* Accent spectrum */
  --cyan: #00d4ff;
  --cyan-glow: rgba(0, 212, 255, 0.15);
  --cyan-dim: rgba(0, 212, 255, 0.4);
  --purple: #7c3aed;
  --purple-glow: rgba(124, 58, 237, 0.15);
  --blue: #0066ff;
  --green: #4ade80;
  --amber: #fbbf24;
  --rose: #f43f5e;

  /* Text */
  --text-primary: #e8ecf4;
  --text-secondary: #8899b8;
  --text-muted: #5a6d8a;

  /* Typography */
  --font-display: 'Instrument Serif', Georgia, serif;
  --font-body: 'Plus Jakarta Sans', system-ui, sans-serif;
  --font-mono: 'JetBrains Mono', 'SF Mono', monospace;

  /* Spacing */
  --section-gap: clamp(6rem, 12vw, 10rem);
}
```
