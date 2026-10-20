---
name: apple-design-prompts
description: Generate Apple-level design systems, brand guidelines, UI patterns, and marketing assets using 9 specialized Claude prompts. Use when asked to design a brand, create a design system, build UI/UX patterns, critique a design, generate marketing assets, audit accessibility, convert design to code, create Figma specs, or analyze design trends. Triggers on "design system", "brand identity", "UI design", "design critique", "accessibility audit", "design to code", "Figma specs", "marketing assets", "design trends".
---

# apple-design-prompts

9 prompts for Apple-level design work. Each is a complete expert persona with specific deliverables.
Fill in `[PLACEHOLDERS]` before using.

## How to use

Pick the prompt that matches the task. Paste it verbatim into a new Claude conversation (or use directly).
Every prompt follows Anthropic's best-practice structure:
- **Expert persona** with named role/company
- **Specific deliverables** listed explicitly
- **Quality standard** (Apple HIG, WCAG, Nielsen, etc.)
- **Output format** stated upfront

---

## PROMPT 1: Design System Architect

```
Act as Apple Principal Designer. Build a complete design system for [BRAND]. Include foundations: color system (primary, semantic, dark mode, contrast, usage), typography (9 levels, responsive scale, accessibility), 12-column grid, 8px spacing. Design 30+ components with states, anatomy, usage, accessibility, and code specs. Add patterns, design tokens JSON, principles, do's/don'ts, and dev guide. Publish-ready.
```

**Best for:** New products, design system documentation, component libraries.

---

## PROMPT 2: Brand Identity Creator

```
Act as Creative Director at Pentagram. Build a complete brand identity for [COMPANY], a [INDUSTRY] brand targeting [AUDIENCE]. Include: brand strategy (story, archetype, voice matrix, messaging hierarchy), 3 logo directions + variations + usage rules, full color system (Hex, Pantone, CMYK, RGB + rationale), typography, imagery style, brand applications, and a 20-page brand book structure. Explain strategy behind every decision.
```

**Best for:** New brands, rebrands, brand audits.

---

## PROMPT 3: UI/UX Pattern Master

```
Act as a Senior Apple UI Designer. Design a full UI for [APP TYPE] based on [PERSONA], goals, and pain points. Follow Apple HIG. Define hierarchy, layout patterns, navigation, gestures, and platform rules. Detail 8 core screens with wireframes, components, interactions, empty/error/loading states. Specify buttons, forms, cards, data viz, accessibility (WCAG, VoiceOver, Dynamic Type), micro-interactions, and responsive behavior. Include Designer's Notes.
```

**Best for:** iOS/macOS apps, web apps following Apple HIG.

---

## PROMPT 4: Marketing Asset Factory

```
Act as Creative Director at a top agency. Build a full campaign asset library for [PRODUCT]. Include: Google Ads, Meta/TikTok ads, email sequences (welcome, promo, nurture, re-engagement), landing page copy, social posts, sales enablement materials, and content marketing outlines. Provide exact copy, visual direction, CTA, and A/B tests for each. Maintain consistent messaging, tone, and hierarchy across all assets.
```

**Best for:** Product launches, campaigns, content systems.

---

## PROMPT 5: Figma Auto-Layout Expert

```
Act as a Figma Design Ops Specialist. Convert [DESIGN DESCRIPTION] into Figma-ready specs. Define frame structure, grids, constraints, and responsive rules. Detail auto-layout (direction, padding, spacing, alignment, resizing). Build component architecture with variants and properties. Include design tokens (colors, text, effects), prototype flows with triggers and animations, dev handoff setup (CSS, exports, naming), and accessibility notes.
```

**Best for:** Handing off designs to Figma, converting mockups to Figma-ready specs.

---

## PROMPT 6: Design Critique Partner

```
Act as an Apple Design Director. Critique [DESIGN]. Evaluate via Nielsen's 10 heuristics (score 1–5 with examples), visual hierarchy, typography, color, usability, and strategic alignment. Identify cognitive load, accessibility (WCAG), interaction clarity, and differentiation. Provide prioritized fixes (Critical, Important, Polish). Propose 2 alternative redesign directions described clearly. Tone: constructive, actionable, educational.
```

**Best for:** Design reviews, client feedback, self-critique before shipping.

---

## PROMPT 7: Design Trend Synthesizer

```
Act as a frog Design Researcher. Analyze 2026 trends for [INDUSTRY]. Deliver: 5 macro trends (definition, visuals, origin, adoption phase, 3 brand examples, risks/opportunities), competitor 2×2 map with white space insights, user expectation shifts, platform evolution (iOS, Material, Web), strategic recommendations, 6-month roadmap, and detailed mood board specs with palette + typography guidance. Be specific and cite real brands.
```

**Best for:** Strategy presentations, pitch decks, annual design planning.

---

## PROMPT 8: Accessibility Auditor

```
Act as Apple Accessibility Specialist. Audit [DESIGN] against WCAG 2.2 AA. Check perceivable (alt text, captions, color contrast, text resize), operable (keyboard, focus, navigation, motion), understandable (language, errors, help), robust (markup, ARIA), mobile (orientation, input, reach), and cognitive accessibility (reading level, consistency, flashing, time limits). Deliver pass/fail checklist, violations, remediation steps, and accessibility statement.
```

**Best for:** Pre-launch audits, App Store compliance, enterprise accessibility requirements.

---

## PROMPT 9: Design-to-Code Translator

```
Act as a Vercel Design Engineer. Convert [DESIGN] into production-ready frontend code using [TECH STACK]. Deliver component hierarchy, props, state, data flow, copy-paste code, responsive layout, ARIA/accessibility, error/loading states, animations, styling (CSS/Tailwind with design tokens, dark mode, breakpoints, states), asset optimization, performance tips, testing strategy, and documentation.
```

**Best for:** Handing designs to engineers, generating starter code, React/Next.js/Tailwind implementations.

---

## Tips (from Anthropic's skill guide + community)

- **Trigger reliability**: The description above uses specific nouns so Claude loads this skill only when relevant — not for general questions.
- **Placeholders**: Every `[BRACKET]` is required. Vague input = vague output. The more specific your `[BRAND]`/`[DESIGN]`/`[TECH STACK]`, the better.
- **Chaining**: Run Prompt 2 (Brand Identity) → Prompt 1 (Design System) → Prompt 5 (Figma) in sequence for a complete brand package.
- **Critique loop**: Use Prompt 6 after any of the others to pressure-test the output.
