# Noble outbound — system of record

Four deliverables in one file: the architecture, the data model, the working component, and what breaks. The component is real SQL that runs on the supplied CSV in this repo; every number below came out of it rather than out of an estimate.

```
make up && make load && make eligible && make test
```

Ten seconds, Docker and Postgres 16, no credentials, no network calls. §4 has the full command set, the reading order, and where the implementation disagrees with its own design notes. The reasoning trail — nine decision tickets, two research files, the counts each rule was designed against — is in `.scratch/noble-outbound-sor/` and is happily available if useful; it is not required to read any of this.

**The short version.** Truth is an append-only event log in a Postgres Noble owns. Every other system produces events into it or is a projection out of it, HubSpot included, in both directions. Identity is a surrogate key with an alias table, because every natural key in this dataset fails on a case the dataset actually contains. Eligibility is computed as a query at send time, never stored as a flag, because HeyReach has no writable blocklist and the ledger is the only enforcement point that exists for LinkedIn. On the supplied file: **2,154 rows → 2,114 people → 723 eligible, 1,391 rejected, each rejection naming the rule that did it and the evidence behind it.**

Three things in here disagree with the brief. They are in §6, argued rather than hinted at.

**§1 comes first on purpose.** It is the questions I would have sent you and the assumptions I used in their place — because every design decision after it rests on one of those calls, and you should be able to overturn any of them before reading a line of the thing they produced. The four deliverables are §2 through §5.

---

## 1. The questions I would have asked, and what I did instead

The brief invited questions by midday Friday the 24th and I did not get to them inside that window, with you away Monday to Wednesday after it. So none of these got asked. That is my miss, and I want to be straight about it rather than let the assumptions read as though the ambiguity was never noticed.

It did not stop the work, because the alternative to an answer is a **stated assumption**, and an assumption carrying its reasoning and its price is auditable in a way a silent guess never is. Every one below was resolved the same way: find what the supplied data actually says, pick the reading that fails least expensively if I am wrong, and write down the number it costs. Where the data could not settle it, I chose the option that is cheapest to reverse.

Roughly twenty questions came up. These are the ones where a different answer from you would have produced different work — the rest resolved themselves against the file. Ordered by what they are worth.

### The one I would have sent first

| Question | What I assumed | Why |
| --- | --- | --- |
| **When a company has an open opportunity, does that freeze the whole account for outbound, or only the named buying committee?** | The whole company | Worth **~900 people — 42% of the file**, far more than every other decision in this project combined. `opportunity` here is a *contact* lifecycle stage (70 contacts across 55 companies, ~1.3 each), so the committee is known by name and person-scoping was genuinely available. I took the conservative reading on asymmetry: a cold sequence landing at a company mid-negotiation can cost a deal in flight, while a suppressed prospect costs only delay — and it is the failure a sales team notices first, which is the failure that costs a new system its mandate. It is one predicate to flip, and the rejection ledger already names all 912 people it excludes, so you can price the other reading in about a minute |

### Identity

| Question | What I assumed | Why |
| --- | --- | --- |
| Is Apollo's `contact_id` stable across re-pulls? | No | It is Apollo's key, not Noble's, and it is meaningless for the 33% of rows from Clay, forms, referrals and uploads. If it *were* stable it would still lose to a surrogate, so the assumption is cheap |
| When Apollo, Clay, a form and HubSpot disagree about someone's email or company, is there a source precedence order? | No precedence needed; last-write-wins with the ordered rule list as tiebreak | Measured: in this file `notes` and HubSpot **never** disagree — all 11 "active Noble account" rows carry `customer`, all 8 "open opp" rows carry `opportunity`, zero conflicts. No arbitration is needed for data that agrees with itself, and inventing a hierarchy on zero evidence is how you get a rule nobody can justify later |
| The ~30 people in ambiguous identity clusters — merge them, or hold them? | Hold both members, surfaced as `identity:needs_review` | The harm is asymmetric and not in the intuitive direction: a *missed* merge is a compliance breach (second domain, suppression leak), a *false* merge is one lost prospect. Holding avoids both for 1.4% of the file, and merges stay reversible through the alias table |
| Do people ever come back to you under a personal address (6 of these are gmail with a real employer)? | Yes, and they roll up to the employer, but free-mail domains never become a company | Otherwise `gmail.com` becomes a company and six freelancers fuse into one — so the day any of them converts, the other five are suppressed |

### Suppression and consent

| Question | What I assumed | Why |
| --- | --- | --- |
| **Do you have a partner list anywhere, and is it account-level or person-level?** | It exists somewhere but not in any system I was given, and it is account-level | The brief names partner conflicts as something that must be excluded, and nothing in the CSV expresses one. I built the table, the rules and the tests, seeded empty, scoped to both levels with account as the default. Inferring it from `source = 'partner_referral'` (123 rows) would have been wrong in the most expensive direction — a referral is a warm introduction, close to the opposite of a conflict |
| Has counsel taken a position on whether an unsubscribe is channel-scoped or global? | Channel-scoped; only an explicit request to stop is global | This is what CAN-SPAM and GDPR Art. 21 actually regulate, and a human sentence ("please stop emailing me") is a stronger signal than a click, so those 6 became global DNC. The stricter reading costs **8 people** and is one predicate — `tests/50` already prices it, so counsel can decide without anyone re-deriving the number |
| Instantly does not expose hard versus soft bounce. Do you have severity anywhere else? | No — every bounce is terminal for that address, never for the person | The only way to learn whether an address is dead is to send to it again, which is exactly the behaviour that burns a sending domain. 13 of the 66 are confirmed hard from `notes`, which supports the conservative default rather than changing it |
| Who releases the 28 people currently "owned by sales" back to outbound, and how? | Sales releases them explicitly; outbound never reclaims them on a timer | A timer here would put a rep's live conversation into a cold sequence. The mechanism is a one-line event; I did not build it because it needs a named owner, which is the same problem as the override table |
| Who is allowed to write a suppression — or an override on one? | A named human, recorded on every row | `added_by` is `NOT NULL` for this reason. An asserted-suppression list with no accountable author is how a departed colleague's grudge silently kills an account for two years, and an *override* with no author is worse, which is why the ~900-person override table is designed and deliberately not built |

### The sending-domain lock

| Question | What I assumed | Why |
| --- | --- | --- |
| **"A person should never be contacted by more than one sending domain. Ever." — did you mean the person, or the account?** | You meant the account, and I moved the lock there | 0 of 2,114 people violate the rule as written; **118 of 135 contacted companies do**, 38 of them from all four domains. The rule as stated is already satisfied and governs nothing, while the thing that actually burns domains is unconstrained. It is a strict strengthening — one domain per company implies one per person — so I treated it as sharpening your intent, not overruling it. Called out in §6 because you should get to disagree |
| What happens to the 118 companies that are already dirty? | Grandfather every existing person→domain pair, bind the lock only on the not-yet-contacted, converge as legacy contacts age out | Measured all three options: grandfathering strands **0**, hard retroactive enforcement strands **317** (half of everyone ever contacted), a blanket rehash creates **470** new violations |
| When a domain burns out, does the lock migrate or is that person unreachable forever? | It migrates, loudly, as a human-approved logged event | A knowing violation of "Ever" — but the alternative is permanently orphaning up to a quarter of the base. Logged as `domain_migrated` so the violation is auditable rather than silent. *Which* domain to retire is deliverability, which you told me to stay out of |
| Does LinkedIn count as a "domain" for this rule? | No | LinkedIn is capped at 200/week per sender, so email and LinkedIn are not substitutable capacity. Collapsing them would sacrifice the multi-channel motion to buy nothing |

### Experiments and the ICP question

| Question | What I assumed | Why |
| --- | --- | --- |
| **Is the ICP question meant to be answered from outbound response?** | It is being asked of outbound, and outbound cannot answer it | The arithmetic is in §6 and it is not close — a two-arm booking-rate test needs ~4.5× the effective sample that exists in the entire contactable file. Reply rate measures message-market fit; ICP is about who retains. This is the assumption I would most want corrected on the call, because if you have volume I could not see in this file, the conclusion changes |
| What is the success metric, and at what point in the funnel? | Reply rate, declared before the experiment runs | At 20 bookings total, a booked-rate comparison is unreadable. `success_metric` is a column on `experiment` precisely so it is chosen up front — a metric picked after the numbers arrive is how 2.6% becomes whatever the deck needs |
| Who assigns segment, from what evidence? | A human, at the company, from domain, TLD and headcount | `industry` is contact-level noise: 142 of 146 companies carry conflicting industries across their own contacts, one of them spanning 8 industries at identical headcount. So I left `segment` and `persona` NULL rather than fabricate the single input the learning loop depends on |
| What is the real weekly send capacity, per domain and per address? | ~2,500/week across four domains | Only matters for one conclusion, and that conclusion is robust: email capacity exceeds the entire eligible pool either way, so email is *audience*-bound while LinkedIn at 200/week/sender is *throughput*-bound. If the true number is half my guess, the finding holds |
| Should there be a holdout? | No global holdout; the control is the previous message variant, run sequentially | At 723 eligible a 10% holdout costs 72 people and buys a comparison nobody has the power to read |

### HubSpot and infrastructure

| Question | What I assumed | Why |
| --- | --- | --- |
| What HubSpot tier are you on — are custom objects available? | Unknown, so the design forks and both branches work | Custom objects are Enterprise-only. If Enterprise, the projection is a custom object; if not, six Contact properties. HubSpot is a projection either way, so this assumption cannot move where truth lives — which is what makes it safe to leave open |
| Are there existing HubSpot workflows that fire on contact property changes? | Assume yes, and design so it does not matter | Write amplification — a sync write triggering a workflow that writes — is the classic way an integration melts a portal, and HubSpot exposes no "skip workflows" flag. Writes are confined to one namespaced property group, and lifecycle stage stays HubSpot's field, written by nobody else |
| Is there a writable Postgres anywhere, or only the read replica? | Only the read replica | Which makes a writable Postgres the one genuinely new piece of infrastructure this design needs, and I said so in §2 rather than quietly assuming a database into existence |
| Does the outbound ledger need to survive n8n failing mid-run? | Yes | Hence the durable inbox in §2. It is twenty lines, and without it the webhook path inherits whatever guarantee n8n happens to give that day |

### The two-sided business

| Question | What I assumed | Why |
| --- | --- | --- |
| Do publisher and brand outbound share one namespace, one domain lock, one set of clocks? | One namespace and one domain lock; **separate clocks and metrics** | A mail admin cannot tell a publisher pitch from a brand pitch — they see two Noble domains — so the lock has to cross the boundary. An editorial ask is a different transaction from a commercial pitch, so the recycle windows should not, and brand-calibrated clocks are *already* acting on 16 publisher contacts nobody chose them for |
| The 7 contacts flagged "active in Noble publisher program" — are they suppressed, or busy? | Busy: they are enrollments in the publisher funnel, not a suppression rule | They must not receive brand outbound because of the one-live-experiment lock, which already exists. Adding a suppression rule for them would encode a temporary state as a permanent fact |

### If I am wrong, this is what it costs

The same decisions priced, so you can check my arithmetic rather than my judgement.

| # | Assumption | Cost if wrong |
| --- | --- | --- |
| 1 | Unsubscribe is channel-scoped; only explicit DNC is global | **8 people.** 447 contacts sit in GDPR jurisdictions and 149 under CASL; a stricter counsel reading globalises all 29 unsubscribes. One predicate to change, and `tests/50` already prices it |
| 2 | Every bounce is terminal for that address (severity is not exposed by Instantly) | Some soft-bounced addresses retired early. The alternative — re-sending to a possibly-dead address to learn whether it is dead — is the behaviour that burns domains |
| 3 | An open opportunity freezes the whole company, not just the named buying committee | **~900 people.** The largest single assumption here. `opportunity` is a *contact* stage (70 contacts across 55 companies), so the committee is known by name and person-scoping was genuinely available. Rejected on asymmetry: a cold sequence landing mid-negotiation can cost a deal in flight; a suppressed prospect costs delay |
| 4 | The domain lock binds at company level, grandfathering existing pairs | 0 people stranded either way. Company level is strictly stronger — see §6 |
| 5 | Domain retirement migrates the lock and re-approaches from the replacement | A knowing, logged violation of "Ever". The opposite choice orphans up to a quarter of the base permanently |
| 6 | HubSpot tier unknown; custom objects may be unavailable | Nothing structural. The projection lands on Contact properties instead of a custom object; HubSpot is a projection in both branches |
| 7 | Segment must be assigned by a human, not derived from `industry` | 142 of 146 companies would be mis-segmented if anyone trusted that field |
| 8 | The 7 `publisher - active in Noble publisher program` contacts are *enrollments*, not suppressions | 7 people. The correct representation is a publisher-funnel enrollment, which needs the publisher funnel to exist |
| 9 | `partner_conflict` has no rows because no source expresses it | The table, the rules and the tests exist; if Noble has a partner list, it is an INSERT away |
| 10 | `as_of` is 2026-07-25 rather than `now()` | Nothing — deliberate, so every count reproduces. `make eligible AS_OF=2026-12-01` moves every clock |

---

## 2. Architecture

```
   DISCOVERY                    THE LEDGER (writable Postgres — new)                EXECUTION
                     ┌─────────────────────────────────────────────────┐
 Apollo ──nightly──► │  WRITABLE                                       │
 Clay   ──nightly──► │    person / person_alias / company              │ ──on-demand──► Instantly
 uploads──on-demand► │    contact_event      (append-only, the truth)  │    (enroll)    (email)
                     │    experiment / experiment_enrollment           │
                     │    suppression_list   (asserted, human-written) │ ──on-demand──► HeyReach
                     │                                                 │    (enroll)    (LinkedIn)
                     │  DERIVED (views — cannot drift from the log)    │
                     │    person_history · person_state                │ ◄──webhook───  reply / bounce /
                     │    rule_fired · eligibility_ledger              │   (at-least-   unsub events
                     │    reconciliation                               │    once)       via n8n
                     └───────▲──────────────────────────┬──────────────┘
                             │                          │
              webhook +      │                          │  hourly batch, 100 records/request,
              nightly batch  │                          │  one namespaced property group
              reconcile      │                          ▼
                        ┌────┴──────────────────────────────────┐
                        │  HubSpot — owns commercial state      │
                        │  (lifecycle, deals, owners).           │
                        │  Reads outbound activity,              │
                        │  never arbitrates it.                  │
                        └───────────────────────────────────────┘

   read-only, on demand:  Postgres read replica · Profound / Scrunch MCP · Fathom transcripts
```

**Truth is the log.** Not a state table. The CSV Noble supplied *is* a state table, and it is the reason none of the four questions in the brief can be answered today: `last_campaign` holds one campaign per person, while eight duplicate clusters in the file prove more than one campaign ran against those people. Those earlier touches were overwritten and are not recoverable. Every rule in this system is a question about history — *has* this person ever been mailed from a second domain, *did* an unsubscribe ever land, *when* was the last touch — and a column holding only the latest value answers none of them. So the component's first act is to reconstruct the 781 contacted rows into 781 synthetic `contact_event` rows: the migration from lossy collapse to event log, demonstrated on the real data rather than described.

The rejected alternative is the hybrid — log plus a transactionally-maintained state row — which is what most teams build and is correct at scale. Rejected here because it creates two truths that drift and needs a `rebuild_state_from_log()` reconciler that must itself be tested. Two truths with an untested reconciler is worse than one slow truth. The cost is stated honestly: every eligibility question is a query over the log. At this volume it is milliseconds, and the fix at the first million events is a materialised view, not a redesign.

**One writer per field.** This is the rule that makes the topology coherent, and it matters more than any rate limit.

| Concern | Owner | Everyone else |
| --- | --- | --- |
| Person and company identity | **Ledger** (`person_id`, surrogate) | consume it; nobody re-keys on email |
| What happened, ever | **Ledger** (`contact_event`) | Instantly and HeyReach *originate* events, they do not hold the history |
| Who may be contacted | **Ledger** (computed, not stored) | no tool in the stack can hold this; HeyReach cannot at all |
| Experiment definition and enrollment | **Ledger** | the sending tools hold the copy, not the design |
| Customer, deal, owner | **HubSpot** | ledger stores a stamped projection, never writes back |
| Enrichment attributes | **Clay** | ledger stores values with an enrichment timestamp |
| Product and platform facts | **Read replica** | joined read-only |
| Message copy | **Instantly / HeyReach** | ledger stores the variant *name* |

**The edges.** Each is exactly one of push-on-event, pull-on-schedule, or on-demand, and each has an idempotency key rather than a hope.

| # | Edge | Trigger | Idempotency |
| --- | --- | --- | --- |
| 1 | Apollo, Clay, uploads → ledger | pull nightly; on-demand for uploads | the three identity resolution rules; re-importing a person is a no-op |
| 2 | Ledger → Instantly / HeyReach | push on-demand, at enrollment | `(experiment_id, person_id)` primary key — a re-run cannot double-enroll. Instantly's `skip_if_in_*` flags are defence in depth only |
| 3 | Instantly / HeyReach → ledger | push on webhook, via n8n | `external_id UNIQUE`. Webhooks are at-least-once, so this constraint *is* the design |
| 4a | HubSpot → ledger | push on lifecycle change **and** pull nightly | upsert on `person_id`, `observed_at` stamped. The nightly pull is the backstop for the webhook the push lost |
| 4b | Ledger → HubSpot | push hourly, batched 100/request | keyed on `person_id` as a custom unique property — never on the HubSpot record id, which is reissued on merge |
| 5 | Read replica → ledger | pull nightly, read-only | a second opinion on "is this already a customer" |
| 6 | Profound, Scrunch, Fathom | on-demand query, no sync | human-in-the-loop inputs to segment assignment |

**HubSpot, without HubSpot becoming the bottleneck.** It receives a per-person summary — last touched, channel, sending domain, experiment, current outcome, next eligible date — in one namespaced property group. It does not receive the raw event stream: 780 timeline events per campaign buys nothing a rep reads and costs exactly the quota that makes HubSpot a bottleneck. The numbers: 625k requests/day on Pro, 100 records per batch counting as one request, Search API capped at 5/sec and therefore unusable for change detection, so the nightly reconcile reads batches by id instead of searching. An hourly push of changed people is ~8 requests against 723 eligible. The limit is three orders of magnitude away. The real risk is not volume but **write amplification** — an external write triggering a workflow that writes that triggers a workflow — which is why writes are confined to one property group with no workflow attached, and why lifecycle stage is HubSpot's field and the ledger never touches it.

*Stated assumption:* Noble's HubSpot tier is unknown and custom objects are Enterprise-only. If Enterprise, edge 4b writes a `noble_outbound_touch` custom object; if not, six Contact properties. Both are projections, neither changes where truth lives — which is what makes this assumption cheap.

**It fails closed.** If the ledger is unreachable at enrollment time, outbound stops. Not a preference: HeyReach has no writable blocklist, so for LinkedIn the ledger is the only place suppression exists, and 8 of the 29 unsubscribes in this file live nowhere else in the stack. Failing open means mailing people who asked not to be mailed — legal exposure. Failing closed means a late campaign — an inconvenience. A system whose job is to prevent contact must degrade toward silence.

**Where each piece lives in Noble's stack.** Apollo discovers. Clay enriches — **and only enriches**: Clay is explicitly out of the eligibility path, because Clay tables are per-list state, so suppression logic there is a per-campaign island, which is the disease rather than the cure. Instantly and HeyReach execute. n8n does event-shaped glue: webhook receipt, retries, HubSpot batching, schedules. **Suppression logic must never live in n8n** — it is set-based, and "one sending domain per company, ever" expressed as a node graph is a rule nobody can read, test, or argue with. That logic lives in SQL in the ledger, which is what §4 is. HubSpot is sales' window onto outbound. Profound and Scrunch inform segment assignment; Fathom informs the ICP question (§6). customer.io, Revenue Hero, Webflow and GA are all downstream of a booked demo and out of scope.

**Three things Noble does not have and would need.** The brief asked for this explicitly.

1. **A writable Postgres.** The read replica is read-only by definition, so the ledger cannot live there. This is the only genuinely new infrastructure, and it is tens of dollars a month at this data volume. Everything else is glue between things Noble already pays for.
2. **A durable inbox for webhooks.** An n8n run that fails mid-execution loses the event it was holding. The cheap version is a raw `event_inbox` table written first and parsed second, with retry and a dead-letter view — about twenty lines. Without it, edge 3 has no at-least-once guarantee of its own.
3. **Liveness monitoring on the ingest path.** Not a tool, a canary — see failure mode 1.

Explicitly **not** requested: a reverse-ETL vendor, a CDP, a warehouse. At 2,154 contacts, 100-record HubSpot batches through n8n are sufficient, and each of those products adds a system with its own opinion about identity, which is the problem being solved, bought again.

---

## 3. The data model

`sql/01_schema.sql` is the authoritative version and is written to be read — every table carries the decision that produced it. This is the summary and the defence of the key.

```
person                          company                     contact_event  (append-only)
  person_id      uuid PK  ◄──┐    company_id     uuid PK       event_id       uuid PK
  primary_email  text      │    primary_domain text UNIQUE   external_id    text UNIQUE  ← idempotency
  linkedin_url   text      │    name_key       text          person_id      uuid FK
  company_id     uuid FK ──┘    employee_count int           occurred_at    date
  is_independent bool           industry       text (noise)  channel        email|linkedin
  needs_review   bool           segment        text (NULL)   event_type     enrolled|sent|opened|
  review_evidence jsonb                                                     replied_*|bounced|
                                company_alias                               unsubscribed|booked|dnc|
person_alias                      company_id uuid FK                        domain_migrated|
  person_id   uuid FK             domain     text PK                         sequence_completed
  alias_type  email|linkedin|source_id                                     sending_domain text
  alias_value text                                                         experiment_id  uuid
  UNIQUE (alias_type, alias_value)                                         email_address  text
                                                                           source         text

experiment                        experiment_enrollment       suppression_list
  experiment_id   uuid PK           experiment_id uuid FK       suppression_id uuid PK
  message_variant text  ← the only    person_id   uuid FK       reason      FK → suppression_reason
  segment/persona text    free dim    enrolled_at date          scope       person|company
  audience        brand|publisher     expires_at  date          person_id / company_id
  success_metric  text  ← declared    PK (experiment_id,        added_by    text NOT NULL ← the writer
  channels        text[]                 person_id)             added_at / expires_at
  max_duration_days int                                         evidence    jsonb

crm_lifecycle  (projection in, stamped)     eligibility_rule / recycle_window / suppression_reason
  person_id uuid PK, stage, observed_at,      the rules as data: name, precedence, scope,
  source                                      duration, origin, rationale
```

Everything else — `person_history`, `person_state`, `rule_fired`, `eligibility_ledger`, `reconciliation` — is a **view**. There is no `state` column anywhere in the schema; a test asserts that. Views cannot drift from the log.

### The deduplication key

**A surrogate `person_id`, resolved by three deterministic rules, with `person_alias` recording every identifier the person has ever been seen under.** Not a natural key. Each candidate natural key fails on a case this dataset actually contains:

| Candidate | Coverage | Fails on |
| --- | --- | --- |
| Normalised email | 2,137 / 2,154 | **Job changes.** Emily Banerjee has one LinkedIn URL and two employers; email reads her as two people. Misses 35 of 54 duplicate clusters. It cannot represent a person whose address changes — which is the single most common cause of a second-domain violation, the one constraint the brief wrote "Ever." after |
| LinkedIn URL | 2,154 / 2,154 | Apollo emits different slugs for the same human (`ingrid-quinn-5420`, `ingrid-quinn-1209`); vanity URLs are user-editable. And an Instantly reply webhook carries an email, not a LinkedIn URL, so events could not resolve against it without a lookup table — at which point the alias table exists anyway, just unnamed |
| `contact_id` | unique in this file | It is *Apollo's* id, not Noble's. Stable until the next re-pull, and meaningless for the 33% of rows from Clay, forms, referrals and uploads |
| `first + last + company_domain` | 2,154 | 38 collisions, 15 of them where it is the only evidence — and one of those (Emily Weber, differing titles, seniorities, email domains and LinkedIn slugs under one domain) is two different humans |

Resolution, applied at ingest and re-appliable at any time:

| Rule | Match on | Clusters | Action |
| --- | --- | --- | --- |
| R1 | `lower(trim(email))`, `+tag` stripped | 19 | auto-merge |
| R2 | normalised LinkedIn slug | 17 | auto-merge |
| R3 | `first + last + company_domain` | 37 | corroborated by R1 or R2 → merge; **uncorroborated → `needs_review`, both members held from sending** |

**2,154 rows → 2,114 people, 40 absorbed.** Normalisation is not cosmetic: 8 rows differ from their twin only by casing and padded whitespace, 6 use `+noble` plus-addressing, and `KOFI.RODRIGUEZ@REEDMARSH.COM ` with trailing space is a hard-bounced address whose twin reads perfectly clean.

**Why R3 holds instead of merging.** The harm is asymmetric, and not in the direction people expect. A *missed* merge means a second sending domain and a suppression leak — a compliance breach. A *false* merge means one prospect never gets contacted — lost opportunity, no breach. That asymmetry argues for merging aggressively. But holding both members of an ambiguous pair avoids **both** errors, and here it costs 30 people out of 2,114 (1.4%). They appear in the rejection ledger under `identity:needs_review` with the conflicting evidence attached, so the system is visibly uncertain rather than silently guessing. Every merge is reversible through `person_alias`.

**What the key buys, measured on the supplied file:** 40 clusters that would otherwise have been assigned a **second sending domain** — Katherine Osei was contacted from `noblehq.io` as `katherine.osei@argentum.io`, and her twin `kosei@argentum.io` was untouched and would have gone out from a different one. And 10 clusters that would otherwise have **leaked past a suppression** — Ingrid Quinn unsubscribed on one record and reads clean on the other.

**Company identity** mirrors it: keyed on the normalised registrable domain, with `company_alias` because Keystone Cloud has two domains (`getkeystone.com`, `keystonecloud.io`) and without the alias table company-level suppression leaks between them. Free-mail domains are blocklisted from ever becoming a company — six rows are freelancers with `company_domain` set to gmail or icloud, and without the blocklist `gmail.com` becomes a company and all six fuse into one, so the day any of them converts the other five are suppressed. They get `company_id = NULL, is_independent = true` and person-level suppression only, which is correct: there is no company there to suppress. **2,114 people at 146 companies plus 7 independents — 14.4 contacts per company, not a flat list of 2,154 strangers.** That single fact drives most of §6: suppression at company level catches 13× what person level does, the domain lock belongs at the company, and the effective sample size for any experiment is a fraction of the headcount.

### Suppression is a query, not a flag

Three of the brief's four named suppression sources are *derived* — customers and open opportunities from the HubSpot projection, do-not-contact from a human sentence in `notes`. Partner conflicts are not derivable from anything: no field in the data expresses "a partner owns this account". So they get `suppression_list`, a table whose defining feature is `added_by NOT NULL` — an asserted-suppression list with no accountable author is the mechanism by which somebody's departed colleague's grudge quietly kills an account for two years. It supports both scopes (a partner agreement is written about an account; `kindredgroup.io` has 37 contacts), carries an `expires_at` read against the run's `as_of` clock so a lapsed agreement stops suppressing without anyone remembering to delete a row, and it is **seeded empty** — because there is no partner-relationship field in the CSV, and inferring one from `source = 'partner_referral'` (123 rows) would be wrong in the most expensive direction, since a partner *referral* is a warm introduction, roughly the opposite of a partner *conflict*. `tests/60` inserts fixtures at both scopes and proves the rules bite, the expiry clock works, and asserted reasons outrank derived ones.

---

## 4. The working component

A SQL pipeline that takes the raw 2,154-row CSV and emits a send-eligible list and a rejection ledger. It runs from this repo on Docker and Postgres with no credentials.

```
make up        # postgres 16 in docker, on host port 5433
make load      # create the schema, load the CSV raw and unmodified
make eligible  # resolve identity, apply the rules, write out/
make test      # 107 assertions
make verify    # run it twice, prove the artifacts are byte-identical
make down
```

`make all` does the first four, in about ten seconds. Not using Docker? Point it
at any Postgres 16 — nothing in the SQL assumes the container:

```
make load eligible DATABASE_URL=postgresql://user:pass@host:5432/db
```

Both of the pipeline's variables are inputs rather than constants, so the two
questions a reviewer actually wants to ask can be asked without editing SQL:

```
make eligible AS_OF=2026-12-01 EXPERIMENT=publisher-outreach-q4
```

`AS_OF` moves every clock in the system at once — that command takes eligible
from 723 to 819 as the recycle windows elapse, which is why the windows can be
argued with rather than taken on faith. `EXPERIMENT` names the experiment
the list is computed for; the eligible artifact is named after it, and because
the scoped rules are evaluated against *that experiment's* channels, an
experiment defined on one channel produces a different list. `tests/50` does
exactly that, flipping the channels to email-only and back.

**What comes out:**

| file | rows |
| --- | --- |
| `out/eligible_<experiment>.csv` | 723 people, each with a channel, a sending domain, and any channel that was withheld and why |
| `out/rejections.csv` | 1,391 people, each with a named rule, its scope and duration, the evidence, and every other rule that also fired |

And the reconciliation, printed at the end of every run:

```
2,154 rows = 723 eligible + 1,391 rejected + 0 quarantined + 40 absorbed by dedup
residual: 0
```

The CSV lands **raw and unmodified** in a landing table — malformed emails, padded whitespace, blank cells and all. Nothing is fixed by hand; cleaning happens downstream in SQL where a reviewer can disagree with it, and where any argument about a number can be settled by querying the landing table. Then: identity resolution, event-log reconstruction, the domain lock, fifteen named rules, two artifacts, and a reconciliation that raises if the residual is ever non-zero.

**The rules, first-match-wins, ordered most-permanent-first so the ledger names the most *meaningful* reason rather than whichever predicate happened to fire first:**

| # | Rule | Scope | Rejected |
| --- | --- | --- | --- |
| 1–3 | `list:partner_conflict`, `list:legal_hold`, `list:manual` | company / person | 0 — asserted, empty by design, tested in `tests/60` |
| 4 | `person:dnc` | person, all channels | 6 |
| 5 | `person:unsubscribed` | person, **channel-scoped** | 0 *(narrows; rejects 16 on an email-only experiment)* |
| 6 | `person:bounced` | person, **address-scoped** | 0 *(narrows; rejects 54 on an email-only experiment)* |
| 7 | `company:customer` | company | 330 |
| 8 | `company:open_opportunity` | company | 912 |
| 9 | `person:owned_by_sales` | person | 28 |
| 10–12 | `person:recycle_window(no_reply / replied_negative / opened_no_reply)` | person, 90 / 180 / 60 days | 62 / 28 / 16 |
| 13 | `identity:needs_review` | identity | 9 |
| 14 | `person:in_live_experiment` | person | 0 at rest |
| 15 | `person:unreachable_on_channel` | person, this experiment only | 0 *(5 on email-only)* |
| — | **eligible** | | **723** — 541 never contacted, 182 recycled, 40 carrying a withheld channel |

`company:domain_lock` is deliberately **not** a rejection rule. Under grandfather-and-converge it never excludes anyone; it only *assigns* a sending domain. That is the point of choosing it over retroactive enforcement, which would have stranded 317 people — half of everyone Noble has ever contacted.

**The rejection ledger is the more useful of the two files.** "723 people are eligible" is unverifiable. "912 excluded by `company:open_opportunity`, here they are, here is the open deal that did it, here are the other rules that also fired" can be argued with, and being argued with is the point. Every rejection carries its rule, the rule's scope and duration, the evidence as JSON, and every other rule that fired for that person.

**Three properties hold, and the tests check all three.** There is no stored state — 781 events reconstructed from the collapsed `last_*` columns, and a test asserts no `state` column exists anywhere. Suppression is a query, so it works for LinkedIn where no tool-side blocklist exists. And every run is deterministic: ids are derived rather than allocated, every clock reads `as_of` rather than `now()`, the domain-assignment hash is stateless — `make verify` runs the pipeline twice and diffs both artifacts byte-for-byte.

**107 assertions**, including the uncomfortable ones — every count the implementation produces that disagrees with the design note that specified it is asserted at the *measured* value, with the disagreement written down. That table is below, because a silent disagreement between a design note and its implementation is worse than either one being wrong.

**Two rules narrow rather than reject, and that is the sharpest thing the build found.** Unsubscribe is channel-scoped and bounce is address-scoped, so on a two-channel experiment neither removes anybody — 40 people simply lose one channel and stay on the list with a `channels_withheld` column naming what took it. Measured: 21 people unsubscribed from email and 8 from LinkedIn with **no overlap**, so nobody is unsubscribed everywhere; 22 bounced people drop to LinkedIn rather than leaving the list. Which means the design note's requirement that every rule name appear in the rejection ledger cannot hold, and it also means a rule nobody specified was missing: `person:unreachable_on_channel`, for the five people on an email-only experiment who would otherwise appear in the eligible file marked eligible with no address to send to.

### How to read it

The SQL is numbered in execution order and is meant to be read that way.

| file | what it settles |
| --- | --- |
| `sql/01_schema.sql` | **The data model** — §3 above in executable form. Every table carries the decision that produced it. Read this one first |
| `sql/02_load.sql` | The CSV, byte-for-byte, into a landing table. Nothing is cleaned on the way in |
| `sql/03_identity.sql` | 2,154 rows → 2,114 persons and 146 companies. Surrogate key, alias table, three resolution rules |
| `sql/04_events.sql` | The 781 contacted rows reconstructed as an append-only event log. This is the migration, demonstrated |
| `sql/05_domain_lock.sql` | The sending-domain lock. Assigns; never rejects |
| `sql/06_eligibility.sql` | The fifteen named rules, first-match-wins, most-permanent-first |
| `sql/07_export.sql` | The two artifacts |
| `sql/08_summary.sql` | The reconciliation, and the exception it raises if the residual is ever non-zero |

The suites run in the same order: `tests/10` identity, `20` the domain lock, `30` the rules, `40` reconciliation, `50` channel scoping on single-channel experiments, `60` the suppression list.

### Where this disagrees with its own design notes

The rules came from the decision record, which carried an expected count for each one. Five of eleven reproduce exactly — `person:dnc` (6), `person:owned_by_sales` (28), `recycle_window(replied_negative)` (28), `recycle_window(opened_no_reply)` (16), `person:in_live_experiment` (0). The rest are listed here rather than quietly reconciled.

| | design note | measured | why |
| --- | --- | --- | --- |
| persons | 2,099 | **2,114** | The note rules that R3-uncorroborated clusters are *held, not merged*, then reports the person count as if they had merged. Only R1 and R2 merge: 40 rows absorbed, not 55 |
| companies | 153 | **146** | 153 is the count of distinct raw `company_domain` values — before the note's own free-mail blocklist (6 domains) and its Keystone alias merge (1) |
| `person:unsubscribed` | 23 rejected | **0 rejected** | Unsubscribe is channel-scoped by the note's own decision, and nobody in the file unsubscribed from both channels. On a two-channel experiment it narrows instead of rejecting; `tests/50` flips to email-only, where it rejects 16 |
| `person:bounced` | 66 rejected | **0 rejected** | Same reasoning, and it is the point: a bounce is terminal for the *address*, not the person — "the person survives on LinkedIn and on any future address". Address-scoped means what channel-scoped means. On an email-only experiment it rejects 54 |
| `company:customer` | 324 | **330** | More persons resolved, the Keystone merge, and the two scoped rules above no longer removing people before this one is reached |
| `company:open_opportunity` | 874 | **912** | The same three causes |
| `recycle_window(no_reply)` | 65 | **62** | 150 people are inside the 90-day window before precedence; 62 survive it. The other two windows land exactly |
| `identity:needs_review` | ~30 | **9 surfaced** | 30 people are held, but 21 are already rejected by a higher-precedence rule. The note's table mixes raw predicate counts with first-match-wins counts, which is why it sums to more than its own total |
| eligible | 724 | **723** | One apart — which is worth being suspicious of rather than pleased about, since the per-rule numbers differ far more than the total does, so the agreement is partly cancellation |

**And it is not a like-for-like comparison, because the design note's own totals do not reconcile with each other.** Its eleven rule counts sum to 1,460 while the same section states 1,430 rejected and 724 eligible out of 2,154 — three figures that cannot all be true. Each per-rule count was measured independently; the total was measured separately.

This pipeline's numbers do reconcile, and that is the claim being made: **723 + 1,391 = 2,114 persons; 2,114 + 40 absorbed = 2,154 rows.** Every rule count is measured *after* precedence is applied, from the same query that writes the ledger, so the parts sum to the whole by construction rather than by coincidence. `make eligible` prints the residual on every run and `sql/08_summary.sql` raises an exception if it is ever non-zero.

Four rules exist in the pipeline and in no design note: `person:unreachable_on_channel`, because the notes enumerate ten reasons a person must *not* be contacted and none for a person who simply *cannot* be; and the three `list:` rules behind `suppression_list` (§3), because partner conflicts are the one named suppression source that no data source emits.

---

## 5. What breaks

Three modes, chosen on one test: has actually happened to somebody, has evidence in this dataset, and would not be caught by anything currently in the stack.

### 1. Silent ingest death — the ledger stops learning while it keeps sending

Instantly disables a webhook after repeated delivery failures and exposes a `resume` endpoint for exactly that, with an unpublished retry window. An n8n run that fails mid-execution loses the event it was holding. Either way the ledger keeps computing eligibility from a history that stopped updating, and every health signal reads normal: queries return, the run reconciles, the list is produced.

This is the worst mode available because it **inverts the design's core safety property**. Fail-closed protects against a ledger that is *down*. A ledger that is *up and stale* fails open — and keeps mailing people whose unsubscribes are sitting undelivered in a disabled webhook. In this file, 95 events (66 bounces, 29 unsubscribes) exist only because something ingested them, and 8 of those unsubscribes exist nowhere else in the stack.

*Monitor:* event-arrival lag per channel and event type, compared against send volume in the same window — `sent > 0` in 24h with zero `opened` is a broken pipe, not a quiet week. A **synthetic canary**: one seeded Noble-owned address in every campaign that must produce `sent` and `opened` within the hour, which is the only signal that distinguishes "no replies" from "no reply *events*". And an hourly poll of Instantly's webhook status, because this failure has an API-visible state; check it rather than infer it. Escalation is paused sending, not an email — the character of this mode is that everything looks fine.

### 2. Identity drift — a person changes jobs and loses their domain lock and suppression history

The brief wrote "Ever." after exactly this constraint, and in the file as supplied the stake was live: **40 clusters would have been assigned a second sending domain and 10 would have leaked past a suppression.** Those are the ones the resolution rules catch. The residual risk is the case the rules cannot see — email *and* company changing together while Apollo re-emits a different LinkedIn slug, so the person resolves as genuinely new, with a clean history and no lock. `person_alias` is the mitigation and it is a good one, but it only works where identifiers overlap; two of three changing at once defeats it.

*Monitor:* the invariant, on every load — people with more than one distinct `sending_domain` in the event log must be **0**, and companies with more than one must never *increase*. The pipeline asserts both today; in production this fails the import rather than printing a number. Then **new-person rate per import** against a band: a re-pull that resolves 400 new people out of 2,000 is not growth, it is a normalisation regression, and it is silent because all 400 look fresh and eligible. And `needs_review` queue depth and age — the hold rule is only honest if somebody adjudicates, and a monotonically growing queue means the system quietly converted "we are unsure" into "we never contact them".

### 3. Ledger–HubSpot divergence — outbound mails an existing customer

The reputational failure, the one a sales team notices first, and therefore the one that costs the system its mandate. `company:customer` and `company:open_opportunity` exclude **1,242 people** in this file, and every one of those exclusions rests on a projection of HubSpot's opinion stamped with `observed_at`. Projections go stale in the obvious way — a missed webhook — and in the subtle way: a HubSpot merge issues a brand-new record id and retires the old one, so anything keyed on that id silently stops matching. Which is why nothing here keys on it.

*Monitor:* the **nightly reconciliation diff**, the highest-value monitor in the design — count of people the ledger calls eligible whose HubSpot lifecycle now reads `customer` or `opportunity`. Expected value **0**; anything above it is a missed webhook or a merge, and it names the person. Plus projection staleness (max `age(observed_at)`, alert past 48h — a projection with no freshness alarm is a cache with no TTL). Plus **per-rule volume bands**, which the run already prints: `company:open_opportunity` at 912 is normal, at 40 something upstream broke — and note that this failure presents as *more* eligible people, which nobody investigates because it looks like a good week. The same bands catch silent eligibility collapse from the other direction; eligible volume moving more than ±20% run-over-run should halt enrollment until a human looks.

### Deliberately not built

| Cut | Why | Worth |
| --- | --- | --- |
| The write path out to Instantly and HeyReach | No tenant to write to, and a component Jason can't run is worth less than one he can. Designed: edge 2, idempotency key `(experiment_id, person_id)` | The system produces lists, it does not yet send |
| `suppression_override` | The right end state for coordinated multi-threading into an open-opportunity account. In four hours it is a table with no writer — and an override with no accountable author is worse than the suppression it relaxes. `suppression_list` is the same shape and is where it lands | **~900 people** |
| Hybrid log + materialised state | Two truths that drift, needing a reconciler that would not get tested. Chose pure derivation | Query cost, until roughly the first million events |
| Segment and persona assignment | `industry` is contact-level noise (142 of 146 companies self-contradict), and §6 argues segment may be the wrong axis entirely. Inventing one fabricates the input the learning loop depends on | Columns exist, NULL; assignment is a human pass |
| `audience` on the recycle clocks | Publisher outreach is a different transaction and brand-calibrated windows are already acting on 16 publisher contacts. One column — but choosing the numbers needs publisher response data that does not exist yet | 7 companies today |
| Fuzzy company merging | Companies key on registrable domain, which cannot know `getkeystone.com` and `keystonecloud.io` are one company. Implemented as exact normalised-name match: merges Keystone, correctly leaves `keystone.co` — a different 450-person company — alone | Small; a fuzzy matcher needs a review queue |
| Live integration of any kind | No tenant access. Integration is designed, never built | — |

---

## 6. Where I think the brief is wrong

### The domain lock is at the wrong level, and the constraint as written governs nothing

> "A person should never be contacted by more than one Noble sending domain. Ever."

Measured on the supplied file: **0 of 2,114 people violate this.** It is already satisfied and it constrains nothing going forward. Meanwhile **118 of 135 contacted companies have received Noble mail from two or more sending domains, and 38 from all four.** One mail admin seeing four Noble domains is the thing that actually burns four domains at once, and the rule as stated does not touch it.

So the lock moves to the **company** and every contact inherits it. This is a strict strengthening rather than a disagreement — a person belongs to one company, so one domain per company implies one domain per person — which makes it a sharpening of the intent, not a rejection of it. It is also the version that survives contact with the data: grandfathering every existing person→domain pair and binding the lock only on the not-yet-contacted strands **0 people**, where hard retroactive enforcement would have stranded 317, and a blanket rehash would have created 470 fresh violations. Dirty companies lock to their plurality domain so they can never acquire a *new* one and converge as legacy contacts age out. LinkedIn is deliberately not a "domain" for this purpose: it is capped at 200/week per sender, so email and LinkedIn are not substitutable capacity and collapsing them buys nothing.

The one place this knowingly breaks the word "Ever" is domain retirement, where a burned domain's companies re-lock to a replacement and already-contacted people there get re-approached from it. The alternative is permanently orphaning up to a quarter of the base. It is therefore an explicit human-approved `domain_migrated` event in the log — an auditable violation rather than a silent one.

### Outbound response cannot answer the ICP question, and asking it to will produce confident noise

This is the pushback I would most want to be wrong about, and the arithmetic is not close.

Historical baseline from the file: 781 contacted → 122 replies (15.6%) → 38 positive (4.9%) → **20 booked (2.6%)**. Two-proportion test, 80% power, α = 0.05:

| Metric | Baseline | To detect | n per arm | Two arms | vs 723 eligible |
| --- | --- | --- | --- | --- | --- |
| Booked | 2.6% | a **doubling** to 5.2% | 866 | 1,732 | 2.4× the entire pool |
| Positive reply | 4.9% | a doubling to 9.8% | 445 | 890 | 1.2× the pool |
| Any reply | 15.6% | +50% relative | 401 | 802 | 1.1× the pool |

And 723 is not 723 independent observations. Eligible is **716 people at 73 companies, 9.8 per company**; contacts inside one company share a buying context, so at an intra-cluster correlation of 0.1 the design effect is 1.88 and the **effective sample is ~385**. A two-arm booking-rate comparison therefore needs roughly 4.5× the effective sample that exists in the entire contactable file — and three segments means three contrasts. This is not a tuning problem.

More fundamentally: **reply rate measures message-market fit. ICP is a claim about who retains, expands, and gets value** — properties visible only after the sale. The segment that replies best and churns in four months is the most expensive possible false positive, and this instrument cannot distinguish it from the real thing.

What I would do instead, in order: **HubSpot closed-won and pipeline data**, with segment assigned retrospectively by hand — small n, but the real outcome rather than a proxy, and it is hours of work; **the Fathom corpus**, which is the fastest available read on which buyer type articulates the problem in Noble's language unprompted versus which has to be taught it, and which Noble already owns and has barely touched; **Profound and Scrunch**, for which prompt surfaces have citable, movable articles at all, since a segment whose buyers' prompts are locked up behind unreachable publishers is a bad ICP however well it replies; and **sequencing segments rather than running them concurrently**, which is nearly free here because 541 of 723 eligible have never been contacted, so nothing warm is being burned to do it.

Outbound's honest job in this question is **disqualification, not selection**. It can cheaply prove a segment does not engage. It cannot tell you which of three engaged segments Noble is best for.

What *is* reachable, and worth running: a two-arm **message** test on reply rate, ~800 enrollments, one full cycle of the list. One test, one cycle, one readable number. Also worth knowing that the binding constraint inverts by channel — email capacity (~2,500/week) exceeds the entire eligible pool, so email is *audience*-bound, while LinkedIn at 200/week/sender is *throughput*-bound. Any design that treats the two as interchangeable capacity is wrong about one of them.

### "There is no system of record" is the right symptom and the wrong cause

The cause is that state is stored as `last_*` columns — a lossy collapse of a stream. `last_campaign` holds one campaign per person while eight duplicate clusters prove more than one ran, and those earlier touches are not recoverable from the file at all. A system of record that stores *current state* would reproduce this failure with better infrastructure and a nicer schema. That is why the component's first act is to reconstruct 781 events from the collapsed columns: it is not a data-loading step, it is the fix, run against the real data. Every one of the four questions in the brief is a question about history, and history is the thing the current shape throws away.

### The constraints are written as if there is one funnel

Noble is described as two-sided in the About section, and then every constraint speaks of one person, one domain, one experiment. In this file the collision is real but small — 7 publisher companies, 16 contacts, and measurably **no** person-level overlap, since all 7 publisher companies contain only publisher-shaped titles. So the resolution is cheap: `audience` is a column on the **experiment**, a partition above the model, never on the person — audience is a property of why you are approaching someone, not of who they are, and the same editor is a publisher target this quarter and a brand target next quarter.

All three company-scoped locks cross the boundary, including the domain lock, which is the one that looks like it should split and must not: a mail admin cannot tell a publisher pitch from a brand pitch, they see two Noble domains. If publisher outreach needs its own voice, that is an argument about the from-name and the copy, not the registrable domain. The genuine exception is the recycle clocks and the success metric, which are per-audience — an editorial ask is not a commercial pitch, and `ecommercebytes.co` already has a live publisher relationship frozen by a brand-side open opportunity while the publisher campaign generates outcomes that brand-calibrated windows will act on. Structural in the business, cheap now, expensive to retrofit once the publisher funnel has volume.

---

## 7. What I would do first, on day one

1. **Stand up the writable Postgres and point this pipeline at it.** It already runs against any Postgres 16 via `DATABASE_URL`. That is the ledger, on day one, with real numbers.
2. **Build the durable webhook inbox and the ingest canary before the write path out.** The system's value is knowing who not to contact; the fastest way to destroy that value is to start sending before you can reliably hear back.
3. **Assign segment by hand, at the company, for the 73 companies that are actually eligible.** Not 146, not 2,154. It is an afternoon, and it unblocks every experiment.
4. **Answer the ICP question from closed-won and Fathom, in parallel**, and let outbound do the thing it is good at: one two-arm message test on reply rate, over one cycle of the list.
5. **Then** the write path, and only then.
