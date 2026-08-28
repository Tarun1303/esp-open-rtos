# Fourth Law Control Room — “The Entity” UI
## Creative + Technical Handoff v1

## 1. Product Intent
Redesign the Fourth Law Control Room so it does **not** feel like a conventional SaaS dashboard. It should feel like the operator is standing in front of a calm, powerful, living superintelligence.

The UI must communicate five things within seconds:
1. What is the main mission?
2. What is the intelligence doing now?
3. Which agent layers are active?
4. What is progressing, completed, blocked, or waiting?
5. What final synthesis is emerging?

Theme keywords: **god-like, omniscient, minimal, premium, dark, alive, calm, superintelligent, high-signal, low-noise**.

Avoid: cyberpunk clutter, terminal-wall aesthetics, excessive neon, gaming RGB, generic enterprise cards, unnecessary charts, verbose text.

---

## 2. Signature Visual: The Entity Core
Create one dominant animated visual representing the Supervisor intelligence. It is the emotional anchor of the interface.

Recommended visual language:
- geometric singularity / neural halo / layered energy lattice
- subtle particles, rings, arcs, or signal lines
- dark graphite/blue-black space around it
- mostly CSS/SVG/Canvas state-driven animation; no AI calls required for rendering

State behavior:
- **Idle:** slow breathing pulse
- **Understanding / Thinking:** rotating inner rings, soft violet/cyan signal movement
- **Planning:** four branching rays or arcs begin forming
- **Delegating:** light flows from core toward agent modules
- **Executing:** stable higher-energy pulse
- **Verifying:** tighter rhythmic ring / scanning sweep
- **Blocked:** amber disturbance / fracture ripple
- **Complete:** convergence, calm bright center, gold-white accent used sparingly

Animation rule: every motion must communicate system state. Never animate purely for decoration.

---

## 3. Primary Information Architecture
Use a 3-zone control-room composition.

### Zone A — Mission Stage
The latest user mission remains visually dominant.

Must show:
- mission title in large typography
- optional context collapsed by default
- current phase: Understanding / Planning / Delegating / Executing / Verifying / Synthesizing / Complete
- compact overall progress
- elapsed time
- one-line current activity summary
- mission composer for next task

When active, mission title can have a restrained glow / animated underline.

### Zone B — Agent Layer Theater
This is the signature operational area.

Default layout: **Layer Stack View**, not a table.
- Layer 0: Supervisor / Entity
- Layer 1: exactly four primary modules
- Layer 2+: child agents only when the runtime actually delegates

Each agent card shows:
- agent name / concise role
- persistent one-line assigned objective/title
- live status
- compact progress strip
- subtask count
- child count if delegated
- blocker if any
- one-line result when complete

Active agent behavior:
- task title softly pulses/blinks while working
- border/rim glow indicates activity
- active subtask is visually highlighted

Completed agent behavior:
- card becomes calmer
- progress reaches full
- result capsule appears

Blocked agent behavior:
- amber/red accent
- concise blocker
- human intervention affordance if required

Optional later mode: **Constellation View** with radial nodes and animated result flow. Do not make it required for v1.

### Zone C — Live Intelligence Detail
The operator can inspect the selected agent or overall system.

Use structured summaries, never raw hidden chain-of-thought.
Show:
- current action summary
- current decision / assumption summary
- active subtask
- next action
- blocker
- verification state
- recent result snippet
- rolling synthesis summary

---

## 4. Agent / Subtask Interaction Model
For each agent, keep the assigned module/subtask title visible while it is active.

Expanded card/panel should show its subtask list:
- queued
- active
- complete
- blocked

Current active subtask gets:
- small progress strip
- moving state indicator
- concise status text

Progress must be deterministic/local whenever possible:
- completed subtasks / total subtasks
- current stage weighting if needed
- never call an LLM just to estimate UI progress

If deeper delegation happens, child agents appear beneath the parent in the next visual layer with a short spawn animation.

---

## 5. Mission Ignition / Synthesis “Wow” Moments
### Mission ignition
On submit:
- ambient background subtly dims
- Entity Core wakes
- mission locks into the mission stage
- four primary modules materialize in sequence

### Delegation cascade
When Supervisor assigns work:
- visual signal flows from Entity Core to the four module cards
- deeper child agents appear only when runtime actually creates them

### Synthesis convergence
As modules complete:
- result signals visually flow back toward the core / synthesis panel
- synthesis panel becomes more visually prominent
- final answer arrives with calm convergence, not fireworks

### Human intervention
When blocked:
- concise intervention drawer appears
- single clear question / required action
- after input, visual execution resumes continuously

---

## 6. Visual System
### Base
- background: near-black / graphite / deep blue-black
- surfaces: layered charcoal, subtle glass, restrained depth
- primary text: cool white
- secondary text: muted blue-gray

### Semantic accents
- Active intelligence: electric cyan / cool blue
- Thinking: violet + cyan
- Success: emerald / teal
- Warning: amber
- Failure/block: crimson-orange
- Final synthesis: restrained gold-white

No rainbow palette.

### Typography
- Mission: large clean cinematic sans
- UI: Inter / Manrope / Satoshi-style modern sans
- Micro-labels: compact uppercase / spaced labels sparingly
- Use hierarchy, spacing, and motion rather than excessive borders and text

---

## 7. Functional Panels
1. **Mission Composer** — goal + optional context + start mission + recent missions
2. **Entity Status Header** — health, active agents, current phase, memory status, optional cost indicator
3. **Entity Core** — animated supervisor state
4. **Supervisor Plan** — exactly four dynamic top-level modules + expected outcomes
5. **Agent Layer Explorer** — expandable layered hierarchy
6. **Selected Agent Detail** — objective, steps, progress, blocker, next action, result
7. **Live Event Feed** — concise structured events only
8. **Synthesis Panel** — emerging / final consolidated result
9. **Intervention Drawer** — only when user action is required
10. **Memory / Efficiency Widget** — shared core memory active, local agent notes, compression/freshness, token-governor status

---

## 8. Data / Backend Contract
The browser must render structured runtime state. It must not ask an LLM to create presentation state.

Prefer SSE for live updates with lightweight polling fallback.

Minimum browser payload per mission:
- mission metadata
- mission status + phase
- supervisor plan
- four top-level modules
- agent tree
- per-agent objective/title
- per-agent state
- subtasks[] with status
- completed / total counts
- blocker
- next action
- concise activity summary
- verification state
- result snippet
- final synthesis
- shared-memory health
- cost-governor summary

Never ship:
- API keys / admin secrets
- raw hidden chain-of-thought
- full internal conversation history
- giant repeated context blocks

Incremental snapshots/event patches are preferred over full giant state dumps when practical.

---

## 9. Local / Cheap Processing Rules
The interface must be computationally cheap and mostly local.

Use browser/server computation for:
- progress bars
- state animation
- agent layout
- expand/collapse state
- elapsed time
- filtering
- hierarchy rendering
- event highlighting
- status colors
- memory/cost visualizations

No LLM calls for UI animation, progress estimation, formatting, card text transformations, or layout decisions.

Reuse existing structured summaries produced by runtime.

Frontend optimization:
- incremental DOM/state updates
- client cache of expanded nodes
- CSS transforms / SVG / lightweight Canvas
- avoid heavy 3D/WebGL engine in v1
- virtualize only if task lists become long

---

## 10. Recommended Frontend Architecture
Preferred production direction:
- React + Vite (or equivalent lightweight SPA)
- Tailwind/custom design tokens
- Framer Motion or CSS/SVG animation
- SSE live stream
- lightweight client store such as Zustand

However, migration must respect the existing FastAPI Control Room. If replacing the current single HTML file with a SPA creates avoidable deployment complexity, stage the redesign:
1. build new visual shell against current REST/SSE contract
2. add missing backend fields
3. switch production route after regression passes

---

## 11. v1 Scope
Must have:
- dark premium Entity theme
- large main mission
- animated Entity Core with runtime state mapping
- exactly four primary module display
- layered agent hierarchy
- persistent active agent objective/title
- subtask list + deterministic progress strip
- selected agent inspector
- concise live event feed
- rolling/final synthesis panel
- intervention drawer
- memory + cost governor widget
- responsive MacBook-first layout

Do later:
- constellation mode
- timeline playback
- agent heatmap
- sound design toggle
- multi-mission wall
- model-routing analytics

---

## 12. Security / Privacy
- preserve current one-time pairing → HttpOnly secure session model
- public exposure remains only Control Room surface
- no secrets in browser
- no raw internal CoT
- sanitize errors before UI
- SSE endpoints must require session auth

---

## 13. Acceptance Criteria
The redesign passes only if an operator can answer at a glance:
- What mission is running?
- What is the Entity doing now?
- What are the four major modules?
- Which agents are active / complete / blocked?
- What subtask is each active agent working on?
- How much of each agent’s task is complete?
- What result is returning upward?
- Is human input required?
- Is shared memory/cost control healthy?

Visual acceptance:
- feels like a superintelligence control room, not a dashboard
- calm authority, not cyberpunk clutter
- readable on MacBook
- meaningful state-driven animation
- low text density
- no decorative motion without semantic meaning

---

## 14. Supervisor Execution Contract — Cost Efficient Design Pass
For this design/architecture pass:
- produce exactly **4 balanced major modules**
- max **2 local reasoning steps per major module**
- **do not create child agents** in this pass
- no browsing, shell, external actions, or deployment
- no repeated full brief/context in outputs
- use shared core memory and compact module-local notes
- deterministic validation first; no ceremonial LLM verification loops
- each module report <= 350 words
- final integrated implementation specification <= 1200 words

Expected four lanes should broadly cover:
1. Visual / interaction system
2. Information architecture + component system
3. Runtime data contracts + local rendering/performance
4. Migration, security, validation + phased rollout

Supervisor final output must include:
- final UI architecture
- component map
- exact runtime data additions required
- animation state machine
- frontend implementation approach
- migration plan from current Control Room
- phased build plan
- acceptance/regression checklist
- implementation risks and mitigations

The output should be directly usable to create the production UI release, not merely a conceptual design essay.
