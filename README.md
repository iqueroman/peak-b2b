# Noble outbound — send-eligible pipeline

Takes the raw 2,154-row contact CSV and emits two files: who can be contacted,
and — more usefully — everyone who cannot, with the rule that excluded them and
the evidence behind it.

Runs from this repo on Docker and Postgres. No credentials, no tenant access,
no network calls.

```
make up        # postgres 16 in docker, on host port 5433
make load      # create the schema, load the CSV raw and unmodified
make eligible  # resolve identity, apply the rules, write out/
make test      # 78 assertions
make verify    # run it twice, prove the artifacts are byte-identical
make down
```

`make all` does the first four. It takes about ten seconds.

Not using Docker? Point it anywhere:

```
make load eligible DATABASE_URL=postgresql://user:pass@host:5432/db
```

## What comes out

| file | rows |
| --- | --- |
| `out/eligible_aeo-saas-aug.csv` | 723 people, each with a channel, a sending domain, and any channel that was withheld and why |
| `out/rejections.csv` | 1,391 people, each with a named rule, its scope and duration, the evidence, and every other rule that also fired |

And the reconciliation, printed at the end of every run:

```
2,154 rows = 723 eligible + 1,391 rejected + 0 quarantined + 40 absorbed by dedup
residual: 0
```

The rejection ledger is the interesting file. "723 people are eligible" is
unverifiable. "912 excluded by `company:open_opportunity`, here they are, here
is the open deal that did it" can be argued with, and being argued with is the
point.

Two of the rules are *scoped* — unsubscribe to a channel, bounce to an address
— so on a two-channel experiment they narrow a person's reachable channels
rather than removing them. Those people are in the eligible file, not the
rejection file, with a `channels_withheld` column naming the rule that took the
channel away. 40 people carry one.

## Reading order

The SQL is numbered in execution order and is meant to be read that way.

| file | what it settles |
| --- | --- |
| `sql/01_schema.sql` | **The data model.** Every table carries the decision that produced it. Read this one first. |
| `sql/02_load.sql` | The CSV, byte-for-byte, into a landing table. Nothing is cleaned on the way in. |
| `sql/03_identity.sql` | 2,154 rows → 2,114 persons and 146 companies. Surrogate key, alias table, three resolution rules. |
| `sql/04_events.sql` | The 781 contacted rows reconstructed as an append-only event log. This is the migration, demonstrated. |
| `sql/05_domain_lock.sql` | The sending-domain lock. Assigns; never rejects. |
| `sql/06_eligibility.sql` | The twelve named rules, first-match-wins, most-permanent-first. |
| `sql/07_export.sql` | The two artifacts. |
| `sql/08_summary.sql` | The reconciliation. |

Three properties hold throughout, and the tests check all three:

- **There is no `state` column anywhere.** State is derived from the event log.
  The CSV *is* a mutable state table, and it is the reason none of the brief's
  four questions can be answered: `last_campaign` holds one campaign per
  person, yet eight duplicate clusters prove more than one campaign ran.
- **Suppression is a query, not a flag.** HeyReach has no writable blocklist,
  so for LinkedIn the ledger is the only enforcement point that exists.
- **Every run is deterministic.** Ids are derived, not allocated; every clock
  reads `as_of` rather than `now()`; the domain hash is stateless. `make verify`
  runs the pipeline twice and diffs the output.

Change the as-of date or the experiment without editing SQL:

```
make eligible AS_OF=2026-12-01 EXPERIMENT=publisher-outreach-q4
```

## Where this disagrees with the design notes

The rules come from the decision record in `.scratch/noble-outbound-sor/`,
which carried expected counts for each one. Five of the eleven reproduce
exactly — `person:dnc` (6), `person:owned_by_sales` (28),
`recycle_window(replied_negative)` (28), `recycle_window(opened_no_reply)` (16),
`person:in_live_experiment` (0). The rest are listed here because a silent
disagreement between a design note and its implementation is worse than either
being wrong.

| | design note | measured | why |
| --- | --- | --- | --- |
| persons | 2,099 | **2,114** | Issue 03 rules that R3-uncorroborated clusters are *held, not merged*, then reports the person count as if they were merged. Only R1 and R2 merge: 40 rows absorbed, not 55. |
| companies | 153 | **146** | 153 is the count of distinct raw `company_domain` values, before 03's own free-mail blocklist (6 domains) and its Keystone alias merge (1). |
| `person:unsubscribed` | 23 rejected | **0 rejected** | Unsubscribe is channel-scoped by 04's own decision, and no one in the file unsubscribed from both channels — 21 email, 8 LinkedIn, no overlap. On a two-channel experiment it narrows channels instead of rejecting. `tests/50` flips the experiment to email-only, where it rejects 16. |
| `person:bounced` | 66 rejected | **0 rejected** | Same reasoning as the row above, which is the point: 04 rules a bounce terminal for the *address*, not the person — "the person survives on LinkedIn and on any future address." Address-scoped means what channel-scoped means. 22 bounced people drop to LinkedIn instead of leaving the list; on an email-only experiment the rule rejects 54. |
| `company:customer` | 324 | **330** | More persons resolved, the Keystone merge, and the two scoped rules above no longer removing people before this one is reached. |
| `company:open_opportunity` | 874 | **912** | Same three causes. |
| `recycle_window(no_reply)` | 65 | **62** | 150 people are inside the 90-day window before precedence; 62 survive it. The other two recycle windows land on 04's number exactly. |
| `identity:needs_review` | ~30 | **9 surfaced** | 30 people are held, but 21 are already rejected by a higher-precedence rule. 04's table mixes raw predicate counts with first-match-wins counts, which is why it sums to more than its own total. |
| eligible | 724 | **723** | One apart, which is closer than the per-rule spread suggests — but see below, because 04's own totals do not reconcile with each other. |

The eligible figure lands one person from 04's, which is worth being suspicious
of rather than pleased about: the per-rule numbers differ much more than the
total does, so the agreement is partly cancellation. It is also not a like-for-
like comparison, because 04's own totals do not reconcile with each other — its
eleven rule counts sum to 1,460 while the same section states 1,430 rejected
and 724 eligible out of 2,154, three figures that cannot all be true. The
per-rule counts were each measured independently; the total was measured
separately.

This pipeline's numbers do reconcile, and that is the claim being made:
**723 + 1,391 = 2,114 persons; 2,114 + 40 absorbed = 2,154 rows.** Every rule
count is measured after precedence is applied, from the same query that writes
the ledger, so the parts sum to the whole by construction rather than by
coincidence. `make eligible` prints the residual on every run and
`sql/08_summary.sql` raises if it is ever non-zero.

One rule is in the pipeline and not in the design notes:
`person:unreachable_on_channel`. The notes enumerate ten reasons a person must
not be contacted and none for a person who simply *cannot* be. Without it, an
email-only experiment returns five people marked eligible with no address to
send to.

## Deliberately not built

- **The write path back to Instantly and HeyReach.** Designed, not built. There
  is no tenant to write to, and a component that cannot run is worth less than
  one that can.
- **`suppression_override`.** The correct end state for coordinated
  multi-threading into an open opportunity — worth roughly 900 people — is a
  table with a deal-owner as its writer. Inside four hours it would be a table
  with no writer.
- **A domain-based company key.** 03 keys a company on "the normalised
  registrable domain", which cannot on its own tell you that `getkeystone.com`
  and `keystonecloud.io` are one company. The `company_id` *is* derived from the
  domain, but the rule that decides which domains belong together is exact
  match on normalised company name. It merges Keystone and nothing else, and it
  correctly leaves `keystone.co` ("Keystone", 450 employees) alone.
- **Segment and persona on the experiment.** Left NULL. Issue 03 established
  that `industry` is contact-level noise (142 of 146 companies carry
  conflicting industries across their own contacts), and issue 05 has not yet
  settled whether segment is the right experimental axis. Inventing one here
  would fabricate the single input the learning loop most depends on.
