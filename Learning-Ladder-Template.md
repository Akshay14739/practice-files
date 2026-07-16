# The Learning Ladder 🪜
### A reusable framework for learning any technology deeply — not just memorizing commands

---

## How to use this

1. When a new topic lands (Karpenter, ArgoCD, Istio, anything), **copy Part A** into a note and fill it in as you learn.
2. Use **Part B** (the AI prompt) to have Claude or any AI teach you *up the ladder* instead of dumping commands at you.
3. Fill the worksheet **during** the learning session, not after — the act of answering each rung in your own words is what builds the model.

**The one rule that fixes the "borrow-for-speed" trap:**
> Always start **three rungs lower** than feels necessary. Your instinct is to jump to the commands (top of the ladder). The rungs underneath — Pain, One Idea, Machinery — are what make the knowledge *stick*.

**The test of whether you actually own something:** you can explain it in one sentence with no notes, and you can *predict* what a change will do before you run it.

---

# PART A — The Fill-In Worksheet

*(Copy this section fresh for each new technology. Write your answers under each rung.)*

---

### 🎯 Rung 0 — The Setup
- **What am I learning?**
- **Why did it land on my desk?** (the task/situation that triggered it)
- **What do I already know about it?** (be honest — none is fine)

_Your answer:_


---

### 🔥 Rung 1 — The Pain
*Why does this thing exist at all?*
- What problem **forced** this to be invented?
- What did people do **before** it? What was painful about that?
- What **breaks** if you don't have it?
- Who feels this pain most — developers, ops, security, the platform team, me?

_Your answer:_


---

### 💡 Rung 2 — The One Idea
*The single sentence everything else hangs off.*
- In **one sentence**, what is the core trick?
- If I could keep only one sentence about this forever, what is it?
- Check: does my sentence let me *derive* the rest of the system, or is it just a definition?

_Your answer (make it ONE sentence):_


---

### ⚙️ Rung 3 — The Machinery *(the most important rung — go slow)*
*How does it actually work under the hood — the physics, not the API?*
- What are the **moving parts**, and what talks to what?
- Where does the **real mechanism** happen? (the specific "how")
- What's going on that the **app/user never sees**?
- If I had to draw it on a whiteboard from memory, what's in the picture?

_Your answer:_


---

### 🏷️ Rung 4 — The Vocabulary Map
*Pin every scary term to its role in the machinery above.*

| Scary term | What it actually is | Which part of the machinery it touches |
|---|---|---|
|  |  |  |
|  |  |  |
|  |  |  |

- Which of these terms are **the same kind of thing** wearing different names?

_Notes:_


---

### 🎬 Rung 5 — The Trace
*Follow ONE concrete request/action end-to-end.*
- Pick one real action. Where does it **start**?
- Step by step, which **component handles it** at each hop, and what does that component do?
- Where does it **end**?

_Your trace (number the steps):_
1.
2.
3.
4.


---

### ⚖️ Rung 6 — The Contrast
*The boundary of a concept defines the concept.*
- What's the **older / alternative** way to do this?
- What can this do that the alternative **can't**? (and vice versa)
- When would I **NOT** use this?
- One-sentence "why this over that":

_Your answer:_


---

### 🧪 Rung 7 — The Prediction Test *(the habit that changes everything)*
*Write predictions BEFORE running anything. Wrong predictions = your model repairing itself.*

| Prediction: "If I do X, then Y will happen, because [mechanism]" | Ran it? | Right? | If wrong — what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

---

### 🎁 Capstone — Compress It
*If you can't do this, you've found your gap — which is useful.*
- **One sentence, no notes:**
- **Explain it to a beginner in 3 sentences:**
- **Which rung do I still feel shaky on?** (that's your next hands-on session)

_Your answer:_


---
---

# PART B — The AI Learning Prompt

*Paste this into Claude (or any AI), fill in the three slots at the top, and it will teach you up the ladder instead of dumping commands. Adjust the slots each time.*

```
I want to deeply learn [TECHNOLOGY / CONCEPT] and build a lasting mental model — not
just memorize commands that I'll forget after the task ships.

My context:
- My background: [e.g. Senior Kubernetes Platform Engineer, ~6 yrs support/DevOps,
  newer to Linux internals and coding]
- Why I'm learning this now: [the actual task/situation that triggered it]
- What I already know about it: [none / some / list what I know]

Teach me using this "Learning Ladder." Climb the rungs strictly in order, bottom to
top. The goal is that I can DERIVE answers, not recall them.

1. The Pain — What problem forced this to exist? What did people do before it, and what
   breaks without it? Who feels the pain most?
2. The One Idea — The single core sentence everything else hangs off. State it
   explicitly and tell me to memorize it.
3. The Machinery — How it ACTUALLY works under the hood: the moving parts, what talks to
   what, and where the real mechanism happens. Explain what's happening that the app/user
   never sees. This is the most important rung — go slow here.
4. The Vocabulary Map — Take the scary jargon and pin each term to its role in the
   machinery from rung 3. Point out which terms are the same kind of thing.
5. The Trace — Pick ONE concrete request/action and follow it end-to-end, step by step,
   naming which component does what at each hop.
6. The Contrast — Compare it to the older/alternative approach. What can it do that the
   alternative can't, and when should I NOT use it?
7. The Prediction Test — Give me 3 "if I do X, then Y happens, because [mechanism]"
   predictions I can actually run and verify myself, so I can test and repair my model.

Then finish by: compressing the whole thing into ONE sentence I should be able to say
cold; giving a 3-sentence beginner explanation; and telling me honestly which rung I'll
most likely need to revisit hands-on.

Rules:
- Prioritize the WHY and the mechanism over API/commands. Commands come LAST, only after
  I understand what they're doing.
- Use plain analogies where they help, and tie explanations to my background and my task.
- Don't dump everything at once. Teach one rung (or two), then pause and check my
  understanding with a quick question before moving on, so I'm not overwhelmed.
  (If I say "do it all in one go," then give me the full ladder in a single response.)
- The first time you use a term I might not know, define it in one line.
```

---

**Reuse tip:** keep the filled-in worksheets. After 5–10 of them you'll notice the *same core concepts* keep showing up across different tools (proxies, control loops, reconciliation, iptables, DNS). Those recurring ones are your real curriculum — learn each deeply once, and a huge chunk of your future "unknowns" collapse on their own.
