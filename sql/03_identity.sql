-- =============================================================================
--  03 — Identity resolution (issue 03)
--
--  Rows in, persons and companies out. Three deterministic rules:
--
--    R1  normalised email        -> merge
--    R2  normalised LinkedIn URL -> merge
--    R3  first + last + company_domain, with no R1/R2 corroboration
--                                -> HOLD BOTH, do not merge
--
--  R3 holds rather than merges because the harm is asymmetric and not in the
--  usual direction. A *missed* merge means a second sending domain and a
--  suppression leak — a compliance breach. A *false* merge means one prospect
--  is never contacted — lost opportunity, no breach. That argues for merging
--  aggressively. But holding both members avoids both errors, and here it is
--  cheap: 30 people out of 2,114.
-- =============================================================================

-- The normalised projection of the raw file. Every identity rule below is
-- expressed against this view, so "what did the rule see?" is one query away.
DROP VIEW IF EXISTS landing_norm CASCADE;
CREATE VIEW landing_norm AS
SELECT row_num,
       contact_id,
       norm.email(email)            AS email,
       norm.linkedin(linkedin_url)  AS linkedin,
       norm.text_key(first_name)        AS first_name,
       norm.text_key(last_name)         AS last_name,
       norm.domain(company_domain)  AS company_domain,
       norm.text_key(company_name)      AS company_name,
       norm.text_key(title)             AS title,
       norm.text_key(seniority)         AS seniority,
       nullif(btrim(country), '')   AS country,
       nullif(btrim(date_added), '')::date AS date_added,
       nullif(btrim(employee_count), '')::int AS employee_count,
       nullif(btrim(industry), '')  AS industry,
       first_name  AS raw_first_name,
       last_name   AS raw_last_name,
       title       AS raw_title,
       linkedin_url AS raw_linkedin_url,
       company_name AS raw_company_name
  FROM landing.contact_csv;


-- -----------------------------------------------------------------------------
--  Companies
-- -----------------------------------------------------------------------------

TRUNCATE company_alias, company CASCADE;

-- Two domains are the same company when they share a normalised company name.
-- This is what folds Keystone Cloud's getkeystone.com and keystonecloud.io
-- into one company — and, correctly, leaves keystone.co ("Keystone", 450
-- employees) alone, because it is a different company that happens to share a
-- word.
--
-- Free-mail domains never become a company (03): without the blocklist,
-- gmail.com is a company and the self-employed contacts fuse into one, so the
-- day any of them converts the rest are suppressed.
WITH weighted AS (
    SELECT company_domain,
           company_name AS name_key,
           count(*) AS n_contacts,
           mode() WITHIN GROUP (ORDER BY raw_company_name) AS display_name
      FROM landing_norm
     WHERE company_domain IS NOT NULL
       AND NOT norm.is_free_mail(company_domain)
     GROUP BY 1, 2
),
-- The primary domain is the one carrying the most contacts; ties break
-- alphabetically so the choice is stable across runs.
grouped AS (
    SELECT name_key,
           (array_agg(company_domain  ORDER BY n_contacts DESC, company_domain))[1] AS primary_domain,
           (array_agg(display_name    ORDER BY n_contacts DESC, company_domain))[1] AS display_name
      FROM weighted
     GROUP BY name_key
)
INSERT INTO company (company_id, primary_domain, name_key, company_name)
SELECT norm.surrogate('company', primary_domain), primary_domain, name_key, display_name
  FROM grouped;

INSERT INTO company_alias (company_id, domain)
SELECT c.company_id, l.company_domain
  FROM company c
  JOIN landing_norm l ON l.company_name = c.name_key
 WHERE l.company_domain IS NOT NULL
   AND NOT norm.is_free_mail(l.company_domain)
 GROUP BY 1, 2;

-- employee_count is reliable (consistent for all but one company); industry is
-- not, and is carried only so that the data model can point at it and say so.
UPDATE company c
   SET employee_count = s.employee_count,
       industry       = s.industry
  FROM (
    SELECT a.company_id,
           mode() WITHIN GROUP (ORDER BY l.employee_count) AS employee_count,
           mode() WITHIN GROUP (ORDER BY l.industry)       AS industry
      FROM landing_norm l
      JOIN company_alias a ON a.domain = l.company_domain
     GROUP BY a.company_id
  ) s
 WHERE s.company_id = c.company_id;


-- -----------------------------------------------------------------------------
--  Person clustering: connected components over R1 ∪ R2
-- -----------------------------------------------------------------------------

DROP TABLE IF EXISTS identity_edge CASCADE;
CREATE TABLE identity_edge (
    lo   bigint NOT NULL,
    hi   bigint NOT NULL,
    rule text   NOT NULL,
    PRIMARY KEY (lo, hi, rule)
);

-- R1. Normalisation is not optional here: eight rows differ from their twin
-- only by casing and padded whitespace, and six use +noble plus-addressing.
-- KOFI.RODRIGUEZ@REEDMARSH.COM with padding is a hard-bounced address whose
-- twin reads clean — miss the merge and you mail a dead address again.
INSERT INTO identity_edge (lo, hi, rule)
SELECT a.row_num, b.row_num, 'R1'
  FROM landing_norm a
  JOIN landing_norm b ON a.email = b.email AND a.row_num < b.row_num
 WHERE a.email IS NOT NULL;

-- R2. LinkedIn is present on 100% of rows, which is why nothing lands in
-- quarantine — but Apollo emits different slugs for the same human
-- (ingrid-quinn-5420, ingrid-quinn-1209), so it cannot be the key on its own.
INSERT INTO identity_edge (lo, hi, rule)
SELECT a.row_num, b.row_num, 'R2'
  FROM landing_norm a
  JOIN landing_norm b ON a.linkedin = b.linkedin AND a.row_num < b.row_num
 WHERE a.linkedin IS NOT NULL;

DROP TABLE IF EXISTS identity_cluster CASCADE;
CREATE TABLE identity_cluster (
    row_num    bigint PRIMARY KEY,
    cluster_id bigint NOT NULL
);

-- Label propagation to a fixpoint: each row takes the lowest label among
-- itself and its neighbours until nothing moves. On 2,154 rows this converges
-- in a handful of passes. A recursive CTE would also work; this is written
-- out because it is the one place the pipeline is genuinely iterative and
-- hiding that would be worse than showing it.
INSERT INTO identity_cluster (row_num, cluster_id)
SELECT row_num, row_num FROM landing_norm;

DO $$
DECLARE
    moved int;
    pass  int := 0;
BEGIN
    LOOP
        WITH neighbour AS (
            SELECT lo AS a, hi AS b FROM identity_edge
            UNION ALL
            SELECT hi, lo FROM identity_edge
        ),
        proposal AS (
            SELECT c.row_num,
                   LEAST(c.cluster_id, COALESCE(min(o.cluster_id), c.cluster_id)) AS new_id
              FROM identity_cluster c
              LEFT JOIN neighbour n ON n.a = c.row_num
              LEFT JOIN identity_cluster o ON o.row_num = n.b
             GROUP BY c.row_num, c.cluster_id
        )
        UPDATE identity_cluster c
           SET cluster_id = p.new_id
          FROM proposal p
         WHERE p.row_num = c.row_num AND c.cluster_id <> p.new_id;

        GET DIAGNOSTICS moved = ROW_COUNT;
        pass := pass + 1;
        EXIT WHEN moved = 0;
        IF pass > 50 THEN
            RAISE EXCEPTION 'identity clustering did not converge in 50 passes';
        END IF;
    END LOOP;
    RAISE NOTICE 'identity clustering converged in % passes', pass;
END $$;


-- The cluster's anchor row (its earliest) names the person; every row in the
-- cluster routes to that person. Defined once here because the events, the
-- alias table and the CRM projection all need the same mapping, and three
-- copies of it is three places for it to drift.
DROP VIEW IF EXISTS row_person CASCADE;
CREATE VIEW row_person AS
SELECT l.row_num,
       l.contact_id,
       norm.surrogate('person', a.anchor_contact_id) AS person_id
  FROM landing_norm l
  JOIN identity_cluster ic USING (row_num)
  JOIN (SELECT ic2.cluster_id,
               (array_agg(l2.contact_id ORDER BY l2.row_num))[1] AS anchor_contact_id
          FROM landing_norm l2 JOIN identity_cluster ic2 USING (row_num)
         GROUP BY ic2.cluster_id) a ON a.cluster_id = ic.cluster_id;


-- -----------------------------------------------------------------------------
--  Persons
-- -----------------------------------------------------------------------------

TRUNCATE person_alias, person CASCADE;

-- person_id is derived from the cluster's earliest source row, and identifying
-- attributes are taken from its *latest* row. Emily Banerjee has one LinkedIn
-- URL and two employers; the recent row is the current employer, and company
-- suppression has to follow the human to where they work now.
WITH survivor AS (
    SELECT cluster_id,
           (array_agg(contact_id ORDER BY row_num))[1] AS anchor_contact_id,
           (array_agg(row_num    ORDER BY date_added DESC NULLS LAST, row_num DESC))[1] AS latest_row
      FROM landing_norm JOIN identity_cluster USING (row_num)
     GROUP BY cluster_id
),
-- The primary email comes from the most recent row that has one — the same
-- ordering as every other person attribute, and for the same reason. Taking
-- the earliest instead would ship someone's old employer's address next to
-- their new employer's name, and would make address-scoped bounce suppression
-- depend on file order rather than on which address is current.
--
-- NULL here means linkedin-only, which is a legitimate state, not a defect.
best_email AS (
    SELECT cluster_id,
           (array_agg(email ORDER BY date_added DESC NULLS LAST, row_num DESC))[1] AS email
      FROM landing_norm JOIN identity_cluster USING (row_num)
     WHERE email IS NOT NULL
     GROUP BY cluster_id
)
INSERT INTO person (person_id, primary_email, linkedin_url, first_name, last_name,
                    title, seniority, country, company_id, is_independent)
SELECT norm.surrogate('person', s.anchor_contact_id),
       e.email,
       norm.linkedin_url(l.linkedin),
       l.raw_first_name,
       l.raw_last_name,
       l.raw_title,
       l.seniority,
       l.country,
       a.company_id,
       -- 03: no company to suppress, so person-level suppression only.
       (a.company_id IS NULL)
  FROM survivor s
  JOIN landing_norm l ON l.row_num = s.latest_row
  LEFT JOIN best_email e ON e.cluster_id = s.cluster_id
  LEFT JOIN company_alias a ON a.domain = l.company_domain;

-- Every identifier the cluster has ever carried. This is the lookup an
-- Instantly reply webhook lands on: it arrives with an email address and
-- nothing else, including an address the person stopped using two jobs ago.
INSERT INTO person_alias (person_id, alias_type, alias_value, first_seen_at)
SELECT rp.person_id, k.alias_type, k.alias_value, min(l.date_added)
  FROM landing_norm l
  JOIN row_person rp USING (row_num)
 CROSS JOIN LATERAL (VALUES
       ('email',     l.email),
       ('linkedin',  l.linkedin),
       ('source_id', l.contact_id)
 ) AS k(alias_type, alias_value)
 WHERE k.alias_value IS NOT NULL
 GROUP BY 1, 2, 3;


-- -----------------------------------------------------------------------------
--  R3: hold, do not merge
-- -----------------------------------------------------------------------------

-- An R3 group spanning more than one R1/R2 component is uncorroborated: name
-- and employer agree, and nothing else does. Emily Weber is the worked example
-- — differing titles, seniority, email domains and LinkedIn slugs under one
-- company_domain, and two different humans.
--
-- Both members are held. They appear in the rejection ledger under
-- identity:needs_review carrying the conflicting evidence, so the system is
-- visibly uncertain rather than silently wrong.
WITH r3_group AS (
    SELECT l.first_name, l.last_name, l.company_domain,
           array_agg(DISTINCT ic.cluster_id) AS clusters,
           array_agg(DISTINCT l.contact_id)  AS contact_ids,
           array_agg(DISTINCT coalesce(l.title, '(none)'))    AS titles,
           array_agg(DISTINCT coalesce(l.seniority, '(none)')) AS seniorities,
           array_agg(DISTINCT coalesce(l.email, '(none)'))    AS emails
      FROM landing_norm l
      JOIN identity_cluster ic USING (row_num)
     WHERE l.first_name IS NOT NULL AND l.last_name IS NOT NULL
       AND l.company_domain IS NOT NULL
     GROUP BY 1, 2, 3
    HAVING count(*) > 1
),
uncorroborated AS (
    SELECT * FROM r3_group WHERE cardinality(clusters) > 1
)
UPDATE person p
   SET needs_review = true,
       review_evidence = jsonb_build_object(
           'rule',           'R3 uncorroborated',
           'matched_on',     u.first_name || ' ' || u.last_name || ' @ ' || u.company_domain,
           'contact_ids',    to_jsonb(u.contact_ids),
           'titles',         to_jsonb(u.titles),
           'seniorities',    to_jsonb(u.seniorities),
           'emails',         to_jsonb(u.emails))
  FROM uncorroborated u
  JOIN identity_cluster ic ON ic.cluster_id = ANY (u.clusters)
  JOIN row_person rp ON rp.row_num = ic.row_num
 WHERE p.person_id = rp.person_id;


-- -----------------------------------------------------------------------------
--  Quarantine
-- -----------------------------------------------------------------------------

-- Rows with neither a usable email nor a LinkedIn URL cannot be keyed at all.
-- This file has none — LinkedIn is present on 100% of rows — but the bucket
-- exists so the reconciliation accounts for it instead of assuming it away.
TRUNCATE quarantine;

INSERT INTO quarantine (row_num, contact_id, reason, payload)
SELECT l.row_num, l.contact_id, 'no usable email or linkedin url',
       to_jsonb(c) - 'row_num'
  FROM landing_norm l
  JOIN landing.contact_csv c USING (row_num)
 WHERE l.email IS NULL AND l.linkedin IS NULL;


-- -----------------------------------------------------------------------------
--  HubSpot lifecycle projection
-- -----------------------------------------------------------------------------

-- 02: HubSpot is a projection, never the key. Where a cluster's rows disagree,
-- the most advanced stage wins — the conservative direction, since every stage
-- here is a reason to suppress rather than a reason to send.
TRUNCATE crm_lifecycle;

INSERT INTO crm_lifecycle (person_id, stage, observed_at, source)
SELECT l.person_id,
       (array_agg(l.stage ORDER BY l.rank))[1],
       config.as_of(),
       'hubspot'
  FROM (
      SELECT rp.person_id,
             nullif(btrim(c.hubspot_lifecycle_stage), '') AS stage,
             CASE nullif(btrim(c.hubspot_lifecycle_stage), '')
                  WHEN 'customer'               THEN 1
                  WHEN 'opportunity'            THEN 2
                  WHEN 'marketingqualifiedlead' THEN 3
                  WHEN 'lead'                   THEN 4
                  WHEN 'subscriber'             THEN 5
                  ELSE 9 END AS rank
        FROM landing.contact_csv c
        JOIN row_person rp USING (row_num)
       WHERE nullif(btrim(c.hubspot_lifecycle_stage), '') IS NOT NULL
  ) l
 GROUP BY l.person_id;
