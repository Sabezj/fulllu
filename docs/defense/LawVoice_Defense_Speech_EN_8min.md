# LawVoice Defense Speech (8-Minute Version)

Main flow: slides 1-15 and 18.
Slides 16-17 are backup slides for questions or extra time.

## Slide 1 (~0:20)

Good afternoon. My thesis presentation is about LawVoice, a voice-based intelligent assistant for teenagers. The current MVP is available as a web prototype and is designed as an educational tool for discussing everyday legal situations and practicing structured reasoning.

## Slide 2 (~0:20)

I will briefly cover the subject area, the relevance of the topic, the goal of the work, the current MVP, its architecture, the main user scenarios, the current limitations, and the next development steps. I will focus on what is already implemented and clearly separate it from what is still planned.

## Slide 3 (~0:35)

The subject area of this work is a voice-first assistant that helps teenagers talk through legal situations in a safe educational format. LawVoice is not positioned as a replacement for a lawyer. Instead, it structures the dialogue: first facts, then risks, then options, and finally a concrete next step. In technical terms, the current LawVoice prototype is a domain-specific layer built on top of an adapted realtime voice-agent base.

## Slide 4 (~0:40)

The topic is relevant for several reasons. Teenagers often face legal or quasi-legal conflicts outside a formal classroom, but they may not be ready to read long legal explanations. A voice format lowers the barrier to entry and makes the interaction more natural. At the same time, the value of the system is not only legal literacy but also critical thinking, because the user is encouraged to compare options and consequences instead of searching for one short answer.

## Slide 5 (~0:35)

The goal of the work is to develop and present the current MVP of a voice-based assistant that helps teenagers explore legal situations and practice structured reasoning. To reach this goal, I define the relevant scenarios, design safe dialogue logic and personas, implement the interface and voice interaction, and then identify the limits of the prototype together with the criteria for future evaluation.

## Slide 6 (~0:35)

This roadmap shows the logic of the project. In the current state, the first four stages are already represented at MVP level: subject analysis, scenario and role design, dialogue logic, and interface implementation. The last two stages, which are pilot testing and impact evaluation, are intentionally treated as future work because they require a separate empirical study and formal measurement design.

## Slide 7 (~0:45)

The user journey is intentionally simple. First, the teenager chooses a scenario and a LawVoice persona. Then the assistant asks for the minimum facts needed to understand the case without collecting unnecessary personal data. After that, LawVoice explains the relevant rights, obligations, and risks in plain language, offers several possible next steps, and finishes with one recommended action plus a short checklist for the next 24 hours. In this way, the conversation supports reasoning rather than passive advice consumption.

## Slide 8 (~0:45)

This slide summarizes what is already present in the current MVP. The interface includes several LawVoice personas, including mentor, peer, analyst, and safety roles. It supports teen and adult modes, a base system prompt, scenario and material input, a knowledge base for uploaded documents, realtime voice dialogue, draft action-plan generation, and analytics such as message count, token usage, and API cost. So the prototype is already more than a static concept slide deck; it is an interactive working MVP.

## Slide 9 (~0:50)

The architecture can be described in three layers. The interface layer contains profile selection, age mode, prompt editing, document input, voice controls, and visual widgets. The logic layer contains intent routing, the LawVoice dialog manager, safety-aware profile switching, and grounded action-plan generation. The AI and data layer combines the OpenAI Realtime API, WebRTC, a Node.js and Express backend, PostgreSQL with pgvector for knowledge chunks, and the current gpt-realtime-mini model. This is why I describe the project as a LawVoice domain layer built on top of an adapted realtime infrastructure.

## Slide 10 (~0:50)

At the moment, the MVP focuses on three main scenario groups. The first is cyberbullying, where the system helps clarify facts, separate evidence from emotion, and suggest safe next actions. The second is online purchases, where the assistant helps structure the situation around payment, delivery, receipts, screenshots, and possible complaint or return steps. The third is rights at school, where the goal is to explain obligations and boundaries in simple language and help the teenager prepare a calm and practical next step. Across all three scenarios, safety escalation remains a cross-cutting rule.

## Slide 11 (~0:40)

The interface is organized into three functional blocks. First, there is the preparation block, which includes persona selection, age mode, rules, prompt configuration, and document input. Second, there is the live dialogue block with the voice session, microphone, audio feedback, and context prompts. Third, there is the reflection and control block with the draft action plan, analytics, logs, and technical monitoring. This structure is convenient both for a demo session and for a future educational study.

## Slide 12 (~0:45)

It is important to state the limitations clearly. This version is still an MVP, so some interface and logic blocks are demonstrational rather than research-validated. There is no completed classroom pilot yet, so I do not claim measured educational impact. The current legal content is tailored to Russian-language scenarios and still needs expert legal and pedagogical review. In addition, any real educational deployment would require stronger privacy, moderation, and escalation procedures. So this presentation stays intentionally conservative in its claims.

## Slide 13 (~0:40)

The next development stage has three directions. The first is content expansion: more scenarios, documents, explanation modes, and role profiles. The second is safety and product maturity: stronger moderation logic, clearer escalation rules, and the replacement of remaining generic elements with fully LawVoice-specific components. The third is evaluation: a pilot study in an educational environment together with metrics for response quality, safety, legal literacy, and critical-thinking support.

## Slide 14 (~0:35)

In conclusion, the current result is a feasible concept and MVP of a voice-first educational legal assistant for teenagers. The prototype demonstrates that realtime voice interaction can support a reasoning process built around facts, risks, options, and the next step. At the same time, the project should be understood as a basis for further expert review and empirical testing, not as a finalized legal guidance product.

## Slide 15 (~0:20)

The presentation is based on three types of sources: the deployed LawVoice MVP, official OpenAI documentation for the realtime stack, and the current project documentation and implementation materials. I separate these sources deliberately so that the defense remains tied to the real current state of the project.

## Slide 16 (backup)

This is a backup slide. If needed, I can use it to show how the main screen is divided into preparation, live voice dialogue, and post-session reflection blocks.

## Slide 17 (backup)

This is also a backup slide. It summarizes the educational session logic as a short chain from situation to facts, rules and risks, options, and finally a recommended action with a 24-hour checklist.

## Slide 18 (~0:10)

Thank you for your attention. I will be glad to answer questions about the dialogue logic, the architecture, or the next research stage.
