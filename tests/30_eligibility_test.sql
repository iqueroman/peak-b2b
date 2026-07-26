-- tests/30_eligibility_test.sql
--
-- The eleven named rules from issue 04 §7, in precedence order, first-match-
-- wins, ordered most-permanent-first so the ledger names the most *meaningful*
-- reason rather than whichever predicate fired first.
--
-- Five of the eleven reproduce 04's count exactly. The rest each carry a note
-- saying why, and in every case the pipeline implements what 04 *decided*
-- while 04's number came from a profiling query that measured something
-- slightly different.
--
-- Two of the rules are *scoped* — unsubscribe to a channel, bounce to an
-- address — so on this two-channel experiment they narrow a person's channels
-- instead of removing them. Both therefore reject nobody here and both are
-- asserted at zero, with the narrowing asserted separately below and the
-- rejecting behaviour asserted in tests/50 on a single-channel experiment.

SELECT test.expect('rules', '01 person:dnc', 6,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:dnc'));

-- CORRECTED FROM 04. 04 expects 23 rejections here, but 04 also rules that
-- unsubscribe is *channel-scoped*: email unsubscribe kills email, LinkedIn
-- withdrawal kills LinkedIn. This experiment runs on both channels, and no
-- person in the file has unsubscribed from both — 21 on email, 8 on LinkedIn,
-- no overlap. So the rule correctly rejects nobody and narrows channels
-- instead. See the email-only case below, where it does bite.
--
-- This is the same shape of finding as the domain lock: a rule that, as
-- specified, constrains far less than its stated count implies.
SELECT test.expect('rules', '02 person:unsubscribed', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:unsubscribed'),
                   '04 says 23; channel-scoped unsubscribe cannot reject on a two-channel experiment');

SELECT test.expect('rules', 'unsubscribes are channel-split, not global', 29,
                   (SELECT count(*) FROM person_history WHERE has_unsubscribed));

SELECT test.expect('rules', 'unsubscribed on email only', 21,
                   (SELECT count(*) FROM person_history
                     WHERE unsubscribed_channels = ARRAY['email']));

-- 04: "8 people's unsubscribes currently exist nowhere but this ledger."
-- These are the LinkedIn ones — 01 established HeyReach has no writable
-- blocklist, so there is no tool-side place for them to live.
SELECT test.expect('rules', 'unsubscribed on linkedin only (enforceable nowhere else)', 8,
                   (SELECT count(*) FROM person_history
                     WHERE unsubscribed_channels = ARRAY['linkedin']));

-- CORRECTED FROM 04. 04 expects 66 — every bounce in the file. But 04 rules
-- that a bounce is terminal for the *address*, not the person: "the person
-- survives on LinkedIn and on any future address; only the address dies."
-- Address-scoped means the same thing channel-scoped means one rule up: on a
-- two-channel experiment a bounced person drops to LinkedIn rather than out of
-- the list. Applying it any other way would make a scoped suppression
-- unscoped.
SELECT test.expect('rules', '03 person:bounced', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:bounced'),
                   '04 says 66; address-scoped bounce narrows to linkedin rather than rejecting');

SELECT test.expect('rules', 'bounced people withheld from email', 22,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE channels_withheld ->> 'email' = 'person:bounced'));

SELECT test.expect('rules', 'bounce events in the log', 66,
                   (SELECT count(*) FROM contact_event WHERE event_type = 'bounced'));

-- A bounce recorded against a LinkedIn touch must not kill an email address
-- that was never mailed. 12 of the 66 sit on a linkedin row and carry no
-- address; the other 54 are email touches and do.
SELECT test.expect('rules', 'bounces carrying an address (email touches only)', 54,
                   (SELECT count(*) FROM contact_event
                     WHERE event_type = 'bounced' AND email_address IS NOT NULL));

SELECT test.expect('rules', 'bounces on a linkedin touch carry no address', 12,
                   (SELECT count(*) FROM contact_event
                     WHERE event_type = 'bounced' AND channel = 'linkedin'
                       AND email_address IS NULL));

-- The two company rules run higher than 04 for three compounding reasons: the
-- pipeline resolves 2,114 persons where 04 assumed 2,099; the Keystone alias
-- merge pulls two domains' contacts under one suppressed company; and the two
-- scoped rules above no longer remove anyone, so the people 04 counted under
-- `person:bounced` fall through to here instead.
SELECT test.expect('rules', '04 company:customer', 330,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'company:customer'),
                   '04 says 324');

SELECT test.expect('rules', '05 company:open_opportunity', 912,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'company:open_opportunity'),
                   '04 says 874');

-- 04's central claim, re-derived: company suppression is the dominant lever.
-- It runs higher here than in 04 partly because the two scoped rules above
-- reject nobody, so their people fall through to it.
SELECT test.expect('rules', 'company suppression total', 1242,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name LIKE 'company:%'),
                   '04 says 1198; the whole recycle-window tuning range is 108');

SELECT test.expect('rules', '06 person:owned_by_sales', 28,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:owned_by_sales'));

-- The three recycle rules are the closest agreement with 04 anywhere in this
-- file: two of them land on 04's number exactly. 150 people are inside the
-- 90-day no_reply window before precedence and 62 survive it, against 04's 65 —
-- a 3-person gap from the different person resolution (2,114 vs 2,099) and from
-- bounced people now falling through to the company rules rather than being
-- removed one precedence level earlier.
SELECT test.expect('rules', '07 person:recycle_window(no_reply)', 62,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:recycle_window(no_reply)'),
                   '04 says 65');

SELECT test.expect('rules', '07 person:recycle_window(no_reply) before precedence', 150,
                   (SELECT count(*) FROM rule_fired
                     WHERE rule_name = 'person:recycle_window(no_reply)'));

SELECT test.expect('rules', '08 person:recycle_window(replied_negative)', 28,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:recycle_window(replied_negative)'));

SELECT test.expect('rules', '09 person:recycle_window(opened_no_reply)', 16,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:recycle_window(opened_no_reply)'));

-- CORRECTED FROM 04. 30 people are held by 03's R3 rule, which is 04's number.
-- But 21 of them are already rejected by a higher-precedence rule — they sit
-- at a customer or open-opportunity company — so only 9 surface in the ledger
-- under this name. 04's "~30" is the raw predicate count, not the
-- first-match-wins count, and mixing the two is what makes 04's rule table sum
-- to more than its own total.
SELECT test.expect('rules', '10 identity:needs_review (surfaced)', 9,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'identity:needs_review'),
                   '04 says ~30, which is the raw count before precedence');

SELECT test.expect('rules', '10 identity:needs_review (raw predicate)', 30,
                   (SELECT count(*) FROM rule_fired
                     WHERE rule_name = 'identity:needs_review'));

-- 04: nobody is enrolled at rest, so the experiment lock excludes nobody on a
-- cold run. It is here because a non-zero count on a warm database is the
-- signal that the lock is doing its job.
SELECT test.expect('rules', '11 person:in_live_experiment', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:in_live_experiment'));

-- NOT IN 04. Added while building — see sql/01_schema.sql. Zero on the default
-- two-channel experiment, which is precisely why it is easy to leave out;
-- tests/50 runs the experiment that makes it fire.
SELECT test.expect('rules', '12 person:unreachable_on_channel', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name = 'person:unreachable_on_channel'),
                   'not one of 04 eleven rules; catches people with no usable channel');

-- 04: company:domain_lock is deliberately not a rejection rule. Under
-- grandfather-and-converge it never excludes anyone. That is the point of
-- choosing it, so its absence from the ledger is an assertion.
SELECT test.expect('rules', 'domain lock rejects nobody', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE rule_name LIKE '%domain_lock%'));

SELECT test.expect('rules', 'ELIGIBLE', 723,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible'),
                   '04 says 724, against 2099 persons');

SELECT test.expect('rules', 'eligible: never contacted', 541,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible' AND eligible_basis = 'never_contacted'),
                   '04 says 576');

SELECT test.expect('rules', 'eligible: recycled', 182,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible' AND eligible_basis = 'recycled'),
                   '04 says 148');

-- 04 requires that every rule name appear in out/rejections.csv. Two of them
-- reject nobody here, so they appear in out/eligible_*.csv instead, as the
-- named reason a channel was withheld. Without this the narrowing is invisible
-- in both artifacts.
SELECT test.expect('rules', 'eligible people carrying a withheld channel', 40,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible' AND channels_withheld <> '{}'::jsonb));

SELECT test.expect('rules', 'every withheld channel names a reason', 0,
                   (SELECT count(*) FROM eligibility_ledger l,
                                        jsonb_each_text(l.channels_withheld) w(ch, reason)
                     WHERE coalesce(reason, '') = ''));

-- Channel assignment is part of the verdict, not an afterthought: 04 scopes
-- unsubscribe to a channel and bounces to an address, so an eligible row
-- without a channel is not actionable.
SELECT test.expect('rules', 'eligible on both channels', 683,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible' AND channels = ARRAY['email', 'linkedin']));

SELECT test.expect('rules', 'eligible on linkedin only', 36,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible' AND channels = ARRAY['linkedin']));

SELECT test.expect('rules', 'eligible on email only', 4,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible' AND channels = ARRAY['email']));

-- Precedence is the property, not the counts. Every rejection must cite the
-- most-permanent rule that applies to that person, so no ledger row may name a
-- rule when a higher-precedence rule also fired for the same person.
SELECT test.expect('rules', 'no rejection cites a lower-precedence rule than one that fired', 0,
                   (SELECT count(*) FROM eligibility_ledger l
                     JOIN rule_fired f USING (person_id)
                     JOIN eligibility_rule cited ON cited.rule_name = l.rule_name
                     JOIN eligibility_rule other ON other.rule_name = f.rule_name
                    WHERE l.decision = 'rejected'
                      AND other.precedence < cited.precedence));

-- Every person gets exactly one verdict. The ledger is the whole population,
-- not a filtered view of it.
SELECT test.expect('rules', 'ledger has one row per person', 0,
                   (SELECT count(*) FROM (SELECT person_id FROM eligibility_ledger
                                          GROUP BY person_id HAVING count(*) > 1) d));

SELECT test.expect('rules', 'ledger covers every person', 2114,
                   (SELECT count(*) FROM eligibility_ledger));
