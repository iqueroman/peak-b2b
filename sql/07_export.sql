-- =============================================================================
--  07 — The two artifacts
--
--  out/eligible_<experiment>.csv  who can be contacted, on which channel,
--                                 from which sending domain.
--  out/rejections.csv             every excluded person, with the rule name
--                                 and the evidence.
--
--  The rejection ledger is the more interesting of the two. A system that says
--  "697 people are eligible" is unverifiable. One that says "879 excluded by
--  company:open_opportunity, here they are, here is the deal that did it" can
--  be argued with — and being argued with is the point.
--
--  Both files are ordered deterministically so that two runs produce
--  byte-identical output and `diff` is a meaningful test.
-- =============================================================================

DROP VIEW IF EXISTS export_eligible CASCADE;
CREATE VIEW export_eligible AS
SELECT p.person_id,
       p.primary_email                          AS email,
       p.linkedin_url,
       p.first_name,
       p.last_name,
       p.title,
       p.seniority,
       c.primary_domain                         AS company_domain,
       c.company_name,
       c.employee_count,
       p.country,
       array_to_string(l.channels, '+')         AS channels,
       l.channels_withheld::text                AS channels_withheld,
       l.sending_domain,
       l.domain_basis,
       l.eligible_basis,
       h.last_sent_at,
       array_to_string(h.campaigns, '+')        AS prior_campaigns,
       config.experiment()                      AS experiment
  FROM eligibility_ledger l
  JOIN person p USING (person_id)
  JOIN person_history h USING (person_id)
  LEFT JOIN company c USING (company_id)
 WHERE l.decision = 'eligible';

DROP VIEW IF EXISTS export_rejections CASCADE;
CREATE VIEW export_rejections AS
SELECT p.person_id,
       p.primary_email                          AS email,
       p.linkedin_url,
       p.first_name,
       p.last_name,
       c.primary_domain                         AS company_domain,
       l.rule_name,
       r.precedence                             AS rule_precedence,
       r.scope                                  AS rule_scope,
       r.duration                               AS rule_duration,
       r.origin                                 AS rule_origin,
       l.evidence::text                         AS evidence,

       -- Every other rule that also fired. Without this the ledger answers
       -- "why was this person excluded?" but not "what else is wrong with this
       -- record?" — and on re-runs after a suppression is lifted, the second
       -- question is the one that matters.
       (SELECT string_agg(f.rule_name, '; ' ORDER BY r2.precedence)
          FROM rule_fired f
          JOIN eligibility_rule r2 USING (rule_name)
         WHERE f.person_id = l.person_id
           AND f.rule_name <> l.rule_name)      AS also_fired,

       h.last_sent_at,
       config.experiment()                      AS experiment
  FROM eligibility_ledger l
  JOIN eligibility_rule r USING (rule_name)
  JOIN person p USING (person_id)
  JOIN person_history h USING (person_id)
  LEFT JOIN company c USING (company_id)
 WHERE l.decision = 'rejected';


-- -----------------------------------------------------------------------------
--  Write the files
-- -----------------------------------------------------------------------------

-- COPY TO STDOUT with psql's \o redirect, rather than server-side COPY TO
-- '<path>': the output lands next to the repo on the machine that ran `make`,
-- not inside the database container, and it needs no volume mount and no
-- superuser grant.
SELECT 'out/eligible_' || config.experiment() || '.csv' AS eligible_path \gset

-- Ordered by company then email. The eligible list is read by a human deciding
-- what to load into Instantly, and company is the unit they think in. Sorting
-- also makes two runs byte-identical, which is how `make verify` tests
-- idempotence.
\o :eligible_path
COPY (SELECT * FROM export_eligible
       ORDER BY company_domain NULLS LAST, email NULLS LAST, person_id)
  TO STDOUT WITH (FORMAT csv, HEADER true);
\o

-- Ordered by precedence: the ledger reads top-down, most permanent first,
-- because the first block is the one that is never coming back.
\o out/rejections.csv
COPY (SELECT * FROM export_rejections
       ORDER BY rule_precedence, company_domain NULLS LAST, email NULLS LAST, person_id)
  TO STDOUT WITH (FORMAT csv, HEADER true);
\o

\echo 'wrote' :'eligible_path' 'and out/rejections.csv'
