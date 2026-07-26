-- =============================================================================
--  Noble outbound system of record — schema
--
--  This file is the data model. It is written to be read: every table carries
--  the decision that produced it and the issue that settled it.
--
--  Three principles, all decided in .scratch/noble-outbound-sor/:
--
--    1. Identity is a surrogate key with an alias table (03). No natural key
--       candidate in this dataset survives contact with the data.
--    2. State is derived from an append-only event log, never stored (04).
--       There is no `state` column anywhere in this file. Search for one.
--    3. Suppression is evaluated as a query, not stored as a flag (04 §3),
--       because HeyReach has no writable blocklist and the ledger is the only
--       enforcement point that exists for LinkedIn.
--
--  Consequence of 2 and 3: everything downstream of identity is a VIEW.
--  Views cannot drift from the log. On 2,154 rows the cost is nil, and the
--  derivation stays legible, which is the point.
-- =============================================================================

DROP SCHEMA IF EXISTS landing CASCADE;
DROP SCHEMA IF EXISTS norm    CASCADE;
DROP SCHEMA IF EXISTS config  CASCADE;

-- Only the tables are named here. Every derived view in sql/03..07 hangs off
-- one of them, so CASCADE takes them all — and a hand-maintained list of view
-- names is a list that silently drifts as views are added.
DROP TABLE IF EXISTS suppression_list      CASCADE;
DROP TABLE IF EXISTS suppression_reason    CASCADE;
DROP TABLE IF EXISTS experiment_enrollment CASCADE;
DROP TABLE IF EXISTS experiment            CASCADE;
DROP TABLE IF EXISTS contact_event         CASCADE;
DROP TABLE IF EXISTS crm_lifecycle         CASCADE;
DROP TABLE IF EXISTS quarantine            CASCADE;
DROP TABLE IF EXISTS person_alias          CASCADE;
DROP TABLE IF EXISTS person                CASCADE;
DROP TABLE IF EXISTS company_alias         CASCADE;
DROP TABLE IF EXISTS company               CASCADE;
DROP TABLE IF EXISTS eligibility_rule      CASCADE;
DROP TABLE IF EXISTS recycle_window        CASCADE;
DROP TABLE IF EXISTS sending_domain        CASCADE;

CREATE SCHEMA landing;
CREATE SCHEMA norm;
CREATE SCHEMA config;


-- =============================================================================
--  0. Run configuration
-- =============================================================================

-- Every clock in this pipeline is evaluated against `as_of`, never now().
-- With now() the counts stop reproducing tomorrow, which would make every
-- assertion in tests/ a slowly-rotting lie.
CREATE TABLE config.setting (
    key   text PRIMARY KEY,
    value text NOT NULL
);

INSERT INTO config.setting (key, value) VALUES
    ('as_of', '2026-07-25'),          -- the date issues 03 and 04 profiled against
    ('experiment', 'aeo-saas-aug');   -- the experiment the eligible list is for

CREATE FUNCTION config.as_of() RETURNS date
    LANGUAGE sql STABLE AS
$$ SELECT value::date FROM config.setting WHERE key = 'as_of' $$;

CREATE FUNCTION config.experiment() RETURNS text
    LANGUAGE sql STABLE AS
$$ SELECT value FROM config.setting WHERE key = 'experiment' $$;


-- =============================================================================
--  1. Landing — the raw file, unmodified
-- =============================================================================

-- Every column is text, including the dates. The malformed emails, the padded
-- whitespace, the blank cells and the shouty casing all land exactly as they
-- appear in the file. Nothing is fixed by hand and nothing is fixed on the way
-- in: cleaning happens downstream in SQL where it is inspectable and where a
-- reviewer can disagree with it.
CREATE TABLE landing.contact_csv (
    row_num                 bigint GENERATED ALWAYS AS IDENTITY,
    contact_id              text,
    first_name              text,
    last_name               text,
    email                   text,
    linkedin_url            text,
    title                   text,
    seniority               text,
    company_name            text,
    company_domain          text,
    employee_count          text,
    industry                text,
    country                 text,
    source                  text,
    date_added              text,
    last_contacted_date     text,
    last_contacted_channel  text,
    last_sending_domain     text,
    last_campaign           text,
    last_outcome            text,
    hubspot_lifecycle_stage text,
    notes                   text
);

COMMENT ON TABLE landing.contact_csv IS
    'The supplied CSV, byte-for-byte. The single most useful property of this '
    'table is that it is boring: any disagreement about a downstream number '
    'can be settled by querying here.';


-- =============================================================================
--  2. Normalisation — the functions the identity rules are made of
-- =============================================================================
--
--  These are separate named functions rather than inline expressions because
--  03's resolution rules are stated in terms of them, and because the six
--  plus-addressed and eight whitespace/case-padded rows are the difference
--  between 2,099 persons and 2,154.

-- Lowercase, trim, strip +tags. Returns NULL for anything that is not a
-- plausible address — the six malformed rows resolve on LinkedIn instead.
CREATE FUNCTION norm.email(raw text) RETURNS text
    LANGUAGE sql IMMUTABLE AS
$$
    SELECT CASE
        WHEN e ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$'
        THEN regexp_replace(e, '\+[^@]*@', '@')
        ELSE NULL
    END
    FROM (SELECT lower(btrim(raw)) AS e) s
$$;

-- The domain half of an address, after normalisation.
CREATE FUNCTION norm.email_domain(raw text) RETURNS text
    LANGUAGE sql IMMUTABLE AS
$$ SELECT split_part(norm.email(raw), '@', 2) $$;

-- Registrable domain: lowercase, trimmed, no scheme, no www., no trailing dot.
CREATE FUNCTION norm.domain(raw text) RETURNS text
    LANGUAGE sql IMMUTABLE AS
$$
    SELECT nullif(regexp_replace(
               regexp_replace(lower(btrim(raw)), '^https?://', ''),
               '^www\.|\.$', '', 'g'), '')
$$;

-- LinkedIn slug. Apollo emits scheme, www, trailing slashes and query strings
-- inconsistently; the slug is the only stable part.
CREATE FUNCTION norm.linkedin(raw text) RETURNS text
    LANGUAGE sql IMMUTABLE AS
$$
    SELECT nullif(regexp_replace(
               lower(btrim(split_part(raw, '?', 1))),
               '^(https?://)?(www\.)?linkedin\.com/in/|/+$', '', 'g'), '')
$$;

-- The slug is the matching key; this is what goes back out to a human or to
-- HeyReach. Storing the slug alone in an export would hand someone a file they
-- cannot click.
CREATE FUNCTION norm.linkedin_url(slug text) RETURNS text
    LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN slug IS NULL THEN NULL
                ELSE 'https://www.linkedin.com/in/' || slug END $$;

-- The comparison key for a free-text field: lowercased, trimmed, internal
-- whitespace collapsed. Named for what it is rather than for names — it keys
-- titles, seniorities and company names too, and calling it norm.name() while
-- applying it to `title` was a small lie in a file meant to be read.
CREATE FUNCTION norm.text_key(raw text) RETURNS text
    LANGUAGE sql IMMUTABLE AS
$$ SELECT nullif(regexp_replace(lower(btrim(raw)), '\s+', ' ', 'g'), '') $$;

-- 03: free-mail domains are blocklisted from ever becoming a company. Without
-- this, gmail.com becomes a company, the six freelancers fuse into one, and
-- the day any of them converts the other five are suppressed.
CREATE FUNCTION norm.is_free_mail(d text) RETURNS boolean
    LANGUAGE sql IMMUTABLE AS
$$
    SELECT norm.domain(d) IN (
        'gmail.com', 'googlemail.com', 'yahoo.com', 'yahoo.co.uk', 'outlook.com',
        'hotmail.com', 'hotmail.co.uk', 'live.com', 'icloud.com', 'me.com',
        'aol.com', 'proton.me', 'protonmail.com', 'gmx.com', 'mail.com'
    )
$$;

-- Deterministic surrogate ids.
--
-- 03 specifies a surrogate uuid. gen_random_uuid() would break the idempotence
-- requirement in 07 — two runs over the same file would produce two different
-- sets of ids and two different output files. So ids are derived from the
-- cluster's earliest source row (its lowest contact_id), which is stable
-- across runs and still opaque: it is not a natural key, carries no meaning,
-- and every identifier the cluster has ever had lives in person_alias.
--
-- Stated deviation: in production person_id is assigned once and persisted
-- forever. Here the pipeline rebuilds from the file on every run, so it must
-- derive rather than allocate. A merge changes the survivor's id only because
-- there is no prior database to preserve it against.
CREATE FUNCTION norm.surrogate(prefix text, natural_key text) RETURNS uuid
    LANGUAGE sql IMMUTABLE AS
$$ SELECT md5(prefix || ':' || natural_key)::uuid $$;


-- =============================================================================
--  2b. Sending domains
-- =============================================================================

-- The one place a domain is added or retired. Retirement is not a DELETE:
-- 04 requires that migrating a company's lock is a logged, human-approved
-- `domain_migrated` event, because it is a knowing violation of the brief's
-- "Ever." and the alternative is permanently orphaning up to a quarter of the
-- base. Setting active = false stops new assignments; it strands nobody.
--
-- Which domain to retire, and on what deliverability signal, is sending
-- infrastructure and the brief rules it out of scope by name.
CREATE TABLE sending_domain (
    domain    text PRIMARY KEY,
    active    boolean NOT NULL DEFAULT true,
    hash_slot int     NOT NULL UNIQUE   -- fixed, so adding a domain later does
                                        -- not reshuffle every existing lock
);

INSERT INTO sending_domain (domain, hash_slot) VALUES
    ('getnoble.io',        0),
    ('noble-outreach.com', 1),
    ('noblehq.io',         2),
    ('trynoble.co',        3);


-- Which of the active sending domains a key lands on. Stateless and
-- deterministic: no sequence, no round-robin counter, identical output on every
-- run. A round-robin would assign a different domain on a re-run and quietly
-- violate the brief's "Ever." for anyone enrolled in between.
--
-- 28 bits rather than 32 so the value is always non-negative — abs() on a
-- 32-bit hash has an overflow case at INT_MIN, and this is exactly the kind of
-- once-in-2-billion bug that would surface as one person on the wrong domain.
CREATE OR REPLACE FUNCTION norm.hash_slot(key text, n_slots int) RETURNS int
    LANGUAGE sql IMMUTABLE AS
$$ SELECT mod(('x' || substr(md5(key), 1, 7))::bit(28)::int, n_slots) $$;


-- Which channels are actually usable for one person on one experiment.
--
-- Defined once, in one place, because it is needed twice and the two uses must
-- never disagree: the ledger uses it to fill in the channel column, and
-- person:unreachable_on_channel uses it to reject anyone for whom it comes back
-- empty. If those two drifted apart, a person could be marked eligible with
-- nothing to reach them on — the precise failure the ledger exists to prevent.
--
-- Returns an empty array, never NULL, so callers can test cardinality without
-- a three-valued-logic trap.
CREATE OR REPLACE FUNCTION available_channels(
    experiment_channels   text[],
    unsubscribed_channels text[],   -- 04: unsubscribe is channel-scoped
    primary_email         text,
    bounced_addresses     text[]    -- 04: a bounce kills an address, not a person
) RETURNS text[] LANGUAGE sql IMMUTABLE AS
$$
    SELECT coalesce(array_agg(ch ORDER BY ch), '{}')
      FROM unnest(experiment_channels) ch
     WHERE ch <> ALL (unsubscribed_channels)
       AND NOT (ch = 'email' AND (primary_email IS NULL
                                  OR primary_email = ANY (bounced_addresses)))
$$;


-- The other half of available_channels: for each channel the experiment wanted
-- but cannot use, why. 04 requires that every rule name appear in the
-- rejection ledger, but a scoped rule that only *narrows* a person's channels
-- never rejects anyone and would otherwise leave no trace in either artifact —
-- 21 people silently dropped from email with nothing on the page to say so.
-- This is where those go.
CREATE OR REPLACE FUNCTION withheld_channels(
    experiment_channels   text[],
    unsubscribed_channels text[],
    primary_email         text,
    bounced_addresses     text[]
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$
    SELECT coalesce(jsonb_object_agg(ch, reason), '{}'::jsonb)
      FROM (
          SELECT ch,
                 CASE
                     WHEN ch = ANY (unsubscribed_channels)          THEN 'person:unsubscribed'
                     WHEN ch = 'email' AND primary_email IS NULL    THEN 'no usable email address'
                     WHEN ch = 'email' AND primary_email = ANY (bounced_addresses)
                                                                    THEN 'person:bounced'
                 END AS reason
            FROM unnest(experiment_channels) ch
      ) r
     WHERE reason IS NOT NULL
$$;


-- The free-text patterns that mean "stop contacting me". Extracted because the
-- backfill in 04 uses it to write the dnc event and the ledger in 06 uses it to
-- quote the sentence as evidence — and evidence that does not match the rule
-- that fired is worse than no evidence.
CREATE FUNCTION norm.is_dnc_note(note text) RETURNS boolean
    LANGUAGE sql IMMUTABLE AS
$$ SELECT note ~* '(asked to be removed|please stop|do not contact|remove me)' $$;


-- =============================================================================
--  3. Identity (03) — company
-- =============================================================================

-- Keyed on the normalised registrable domain. Not on company_name: 03 found
-- name spellings disagree across sources while the domain does not.
CREATE TABLE company (
    company_id     uuid PRIMARY KEY,
    primary_domain text NOT NULL UNIQUE,
    name_key       text NOT NULL,   -- normalised; the alias-merge key
    company_name   text,            -- display spelling, as it appears in source
    employee_count int,          -- reliable: consistent for 152/153 companies
    industry       text,         -- UNRELIABLE. 142/153 companies carry
                                 -- conflicting industries across their own
                                 -- contacts. Never segment on it (03).
    segment        text          -- assigned, never inferred. Awaits issue 05.
);

-- Exists because Keystone Cloud has two domains (getkeystone.com,
-- keystonecloud.io). Without it that is two companies and company-level
-- suppression leaks across them.
CREATE TABLE company_alias (
    company_id uuid NOT NULL REFERENCES company(company_id),
    domain     text NOT NULL PRIMARY KEY
);


-- =============================================================================
--  4. Identity (03) — person
-- =============================================================================

CREATE TABLE person (
    person_id     uuid PRIMARY KEY,
    primary_email text,           -- NULL for the 11 linkedin-only contacts
    linkedin_url  text NOT NULL,  -- 100% coverage in this file
    first_name    text,
    last_name     text,
    title         text,
    seniority     text,
    country       text,
    company_id    uuid REFERENCES company(company_id),

    -- 03: free-mail company_domain means there is no company to suppress.
    -- These get person-level suppression only, which is correct.
    is_independent boolean NOT NULL DEFAULT false,

    -- 03 R3-uncorroborated: name+domain matched, nothing else did. Both cluster
    -- members are held from sending until a human adjudicates. ~30 people out
    -- of 2,099 — cheap enough to avoid both the missed merge (a compliance
    -- breach) and the false merge (a lost prospect).
    needs_review   boolean NOT NULL DEFAULT false,
    review_evidence jsonb
);

-- Every identifier this person has ever been seen under. This is what makes
-- the surrogate key work in practice: an Instantly reply webhook carrying only
-- an email still resolves to the right person, including after a job change,
-- and including for an address they no longer use.
CREATE TABLE person_alias (
    person_id     uuid NOT NULL REFERENCES person(person_id),
    alias_type    text NOT NULL CHECK (alias_type IN ('email', 'linkedin', 'source_id')),
    alias_value   text NOT NULL,
    first_seen_at date,
    PRIMARY KEY (alias_type, alias_value)
);

-- Rows that could not be keyed at all. Empty for this file (linkedin_url is
-- present on 100% of rows) but the bucket exists because the reconciliation
-- must account for it rather than assume it away.
CREATE TABLE quarantine (
    row_num bigint PRIMARY KEY,
    contact_id text,
    reason  text NOT NULL,
    payload jsonb NOT NULL
);


-- =============================================================================
--  5. The event log (04) — the only truth
-- =============================================================================
--
--  Why not a mutable state table: the CSV *is* a mutable state table, and it is
--  the reason none of Jason's four questions can be answered. last_campaign
--  holds one campaign per person, yet duplicate clusters prove more than one
--  campaign ran against those people. The earlier touches were overwritten and
--  cannot be recovered.
--
--  Every rule downstream is a question about history — *has* this person ever
--  been mailed from a second domain, *did* an unsubscribe ever land, *when* was
--  the last touch. A column holding only the latest value answers none of them.

CREATE TABLE contact_event (
    event_id       uuid PRIMARY KEY,

    -- 02: HubSpot and Instantly webhooks are at-least-once. Consumers must be
    -- idempotent, so the natural idempotency key from the source system is
    -- carried and enforced here rather than trusted upstream.
    external_id    text NOT NULL UNIQUE,

    person_id      uuid NOT NULL REFERENCES person(person_id),
    occurred_at    date NOT NULL,
    channel        text CHECK (channel IN ('email', 'linkedin')),
    event_type     text NOT NULL CHECK (event_type IN (
                       'enrolled', 'sent', 'opened',
                       'replied_positive', 'replied_negative',
                       'bounced', 'unsubscribed', 'booked',
                       'dnc', 'domain_migrated', 'sequence_completed')),
    sending_domain text,
    experiment_id  uuid,
    campaign       text,          -- the pre-experiment campaign name, backfilled
    email_address  text,          -- bounces are address-scoped, not person-scoped
    source         text NOT NULL, -- 'csv_backfill' | 'instantly' | 'heyreach' | ...
    source_row_id  text           -- provenance back to landing.contact_csv
);

CREATE INDEX ON contact_event (person_id, occurred_at);
CREATE INDEX ON contact_event (event_type);

COMMENT ON TABLE contact_event IS
    'Append-only. Never updated, never deleted. The 781 contacted rows in the '
    'CSV are reconstructed here as synthetic events tagged source=csv_backfill: '
    'the migration from lossy collapse to event log is itself the deliverable.';

-- HubSpot lifecycle is a projection *in*, not an event. It is a snapshot of
-- another system's opinion, so it is stored as one and stamped with when it
-- was observed. 02: never key on the HubSpot record id, which changes on merge.
CREATE TABLE crm_lifecycle (
    person_id   uuid PRIMARY KEY REFERENCES person(person_id),
    stage       text NOT NULL,
    observed_at date NOT NULL,
    source      text NOT NULL
);


-- =============================================================================
--  6. Experiments (04 §5)
-- =============================================================================

-- One live experiment per person, the brief read literally. A multi-channel
-- sequence is NOT two experiments — it is one experiment whose definition
-- contains both an email step and a LinkedIn step. That is what keeps a reply
-- attributable to one thing.
CREATE TABLE experiment (
    experiment_id     uuid PRIMARY KEY,
    name              text NOT NULL UNIQUE,

    -- 05: the only *free* dimension. Three free dimensions is 6 x 3 x 4 = 72
    -- cells against 723 contactable people, which is ten per cell — not an
    -- experiment. One dimension varies, the rest are held fixed.
    message_variant   text NOT NULL,

    -- Held fixed unless they are the thing being tested. NULL here and in 07's
    -- seeded row on purpose: 03 found `industry` is contact-level noise, so
    -- segment must be assigned by a human at the company, and inventing one to
    -- fill the column would fabricate the input the learning loop depends on.
    segment           text,
    persona           text,

    -- 09: audience is a partition *above* this model — a property of why you
    -- are approaching someone, not of who they are. The same editor is a
    -- publisher target this quarter and a brand target next quarter, so putting
    -- it on the person would mean rewriting people when the pitch changes.
    audience          text NOT NULL DEFAULT 'brand'
                      CHECK (audience IN ('brand', 'publisher')),

    -- 05: declared before the experiment runs, never chosen afterwards. A
    -- metric picked after the numbers are in is how 2.6% becomes whatever the
    -- deck needs. Also the field that records which rates are even readable:
    -- at this volume `booked` is not, and `replied` barely is.
    success_metric    text NOT NULL DEFAULT 'replied'
                      CHECK (success_metric IN ('replied', 'replied_positive', 'booked')),

    channels          text[] NOT NULL,
    max_duration_days int NOT NULL DEFAULT 30
);

CREATE TABLE experiment_enrollment (
    experiment_id uuid NOT NULL REFERENCES experiment(experiment_id),
    person_id     uuid NOT NULL REFERENCES person(person_id),
    enrolled_at   date NOT NULL,
    -- Without expires_at a stalled sequence holds a person forever: 01
    -- established the sending tools will not release them.
    expires_at    date NOT NULL,
    PRIMARY KEY (experiment_id, person_id)
);


-- =============================================================================
--  7. The suppression list — asserted exclusions (brief: "partner conflicts")
-- =============================================================================
--
--  Every other suppression in this model is *derived*: from the event log, from
--  the HubSpot lifecycle projection, from the notes field. Three of the brief's
--  four named suppression sources work that way — customers and open
--  opportunities come from HubSpot, do-not-contact requests come from a human
--  sentence in `notes`.
--
--  Partner conflicts do not. Nothing in the data expresses "we may not approach
--  this account because a partner owns it": it is a fact that lives in a
--  person's head, or in a signed agreement, and it reaches the system only
--  because somebody writes it down. That makes it a different *kind* of
--  suppression, and it needs a table rather than a predicate.
--
--  Which means the honest version of this table is defined by its writer, not
--  its rows. `added_by` is NOT NULL for that reason: an asserted-suppression
--  list with no accountable author is the mechanism by which someone's
--  ex-colleague's grudge quietly removes an account for two years. The rows are
--  cheap; the write path — who may add, who reviews, what expires — is the part
--  that costs something, and it is named in README.md as a designed-not-
--  built item.
--
--  It is seeded EMPTY, deliberately. There is no partner-relationship field in
--  the CSV, and inferring one from `source = 'partner_referral'` (123 rows)
--  would be wrong in the most expensive direction: a partner *referral* is a
--  warm introduction, close to the opposite of a partner *conflict*. So the
--  constraint is answered with a mechanism that demonstrably works, on zero
--  rows, rather than with a number invented to look thorough. tests/60 inserts
--  fixtures and proves the rules bite.
--
--  This is also where `suppression_override` lands when it is built — the
--  inverse table, letting a deal owner re-open a named person inside an
--  otherwise-frozen open-opportunity account. Same shape, same writer problem,
--  worth ~900 people. Cut for now; see README.md.

-- The reason catalogue. Reasons are data, so a new one is an INSERT rather than
-- a migration — and the eligibility rules below are generated from this table,
-- exactly as the recycle windows are, so a reason can never exist without a
-- rule name that the rejection ledger is allowed to cite.
CREATE TABLE suppression_reason (
    reason        text PRIMARY KEY,
    precedence    int  NOT NULL UNIQUE,
    default_scope text NOT NULL CHECK (default_scope IN ('person', 'company')),
    rationale     text NOT NULL
);

INSERT INTO suppression_reason (reason, precedence, default_scope, rationale) VALUES
    ('partner_conflict', 1, 'company',
     'Named by the brief. A partner owns the account, or a reseller agreement '
     'forbids direct approach. Company-scoped by default because partner '
     'agreements are written about accounts, not individuals.'),

    ('legal_hold', 2, 'person',
     'Counsel or a GDPR Art.17 erasure request. Person-scoped and permanent. '
     'Distinct from person:dnc because its origin is a legal instrument rather '
     'than a prospect saying stop, and it must survive a re-import that would '
     'overwrite the notes field the DNC rule reads.'),

    ('manual', 3, 'person',
     'The escape hatch, and deliberately last of the three: anything a human '
     'needs excluded today that the model has no vocabulary for yet. Every '
     'entry here is a request for a real reason to be added above it.');

CREATE TABLE suppression_list (
    suppression_id uuid PRIMARY KEY,
    reason         text NOT NULL REFERENCES suppression_reason(reason),
    scope          text NOT NULL CHECK (scope IN ('person', 'company')),
    person_id      uuid REFERENCES person(person_id),
    company_id     uuid REFERENCES company(company_id),

    -- The accountable author. Not nullable, and not defaulted to a system name:
    -- an assertion nobody signed is an assertion nobody will ever remove.
    added_by       text NOT NULL,
    added_at       date NOT NULL,

    -- NULL means permanent. A partner agreement that lapses in March should
    -- stop suppressing in March without anyone remembering to delete a row,
    -- and it is read against config.as_of() like every other clock here.
    expires_at     date,

    evidence       jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- Scope and target must agree. A company-scoped row carrying a person_id
    -- would suppress either one person or three hundred depending on which
    -- half of the predicate a future reader trusted.
    CONSTRAINT scope_matches_target CHECK (
        (scope = 'person'  AND person_id  IS NOT NULL AND company_id IS NULL) OR
        (scope = 'company' AND company_id IS NOT NULL AND person_id  IS NULL))
);

CREATE INDEX ON suppression_list (person_id);
CREATE INDEX ON suppression_list (company_id);

COMMENT ON TABLE suppression_list IS
    'Asserted suppression: the exclusions a human writes down because no data '
    'source emits them. Empty on this dataset by design — there is no partner '
    'relationship field in the CSV and source=partner_referral means the '
    'opposite. tests/60 proves the rules fire.';


-- =============================================================================
--  8. The rule table (04 §7)
-- =============================================================================
--
--  The rules are data, not code branches. Precedence is a column, so the order
--  can be argued with — and the rejection ledger joins to this table, which is
--  why no rejection can cite a rule that was never declared.
--
--  Ordered most-permanent-first so the ledger names the most *meaningful*
--  reason rather than whichever predicate happened to fire first.

-- The recycle clocks, as data. They were prose in one place and a CASE in
-- another, which is two sources of truth for the same three numbers.
--
-- The asymmetry is the defensible part: someone who opened and stayed silent is
-- *warmer* than someone who ignored you entirely, so they return sooner, not
-- later. 04's headline finding is that tuning this whole table is a rounding
-- error — aggressive (60/30/180) yields 754 eligible, conservative
-- (180/120/365) yields 646, a range of 108 people against the ~1,200 that
-- company suppression moves. Any conversation about recycle cadence that is not
-- first a conversation about suppression scope is optimising the wrong order of
-- magnitude.
CREATE TABLE recycle_window (
    outcome     text PRIMARY KEY,
    window_days int  NOT NULL,
    rationale   text NOT NULL
);

INSERT INTO recycle_window (outcome, window_days, rationale) VALUES
    ('opened_no_reply',  60, 'Opened and stayed silent is warmer than ignored entirely, so they return sooner.'),
    ('no_reply',         90, 'Silence after a send.'),
    ('replied_negative', 180, 'An explicit no. The longest window that is not permanent.');


CREATE TABLE eligibility_rule (
    rule_name   text PRIMARY KEY,
    precedence  int  NOT NULL UNIQUE,
    scope       text NOT NULL CHECK (scope IN ('person', 'company', 'identity')),
    duration    text NOT NULL,
    origin      text NOT NULL,
    rationale   text NOT NULL
);

INSERT INTO eligibility_rule (rule_name, precedence, scope, duration, origin, rationale) VALUES
 ('person:dnc', 4, 'person', 'permanent', 'notes free text',
  'A human sentence is a stronger signal than a click, so an explicit removal '
  'request is global across every channel, not channel-scoped like an unsubscribe.'),

 ('person:unsubscribed', 5, 'person', 'permanent, channel-scoped', 'Instantly / HeyReach webhook',
  'Channel-scoped because that is what CAN-SPAM and GDPR Art.21 actually '
  'regulate. Stated assumption: a stricter counsel reading globalises all 29 '
  'unsubscribes at a cost of 8 people.'),

 ('person:bounced', 6, 'person', 'permanent, address-scoped', 'Instantly webhook',
  'Every bounce is terminal for that address. 01 established Instantly exposes '
  'no bounce-type field, and inferring severity from repetition requires '
  're-sending to a possibly-dead address to learn whether it is dead — which is '
  'exactly the behaviour that burns a sending domain. The person survives on '
  'LinkedIn and on any future address.'),

 ('company:customer', 7, 'company', 'permanent', 'HubSpot lifecycle',
  'Company-wide. Cold outbound into an existing account reads as a failure of '
  'basic record-keeping to the customer receiving it.'),

 ('company:open_opportunity', 8, 'company', 'while open, +90d after close-lost', 'HubSpot lifecycle',
  'Company-wide, and the single largest input to eligible volume — 47% of the '
  'list sits at a company with an open deal. Suppressing only the named buying '
  'committee was worth ~910 more people and was rejected on asymmetry: a cold '
  'sequence landing mid-negotiation can cost a deal in flight, while a '
  'suppressed prospect costs only delay.'),

 ('person:owned_by_sales', 9, 'person', 'until sales releases', 'Instantly / HubSpot',
  'booked or replied_positive. Outbound does not own this person any more.'),

 ('identity:needs_review', 13, 'identity', 'until adjudicated', '03 R3-uncorroborated',
  'Both members of an ambiguous cluster are held. The system is visibly aware '
  'of its own uncertainty rather than silently guessing.'),

 ('person:in_live_experiment', 14, 'person', 'until terminal event or expiry', 'ledger',
  'The ledger is the enforcement point. 01 established Instantly creates '
  'duplicate lead rows across campaigns unless skip_if_in_* is set, and those '
  'vendor flags are defence in depth only.'),

 -- NOT IN 04. Added while building: 04 enumerates ten reasons a person must
 -- not be contacted and none for a person who simply cannot be reached on the
 -- channels this experiment uses. Without it, an email-only experiment returns
 -- five people with a verdict of "eligible" and no address to send to — a
 -- silently unactionable row, which is the exact failure the rejection ledger
 -- exists to prevent.
 --
 -- Last in precedence because it is the least permanent reason on the list:
 -- it is a property of the experiment, not of the person, and it disappears
 -- the moment the same person is put in a LinkedIn sequence.
 ('person:unreachable_on_channel', 15, 'person', 'for this experiment only', 'derived',
  'No channel in the experiment is usable for this person: no valid email '
  'address for an email step, or an unsubscribe or bounce covering every '
  'channel the experiment uses.');

-- Rules 10-12 are generated from recycle_window so the day counts cannot be
-- stated in one place and enforced from another.
INSERT INTO eligibility_rule (rule_name, precedence, scope, duration, origin, rationale)
SELECT 'person:recycle_window(' || w.outcome || ')',
       v.precedence, 'person', w.window_days || ' days', 'derived', w.rationale
  FROM (VALUES ('no_reply', 10), ('replied_negative', 11), ('opened_no_reply', 12))
       AS v(outcome, precedence)
  JOIN recycle_window w USING (outcome);

-- Rules 1-3 are generated from suppression_reason, the same way, and take the
-- top of the precedence order.
--
-- Asserted suppression outranks every derived rule, including person:dnc. Not
-- because it is more permanent — both are permanent — but because the ledger
-- names the single most *meaningful* reason a person was excluded, and "a
-- partner owns this account, asserted by a named human on a date" is a better
-- answer to "why is this account cold?" than a regex over a notes field. The
-- ordering has no effect on volume: a person who fires both is rejected either
-- way. It only changes what the rejection ledger says, which is the artifact
-- someone actually has to argue with.
INSERT INTO eligibility_rule (rule_name, precedence, scope, duration, origin, rationale)
SELECT 'list:' || s.reason,
       s.precedence,
       s.default_scope,
       'until removed or expires_at',
       'suppression_list, written by a human',
       s.rationale
  FROM suppression_reason s;

COMMENT ON TABLE eligibility_rule IS
    'company:domain_lock is deliberately absent. Under grandfather-and-converge '
    'it never excludes anyone — it only assigns a sending domain. That is the '
    'point of choosing it over retroactive enforcement, which would have '
    'stranded 317 people.';
