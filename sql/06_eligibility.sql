-- =============================================================================
--  06 — Eligibility (issue 04 §7)
--
--  Suppression is evaluated as a query, not stored as a flag. 01 forces this:
--  Instantly has a writable blocklist, HeyReach has none, so for LinkedIn the
--  ledger is the only enforcement point that exists. Tool-side blocklists are
--  redundant defence in depth, never the mechanism.
--
--  Two views:
--
--    rule_fired          every (person, rule) pair that applies, with evidence.
--                        A person can fire several rules; all of them are here.
--    eligibility_ledger  one row per person: the verdict, and for a rejection
--                        the single most-permanent rule that fired.
--
--  Keeping them separate is what makes the ledger arguable. "618 excluded by
--  person:domain_locked, here they are" can be disagreed with; "1,002 people
--  are eligible" cannot.
-- =============================================================================

-- One experiment, so the eligible list has something to be *for*. Its segment
-- and persona are deliberately NULL: issue 05 has not yet settled whether
-- segment is the right experimental axis, and 03 established that `industry`
-- is contact-level noise (142 of 146 companies carry conflicting industries
-- across their own contacts), so inventing a segment here would be fabricating
-- the one input the learning loop most depends on.
INSERT INTO experiment (experiment_id, name, message_variant, channels, max_duration_days)
SELECT norm.surrogate('experiment', config.experiment()), config.experiment(), 'v1',
       ARRAY['email', 'linkedin'], 30
 WHERE NOT EXISTS (SELECT 1 FROM experiment WHERE name = config.experiment());


DROP VIEW IF EXISTS rule_fired CASCADE;
CREATE VIEW rule_fired AS

-- 1-3. list:<reason> — asserted suppression. The brief names partner conflicts
--       alongside customers, open opportunities and DNC requests; this is the
--       one of the four that no data source emits, so it is the one that needs
--       a table (schema §7) rather than a predicate over the log.
--
--       One block covers all three reasons because the predicate is identical
--       and only the reason differs — the same reason the two company lifecycle
--       rules share a block below.
--
--       Company-scoped entries expand to every person at the company, which is
--       the whole point: a partner agreement is written about an account, and
--       `kindredgroup.io` has 37 contacts. Person-scoped entries hit one human.
--
--       Fires for nobody on this dataset, because the table is empty and
--       inventing rows would be worse than an empty table honestly labelled
--       (see schema §7 on why source=partner_referral is not this). tests/60
--       inserts fixtures at both scopes, checks the expiry clock reads as_of
--       rather than now(), and checks these rules outrank company:customer.
SELECT p.person_id, ('list:' || s.reason)::text AS rule_name,
       jsonb_build_object('scope', s.scope,
                          'company', c.primary_domain,
                          'added_by', s.added_by,
                          'added_at', s.added_at,
                          'expires_at', s.expires_at,
                          'asserted_evidence', s.evidence) AS evidence
  FROM suppression_list s
  JOIN person p ON (s.scope = 'person'  AND p.person_id  = s.person_id)
                OR (s.scope = 'company' AND p.company_id = s.company_id)
  LEFT JOIN company c ON c.company_id = p.company_id
 -- Read against as_of, like every other clock here, so a lapsed partner
 -- agreement stops suppressing on its own and the run stays reproducible.
 WHERE s.expires_at IS NULL OR s.expires_at > config.as_of()

UNION ALL

-- 4. person:dnc — a human sentence, global across every channel, permanent.
SELECT h.person_id, 'person:dnc',
       jsonb_build_object('source', 'notes free text',
                          'note', (SELECT string_agg(DISTINCT c.notes, '; ')
                                     FROM landing.contact_csv c
                                     JOIN row_person rp USING (row_num)
                                    WHERE rp.person_id = h.person_id
                                      AND norm.is_dnc_note(c.notes))) AS evidence
  FROM person_history h
 WHERE h.has_dnc

UNION ALL

-- 5. person:unsubscribed — channel-scoped, permanent.
--
--    Stated assumption: an email unsubscribe kills email and a LinkedIn
--    withdrawal kills LinkedIn, matching what CAN-SPAM and GDPR Art.21 actually
--    regulate. 447 of these contacts sit in GDPR jurisdictions and 149 in
--    Canada under CASL. A stricter counsel reading would globalise every
--    unsubscribe; that change is one predicate and costs 8 people.
--
--    A person unsubscribed on every channel the experiment uses is rejected.
--    Unsubscribed on some but not all: they stay eligible, on the remainder.
SELECT h.person_id, 'person:unsubscribed',
       jsonb_build_object('unsubscribed_channels', to_jsonb(h.unsubscribed_channels),
                          'experiment_channels', to_jsonb(x.channels))
  FROM person_history h
 CROSS JOIN (SELECT channels FROM experiment WHERE name = config.experiment()) x
 WHERE h.has_unsubscribed
   -- Deliberately NOT available_channels(): this rule asks only whether the
   -- unsubscribes cover every channel. Folding in the email/bounce checks would
   -- reject someone for having no address under the name "unsubscribed", which
   -- is a different fact and belongs to rule 15.
   AND NOT EXISTS (SELECT 1 FROM unnest(x.channels) ch
                    WHERE ch <> ALL (h.unsubscribed_channels))

UNION ALL

-- 6. person:bounced — terminal for that address, not for the person.
--
--    01 established Instantly exposes one email_bounced event with no type
--    field, so severity is unavailable. Inferring it from repetition was
--    rejected: it requires re-sending to a possibly-dead address to learn
--    whether it is dead, which is exactly the behaviour that burns a domain.
--
--    Like unsubscribe, this rule *narrows* before it rejects. 04 is explicit
--    that "the person survives on LinkedIn and on any future address; only the
--    address dies", so on a two-channel experiment a bounced person is still
--    reachable and drops to LinkedIn rather than out of the list. It rejects
--    only when the bounce leaves nothing to send on — which is exactly the
--    email-only case.
--
--    Applying this rule any other way would be inconsistent with rule 2: both
--    are scoped suppressions, and a scoped suppression that removes a person
--    from every channel is not scoped.
SELECT h.person_id, 'person:bounced',
       jsonb_build_object('bounced_addresses', to_jsonb(h.bounced_addresses),
                          'current_email', p.primary_email,
                          'experiment_channels', to_jsonb(x.channels))
  FROM person_history h
  JOIN person p USING (person_id)
 CROSS JOIN (SELECT channels FROM experiment WHERE name = config.experiment()) x
 WHERE h.has_bounced
   AND p.primary_email = ANY (h.bounced_addresses)
   AND cardinality(available_channels(x.channels, h.unsubscribed_channels,
                                      p.primary_email, h.bounced_addresses)) = 0

UNION ALL

-- 7-8. company:customer and company:open_opportunity — both company-wide.
--
--    One block over two stages, because the predicate is identical and only the
--    HubSpot lifecycle stage differs. Writing it twice would be two places to
--    fix the day someone changes what "at this company" means.
--
--    company:customer, permanent: cold outbound into an existing account reads
--    to the customer receiving it as a failure of basic record-keeping.
--
--    company:open_opportunity is the single largest input to eligible volume —
--    47% of the list sits at a company with an open deal. `opportunity` is a
--    *contact* lifecycle stage, so the buying committee is known by name (70
--    contacts across 55 companies, ~1.3 each) and suppressing only them was a
--    live option worth roughly 900 more people.
--
--    Rejected on asymmetry: a cold sequence landing at a company mid-
--    negotiation can cost a deal in flight; a suppressed prospect costs only
--    delay. It is also the failure a sales team notices first.
--
--    Coordinated multi-threading is the correct end state, via a
--    suppression_override table with a deal-owner as its writer. Designed, not
--    built — without a named owner authorised to relax a suppression, it
--    would be a table with no writer.
SELECT p.person_id, g.rule_name,
       jsonb_build_object('company', c.primary_domain,
                          'stage', g.stage,
                          'contacts_at_company', g.contacts_at_company,
                          'stage_held_by', g.stage_held_by)
  FROM person p
  JOIN company c USING (company_id)
  JOIN (
      SELECT p2.company_id,
             v.stage,
             v.rule_name,
             count(*)                                     AS contacts_at_company,
             string_agg(DISTINCT p2.primary_email, ', ')
               FILTER (WHERE cl.stage = v.stage)          AS stage_held_by
        FROM (VALUES ('customer',    'company:customer'),
                     ('opportunity', 'company:open_opportunity'))
             AS v(stage, rule_name)
        JOIN person p2 ON p2.company_id IS NOT NULL
        LEFT JOIN crm_lifecycle cl USING (person_id)
       GROUP BY p2.company_id, v.stage, v.rule_name
      HAVING count(*) FILTER (WHERE cl.stage = v.stage) > 0
  ) g ON g.company_id = p.company_id

UNION ALL

-- 9. person:owned_by_sales — booked or replied positive. Outbound does not own
--    this person any more, and only sales can release them.
SELECT h.person_id, 'person:owned_by_sales',
       jsonb_build_object('last_sent_at', h.last_sent_at,
                          'signal', CASE WHEN EXISTS (SELECT 1 FROM contact_event e
                                                       WHERE e.person_id = h.person_id
                                                         AND e.event_type = 'booked')
                                         THEN 'booked' ELSE 'replied_positive' END)
  FROM person_history h
 WHERE h.owned_by_sales

UNION ALL

-- 10-12. person:recycle_window(...) — elapsed time since the last send.
--
--    The asymmetry is the defensible part: someone who opened and stayed
--    silent is *warmer* than someone who ignored you entirely, so they come
--    back sooner (60d), not later. Silence is 90d, an explicit no is 180d.
--
--    Evaluated against config.as_of(), never now(). With now() every count in
--    tests/ would stop reproducing tomorrow.
--
--    04's headline: tuning this whole table is a rounding error. Aggressive
--    (60/30/180) yields 754 eligible, conservative (180/120/365) yields 646 —
--    a range of 108 people, against the 1,198 that company suppression moves.
SELECT lo.person_id,
       'person:recycle_window(' || lo.outcome || ')',
       jsonb_build_object('last_sent_at', lo.last_sent_at,
                          'window_days', w.window_days,
                          'days_elapsed', config.as_of() - lo.last_sent_at,
                          'eligible_again_on', lo.last_sent_at + w.window_days)
  FROM person_last_outcome lo
  JOIN recycle_window w ON w.outcome = lo.outcome
 WHERE lo.last_sent_at IS NOT NULL
   AND config.as_of() < lo.last_sent_at + w.window_days

UNION ALL

-- 13. identity:needs_review — 03's R3-uncorroborated clusters. Both members
--     are held until a human adjudicates. This is the system being visibly
--     aware of its own uncertainty rather than silently guessing.
SELECT p.person_id, 'identity:needs_review', p.review_evidence
  FROM person p
 WHERE p.needs_review

UNION ALL

-- 14. person:in_live_experiment — the brief's one-live-experiment rule.
--
--     A multi-channel sequence is NOT two experiments; it is one experiment
--     whose definition contains both an email step and a LinkedIn step. That
--     is what keeps a reply attributable to one thing.
--
--     Zero at rest, because nothing is enrolled on a cold run. It is here
--     because the ledger is the enforcement point: 01 established Instantly
--     creates duplicate lead rows across campaigns unless skip_if_in_* is set,
--     and those vendor flags are defence in depth only.
--
--     expires_at is load-bearing: without it a stalled sequence holds a person
--     forever, since the sending tools will not release them.
SELECT en.person_id, 'person:in_live_experiment',
       jsonb_build_object('experiment', x.name,
                          'enrolled_at', en.enrolled_at,
                          'expires_at', en.expires_at)
  FROM experiment_enrollment en
  JOIN experiment x USING (experiment_id)
 WHERE en.expires_at > config.as_of()
   AND NOT EXISTS (
       -- A terminal event releases the person before expiry.
       SELECT 1 FROM contact_event e
        WHERE e.person_id = en.person_id
          AND e.experiment_id = en.experiment_id
          AND e.event_type IN ('replied_positive', 'replied_negative', 'booked',
                               'unsubscribed', 'bounced', 'sequence_completed'))

UNION ALL

-- 15. person:unreachable_on_channel — nothing left to send on.
--
--     Not one of 04's rules. 04 enumerates ten reasons a person must not be
--     contacted and none for a person who simply cannot be. On the default
--     two-channel experiment this fires for nobody, which is why it is easy to
--     miss; on an email-only experiment it catches the five people whose only
--     address is blank or malformed, who would otherwise appear in
--     eligible.csv with no address to send to.
--
--     Last in precedence: it is a property of the experiment, not of the
--     person, and it disappears the moment they are put in a LinkedIn sequence.
SELECT p.person_id, 'person:unreachable_on_channel',
       jsonb_build_object('experiment_channels', to_jsonb(x.channels),
                          'has_email', p.primary_email IS NOT NULL,
                          'unsubscribed_channels', to_jsonb(h.unsubscribed_channels),
                          'bounced_addresses', to_jsonb(h.bounced_addresses))
  FROM person p
  JOIN person_history h USING (person_id)
 CROSS JOIN (SELECT channels FROM experiment WHERE name = config.experiment()) x
 WHERE cardinality(available_channels(x.channels, h.unsubscribed_channels,
                                      p.primary_email, h.bounced_addresses)) = 0;


-- -----------------------------------------------------------------------------
--  The ledger
-- -----------------------------------------------------------------------------

DROP VIEW IF EXISTS eligibility_ledger CASCADE;
CREATE VIEW eligibility_ledger AS
WITH ranked AS (
    -- First match wins, ordered most-permanent-first, so the ledger names the
    -- most *meaningful* reason rather than whichever predicate fired first.
    SELECT f.person_id, f.rule_name, f.evidence, r.precedence,
           row_number() OVER (PARTITION BY f.person_id ORDER BY r.precedence) AS rn
      FROM rule_fired f
      JOIN eligibility_rule r USING (rule_name)
),
verdict AS (
    SELECT p.person_id, k.rule_name, k.evidence
      FROM person p
      LEFT JOIN ranked k ON k.person_id = p.person_id AND k.rn = 1
)
SELECT v.person_id,
       CASE WHEN v.rule_name IS NULL THEN 'eligible' ELSE 'rejected' END AS decision,
       v.rule_name,
       v.evidence,
       CASE
           WHEN v.rule_name IS NOT NULL          THEN NULL
           WHEN lo.last_sent_at IS NULL          THEN 'never_contacted'
           ELSE                                       'recycled'
       END AS eligible_basis,

       -- Which channels this person can be approached on, for this experiment.
       -- Channel selection is part of the verdict: 04 scopes unsubscribe to a
       -- channel and bounces to an address, so "eligible" without a channel is
       -- not actionable.
       CASE WHEN v.rule_name IS NOT NULL THEN NULL
            ELSE available_channels(x.channels, h.unsubscribed_channels,
                                    p.primary_email, h.bounced_addresses)
       END AS channels,

       -- The channels this experiment wanted and cannot use, and why. Rules 2
       -- and 3 are scoped, so on a multi-channel experiment they narrow rather
       -- than reject — and without this column that narrowing appears in
       -- neither artifact.
       CASE WHEN v.rule_name IS NOT NULL THEN NULL
            ELSE withheld_channels(x.channels, h.unsubscribed_channels,
                                   p.primary_email, h.bounced_addresses)
       END AS channels_withheld,

       pd.sending_domain,
       pd.assignment_basis AS domain_basis
  FROM verdict v
  JOIN person p USING (person_id)
  JOIN person_history h USING (person_id)
  JOIN person_last_outcome lo USING (person_id)
  JOIN person_domain pd USING (person_id)
 CROSS JOIN (SELECT channels FROM experiment WHERE name = config.experiment()) x;


-- -----------------------------------------------------------------------------
--  Derived state, for the record
-- -----------------------------------------------------------------------------

-- 04 §6's state machine. State is a view — these are derived classifications,
-- never stored values. Nothing in the pipeline reads this; it exists so that
-- "what state is this person in?" has an answer that cannot drift from the log.
DROP VIEW IF EXISTS person_state CASCADE;
CREATE VIEW person_state AS
SELECT l.person_id,
       CASE
           WHEN p.needs_review                        THEN 'held'
           WHEN l.rule_name LIKE 'company:%'
             OR l.rule_name LIKE 'list:%'
             OR l.rule_name IN ('person:dnc', 'person:unsubscribed',
                                'person:bounced')     THEN 'suppressed'
           WHEN l.rule_name = 'person:owned_by_sales' THEN 'responded'
           WHEN l.rule_name LIKE 'person:recycle_window%' THEN 'cooling'
           WHEN l.rule_name = 'person:in_live_experiment' THEN 'in_flight'
           WHEN lo.last_sent_at IS NULL               THEN 'never_contacted'
           ELSE                                            'eligible'
       END AS state
  FROM eligibility_ledger l
  JOIN person p USING (person_id)
  JOIN person_last_outcome lo USING (person_id);


-- -----------------------------------------------------------------------------
--  Reconciliation
-- -----------------------------------------------------------------------------

-- The claim the component rests on: nothing is lost between the raw file and
-- the two output artifacts, and the residual is zero.
DROP VIEW IF EXISTS reconciliation CASCADE;
CREATE VIEW reconciliation AS
SELECT (SELECT count(*) FROM landing.contact_csv)                     AS rows_in,
       (SELECT count(*) FROM person)                                  AS persons,
       (SELECT count(*) FROM landing.contact_csv) - (SELECT count(*) FROM person)
                                                                      AS rows_absorbed,
       (SELECT count(*) FROM quarantine)                              AS quarantined,
       (SELECT count(*) FROM eligibility_ledger WHERE decision = 'eligible') AS eligible,
       (SELECT count(*) FROM eligibility_ledger WHERE decision = 'rejected') AS rejected;
