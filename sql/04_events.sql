-- =============================================================================
--  04 — Reconstruct the event log from the CSV's collapsed columns
--
--  This is the migration, demonstrated. The CSV holds last_contacted_date,
--  last_campaign, last_outcome — one value each, per person. Eight duplicate
--  clusters prove more than one campaign actually ran against those people;
--  the earlier touches were overwritten and are gone.
--
--  So the backfill is honestly lossy and says so: every synthetic event is
--  tagged source='csv_backfill', and what it reconstructs is the *last* touch,
--  because that is all the file retained. Real events arriving from Instantly
--  and HeyReach after cutover carry source='instantly' / 'heyreach' and are
--  complete. The two are distinguishable forever, which matters the first time
--  someone asks why a person has one send event and a six-month history.
--
--  Nothing here updates. contact_event is append-only; the pipeline rebuilds
--  it wholesale on each run, which is the batch equivalent of the same rule.
-- =============================================================================

TRUNCATE contact_event;

-- Idempotency: external_id is the natural key from the source system, and
-- event_id is derived from it with norm.surrogate rather than allocated. 02
-- established HubSpot and Instantly webhooks are at-least-once, so replaying an
-- event must be a no-op rather than a duplicate. Here the same property makes
-- the whole pipeline re-runnable.


-- -----------------------------------------------------------------------------
--  The send that actually happened
-- -----------------------------------------------------------------------------

-- 781 rows carry a last_contacted_date. Each becomes one `sent` event holding
-- the three facts the brief says Noble cannot currently answer: which channel,
-- which domain, which message.
INSERT INTO contact_event (event_id, external_id, person_id, occurred_at, channel,
                           event_type, sending_domain, campaign, email_address,
                           source, source_row_id)
SELECT norm.surrogate('event', 'csv:' || c.contact_id || ':sent'),
       'csv:' || c.contact_id || ':sent',
       rp.person_id,
       btrim(c.last_contacted_date)::date,
       nullif(btrim(c.last_contacted_channel), ''),
       'sent',
       nullif(btrim(c.last_sending_domain), ''),
       nullif(btrim(c.last_campaign), ''),
       norm.email(c.email),
       'csv_backfill',
       c.contact_id
  FROM landing.contact_csv c
  JOIN row_person rp USING (row_num)
 WHERE nullif(btrim(c.last_contacted_date), '') IS NOT NULL;


-- -----------------------------------------------------------------------------
--  What came back
-- -----------------------------------------------------------------------------

-- The outcome column is mapped to exactly the event it names and nothing more.
-- `no_reply` produces no event at all — silence is the absence of a response,
-- not a kind of response, and inventing a `no_reply` event would make the log
-- claim knowledge of a moment that never occurred. Absence is recoverable: a
-- `sent` with no subsequent reply IS no_reply, derived in person_history.
--
-- `opened_no_reply` produces `opened` only, for the same reason.
INSERT INTO contact_event (event_id, external_id, person_id, occurred_at, channel,
                           event_type, sending_domain, campaign, email_address,
                           source, source_row_id)
SELECT norm.surrogate('event', 'csv:' || c.contact_id || ':' || m.event_type),
       'csv:' || c.contact_id || ':' || m.event_type,
       rp.person_id,
       btrim(c.last_contacted_date)::date,
       nullif(btrim(c.last_contacted_channel), ''),
       m.event_type,
       nullif(btrim(c.last_sending_domain), ''),
       nullif(btrim(c.last_campaign), ''),
       -- Address-scoped rules key off this, so it is populated only for email
       -- touches. 10 of the 66 bounces in the file sit on a row whose
       -- last_contacted_channel is `linkedin`; attaching an address to those
       -- would let a LinkedIn event kill an email address that has never been
       -- mailed. What a "bounce" means on LinkedIn is a question for the source
       -- data, and the honest answer here is to record the event and decline to
       -- infer an address from it.
       CASE WHEN btrim(c.last_contacted_channel) = 'email'
            THEN norm.email(c.email) END,
       'csv_backfill',
       c.contact_id
  FROM landing.contact_csv c
  JOIN row_person rp USING (row_num)
 CROSS JOIN LATERAL (
     SELECT CASE btrim(c.last_outcome)
                 WHEN 'opened_no_reply'  THEN 'opened'
                 WHEN 'replied_positive' THEN 'replied_positive'
                 WHEN 'replied_negative' THEN 'replied_negative'
                 WHEN 'bounced'          THEN 'bounced'
                 WHEN 'unsubscribed'     THEN 'unsubscribed'
                 WHEN 'booked'           THEN 'booked'
                 ELSE NULL END AS event_type
 ) m
 WHERE nullif(btrim(c.last_contacted_date), '') IS NOT NULL
   AND m.event_type IS NOT NULL;


-- -----------------------------------------------------------------------------
--  DNC, from free text
-- -----------------------------------------------------------------------------

-- 04: `notes` is the only suppression source in this file that HubSpot does
-- not carry. It contributes exactly three signals — DNC requests, confirmed
-- hard bounces, and linkedin-only markers — and of those only DNC is
-- authoritative. The other two corroborate what the outcome column already
-- says, with zero disagreement across the file.
--
-- A human sentence outranks a click, so these are person-level and global
-- across every channel, where an unsubscribe is only channel-scoped.
INSERT INTO contact_event (event_id, external_id, person_id, occurred_at,
                           event_type, source, source_row_id)
SELECT norm.surrogate('event', 'csv:' || c.contact_id || ':dnc'),
       'csv:' || c.contact_id || ':dnc',
       rp.person_id,
       coalesce(nullif(btrim(c.last_contacted_date), '')::date,
                btrim(c.date_added)::date),
       'dnc',
       'csv_backfill',
       c.contact_id
  FROM landing.contact_csv c
  JOIN row_person rp USING (row_num)
 WHERE norm.is_dnc_note(c.notes)
ON CONFLICT (external_id) DO NOTHING;


-- -----------------------------------------------------------------------------
--  Derived history — the questions the CSV could not answer
-- -----------------------------------------------------------------------------

-- Every predicate downstream reads from here. Nothing in this view is stored;
-- it is recomputed from the log on every query, which is the whole argument of
-- issue 04 §1 expressed as SQL.
DROP VIEW IF EXISTS person_history CASCADE;
CREATE VIEW person_history AS
SELECT p.person_id,

       -- "Who have we contacted?"
       count(*) FILTER (WHERE e.event_type = 'sent')            AS sends,
       max(e.occurred_at) FILTER (WHERE e.event_type = 'sent')  AS last_sent_at,

       -- "From which domain?" — and, unlike the CSV column, from *every*
       -- domain, which is what makes the "Ever." constraint checkable at all.
       -- Every array here is coalesced to empty rather than left NULL. An
       -- empty history is a real, common state (1,341 people have never been
       -- contacted), and a NULL array silently poisons every `= ANY` and
       -- `<> ALL` downstream into NULL — which reads as "no channel available"
       -- rather than "no restriction". Empty is the honest zero.
       coalesce(array_remove(array_agg(DISTINCT e.sending_domain), NULL), '{}') AS domains_used,

       -- "With which message?"
       coalesce(array_remove(array_agg(DISTINCT e.campaign), NULL), '{}')      AS campaigns,
       coalesce(array_remove(array_agg(DISTINCT e.channel), NULL), '{}')       AS channels_used,

       -- "What happened?"
       bool_or(e.event_type = 'dnc')              AS has_dnc,
       bool_or(e.event_type = 'unsubscribed')     AS has_unsubscribed,
       bool_or(e.event_type = 'bounced')          AS has_bounced,
       bool_or(e.event_type IN ('booked', 'replied_positive')) AS owned_by_sales,

       max(e.occurred_at) FILTER (WHERE e.event_type = 'replied_negative') AS replied_negative_at,
       max(e.occurred_at) FILTER (WHERE e.event_type = 'opened')           AS opened_at,
       bool_or(e.event_type IN ('replied_positive', 'replied_negative',
                                'bounced', 'unsubscribed', 'booked'))      AS had_response,

       -- The channel an unsubscribe landed on: unsubscribe is channel-scoped,
       -- so "unsubscribed" alone is not enough to decide anything.
       coalesce(array_remove(array_agg(DISTINCT e.channel)
                    FILTER (WHERE e.event_type = 'unsubscribed'), NULL), '{}') AS unsubscribed_channels,

       -- Bounces kill an address, not a person. Someone who bounced at an old
       -- employer is reachable at the new one.
       coalesce(array_remove(array_agg(DISTINCT e.email_address)
                    FILTER (WHERE e.event_type = 'bounced'), NULL), '{}') AS bounced_addresses

  FROM person p
  LEFT JOIN contact_event e USING (person_id)
 GROUP BY p.person_id;


-- The outcome classification the recycle clocks branch on. Derived, not
-- stored — and derived from the presence or absence of events rather than from
-- a column that only ever held the latest value.
DROP VIEW IF EXISTS person_last_outcome CASCADE;
CREATE VIEW person_last_outcome AS
SELECT h.person_id,
       h.last_sent_at,
       CASE
           WHEN h.last_sent_at IS NULL      THEN 'never_contacted'
           WHEN h.owned_by_sales            THEN 'owned_by_sales'
           WHEN h.has_bounced               THEN 'bounced'
           WHEN h.has_unsubscribed          THEN 'unsubscribed'
           WHEN h.replied_negative_at IS NOT NULL THEN 'replied_negative'
           WHEN h.opened_at IS NOT NULL     THEN 'opened_no_reply'
           ELSE                                  'no_reply'
       END AS outcome
  FROM person_history h;
