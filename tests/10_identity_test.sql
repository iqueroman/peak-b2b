-- tests/10_identity_test.sql
--
-- Identity resolution, per issue 03. The load must be lossless and the
-- collapse from rows to persons must be exactly the collapse 03 measured.

SELECT test.expect('identity', 'landing rows loaded raw', 2154,
                   (SELECT count(*) FROM landing.contact_csv));

-- The landing table is raw. If cleaning leaked upstream of SQL, these break:
-- 11 blank emails and 6 malformed ones must survive the load untouched.
SELECT test.expect('identity', 'blank emails survive landing', 11,
                   (SELECT count(*) FROM landing.contact_csv
                     WHERE coalesce(btrim(email), '') = ''));

SELECT test.expect('identity', 'malformed emails survive landing', 6,
                   (SELECT count(*) FROM landing.contact_csv
                     WHERE coalesce(btrim(email), '') <> ''
                       AND norm.email(email) IS NULL));

-- CORRECTED FROM 03. Issue 03 states 2,099 persons / 55 rows absorbed, but
-- that figure merges the R3-uncorroborated clusters — which 03 itself rules
-- must be *held, not merged*, two paragraphs earlier. Only R1 and R2 merge:
-- 40 clusters, 40 rows absorbed, 2,114 persons. 03's 2,099 is the
-- merge-everything count and is internally inconsistent with its own rule.
SELECT test.expect('identity', 'persons resolved', 2114,
                   (SELECT count(*) FROM person),
                   '03 says 2099; that count merges R3-uncorroborated, which 03 rules must be held');

SELECT test.expect('identity', 'rows absorbed by dedup (R1 union R2)', 40,
                   (SELECT 2154 - count(*) FROM person),
                   '03 says 55, same cause');

SELECT test.expect('identity', 'R3 groups already merged by R1/R2 (corroborated)', 22,
                   (SELECT count(*) FROM (
                      SELECT 1 FROM landing_norm l JOIN identity_cluster ic USING (row_num)
                       WHERE l.first_name IS NOT NULL AND l.last_name IS NOT NULL
                         AND l.company_domain IS NOT NULL
                       GROUP BY l.first_name, l.last_name, l.company_domain
                      HAVING count(*) > 1 AND count(DISTINCT ic.cluster_id) = 1) s));

SELECT test.expect('identity', 'R3 groups uncorroborated (held)', 15,
                   (SELECT count(*) FROM (
                      SELECT 1 FROM landing_norm l JOIN identity_cluster ic USING (row_num)
                       WHERE l.first_name IS NOT NULL AND l.last_name IS NOT NULL
                         AND l.company_domain IS NOT NULL
                       GROUP BY l.first_name, l.last_name, l.company_domain
                      HAVING count(*) > 1 AND count(DISTINCT ic.cluster_id) > 1) s));

-- Every source row keeps a route back to its person. This is what makes the
-- surrogate key usable: a webhook carrying only an email still resolves.
SELECT test.expect('identity', 'every landing row maps to a person', 2154,
                   (SELECT count(*) FROM landing.contact_csv c
                     JOIN person_alias a
                       ON a.alias_type = 'source_id'
                      AND a.alias_value = c.contact_id));

SELECT test.expect('identity', 'no alias points at a missing person', 0,
                   (SELECT count(*) FROM person_alias a
                     LEFT JOIN person p USING (person_id)
                    WHERE p.person_id IS NULL));

-- 03: R3 matches with no R1/R2 corroboration hold rather than merge. Both
-- members of the cluster are held, which is why this is a person count.
-- 30 of 2,114 — 1.4%, the price of refusing to guess.
SELECT test.expect('identity', 'held for adjudication (R3 uncorroborated)', 30,
                   (SELECT count(*) FROM person WHERE needs_review));

SELECT test.expect('identity', 'every held person carries its conflicting evidence', 0,
                   (SELECT count(*) FROM person
                     WHERE needs_review AND review_evidence IS NULL));

-- CORRECTED FROM 03. 03 says 153 companies; 153 is the count of distinct raw
-- company_domain values, before applying the two company rules 03 itself
-- specifies. 6 of those domains are free-mail and are blocklisted, and
-- Keystone Cloud's two domains fold into one company: 153 - 6 - 1 = 146.
SELECT test.expect('identity', 'distinct raw company_domain values', 153,
                   (SELECT count(DISTINCT norm.domain(company_domain))
                      FROM landing.contact_csv));

SELECT test.expect('identity', 'companies resolved', 146,
                   (SELECT count(*) FROM company),
                   '03 says 153 = raw domains, before its own free-mail blocklist and alias merge');

-- 03: free-mail domains are blocklisted from ever becoming a company, or the
-- freelancers fuse into one and suppress each other.
SELECT test.expect('identity', 'no free-mail domain became a company', 0,
                   (SELECT count(*) FROM company
                     WHERE norm.is_free_mail(primary_domain)));

SELECT test.expect('identity', 'independents (no company)', 7,
                   (SELECT count(*) FROM person WHERE is_independent),
                   '03 says 6; it missed proton.me in its free-mail list');

-- 03: Keystone Cloud is the reason company_alias exists.
SELECT test.expect('identity', 'keystone cloud is one company, two domains', 1,
                   (SELECT count(DISTINCT company_id) FROM company_alias
                     WHERE domain IN ('getkeystone.com', 'keystonecloud.io')));
