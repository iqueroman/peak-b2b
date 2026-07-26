-- tests/20_domain_lock_test.sql
--
-- The domain lock, per issue 04. It binds at company level and it *assigns* —
-- it never rejects anyone. Grandfather-and-converge: every historical
-- person->domain pair is honoured forever, and only people not yet contacted
-- inherit the company lock.

-- The three branches of the assignment rule. 04 reports 118 / 17 / 18 against
-- 153 raw company_domain values; these run against the 146 resolved companies,
-- after the free-mail blocklist and the Keystone alias merge that 04's own
-- inputs from 03 require. Contacted companies still total 135, as 04 says.
SELECT test.expect('domain_lock', 'companies with >1 historical domain', 117,
                   (SELECT count(*) FROM company_lock WHERE lock_basis = 'plurality'),
                   '04 says 118, at raw-domain grain; the Keystone merge folds two into one');

SELECT test.expect('domain_lock', 'companies with exactly 1 historical domain', 18,
                   (SELECT count(*) FROM company_lock WHERE lock_basis = 'sole_historical'),
                   '04 says 17');

SELECT test.expect('domain_lock', 'companies never contacted (hash assigned)', 11,
                   (SELECT count(*) FROM company_lock WHERE lock_basis = 'hash'),
                   '04 says 18; 153 raw domains - 6 free-mail - 1 merged = 146 companies');

SELECT test.expect('domain_lock', 'companies contacted at all', 135,
                   (SELECT count(*) FROM company_lock WHERE lock_basis <> 'hash'));

SELECT test.expect('domain_lock', 'every company holds exactly one lock', 146,
                   (SELECT count(*) FROM company_lock WHERE locked_domain IS NOT NULL));

-- 04's headline measurement, re-derived rather than trusted: the brief's
-- constraint as written is already satisfied by the existing data and
-- therefore constrains nothing, while 117 of 135 companies violate what it
-- was written to protect.
SELECT test.expect('domain_lock', 'persons already contacted from >1 domain', 0,
                   (SELECT count(*) FROM person_domain WHERE historical_domain_count > 1));

-- The brief's constraint, read literally, checked against the output rather
-- than assumed: no person is assigned a domain other than the one they were
-- historically contacted from.
SELECT test.expect('domain_lock', 'grandfathering strands nobody', 0,
                   (SELECT count(*) FROM person_domain
                     WHERE historical_domain IS NOT NULL
                       AND sending_domain IS DISTINCT FROM historical_domain));

SELECT test.expect('domain_lock', 'people carrying a historical lock', 629,
                   (SELECT count(*) FROM person_domain WHERE historical_domain IS NOT NULL));

SELECT test.expect('domain_lock', 'every person has a sending domain', 0,
                   (SELECT count(*) FROM person_domain WHERE sending_domain IS NULL));

SELECT test.expect('domain_lock', 'no domain outside the declared set', 0,
                   (SELECT count(*) FROM person_domain pd
                     WHERE NOT EXISTS (SELECT 1 FROM sending_domain s
                                        WHERE s.domain = pd.sending_domain)));

-- 04 chose grandfather-and-converge precisely so that a dirty company can
-- never acquire a *new* domain. Not-yet-contacted people at a dirty company
-- must all inherit its plurality domain.
SELECT test.expect('domain_lock', 'uncontacted people inherit the company lock', 0,
                   (SELECT count(*) FROM person_domain pd
                     JOIN person p USING (person_id)
                     JOIN company_lock cl USING (company_id)
                    WHERE pd.historical_domain IS NULL
                      AND pd.sending_domain IS DISTINCT FROM cl.locked_domain));

-- The converse, and the reason the lock moved to the company: no company may
-- acquire a domain it has not already used. Dirty companies converge, clean
-- ones stay clean.
SELECT test.expect('domain_lock', 'no company acquires a new domain', 0,
                   (SELECT count(*) FROM company_lock cl
                     WHERE cl.lock_basis <> 'hash'
                       AND NOT EXISTS (SELECT 1 FROM company_domain_history h
                                        WHERE h.company_id = cl.company_id
                                          AND h.sending_domain = cl.locked_domain)));

-- Hash assignment is what makes the pipeline re-runnable. A round-robin or a
-- sequence would produce different output on the second run.
SELECT test.expect('domain_lock', 'hash spreads across all four domains', 4,
                   (SELECT count(DISTINCT locked_domain) FROM company_lock
                     WHERE lock_basis = 'hash'));
