-- =============================================================================
--  05 — The sending-domain lock (issue 04 §2)
--
--  The brief: "A person should never be contacted by more than one Noble
--  sending domain. Ever."
--
--  The data, measured:
--      persons contacted from >1 domain      0 of 2,114
--      companies contacted from >1 domain  118 of 135
--
--  The constraint as written is already satisfied and constrains nothing. What
--  actually burns domains — one mail admin receiving Noble from four different
--  senders — is entirely ungoverned. So the lock binds at COMPANY level and
--  every contact inherits it.
--
--  This is a strict strengthening, not a disagreement: a person belongs to
--  exactly one company, so (for all companies: |domains| <= 1) implies the
--  brief's (for all persons: |domains| <= 1).
--
--  Grandfather-and-converge, chosen on measurement:
--
--      policy                        stranded   new "Ever." violations
--      grandfather + converge               0                        0
--      hard retroactive, plurality        317                        0
--      amnesty, rehash everything           0                      470
--
--  Every historical person->domain pair is honoured forever. Only people not
--  yet contacted inherit the company lock. Dirty companies lock to their
--  plurality domain specifically so they can never acquire a *new* one; they
--  converge as legacy contacts age out.
--
--  This file assigns. It never rejects — which is why company:domain_lock is
--  absent from eligibility_rule. That is the point of choosing it.
-- =============================================================================

-- Which domains a company has actually been contacted from, derived from the
-- log rather than from last_sending_domain. The CSV column holds one value per
-- person and cannot answer "every domain ever used at this company", which is
-- exactly the question the constraint is about.
DROP VIEW IF EXISTS company_domain_history CASCADE;
CREATE VIEW company_domain_history AS
SELECT p.company_id,
       e.sending_domain,
       count(*) AS sends
  FROM contact_event e
  JOIN person p USING (person_id)
 WHERE e.event_type = 'sent'
   AND e.sending_domain IS NOT NULL
   AND p.company_id IS NOT NULL
 GROUP BY 1, 2;


DROP VIEW IF EXISTS company_lock CASCADE;
CREATE VIEW company_lock AS
WITH history AS (
    SELECT company_id,
           count(*) AS n_domains,
           -- Plurality, ties broken alphabetically. A tie-break that depends
           -- on row order would make the pipeline non-reproducible, and the
           -- whole design leans on it being re-runnable.
           (array_agg(sending_domain ORDER BY sends DESC, sending_domain))[1] AS plurality_domain
      FROM company_domain_history
     GROUP BY company_id
)
SELECT c.company_id,
       CASE
           WHEN h.n_domains > 1 THEN 'plurality'
           WHEN h.n_domains = 1 THEN 'sole_historical'
           ELSE                      'hash'
       END AS lock_basis,
       COALESCE(h.plurality_domain, d.domain) AS locked_domain,
       COALESCE(h.n_domains, 0) AS historical_domain_count
  FROM company c
  LEFT JOIN history h USING (company_id)
  -- Hash assignment for companies never contacted. See norm.hash_slot.
  LEFT JOIN LATERAL (
      SELECT s.domain
        FROM sending_domain s
       WHERE s.active
         AND s.hash_slot = norm.hash_slot(c.primary_domain,
                                          (SELECT count(*)::int FROM sending_domain WHERE active))
  ) d ON true;


DROP VIEW IF EXISTS person_domain CASCADE;
CREATE VIEW person_domain AS
-- The domain this person was actually contacted from, derived once. Should
-- always be at most one value; tests assert the brief's "Ever." constraint
-- holds in the source data rather than assuming issue 04 measured it correctly.
WITH historical AS (
    SELECT e.person_id,
           (array_agg(DISTINCT e.sending_domain))[1] AS domain,
           count(DISTINCT e.sending_domain)          AS domain_count
      FROM contact_event e
     WHERE e.event_type = 'sent'
       AND e.sending_domain IS NOT NULL
     GROUP BY e.person_id
)
SELECT p.person_id,
       hi.domain                          AS historical_domain,
       coalesce(hi.domain_count, 0)       AS historical_domain_count,

       -- Grandfather first, then the company lock. Independents have no company
       -- to inherit from (03: no company means nothing to suppress and nothing
       -- to lock to), so they fall back to a person-level hash.
       COALESCE(hi.domain, cl.locked_domain, ind.domain) AS sending_domain,

       CASE
           WHEN hi.domain IS NOT NULL        THEN 'grandfathered'
           WHEN cl.locked_domain IS NOT NULL THEN 'company_lock:' || cl.lock_basis
           ELSE                                   'independent_hash'
       END AS assignment_basis

  FROM person p
  LEFT JOIN historical  hi USING (person_id)
  LEFT JOIN company_lock cl USING (company_id)
  LEFT JOIN LATERAL (
      SELECT s.domain
        FROM sending_domain s
       WHERE s.active
         AND s.hash_slot = norm.hash_slot(p.person_id::text,
                                          (SELECT count(*)::int FROM sending_domain WHERE active))
  ) ind ON p.company_id IS NULL;
