# Paid Trial Project — GTM Engineer, Noble

Thanks for the time on the interview. This is the next step: a short, paid project so we can see how you think about a real problem we have right now.

**Payment:** $150 USD, flat, paid on submission — whether or not we move forward together.
**Time:** Please stop at four hours. We would rather see an honest four-hour result than a polished twelve-hour one. How you decide what to cut is part of what we're looking at.
**Due:** Wednesday, July 29 — do the work whenever suits you inside that window.
**Questions:** Please send any by midday Friday, July 24 (noon Pacific). I'm away Monday through Wednesday, so that's the window where I can actually give you a useful answer.
**After:** A 30-minute call where you walk us through what you built and why.

---

## About Noble

When someone asks ChatGPT or Claude "what's the best CRM software," the model doesn't invent an answer. It pulls from third-party articles — listicles, comparisons, buyer's guides — and cites them.

Noble gets our customers mentioned in those articles. We monitor the prompts their buyers are actually asking, find the articles the LLMs cite to answer them, and work with those publishers to include or correct our customer's mention.

That makes us a two-sided business. Brands on one side. Publishers on the other. We run outbound to both.

We're about ten people. Marketing is me and a content lead. We've been growing very quickly, and most of our systems were built fast rather than built well. That's the job.

---

## The stack you'd have

**Outbound:** Apollo, Clay, Instantly (email), HeyReach (LinkedIn)
**Automation:** n8n, Claude Code
**Customer comms:** customer.io
**CRM:** HubSpot, plus Revenue Hero for demo scheduling
**Data:** a Postgres read replica of the Noble platform database
**Call recordings:** Fathom — transcripts of every sales call, demo, and internal meeting
**Web:** Webflow, Google Analytics
**Partner tools:** Profound and Scrunch, both with MCP servers we've barely touched

Assume you have access to all of it. If your approach needs something not on this list, say so and say why.

---

## The problem

We run outbound across email and LinkedIn. Leads are sourced in Apollo, enriched in Clay, and sent through Instantly and HeyReach. We send from multiple domains, with several sending addresses on each domain.

The sending infrastructure itself is solid. Domains, authentication, warming, and inbox rotation are all handled and working. Don't spend your four hours there — the problem is everything upstream and downstream of the send.

We're also still figuring out our ICP. We sell to B2B software companies, to consumer and retail brands, and to agencies, and we don't yet know which of those we're actually best for. So we need to run a lot of messaging experiments and learn from them.

Right now we can't reliably answer any of these:

- Who have we contacted?
- On which channel, from which domain, with which message?
- What happened — did they reply, book, go quiet?
- When is it safe to contact them again, and with what?

There is no system of record. Every campaign is its own island. **Design the thing that fixes that.**

### Constraints

- A person should never be contacted by more than one Noble sending domain. Ever.
- A person should never be in two live experiments at the same time.
- Suppression has to work at both the person level and the company level. Current customers, open opportunities, do-not-contact requests, and partner conflicts all need to be excluded.
- There needs to be a recycle rule: when can someone re-enter outbound, and under what conditions.
- Every send needs to be attributable to an experiment — some combination of message, segment, and persona — so we can actually learn something.
- It has to work across email and LinkedIn, not just email.
- It has to reconcile with HubSpot without HubSpot becoming the bottleneck.

### What we're giving you

Attached is a CSV of roughly 2,000 contacts representing the kind of list we'd work from. It's realistic, which means it is not clean.

---

## What to deliver

**1. Architecture — one page.**
Where does truth live? What syncs to what, in which direction, triggered by what? A diagram plus a few paragraphs is plenty. We don't need it pretty.

**2. The data model.**
Tables or objects, fields, keys. Be explicit about your deduplication key and why you picked it over the alternatives.

**3. One working component.**
Your choice — build whichever piece you think is most load-bearing. An n8n workflow that ingests a reply event and updates state. A Clay table that applies the suppression logic. A SQL script that produces a send-eligible list from the attached data. Something else you think matters more. It should actually run.

**4. A short note on what breaks.**
Top three failure modes. What you'd monitor to catch them. And what you deliberately chose not to build in four hours, and why.

Send it however is easiest — repo, Google Drive folder, Loom, whatever. Format isn't being graded.

---

## Ground rules

**Use AI.** Claude, Codex, whatever you normally reach for. We use it constantly and we'd think it was strange if you didn't. The walkthrough call is where we'll dig into your reasoning, so make sure you understand what you're handing us.

**Ask questions.** This brief is deliberately underspecified, because the real work is too. If something is ambiguous, email me. Asking is not a mark against you — it's the opposite.

**Push back.** If you think the framing is wrong, or that we're solving the wrong problem, say so in your submission. Some of the best outcomes here would start with someone telling me I've set this up badly.

Looking forward to seeing what you come up with.

Jason
