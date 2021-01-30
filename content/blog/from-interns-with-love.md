---
title: "From Interns, With Love"
date: 2020-12-16
summary: A peek into what interns at CRDB work on.
preview: img/from-interns-with-love/watson-lab.jpg
---

<span class="marginnote">
  The world's most powerful computer (1954) at Columbia University's [Watson Lab](http://www.columbia.edu/cu/computinghistory/).
</span>
{{< gallery hover-effect="none" caption-effect="none" >}}
  {{< figure src="img/from-interns-with-love/watson-lab.jpg" size="1080x460" thumb="img/from-interns-with-love/watson-lab.jpg" caption="The world's most powerful computer (1954) at Columbia University's Watson Lab." >}}
{{< /gallery >}}
<span class="collapsed-marginnote">
  The world's most powerful computer (1954) at Columbia University's [Watson Lab](http://www.columbia.edu/cu/computinghistory/).
</span>

_Spoke with our interns this year to understand what they were working on. Some
version of this will post eventually find its way to the company's engineering
[blog](https://www.cockroachlabs.com/blog/engineering/). To keep up with new
writing, sign up for my [newsletter](/newsletter)._

---

While not exactly _envious_ of our current crop of interns (cause, you know,
the whole work from home thing), I'll admit I find myself reminiscing back to
when I was one myself. I'm still surprised they let me anywhere near the stuff
they did. When I first interned four years ago, we had just declared a [code yellow](https://www.cockroachlabs.com/blog/cockroachdb-stability-from-1-node-to-100-nodes/)
to focus our energy towards [stabilizing](https://www.cockroachlabs.com/blog/cant-run-100-node-cockroachdb-cluster/) <abbrev>CRDB</abbrev>.
Having joined the newly-formed distributed query execution[^distsql-rfc] team,
but now with its attention directed elsewhere, what that meant for me was free
rein to flesh out a few nifty things: distributed [hash](https://github.com/cockroachdb/cockroach/pull/10438)
and [merge](https://github.com/cockroachdb/cockroach/pull/10346) joins[^better-joins],
[aggregation](https://github.com/cockroachdb/cockroach/pull/9793) primitives
(think `SUM`, `COUNT`, [`DISTINCT`](https://github.com/cockroachdb/cockroach/pull/10034),
etc.), and various [sorting](https://github.com/cockroachdb/cockroach/pull/9224) algorithms.

That was more than enough to rope me back in for a second internship. This time
I brought my dear friend Bilal along, who similarly went on to intern twice. I
even managed to sneak [my brother](https://ridwanmsharif.github.io/) in (a
strictly worse engineer), also as a two-time intern.

All of which is to say that I think internships here can be pretty great.
<abbrev>CRDB</abbrev> is a mostly-cool system to be working on, and we're still at the point
where we're happy to let junior engineers take on work that, I think, would
otherwise only be accessible to someone further along career-wise. This was
true for me back when, and I'd say the same applied for our most recent cohort.

We hosted several interns over the year across various engineering teams,
all working on projects deserving of full-length blog posts. Today however
we'll highlight two projects from our most recent batch and give a briefer
treatment for the remaining.

## 1. Read-based compaction heuristics

[Aaditya Sondhi](https://www.aadityasondhi.com/) interned on our Storage team
to work on [Pebble](https://www.cockroachlabs.com/blog/pebble-rocksdb-kv-store/),
a storage engine based on [log-structured](http://www.benstopford.com/2015/02/14/log-structured-merge-trees/) merge trees[^lsm-history][^crdb-rocksdb]
\(abbrev. <abbrev>LSM</abbrev>s). Aaditya worked on introducing read-based compactions to
Pebble, but before diving into what that means, we'll first need to understand
what read-amplification and compactions are.

### 1.1 Compactions and read-amplification in LSMs

In <abbrev>LSM</abbrev>s, keys and values are stored as sorted strings in immutable blobs
called <abbrev>SST</abbrev>s (sorted string tables). <abbrev>SST</abbrev>s are stacked across multiple levels
(<abbrev>L1</abbrev>, <abbrev>L2</abbrev>, ...), don't overlap within a level, and when searching for a key that
overlaps with multiple <abbrev>SST</abbrev>s (necessarily across multiple levels), the one found
at the higher level is considered authoritative. This brings us
to read-amplification: the amount of physical work done (bytes read, number of
disk seeks, blocks decompressed, etc.) per logical operation. When reading a
key `k` from a two-level <abbrev>LSM</abbrev>, we may have to trawl through both if it isn't
found in the first.

That in turn brings us to compactions[^leveled-cmps]. As data flows into higher
level <abbrev>SST</abbrev>s, <abbrev>LSM</abbrev>s maintain a _healthy_ structure by compacting them into (fewer
but larger) lower level <abbrev>SST</abbrev>s. At one level (sorry) this lets <abbrev>LSM</abbrev>s reclaim
storage (range deletion tombstones and newer revisions mask out older values),
but also helps bound the read <abbrev>IOPS</abbrev> required to sustain a fixed workload. Like
all things, this is counter-balanced[^compaction-1][^compaction-2][^compaction-3][^compaction-4]
with the need to maintain sane write/space-amplification, which the rate of
compactions directly play into.

<span class="marginnote">
  An <abbrev>SST</abbrev> compaction; the L1 <abbrev>SST</abbrev> overlaps with two L2 <abbrev>SST</abbrev>s and is compacted into it.
</span>
{{< gallery hover-effect="none" caption-effect="none" >}}
  {{< figure src="img/from-interns-with-love/compaction.png" size="3515x1080"
      thumb="img/from-interns-with-love/compaction.png"
      caption="An SST compaction; the L1 SST overlaps with two L2 SSTs and is compacted into it." >}}
{{< /gallery >}}
<span class="collapsed-marginnote">
  Figure 1. An <abbrev>SST</abbrev> compaction; the L1 <abbrev>SST</abbrev> overlaps with two L2 <abbrev>SST</abbrev>s and is compacted into it.
</span>

(Aside: there's something to be said about how storage engines are
characterized in terms of resource utilization[^perf-util] as opposed to
unqualified _throughput_ or _latency_. System-wide measures like `$/tpmC`[^tpmc]
are another example of this. These feel comparatively easier to reason about,
more useful for capacity planning, and easily verifiable.)

### 1.2 Optimizing compactions for read-amplification

Compacting <abbrev>LSM</abbrev>s based on reads isn't a novel idea. It was originally
implemented in _[google/leveldb](https://github.com/google/leveldb)_, and later
dropped in _[facebook/rocksdb](https://github.com/facebook/rocksdb/)_. As for
the Go re-implementation of it (_[golang/leveldb](https://github.com/golang/leveldb)_,
incidentally where we forked Pebble from), it hasn't ported over the heuristic
yet. Part of the motivation for using a purpose-built storage engine was to let
us pull on threads exactly like this.

We hypothesized that by scheduling compactions for oft-read key ranges, we
could lower read amplification for subsequent reads, thus lowering resource
utilization and improving read performance. In [implementing](https://github.com/cockroachdb/pebble/pull/1009) it,
we borrowed from the ideas present in _[google/leveldb](https://github.com/google/leveldb)_.
For every positioning operation that returned a user key (think `Next`, `Prev`,
`Seek`, etc.), we sampled the key range (mediated by tunable knobs). The
sampling process checked for overlapping <abbrev>SST</abbrev>s across the various levels in the
<abbrev>LSM</abbrev>. If an oft-read <abbrev>SST</abbrev> was found to overlap with ones from lower levels, it
was scored higher to prioritize its compaction.

<span class="marginnote">
  Benchmarks showing the effect of read-based compactions on throughput,
  read-amplification and write-amplification.
</span>
```
$ benchstat baseline-1024.txt read-compac-1024.txt
                    old ops/sec  new ops/sec  delta
ycsb/C/values=1024    605k ± 8%   1415k ± 5%  +133.93%  (p=0.008 n=5+5)

                    old r-amp    new r-amp    delta
ycsb/C/values=1024    4.28 ± 1%    1.24 ± 0%   -71.00%  (p=0.016 n=5+4)

                    old w-amp    new w-amp    delta
ycsb/C/values=1024    0.00         0.00           ~     (all equal)


$ benchstat baseline-64.txt read-compac-64.txt
                  old ops/sec  new ops/sec  delta
ycsb/B/values=64    981k ±11%   1178k ± 2%   +20.14%  (p=0.016 n=5+4)

                  old r-amp    new r-amp    delta
ycsb/B/values=64    4.18 ± 0%    3.53 ± 1%   -15.61%  (p=0.008 n=5+5)

                  old w-amp    new w-amp    delta
ycsb/B/values=64    4.29 ± 1%   14.86 ± 3%  +246.80%  (p=0.008 n=5+5)
```
<span class="collapsed-marginnote">
  Figure 2. Benchmarks showing the effect of read-based compactions on
  throughput, read-amplification and write-amplification.
</span>


As expected, we [found](https://github.com/cockroachdb/pebble/issues/29#issuecomment-744514344)
that read-based compactions led to significant improvement in read heavy
workloads. Our benchmarks running <abbrev>YCSB-C</abbrev> 100% reads) using <abbrev>1KB</abbrev> writes saw
read amplification reduced by ~71% and throughput increased by ~133%. With
<abbrev>YCSB-B</abbrev> (95% reads) using small value reads/writes (64 bytes), we reduced
read-amplification by ~15% which led to a throughput increase of ~20%.  These
benchmarks targeted Pebble directly, and there's still a bit of legwork to be
done around parameter tuning (we're necessarily trading off some
write-amplification in this process), but the results are encouraging.

## 2. Query denylists (and our RFC process)

[Angela Wen](https://www.linkedin.com/in/angelapwen) interned on our <abbrev>SQL</abbrev>
Experience team, which owns the frontier where <abbrev>SQL</abbrev> clients meet the database.
During her internship Angela worked on introducing a mechanism to gate certain
classes of queries from being run against the database. This was motivated by
our cloud <abbrev>SRE</abbrev>s running
large <abbrev>CRDB</abbrev> installations, and wanting the ability to deny
queries(-of-death[^queries-of-death]) when emergent situations call for it (think _circuit
breakers_[^circuit-breakers]).

Angela's experience captures the kind of broad leeway accorded to
interns that I'm arguing we do a bit better than elsewhere. A general purpose
[query denylist](https://github.com/cockroachdb/cockroach/issues/51643) is a
very open-ended problem, with many personas you could design it for, and one
took deliberate effort to build consensus on. The [process](https://github.com/cockroachdb/cockroach/blob/v20.2.3/docs/RFCS/README.md)
we use to structure these conversations are <abbrev>RFC</abbrev>s, and we ended up [authoring](https://github.com/cockroachdb/cockroach/pull/55778) one
here as well.

The <abbrev>RFC</abbrev> and the ensuing
discussions clarified who the intended users were, the _must
haves/nice-to-haves_, catalogued the various classes of deniable queries, and
most importantly, outlined the actual mechanics of the denial itself. For all
my gripes with <abbrev>RFC</abbrev>s, I find the process of actually writing one edifying. It
can foster real agency over a component's design and works decently well as a
pedagogical tool (also I imagine it's cool to have public design documents to
share with friends similarly into query denylists).

We ended up eschewing our original proposal to implement file-mounted
regex-based denylists (the contentions here being around usability, deployment,
etc.) in favor of cluster settings of the form:
```
SET CLUSTER SETTING feature.changefeed.enabled = FALSE;
SET CLUSTER SETTING feature.schema_change.enabled = TRUE;
```
Configuration changes were made to disseminate cluster-wide by means of
gossip[^gossip]. Individual nodes listen in on these updates use the deltas to
keep an in-memory block-cache (sorry) up-to-date. This is later checked against
during query execution to determine whether or it's an allowable operation.

Like mentioned earlier, we scrapped lots of alternate designs during this
process, and were better off for it. We re-sized our scope to focus
instead on certain classes of queries as opposed to more granularly matching
specific ones. This came after observing that a vast majority of problematic
queries during prior incidents were well understood, and could be structurally
grouped/gated wholesale. That said, we [modularized](https://github.com/cockroachdb/cockroach/pull/57040)
our work to make it simple to introduce new [categories](https://github.com/cockroachdb/cockroach/pull/57076)
as needed.

## 3. Observability, design tokens, data-loss repair, and more

We hosted a few other interns this semester, and there's much to be said
about their individual contributions. We typically structure our programs to
have folks work on one or two _major_ projects, building up to them with
_starter_ ones. Here we'll briefly touch what these were.

### 3.1 Query runtime statistics

<span class="marginnote">
  The query execution plan for a full table scan followed by an `AVG`.
</span>
{{< gallery hover-effect="none" caption-effect="none" >}}
  {{< figure src="img/from-interns-with-love/explain-analyze.png" size="2222x1754"
      thumb="img/from-interns-with-love/explain-analyze.png"
      caption="The query execution plan for a full table scan followed by an `AVG`." >}}
{{< /gallery >}}
<span class="collapsed-marginnote">
  Figure 3. The query execution plan for a full table scan followed by an `AVG`.
</span>

[Cathy Wang](https://www.linkedin.com/in/cathy-m-wang) interned on our SQL
Execution team and worked on improving observability for running queries. We
have some existing [infrastructure](https://www.cockroachlabs.com/docs/v20.2/explain-analyze.html)
in place to surface various execution statistics. Cathy built upon this to
include details about network [latencies](https://github.com/cockroachdb/cockroach/pull/55705)
(useful for debugging queries run within geo-distributed clusters), structured
our traces to break down how much time is spent across [various layers](https://github.com/cockroachdb/cockroach/pull/57495)
in the system, and tacked on memory utilization to our traces to surface
exactly how much memory is in-use during any point mid-execution. This last bit
is worth elaborating on: Go's garbage collector doesn't give us fine-grained
control over allocations, and to that end a result we've had to design our own
[memory accounting/monitoring](https://github.com/cockroachdb/cockroach/blob/v20.2.3/pkg/util/mon/bytes_usage.go#L29-L169) infrastructure
to closely track usage during a query's lifecycle. By exposing these internal
statistics, we expect developers to better understand the memory footprint of
individual queries and to tune them accordingly.

### 3.2 Design tokens

[Pooja Maniar](https://www.linkedin.com/in/pooja-maniar-03) interned within the
Cloud organization, specifically on the Console team. One of the projects she
worked on was consolidating and standardizing our _[design
tokens](https://amzn.github.io/style-dictionary/#/)_.  Think of these as
abstractions over visual properties, variables to replace hardcoded color
palettes, fonts, box shadows on pressed buttons, etc. The motivation here was
to limit the number of design decisions developers had to
make, whether it be choosing between specific hexcodes, <abbrev>UI</abbrev> components, etc. We
wanted to create and hoist guidelines into a centralized, shared [repo](https://github.com/cockroachdb/ui)
and then integrate it into our several console pages (accessible both through
the database itself and through the cloud offering). We were also partway
through a brand-refresh at the time, and Pooja's grand unification helped [ensure](https://github.com/cockroachdb/ui/pull/137)
brand consistency throughout.

### 3.3 Quorum recovery

[Sam Huang](https://www.linkedin.com/in/samshuang) interned on the <abbrev>KV</abbrev> team
(they let me mentor this fellow), and one of the projects we worked on was
to introduce a [quorum recovery](https://github.com/cockroachdb/cockroach/pull/56333)
mechanism within <abbrev>CRDB</abbrev>. Because <abbrev>CRDB</abbrev> is built atop raft-replicated key-ranges,
when a cluster permanently loses quorum for a given set of keys (think
persistent node/disk failures), it's unable to recover from it. This necessarily
entails data-loss, but we still want the ability to [paper over](https://github.com/cockroachdb/cockroach/issues/41411)
such keys and provide [tooling](https://github.com/cockroachdb/cockroach/pull/57034)
for manual repair. Sam worked on introducing an out-of-band mechanism to
_reset_ the quorum for a given key-range, and somewhat cleanly, we were able to
leverage existing Raft machinery to do so. This came from the observation that
if we were to construct a synthetic snapshot (seeded using data from extant
replicas, if any), and configured it to specify a new set of participants, we
would essentially trick the underlying replication sub-system into recovering
quorum for this key-range. Our synthetic snapshot incremented the relevant
counters to _come after_ the existing data, which also in-turn purged older
replicas from the system.

### 3.4 Metamorphic schema changes

[Jayant Shrivastava](https://jayshrivastava.me/) interned on our SQL Schemas
team, and spent his time here ruggedizing our schemas infrastructure. <abbrev>CRDB</abbrev>
makes use of several advanced testing strategies to ensure correctness and
stability, including use of [fuzzers](https://www.cockroachlabs.com/blog/sqlsmith-randomized-sql-testing/),
[metamorphic](https://en.wikipedia.org/wiki/Metamorphic_testing) and
[chaos](https://www.cockroachlabs.com/blog/diy-jepsen-testing-cockroachdb/)
testing, [Jepsen](https://www.cockroachlabs.com/blog/jepsen-tests-lessons/)[^crdb-jepsen],
and much more. Having observed some latent fragility in this area recently,
Jayant fleshed out an [equivalent test harness](https://github.com/cockroachdb/cockroach/pull/55521)
but focusing instead on [schema changes](https://github.com/cockroachdb/cockroach/pull/54889).
We constructed a workload generator to execute randomly generated <abbrev>DDL</abbrev>
statements, executing within the confines of individual transactions. These
statements generate and drop tables on the fly, do the same for columns with
randomized types, and are executed concurrently with statements issued against
those very tables/columns. We leveraged metamorphic methods here by
[asserting](https://github.com/cockroachdb/cockroach/issues/56119) against the
invariants of the system rather than specific outputs (things like
_transactions that have read from a certain column should expect to always find
it in subsequent reads_). Put together we were able to cover a large space of
possible interleavings and uncovered [several](https://github.com/cockroachdb/cockroach/pull/56858)
[critical](https://github.com/cockroachdb/cockroach/pull/56589)
[bugs](https://github.com/cockroachdb/cockroach/issues/56230) in the process.

### 3.5 Import compatibility

[Monica Xu](https://monicaxu.me/) took a brief hiatus from her aspiring [music
career](https://youtu.be/vYrI1rcj-z4) to intern on our Bulk IO team. Her team's
broadly responsible for getting data in and out of <abbrev>CRDB</abbrev> as fast as possible
(specifically import/export and backup/restore). Monica made several contributions in
this area, including enabling [progress tracking](https://github.com/cockroachdb/cockroach/pull/55511)
for dump files, supporting [dry run](https://github.com/cockroachdb/cockroach/pull/56080)
[imports](https://github.com/cockroachdb/cockroach/pull/56587), and
improving `pg_dump`[^pg-dump] compatibility. There were kinks to be work out
with the latter seeing as how <abbrev>CRDB</abbrev> only supports a [subset](https://www.cockroachlabs.com/blog/why-postgres/)
of Postgres syntax, which can be problematic when processing `pg_dump` files as
is. The particular set of questions Monica helped address was what
_reasonable behavior_ is when chewing through potentially destructive import
directives. Think `DROP TABLE [IF EXISTS]`, or `CREATE VIEW`, which is
particularly tricky given it stores the results of the query it was constructed
using, results subject to change during the import process. Monica engaged with
our product teams when forming these judgements (we now simply [defer](https://github.com/cockroachdb/cockroach/pull/56920) to the user
with instructive messaging), and helped [significantly](https://github.com/cockroachdb/cockroach/pull/55126)
[ease](https://github.com/cockroachdb/cockroach/pull/57339) the onboarding
experience for developers migrating off of their existing installations.

## 4. Parting thoughts

If you're still here and interested, hit us up. And don't let the
database-speak throw you off, most of us didn't know any of it coming in.

[^better-joins]: Raphael Poss. 2017. [On the Way to Better SQL Joins in CockroachDB](https://www.cockroachlabs.com/blog/better-sql-joins-in-cockroachdb/)
[^distsql-rfc]: Radu Berinde, Andrei Matei. 2016. [Distributing SQL Queries in CockroachDB](https://github.com/cockroachdb/cockroach/blob/v20.2.3/docs/RFCS/20160421_distributed_sql.md).
[^crdb-rocksdb]: Arjun Narayan, Peter Mattis. 2019. [Why we built CockroachDB on top of RocksDB](https://www.cockroachlabs.com/blog/cockroachdb-on-rocksd/).
[^lsm-history]: Arjun Narayan, 2018. [A Brief History of Log Structured Merge Trees](https://ristret.com/s/gnd4yr/brief_history_log_structured_merge_trees).
[^compaction-1]: Mark Callaghan, 2018. [Read, Write & Space Amplification -- Pick Two](http://smalldatum.blogspot.com/2015/11/read-write-space-amplification-pick-2_23.html).
[^compaction-2]: Mark Callaghan, 2018. [Describing Tiered and Leveled Compactions](http://smalldatum.blogspot.com/2018/10/describing-tiered-and-leveled-compaction.html).
[^compaction-3]: Mark Callaghan, 2018. [Name that Compaction Algorithm](http://smalldatum.blogspot.com/2018/08/name-that-compaction-algorithm.html).
[^compaction-4]: Mark Callaghan, 2018. [Tiered or Leveled Compactions, Why Not Both?](http://smalldatum.blogspot.com/2018/07/tiered-or-leveled-compaction-why-not.html).
[^leveled-cmps]: Siying Dong, [n.d.]. [Leveled Compactions in RocksDB](https://github.com/facebook/rocksdb/wiki/Leveled-Compaction).
[^perf-util]: Nelson Elhage, 2020. [Performance as Hardware Utilization](https://buttondown.email/nelhage/archive/f5f191bc-c180-4418-bed8-2c6d6270f3f0).
[^queries-of-death]:  Mike Ulrich, 2017. [Site Reliability Engineering, Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/).
[^circuit-breakers]: Martin Fowler, 2014. [Circuit Breakers](https://martinfowler.com/bliki/CircuitBreaker.html).
[^crdb-jepsen]: Kyle Kingsbury, 2016. [Jepsen Testing CockroachDB](https://jepsen.io/analyses/cockroachdb-beta-20160829).
[^pg-dump]: PostgreSQL 9.6.20 Documentation, [n.d.]. [`pg_dump`](https://www.postgresql.org/docs/9.6/app-pgdump.html).
[^gossip]: Abhinandan Das, Indranil Gupta, et. al. 2002. [SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf).
[^tpmc]: TPC-C, [n.d.]. [What is TPC-C](http://www.tpc.org/tpcc/faq5.asp).
