---
title: "From Interns, With Love"
date: 2020-12-13
---

While not exactly _envious_ of our current crop of interns (cause, you know,
the whole work from home thing), I'll admit I find myself reminiscing back to
when I was one myself (I'm also writing this while on-call, which is wholly
unrelated to the sentiment).

I'm still surprised they let me anywhere near the stuff they did. When I first
joined four years ago, we had just declared a ["code yellow"](https://www.cockroachlabs.com/blog/cockroachdb-stability-from-1-node-to-100-nodes/)
to focus our energy towards [stabilizing CRDB](https://www.cockroachlabs.com/blog/cant-run-100-node-cockroachdb-cluster/)
(read: shit hit the fan). What that meant for me, an intern on a team that had
just finalized the design for a new distributed query execution
engine[^distsql-rfc] but now with its focus directed elsewhere, was free rein
to build the first version of it all from ground up.
Concretely, I got to flesh out [distributed hash joins](https://github.com/cockroachdb/cockroach/pull/10438)[^better-joins],
[merge joins](https://github.com/cockroachdb/cockroach/pull/10346), several
[aggregation primitives](https://github.com/cockroachdb/cockroach/pull/9793)
(think `SUM`, `COUNT`, [`DISTINCT`](https://github.com/cockroachdb/cockroach/pull/10034),
etc.), and [distributed sorting algorithms](https://github.com/cockroachdb/cockroach/pull/9224).

That was more than enough bait to rope me back a second time, in part to get
closer to the distributed, consistent key-value store (where shit had formerly
hit the fan, I was curious). This time I brought my dear friend
[Bilal](https://www.cockroachlabs.com/blog/from-intern-to-full-time-engineer-at-cockroach-labs/)
along, who similarly went on to intern twice (and later helped me start a
Canadian engineering office), and then sneaked my brother in (a strictly worse
engineer), also as a two-time intern (parentheses).

All of which is to say that I think internships here can be [pretty great](https://www.cockroachlabs.com/blog/equity-for-interns/).
CRDB is a mostly-cool system to be working on, and culturally we're still at
the point where we're happy to let junior engineers take on work that I think
would otherwise only be accessible to someone further along career-wise. This
still rings true for me, and I'd say the same applied for our most recent
intern cohort (something I'm going to try convincing you of).

We hosted several interns over the year across various engineering teams,
all working on projects deserving of full-length blog posts. Today however
we'll focus on our most recent batch, going into detail for two specific
projects (they showcase some unique aspects of internships here), and
give a briefer treatment for the remaining (but with plenty of links to follow
up on).

## Read-based compaction heuristics

[Aaditya Sondhi](https://www.aadityasondhi.com/) interned on our storage team
to work on [Pebble](https://www.cockroachlabs.com/blog/pebble-rocksdb-kv-store/),
a storage engine based on [log-structured merge trees](http://www.benstopford.com/2015/02/14/log-structured-merge-trees/)[^lsm-history][^crdb-rocksdb]
\(abbrev. LSMs). Aaditya worked on introducing read-based compactions to Pebble,
but before diving into what means, we'll first need to understand what
read-amplification and compactions are.

### Compactions and read-amplification in LSMs

In LSMs, keys and values are stored as sorted strings in blobs
called SSTs (sorted string tables). SSTs are stacked across multiple levels
(L1, L2, ...), don't overlap within a level, and when searching for a key that
overlaps with multiple SSTs (necessarily across multiple levels), the one found
at the higher level is considered authoritative. This brings us
to read-amplification: the amount of physical work done (bytes read, number of
disk seeks, blocks decompressed, etc.) per logical operation. When reading a
key `k` from a two-level LSM, we may have to trawl through both if it isn't
found in the first.

That in turn brings us to compactions[^leveled-cmps]. As data flows into higher
level SSTs, LSMs maintain a "healthy" structure by compacting them into (fewer
but larger) lower level SSTs. At one level (sorry) this lets LSMs reclaim
storage (range deletion tombstones and newer revisions mask out older values),
but also helps bound the read IOPS required to sustain a fixed workload. Like all
things, this is counter-balanced[^compaction-1][^compaction-2][^compaction-3][^compaction-4]
with the need to maintain sane {write,space}-amplification (which the rate of
compactions directly play into).

TODO: picture of read amp and compactions.

(Aside: there's something to be said about how storage engines are
characterized in terms of resource utilization[^perf-util] as opposed to
unqualified "throughput" or "latency". System-wide measures like $/tpmC are
another example of the same. These feel comparatively easier to reason about,
more useful for capacity planning, and verifiable; let's strive to think in
these terms for other measures of performance.)

### Optimizing compactions for read-amplification

Compacting LSMs based on reads isn't a wild idea. It was originally
implemented in [google/leveldb](https://github.com/google/leveldb), and later
dropped in [facebook/rocksdb](https://github.com/facebook/rocksdb/). As for
the Go re-implementation of it ([golang/leveldb](https://github.com/golang/leveldb),
incidentally where we had forked Pebble from), it hadn't ported over the
heuristic as yet. Part of the motivation for using a purpose-built storage
engine was to let us pull on threads exactly like this.

We hypothesized that by scheduling compactions for oft-read key ranges, we
could lower read amplification for subsequent reads, thus lowering resource
utilization and improving read performance. In [implementing it](https://github.com/cockroachdb/pebble/pull/1009),
we borrowed from the ideas present in [google/leveldb](https://github.com/google/leveldb).
For every positioning operation that returned a user key (think `Next`, `Prev`,
`Seek`, etc.), we sampled the key range (mediated by tunable knobs). The
sampling process checked for overlapping SSTs across the various levels in the
LSM. If an oft-read SST was found to overlap with ones from lower levels, it
was scored higher to prioritize its compaction.

As expected, we [found](https://github.com/cockroachdb/pebble/issues/29#issuecomment-744514344)
that read-based compactions led to significant improvement in read heavy
workloads. Our benchmarks running YCSB-C (100% reads) using 1KB writes saw
read amplification reduced by ~71% and throughput increased by ~133%. With
YCSB-B (95% reads) using small value reads/writes (64 bytes), we reduced
read-amplification by ~15% which led to a throughput increase of ~20%.  These
benchmarks targeted Pebble directly, and there's still a bit of legwork to be
done around parameter tuning (we're necessarily trading off some
write-amplification in this process), but the results are encouraging.

TODO: image here, or benchmark snippets

## Query denylists (and our RFC process)

[Angela Wen](https://www.linkedin.com/in/angelapwen) interned on our SQL
experience team, which owns the frontier where SQL clients meet the database.
During her internship, Angela worked on introducing an out-of-band mechanism to
gate certain classes of queries from being run against the database. This was
motivated by [our cloud](https://www.cockroachlabs.com/product/cockroachcloud/)
SREs running large CRDB installations, and wanting the ability to deny queries
when emergent situations (think "queries-of-death"[^queries-of-death]) call for
it ("circuit breakers"[^circuit-breakers]).

Angela's experience here captures exactly the kind of broad leeway accorded to
interns that I'm arguing we do a bit better than elsewhere. A general purpose
[query denylist](https://github.com/cockroachdb/cockroach/issues/51643)
facility is a very open-ended problem, with many personas you could
design it for, and one that looks to have taken deliberate effort (see below)
to build consensus on to then get something done. The [process](https://github.com/cockroachdb/cockroach/blob/v20.2.3/docs/RFCS/README.md)
we maintain to structure these conversations are RFCs, and we ended up
authoring one here as well.

The [denylist RFC](https://github.com/cockroachdb/cockroach/pull/55778)
and the ensuing discussions (worth reading in full if you're really into
query denylists for some reason) ended up clarifying who the intended users
were, the "must haves"/"nice-to-haves", catalogued the various classes of
deniable queries, and finally outlined the actual mechanics of the denial
itself. For all my gripes with RFCs, I find the process of actually writing one
edifying. It can foster real agency over a component's design and can work
decently well as a pedagogical tool (also I imagine it's cool to have public
links to your design documents to share with friends also super into query
denylists for some reason).

For posterity we ended up eschewing our original proposal to implement
file-mounted regex-based denylists (the contentions here being around
usability, deployment, etc.) in favor of cluster settings of the form:
```
SET CLUSTER SETTING feature.changefeed.enabled = FALSE;
SET CLUSTER SETTING feature.schema_change.enabled = TRUE;
```
Configuration changes here were then designed to disseminate cluster-wide
through CRDB's internal use of gossip. Individual nodes listening in on these
updates end up using these deltas to keep an in-memory block-cache (sorry)
up-to-date, something that's later checked against during query execution to
determine whether or it's an allowable operation. 

Like mentioned above, we scrapped a lot of alternate designs during this
process, and were (probably) better off for it. We re-sized our scope to focus
instead on certain "classes" of queries as opposed to more granularly matching
specific ones. This came after observing that a vast majority of problematic
queries during prior incidents were well understood, and could be structurally
grouped/gated wholesale. That said, we [modularized our work](https://github.com/cockroachdb/cockroach/pull/57040)
to make it simple to introduce [new categories](https://github.com/cockroachdb/cockroach/pull/57076)
as needed.

## Observability, design tokens, data-loss repair, and more!

We hosted a few other interns this last semester, and there's much to be said
about their individual contributions (of which there were many). We typically
structure our programs to have folks work on one or two "major" projects,
building up to them with smaller ["starter"](https://www.cockroachlabs.com/blog/onboarding-starter-projects/)
ones. Here I'll briefly elaborate on a few of these.

### Query runtime statistics 

TODO: show example usage of EXPLAIN ANALYZE, and TraceAnalyze. https://github.com/cockroachdb/cockroach/pull/55705

[Cathy Wang](https://www.linkedin.com/in/cathy-m-wang) interned on our SQL
execution team, and worked on improving observability for running queries. We
have some [existing infrastructure](https://www.cockroachlabs.com/docs/v20.2/explain-analyze.html)
in place to surface various execution statistics. Cathy built upon this to
include [details about network latencies](https://github.com/cockroachdb/cockroach/pull/55705)
(useful for debugging queries run against geo-distributed clusters), structured
our traces to break down how much time is spent [across various layers](https://github.com/cockroachdb/cockroach/pull/57495)
in the system, and tacked on memory utilization to our traces to surface
exactly how much memory is in-use during any point mid-execution. This last bit
is worth elaborating on: Go's garbage collector doesn't give us fine-grained
control over allocations, and to that end a result we've had to design our own
[memory accounting/monitoring infrastructure](https://github.com/cockroachdb/cockroach/blob/v20.2.3/pkg/util/mon/bytes_usage.go#L29-L169)
to closely track usage during a query's lifecycle. By exposing these internal
statistics, we expect developers to better understand the memory footprint of
individual queries and tune them accordingly.

### Design tokens

TODO: show screenshots

[Pooja Maniar](https://www.linkedin.com/in/pooja-maniar-03) interned in our
[cloud](https://cockroachlabs.cloud/) org, specifically on our Console team.
One of the projects she worked on was consolidating and standardizing our
["design tokens"](https://amzn.github.io/style-dictionary/#/). Think of these
as abstractions over visual properties, variables to replace hardcoded color
palettes, fonts, box shadows on pressed buttons, etc. The motivation here was
to limit the number of design decisions developers had to make, whether it was
choosing between specific hexcodes, UI components, etc. We wanted to create and
hoist guidelines into a centralized, [shared repo](https://github.com/cockroachdb/ui)
and then integrate it into our several console pages (accessible both through
the database itself and our cloud offering). We were also partway through a
brand-refresh at the time, and Pooja's grand unification [helped ensure](https://github.com/cockroachdb/ui/pull/137)
brand consistency throughout.

### Quorum recovery

[Sam Huang](https://www.linkedin.com/in/samshuang) interned on the KV team
(they let me mentor this fellow), and one of the projects we worked on was
to introduce a [quorum recovery](https://github.com/cockroachdb/cockroach/pull/56333)
mechanism within CRDB. Because CRDB is built atop raft-replicated key-ranges,
when a cluster permanently loses quorum for a given set of keys (think
permanent node/disk failures), it's unable to recover from it. This necessarily
entails permanent data-loss, but we still wanted the ability to [paper over such
keys](https://github.com/cockroachdb/cockroach/issues/41411) and provide
operators [tooling](https://github.com/cockroachdb/cockroach/pull/57034) for
manual repair. Sam worked on introducing this out-of-band mechanism to "reset
quorum" for a given key-range, and somewhat cleanly, we were able to leverage
existing Raft machinery to do so. This came from the observation that if were
to construct a "synthetic snapshot" (seeded using data from extant replicas, if
any), and configured it to specify a new quorum membership, we would
essentially be tricking the underlying replication sub-system into recovering
quorum for this key-range. Our snapshot construction incremented the relevant
counters to "come after" the existing data, which also brought about the
desired side-effect of purging older replicas from the system.

### Metamorphic schema changes

[Jayant Shrivastava](https://jayshrivastava.me/) interned on newly formed SQL
schemas team, and spent some his time here ruggedizing our schemas
infrastructure. We recently spun a team around this area due to latent
fragility observed across a few of our previous releases. CRDB makes use of
several advanced testing strategies to ensure correctness and stability,
including use of [fuzzers](https://www.cockroachlabs.com/blog/sqlsmith-randomized-sql-testing/), 
[metamorphic testing](https://en.wikipedia.org/wiki/Metamorphic_testing),
[chaos](https://www.cockroachlabs.com/blog/diy-jepsen-testing-cockroachdb/),
[jepsen](https://www.cockroachlabs.com/blog/jepsen-tests-lessons/)[^crdb-jepsen],
and much more. Jayant fleshed out an [equivalent harness](https://github.com/cockroachdb/cockroach/pull/55521),
but focusing instead on [schema changes](https://github.com/cockroachdb/cockroach/pull/54889).
We constructed a workload generator to execute randomly generated DDL
statements, executing within the confines of individual transactions. These
statements generate and drop tables on the fly, do the same for columns with
randomized types, and are executed concurrently with statements issued against
those very tables/columns. We leveraged metamorphic methods here,
[asserting](https://github.com/cockroachdb/cockroach/issues/56119) against the
properties/invariants of the system rather than specific outputs (think
invariants such as "transactions that have read from a certain column should
expect to always find it in subsequent reads"). Put together we were able to
cover a large space of possible interleavings and uncovered a
[several](https://github.com/cockroachdb/cockroach/pull/56858)
[critical](https://github.com/cockroachdb/cockroach/pull/56589)
[bugs](https://github.com/cockroachdb/cockroach/issues/56230) in doing so.

### Import compatibility

[Monica Xu](https://monicaxu.me/) took a brief hiatus from her promising [music
career](https://youtu.be/vYrI1rcj-z4) to intern on our [Bulk IO](https://www.cockroachlabs.com/blog/bulk-data-import/)
team. Her team's broad mandate covers getting data in and out of CRDB as fast
as possible (think [import](https://www.cockroachlabs.com/docs/v20.2/import.html)/[export](https://www.cockroachlabs.com/docs/v20.2/export.html)
and [backup](https://www.cockroachlabs.com/docs/v20.2/backup.html)/[restore](https://www.cockroachlabs.com/docs/v20.2/restore.html),
to and from raw files or other databases). Monica made several contributions in
this area, including enabling [progress tracking](https://github.com/cockroachdb/cockroach/pull/55511)
for dump files, supporting [dry](https://github.com/cockroachdb/cockroach/pull/56080)
[run](https://github.com/cockroachdb/cockroach/pull/56587) imports, and improving 
[`pg_dump`](https://www.postgresql.org/docs/9.6/app-pgdump.html) [compatibility](https://github.com/cockroachdb/cockroach/issues/56659).
There were kinks to be worked
out with the latter seeing as how CRDB only supports a [subset of Postgres
syntax](https://www.cockroachlabs.com/blog/why-postgres/), which can be
problematic when processing `pg_dump` files as is. A particular set of
questions that Monica helped address was what "reasonable behavior" was when
chewing through potentially destructive import directives.  Think `DROP TABLE
[IF EXISTS]`, or `CREATE VIEW`, which is tricky in particular seeing as how
they store the results of the query they were constructed using, results could
potentially be changed during the import process). Monica engaged with our
product teams when forming these judgements (we now end up [deferring to the
user](https://github.com/cockroachdb/cockroach/pull/56920), with instructive
messaging, when encountering the above), and helped significantly ease the
[onboarding](https://github.com/cockroachdb/cockroach/pull/55126)
[experience](https://github.com/cockroachdb/cockroach/pull/57339) for
developers looking to migrate off of their existing database installations. 


## Parting thoughts

If you're still here, and interested, reach out to us. And don't let the
database-speak throw you off, most of us didn't know any of it coming in.

[^better-joins]: Raphael Poss. 2017. [On the Way to Better SQL Joins in CockroachDB](https://www.cockroachlabs.com/blog/better-sql-joins-in-cockroachdb/)
[^distsql-rfc]: Radu Berinde, Andrei Matei, Raphael Poss. 2016. [RFC for Distributing SQL queries in CockroachDB](https://github.com/cockroachdb/cockroach/blob/v20.2.3/docs/RFCS/20160421_distributed_sql.md).
[^crdb-rocksdb]: Arjun Narayan, Peter Mattis. 2019. [Why we built CockroachDB on top of RocksDB](https://www.cockroachlabs.com/blog/cockroachdb-on-rocksd/).
[^lsm-history]: Arjun Narayan, 2018. [A Brief History of Log Structured Merge Trees](https://ristret.com/s/gnd4yr/brief_history_log_structured_merge_trees).
[^compaction-1]: Mark Callaghan, 2018. [Read, write & space amplification -- pick two](http://smalldatum.blogspot.com/2015/11/read-write-space-amplification-pick-2_23.html).
[^compaction-2]: Mark Callaghan, 2018. [Describing tiered and leveled compaction](http://smalldatum.blogspot.com/2018/10/describing-tiered-and-leveled-compaction.html).
[^compaction-3]: Mark Callaghan, 2018. [Name that compaction algorithm](http://smalldatum.blogspot.com/2018/08/name-that-compaction-algorithm.html).
[^compaction-4]: Mark Callaghan, 2018. [Describing tiered and leveled compaction](http://smalldatum.blogspot.com/2018/10/describing-tiered-and-leveled-compaction.html).
[^leveled-cmps]: [Leveled Compactions in RocksDB](https://github.com/facebook/rocksdb/wiki/Leveled-Compaction)
[^perf-util]: Nelson Elhage, 2020. [Performance as hardware utilization](https://buttondown.email/nelhage/archive/f5f191bc-c180-4418-bed8-2c6d6270f3f0).
[^queries-of-death]:  Mike Ulrich, 2017. [Site Reliability Engineering: Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/).
[^circuit-breakers]: Martin Fowler, 2014. [CircuitBreaker](https://martinfowler.com/bliki/CircuitBreaker.html).
[^crdb-jepsen]: Kyle Kingsbury, 2016. [Jepsen testing CockroachDB](https://jepsen.io/analyses/cockroachdb-beta-20160829).
