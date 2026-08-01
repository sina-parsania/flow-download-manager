# Throughput techniques for a libcurl download manager on a high-RTT lossy link

**Question.** On a ~127 ms RTT, lossy international path where **one** TCP connection caps near
0.6–1 MB/s but **8** parallel range requests reach ~14 MB/s, what can Flow do to go faster?

**Status.** Research, not a decision. Nothing here is an ADR. Findings are claims with citations;
recommendations at the end are ranked and evidence-graded.

## Provenance and how to read the citations

Primary sources only. Three kinds of citation appear:

| Form | Means |
| --- | --- |
| `curl-8_21_0:lib/http2.c:70` | curl's own source at the exact tag Flow vendors. Fetch: `https://raw.githubusercontent.com/curl/curl/curl-8_21_0/lib/http2.c` |
| `xnu-12377.121.6:bsd/netinet/tcp_subr.c:3901` | Apple's published xnu source. Fetch: `https://raw.githubusercontent.com/apple-oss-distributions/xnu/xnu-12377.121.6/bsd/netinet/tcp_subr.c` |
| `Sources/CCurl/DMCurlSupport.c:112` | this repo, working tree at time of writing |

Anything weaker is labelled **[WEAK]** inline. Anything I could not source is labelled
**[NO PRIMARY SOURCE FOUND]** rather than guessed.

**Environment the platform numbers came from** — measured locally, not quoted from a doc:

- macOS 26.5.2 (build 25F84), arm64
- Vendored libcurl: `curl 8.21.0 (aarch64-apple-darwin) libcurl/8.21.0 OpenSSL/3.5.1 zlib/1.2.12
  libssh2/1.11.1 nghttp2/1.66.0`, Release-Date 2026-06-24
  (`VendorBuild/prefix/arm64/curl-version.txt`)
- Vendored feature list: `alt-svc AppleSecTrust AsynchDNS HSTS HTTP2 HTTPS-proxy IPv6 Largefile
  libz SSL threadsafe TLS-SRP UnixSockets` (`VendorBuild/prefix/arm64/curl-features.txt`) —
  **note the absence of `HTTP3`**
- xnu source read at tag `xnu-12377.121.6` (latest tag at time of writing). The sysctl *values*
  below are from this machine; another machine or macOS version may differ.

---

## Area 0 — What the measurement itself says (read this first)

The two numbers in the question are the strongest evidence in this document, and they discriminate
between the candidate explanations better than any doc does.

**Claim 0.1 — The path is loss-limited, not window-limited.**
The steady-state throughput of a loss-based TCP sender is approximately
`BW ≈ MSS / (RTT · √p)`. RFC 5348 §3.1 gives the standardised form of this TCP throughput equation
(<https://www.rfc-editor.org/rfc/rfc5348.html#section-3.1>); the original derivation is Mathis,
Semke, Mahdavi & Ott, *The Macroscopic Behavior of the TCP Congestion Avoidance Algorithm*,
ACM SIGCOMM CCR 27(3), 1997. With `MSS ≈ 1448 B` and `RTT = 0.127 s`:

| loss rate `p` | predicted single-flow throughput |
| --- | --- |
| 0.01 % | 1.14 MB/s |
| 0.03 % | 0.66 MB/s |
| 0.10 % | 0.36 MB/s |

The observed 0.6–1 MB/s per connection implies `p ≈ 0.02–0.06 %`. That is an ordinary lossy
long-haul path. **Evidence: strong for the model, inferential for the conclusion** — the model is
primary-sourced, but the loss rate was inferred from the reported throughput, not measured. A
direct check would be `netstat -s -p tcp` (retransmit counters) during a transfer.

**Claim 0.2 — The receive window is nowhere near binding, so buffer tuning cannot be the fix.**
At 127 ms, sustaining 1 MB/s needs only ~127 KB of in-flight window. The current 2 MiB socket
buffer supports ~16.5 MB/s on that RTT. The window is oversized by more than an order of magnitude
relative to what the connection achieves. **Evidence: strong** (arithmetic on the reported numbers).

**Claim 0.3 — This is exactly why N connections give ~N× the throughput.**
Each TCP connection runs its own congestion controller, so N flows sharing a bottleneck each obtain
a loss-limited share, and the aggregate scales roughly linearly until the bottleneck link, the
server, or a middlebox saturates. The reported 8 → ~14 MB/s (≈1.75 MB/s per flow, *above* the
single-flow 0.6–1 MB/s) is consistent with that and suggests the ceiling had not yet been reached
at 8. **Evidence: strong** — this is the direct consequence of per-connection congestion control
(RFC 5681 §3.1, <https://www.rfc-editor.org/rfc/rfc5681.html#section-3.1>) plus the measurement.

**The consequence that governs the whole document:** the dominant lever is *number of independent
congestion controllers*, i.e. connection count. Anything that folds segments onto one congestion
controller destroys the win. Anything that only widens buffers is treating a non-bottleneck.

---

## Area 1 — HTTP/3 + QUIC in libcurl

### Would QUIC help here?

**Claim 1.1 — QUIC's head-of-line-blocking fix does not apply to Flow's design.**
QUIC removes HOL blocking *between streams of one connection*: a lost packet carrying stream A's
data does not stall stream B. Flow does not multiplex — it runs one range request per connection
(`Sources/CCurl/DMCurlSupport.c:1434`). With one stream per connection there is no inter-stream HOL
blocking to remove. **Evidence: strong.**

**Claim 1.2 — One QUIC connection is one congestion controller, exactly like one TCP connection.**
RFC 9002 §7: *"The congestion controller is per path, so packets sent on other paths do not alter
the current path's congestion controller"* and *"This document specifies a sender-side congestion
controller for QUIC similar to TCP NewReno [RFC6582]."*
(<https://www.rfc-editor.org/rfc/rfc9002.html#section-7>). So a single H3 connection carrying 8
multiplexed range streams would be subject to **one** congestion window — the same trap the repo
already avoids for HTTP/2. **This is the key finding for Area 1: HTTP/3 does not replace parallel
connections; used naively it is a regression.** Evidence: strong.

**Claim 1.3 — QUIC has the same two-level flow control as HTTP/2.**
RFC 9000 §4.1: *"Stream flow control, which prevents a single stream from consuming the entire
receive buffer… Connection flow control, which prevents senders from exceeding a receiver's buffer
capacity"*, and *"Senders MUST NOT send data in excess of either limit."*
(<https://www.rfc-editor.org/rfc/rfc9000.html#section-4.1>). QUIC is not structurally freer than h2
here. **Evidence: strong.**

**Claim 1.4 — QUIC's loss *recovery* is genuinely better on lossy paths, and this is the one real
upside.** RFC 9002 §4.2: *"QUIC's packet number is strictly increasing within a packet number space
and directly encodes transmission order… Consequently, more accurate RTT measurements can be made,
spurious retransmissions are trivially detected."* RFC 9002 §4.5: *"QUIC supports many ACK ranges,
as opposed to TCP's three SACK ranges. In high-loss environments, this speeds recovery, reduces
spurious retransmits, and ensures forward progress without relying on timeouts."*
(<https://www.rfc-editor.org/rfc/rfc9002.html>). At `p ≈ 0.02–0.06 %` this is a real but
second-order effect — it improves recovery efficiency, it does not change the `1/√p` scaling law.
**Evidence: strong for the mechanism, unquantified for the magnitude.** I found no primary source
quantifying the H3-vs-H2 bulk-throughput delta at this loss rate. **[NO PRIMARY SOURCE FOUND]**

**Claim 1.5 — 0-RTT saves handshake latency, not throughput, and carries a replay caveat.**
RFC 9000 §5: *"0-RTT allows application data to be sent by a client before receiving a response
from the server. However, 0-RTT provides no protection against replay attacks."*
(<https://www.rfc-editor.org/rfc/rfc9000.html#section-5>). For a multi-hundred-megabyte download,
saving one RTT of handshake is noise. It would matter marginally for Flow's per-segment connection
setup if segments were short-lived, which they are not. **Evidence: strong.**

### What it would take to enable it

**Claim 1.6 — Flow's vendored libcurl has no HTTP/3 at all.**
`VendorBuild/prefix/arm64/curl-features.txt` lists no `HTTP3` feature, and
`VendorBuild/scripts/build-libcurl.sh:159-174` configures curl with `--with-openssl`,
`--with-nghttp2`, `--with-libssh2`, `--with-zlib`, `--with-apple-sectrust` — no `--with-ngtcp2`,
no `--with-nghttp3`, no `--with-quiche`. Setting `CURL_HTTP_VERSION_3` today cannot do anything.
**Evidence: strong (build script + built artifact both checked).**

**What curl does *not* document: the behaviour when HTTP/3 is not compiled in.**
<https://curl.se/libcurl/c/CURLOPT_HTTP_VERSION.html> describes `CURL_HTTP_VERSION_3` and
`_3ONLY` in one sentence each and says nothing about an uncompiled build. `curl.1` only notes *"For
--http3 to work, it requires that the underlying libcurl is built to support HTTP/3."*
`CURLE_NOT_BUILT_IN (4)` exists and reads *"A requested feature, protocol or option was not found
built into this libcurl due to a build-time decision"*
(<https://curl.se/libcurl/c/libcurl-errors.html>), but **no curl document links it to
`CURL_HTTP_VERSION_3`**. Anyone relying on a specific failure mode should test it rather than
assume. **[NO PRIMARY SOURCE FOUND]** for the exact return code.

**Claim 1.7 — curl 8.21.0 has exactly two HTTP/3 backends.**
`curl-8_21_0:configure.ac:199` renders the "no HTTP/3" help string as
`"no       (--with-ngtcp2 --with-nghttp3, --with-quiche)"`. Those are the only two.
**There is no standalone `--with-openssl-quic` backend in 8.21.0** — I grepped `configure.ac` for
it and it does not exist. OpenSSL's own QUIC API is instead consumed *through* ngtcp2: when
`OPENSSL_QUIC_API2` is defined (OpenSSL 3.5+ new QUIC API), curl links `ngtcp2_crypto_ossl`
(`curl-8_21_0:configure.ac:3366`, `:3405`, `:3420`). msh3 is likewise absent from this version.
**Evidence: strong.** This corrects a common assumption — treat "OpenSSL-QUIC" as a *TLS provider
under ngtcp2*, not as an alternative backend.

**Claim 1.8 — curl's own maturity statement.**
`curl-8_21_0:docs/HTTP3.md:24-28`, verbatim:

> ## Experimental
>
> HTTP/3 support using *quiche* in curl is considered **EXPERIMENTAL** until further notice. Only
> the *ngtcp2* backend is not experimental.

So: **ngtcp2 is the non-experimental backend; quiche is experimental.** Evidence: strong (curl's own
words, at the vendored tag; the same text is served live at <https://curl.se/docs/http3.html>).

Two honest qualifications. **curl never uses the word "recommended" for any backend** — reading
*"Only the ngtcp2 backend is not experimental"* as "use ngtcp2" is an inference, not a curl claim.
And **curl's own documentation is internally inconsistent about a third backend, msh3**:
<https://everything.curl.dev/build/autotools.html> still lists *"msh3: --with-msh3"*, while
<https://everything.curl.dev/build/deps.html> and `docs/http3.html` list only ngtcp2 and quiche. The
authoritative resolution for the vendored version is the source: `configure.ac:199` names exactly
two, and there is no `--with-msh3` in it. **Evidence: strong (source breaks the doc tie).**

**Claim 1.9 — the ngtcp2 build for Flow is unusually cheap, because OpenSSL 3.5.1 is already
vendored.** `curl-8_21_0:docs/HTTP3.md:38-40`: *"Building curl with ngtcp2 involves 3 components:
`ngtcp2` itself, `nghttp3` and a QUIC supporting TLS library."* And `:52`: *"OpenSSL v3.5.0+
requires *ngtcp2* v1.12.0+. Earlier versions do not work."* Flow already ships OpenSSL 3.5.1, so
the delta is two new static libraries (nghttp3, ngtcp2 ≥ 1.12.0) plus
`--with-ngtcp2=… --with-nghttp3=…` on the curl configure line
(`curl-8_21_0:docs/HTTP3.md:93`). **Evidence: strong.**

**Claim 1.10 — `CURL_HTTP_VERSION_3` vs `_3ONLY`, and Alt-Svc discovery.**
Both constants exist in the vendored header: `CURL_HTTP_VERSION_3 = 30L` documented in-header as
*"Use HTTP/3, fallback to HTTP/2 or HTTP/1.1"* and `CURL_HTTP_VERSION_3ONLY = 31L` as *"Use HTTP/3
without fallback"* (`VendorBuild/prefix/arm64/include/curl/curl.h:2322`, `:2326`). The fallback for
`_3` is not a simple retry — it is **HTTPS eyeballing**, described in
`curl-8_21_0:docs/HTTP3.md:259-289`:

> The `happy-eyeballs-timeout-ms` value is the **hard** timeout, meaning after that time expired, a
> TLS connection is opened in addition to negotiate HTTP/2 or HTTP/1.1. At half of that value -
> currently - is the **soft** timeout. The soft timeout fires, when there has been **no data at
> all** seen from the server on the HTTP/3 connection.
>
> Without you specifying anything, the hard timeout is 200ms and the soft is 100ms

This is the safe way to try H3: worst case costs 100–200 ms per connection, and *"The whole
transfer only fails, when **both** QUIC and TLS+TCP fail to handshake or time out."*
`CURLOPT_ALTSVC` (a cache file path) plus `CURLOPT_ALTSVC_CTRL` bits `CURLALTSVC_H1/H2/H3`
(`…/curl.h:1034-1037`, `:2141`, `:2144`) let curl learn `Alt-Svc: h3=…` advertisements across runs.
Alt-svc **is** compiled into Flow's curl (`alt-svc` appears in the feature list) but Flow does not
set `CURLOPT_ALTSVC` anywhere — grep of `Sources/` returns no hits.

Three details that matter if this is ever wired up
(<https://curl.se/libcurl/c/CURLOPT_ALTSVC.html>, <https://curl.se/libcurl/c/CURLOPT_ALTSVC_CTRL.html>):

- **The engine is off by default.** `CURLOPT_ALTSVC_CTRL` defaults to *"0 - Alt-Svc handling is
  disabled"*, and `CURLOPT_ALTSVC` defaults to *"NULL. The alt-svc cache is not read nor written to
  file."*
- **Setting the cache path alone is enough to enable it**: *"If CURLOPT_ALTSVC is set,
  CURLOPT_ALTSVC_CTRL gets a default value corresponding to CURLALTSVC_H1 | CURLALTSVC_H2 |
  CURLALTSVC_H3 - the HTTP/2 and HTTP/3 bits are only set if libcurl was built with support for
  those versions."*
- **Alt-Svc loses to connection reuse**: *"Alternative services are only used when setting up new
  connections. If there exists an existing connection to the host in the connection pool, then that
  is preferred."* For Flow, which opens many fresh segment connections and shares a connection cache
  via `CURLOPT_SHARE`, this interaction would need testing rather than assuming.

**Evidence: strong.**

### Area 1 verdict

HTTP/3 is **not** the answer to this bottleneck. The bottleneck is loss-limited per-flow throughput,
and QUIC does not change the per-flow scaling law — it gives one congestion controller per
connection, exactly as TCP does. Its genuine advantages (better loss recovery, fewer spurious
retransmits) are second-order at this loss rate, and its headline advantage (no inter-stream HOL
blocking) is irrelevant to a design that does not multiplex. If H3 is ever built, it must be
**H3 with N parallel connections**, not H3 with N streams.

**Weak spots in this area:** I could not find a primary source quantifying H3-vs-H2 throughput on a
lossy high-RTT path. Also unquantified: QUIC's userspace-CPU cost versus kernel TCP on arm64, and
whether any given international path throttles or blocks UDP/443 — both would need measurement, not
literature.

---

## Area 2 — HTTP/2 multiplexing vs one connection per range

### Is the repo's `CURLPIPE_NOTHING` reasoning correct?

The repo comment (`Sources/CCurl/DMCurlSupport.c:1431-1433`) reads:

> Segmented ranges must each own a TCP connection: with the default `CURLPIPE_MULTIPLEX`, HTTP/2
> servers get all segments folded onto one connection and per-connection throttles defeat the
> parallelism.

**Claim 2.1 — The conclusion is correct, and the strongest reason is one the comment does not
state.** The comment blames "per-connection throttles". The more fundamental reason is that all
multiplexed streams share **one TCP congestion window** — which, per Area 0, is precisely the
scarce resource on this path. Multiplexing 8 ranges onto one connection would take Flow from 8
congestion controllers back to 1, i.e. from ~14 MB/s to ~1 MB/s. **Evidence: strong.** The comment
is not wrong, it is under-argued; it would be worth strengthening so a future reader does not
"optimise" it away.

**Claim 2.2 — HTTP/2 flow control adds a second, independent limiter on top of TCP.**
RFC 9113 §5.2: *"Flow control is used for both individual streams and the connection as a whole."*
§5.2.1: *"Flow control is specific to a connection. HTTP/2 flow control operates between the
endpoints of a single hop and not over the entire end-to-end path"* and *"Of the frames specified
in this document, only DATA frames are subject to flow control."*
(<https://www.rfc-editor.org/rfc/rfc9113.html#section-5.2>). Both windows start small: §5.2.1 —
*"The initial value for the flow-control window is 65,535 octets for both new streams and the
overall connection."* §6.5.2 — `SETTINGS_INITIAL_WINDOW_SIZE` *"The initial value is 2^16−1 (65,535)
octets."* **Evidence: strong.**

**Claim 2.3 — `SETTINGS_MAX_CONCURRENT_STREAMS` has no default limit in the spec.**
RFC 9113 §6.5.2: *"Initially, there is no limit to this value."*
(<https://www.rfc-editor.org/rfc/rfc9113.html#section-6.5.2>). So the practical stream cap is
whatever the server advertises — commonly 100–128, but that is server policy, not a standard.
Flow cannot rely on any particular number. **Evidence: strong for the spec statement; the
"commonly 100–128" figure is [NO PRIMARY SOURCE FOUND] and should not be relied on.**

**Claim 2.4 — RFC 9113 does not forbid multiple connections; it only notes fewer are possible.**
§1.5: *"The resulting protocol is more friendly to the network because fewer TCP connections can be
used in comparison to HTTP/1.x."* That is a stated benefit, not a requirement. Nothing in RFC 9113
prohibits a client opening N connections to one origin. **Evidence: strong.**

### Does negotiating h2 without multiplexing cost anything? — a promising lead that did not survive

**Claim 2.5 — Flow negotiates HTTP/2 *and* refuses to multiplex, so every segment pays h2's
flow-control machinery for a single stream.** `Sources/CCurl/DMCurlSupport.c:123` sets
`CURL_HTTP_VERSION_2TLS`, so every segment connection is an h2 connection carrying exactly one
stream. curl advertises an initial per-stream window of only 64 KiB:

- `curl-8_21_0:lib/http2.c:70` — `#define H2_STREAM_WINDOW_SIZE_INITIAL  (64 * 1024)`
- `curl-8_21_0:lib/http2.c:221-223` — that value is placed in `NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE`
  in the initial SETTINGS frame
- `curl-8_21_0:lib/http2.c:66` — the stream window is later raised to
  `H2_STREAM_WINDOW_SIZE_MAX (10 * 1024 * 1024)`
- `curl-8_21_0:lib/http2.c:898` — the raise happens in `h2_xfer_write_resp_hd`, i.e. **only once the
  response headers have arrived**

The connection-level window is not a concern: `curl-8_21_0:lib/http2.c:2469-2470` sets it to
`HTTP2_HUGE_WINDOW_SIZE`, defined at `:84` as `(100 * H2_STREAM_WINDOW_SIZE_MAX)` = 1 GiB.

So per segment the server may send at most 64 KiB until curl's `WINDOW_UPDATE` reaches it. In
isolation that would cap the opening interval at `64 KiB / 0.127 s ≈ 0.52 MB/s` — suspiciously close
to the observed per-connection rate, which is what makes this worth checking carefully.

**Claim 2.5b — but TCP slow start is slower than the h2 window opens, so the h2 window almost never
binds. This corrects the obvious reading of Claim 2.5.**
macOS starts every connection at **IW10**: `xnu-12377.121.6:bsd/netinet/tcp_cc.h:284-288` —
`tcp_initial_cwnd(tp) { return TCP_CC_CWND_INIT_PKTS * tp->t_maxseg; }` with
`:232` — `#define TCP_CC_CWND_INIT_PKTS 10`. This matches RFC 6928
(<https://www.rfc-editor.org/rfc/rfc6928.html>). With `MSS = 1448 B`, and assuming ideal doubling
per RTT (delayed ACKs make real growth *slower*, which only strengthens the conclusion):

| data RTT | cwnd | vs. the 64 KiB h2 window (45.3 MSS) |
| --- | --- | --- |
| 1 | 10 MSS = 14,480 B | far below |
| 2 | 20 MSS = 28,960 B | far below |
| 3 | 40 MSS = 57,920 B | still below |
| 4 | 80 MSS = 115,840 B | **first exceeds** |

curl fires the `WINDOW_UPDATE` from `h2_xfer_write_resp_hd` (`lib/http2.c:898`) — i.e. the moment
response *headers* are written, at the start of data flow — so the window is open to 10 MiB by
roughly data-RTT 2, while cwnd does not reach 64 KiB until roughly data-RTT 4. **The congestion
window is the binding constraint throughout the ramp; the h2 window is not.** And in steady state
the connection sits at 0.6–1 MB/s, which needs only 76–127 KB of window — an order of magnitude
under the 10 MiB curl settles on.

**Evidence: strong** — curl source, xnu source, and arithmetic. **Consequence: the h2-versus-HTTP/1.1
delta on this path is probably near zero, and the earlier framing of "one extra RTT per segment"
overstates it.** The residual cost of h2 here is small and hard to sign: extra framing, one SETTINGS
exchange, and the `WINDOW_UPDATE` itself, against h2's header compression. The narrow case where the
h2 window *could* bind is a connection whose cwnd is already large — a warm reused connection — but
Flow deliberately does not share the connection cache (see `CURLOPT_SHARE` below), so every segment
connection starts cold. **This remains worth an A/B measurement, but it is now a low-expected-value
one, not a suspected bottleneck.**

**Claim 2.6 — the option is `CURLMOPT_MAX_CONCURRENT_STREAMS` (a *multi* option), it advertises
rather than caps, and it is irrelevant to Flow.**
First, the naming: `CURLOPT_MAX_CONCURRENT_STREAMS` does not exist —
<https://curl.se/libcurl/c/CURLOPT_MAX_CONCURRENT_STREAMS.html> returns HTTP 404. The real option is
`CURLMOPT_MAX_CONCURRENT_STREAMS`, set with `curl_multi_setopt()`
(<https://curl.se/libcurl/c/CURLMOPT_MAX_CONCURRENT_STREAMS.html>), default `100`.

Second, the semantics. The man page says only *"The set number is used as the maximum number of
concurrent streams libcurl should support on connections done using HTTP/2 or HTTP/3"* — which does
**not** distinguish advertising from capping, and neither `curl.1` nor the everything.curl.dev book
resolves it (the book never mentions the option). **The docs are genuinely ambiguous here.** The
source is not: `curl-8_21_0:lib/http2.c:220-221` feeds the value straight into the SETTINGS frame
curl *sends*:

```c
  iv[0].settings_id = NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS;
  iv[0].value = Curl_multi_max_concurrent_streams(data->multi);
```

Per RFC 9113 §6.5.2 a SETTINGS value sent by an endpoint constrains what its *peer* may do, so this
is what curl tells the **server** about streams the *server* may open toward it. It does not cap
what curl opens. **Evidence: strong from source; the documentation alone would not settle it.**
Either way it is irrelevant to Flow, which multiplexes nothing.

**Claim 2.7 — `CURLMOPT_MAX_HOST_CONNECTIONS` is a cap Flow should be aware of but currently
leaves at default.** Flow sets no connection-pool limits: grep of `Sources/` finds no
`CURLMOPT_MAX_HOST_CONNECTIONS`, `CURLMOPT_MAXCONNECTS`, `CURLMOPT_MAX_TOTAL_CONNECTIONS`, or
`CURLOPT_MAXCONNECTS`. See Area 5 for the documented defaults.

### When *would* multiplexing beat separate connections?

**Claim 2.8** — Multiplexing wins when connection setup dominates transfer time: many small objects,
or a server/CDN that rate-limits per *connection* rather than per *client*. It loses whenever the
bottleneck is the congestion window, which is exactly the high-RTT lossy case. For Flow's workload —
a few very large objects on a lossy long-haul path — separate connections are correct.
**Evidence: strong for the mechanism; the "many small objects" case is a design-space observation,
not a measured claim about Flow.**

### Area 2 verdict

**The repo's `CURLPIPE_NOTHING` decision is right, and should stay.** The comment justifying it is
directionally correct but cites the weaker of the two reasons — strengthen it to name the shared
congestion window, so nobody undoes it.

The h2-versus-HTTP/1.1 question (Claim 2.5) looked like a real lever and, on inspection, is not:
TCP slow start from IW10 keeps cwnd below the 64 KiB h2 window for the first three round trips,
by which time curl has already raised the window to 10 MiB (Claim 2.5b). Recording the negative
result matters as much as the positive ones — the 0.52 MB/s number that 64 KiB / 127 ms produces is
close enough to the observed 0.6–1 MB/s to be a very convincing false lead.

---

## Area 3 — Darwin TCP tuning available to a userspace app

### Does `setsockopt(SO_RCVBUF)` disable macOS receive-buffer autotuning?

**Yes. Definitively, from xnu source.**

**Claim 3.1 — `SO_RCVBUF` clears `SB_AUTOSIZE`.**
`xnu-12377.121.6:bsd/kern/uipc_socket.c:4885-4896`, inside `sosetopt`:

```c
case SO_RCVBUF: {
        struct sockbuf *sb = …&so->so_rcv;
        if (sbreserve(sb, (u_int32_t)optval) == 0) {
                error = ENOBUFS;
                goto out;
        }
        sb->sb_flags |= SB_USRSIZE;
        sb->sb_flags &= ~SB_AUTOSIZE;
        sb->sb_idealsize = (u_int32_t)optval;
```

**Claim 3.2 — With `SB_AUTOSIZE` cleared, the autotuner refuses to grow the buffer.**
`xnu-12377.121.6:bsd/netinet/tcp_input.c:1042-1063`, in `tcp_sbrcv_grow`:

```c
	/*
	 * Do not grow the receive socket buffer if
	 * - auto resizing is disabled, globally or on this socket
	 …
	 */
	if (tcp_do_autorcvbuf == 0 ||
	    (sbrcv->sb_flags & SB_AUTOSIZE) == 0 ||
	    sbrcv->sb_hiwat >= tcp_autorcvbuf_max ||
	    …) {
		/* Can not resize the socket buffer, just return */
		goto out;
	}
```

So the repo's `setsockopt(SO_RCVBUF, 2 MiB)` at `Sources/CCurl/DMCurlSupport.c:112` **pins the
receive buffer at 2 MiB for the life of every connection.** Evidence: strong.

**Claim 3.3 — and it also *lowers the negotiated window scale*, which is the part that makes it a
strict downgrade.** This is the decisive finding. `xnu-12377.121.6:bsd/netinet/tcp_subr.c:3894-3916`:

```c
uint8_t
tcp_get_max_rwinscale(struct tcpcb *tp, struct socket *so)
{
	…
	rcv_wscale = MAX((uint8_t)tcp_win_scale, tp->request_r_scale);
	maxsockbufsize = ((so->so_rcv.sb_flags & SB_USRSIZE) != 0) ?
	    so->so_rcv.sb_hiwat : tcp_autorcvbuf_max;

	while (rcv_wscale < TCP_MAX_WINSHIFT &&
	    ((TCP_MAXWIN + 1) << rcv_wscale) < maxsockbufsize) {
		rcv_wscale++;
	}
```

Read the ternary carefully. **If the app set `SO_RCVBUF` (`SB_USRSIZE`), the window scale is sized
from the app's value. Otherwise it is sized from `tcp_autorcvbuf_max`.** Apple's own comment above
the function (`:3889-3892`) says it outright: *"Compute receive window scaling that we are going to
request for this connection based on sb_hiwat. Try to leave some room to potentially increase the
window size upto a maximum defined by the constant tcp_autorcvbuf_max."*

Working the loop with this machine's values (`net.inet.tcp.win_scale_factor = 3`,
`TCP_MAXWIN = 65535`, `TCP_MAX_WINSHIFT = 14` from
`MacOSX26.5.sdk/usr/include/netinet/tcp.h:205,208`):

| configuration | `maxsockbufsize` | resulting `rcv_wscale` | max advertised window | ceiling @ 127 ms |
| --- | --- | --- | --- | --- |
| **default** (autotune, no `SO_RCVBUF`) | 4 MiB (`autorcvbufmax`) | **6** | 4,194,240 B | **33.0 MB/s** |
| **Flow today** (`SO_RCVBUF` = 2 MiB) | 2 MiB (`sb_hiwat`) | **5** | 2,097,120 B | **16.5 MB/s** |

**Evidence: strong** — xnu source plus arithmetic; the sysctl values are measured on macOS 26.5.2.

### Platform defaults measured on macOS 26.5.2 (arm64)

| sysctl | value |
| --- | --- |
| `net.inet.tcp.doautorcvbuf` | `1` (autotuning on) |
| `net.inet.tcp.autorcvbufmax` | `4194304` (4 MiB) |
| `net.inet.tcp.autosndbufmax` | `4194304` (4 MiB) |
| `kern.ipc.maxsockbuf` | `8388608` (8 MiB) |
| `net.inet.tcp.recvspace` | `131072` (128 KiB — the autotuner's *starting* size) |
| `net.inet.tcp.sendspace` | `131072` (128 KiB) |
| `net.inet.tcp.win_scale_factor` | `3` |

`net.inet.tcp.autorcvbufhigh`, `net.inet.tcp.doautosndbuf` and `net.inet.tcp.rfc1323` do not exist
on this release (`sysctl: unknown oid`). Anyone repeating this should re-measure rather than quote
these — they are one machine's values, not a documented contract.

### Is Flow's 2 MiB `SO_RCVBUF` helping or hurting? — plainly

**It is hurting, mildly, and it is buying nothing.** Three separate statements, in order of
confidence:

1. **It is not the current bottleneck.** 16.5 MB/s ≫ the ~1 MB/s a single connection achieves.
   Removing it will probably not change today's measured throughput at all. *(strong)*
2. **It is nevertheless a strict downgrade of the ceiling**: window scale 5 instead of 6, buffer
   pinned at 2 MiB instead of autotuning to 4 MiB. It halves the headroom for the case Flow is
   trying to reach — a fast, less lossy path where a single connection *could* run at 20–30 MB/s.
   *(strong)*
3. **The usual justification for setting it does not apply here.** The reason apps set `SO_RCVBUF`
   from a sockopt callback is that the callback runs before `connect()` — curl documents exactly
   that: *"this callback function gets called by libcurl when the socket has been created, but
   before the connect call to allow applications to change specific socket options"*
   (<https://curl.se/libcurl/c/CURLOPT_SOCKOPTFUNCTION.html>) — so the buffer size is in place when
   the SYN's window scale is computed. The trick is real and Flow implements it correctly. It is
   simply **pointless on macOS**: with autotuning left alone, `tcp_get_max_rwinscale` already
   derives the scale from `tcp_autorcvbuf_max` (4 MiB), which is *larger* than what Flow requests.
   Flow pays the cost of the trick and gets a worse result than doing nothing. *(strong — this is
   the ternary at `tcp_subr.c:3901-3902`)*

There is **no supported way to raise a floor without disabling autotuning** — `SB_USRSIZE` and
`SB_AUTOSIZE` are mutually exclusive in `sosetopt`. It is all or nothing.

Two secondary notes. `sbreserve` is checked and can fail (returning `ENOBUFS`) — the requested size
is bounded by `kern.ipc.maxsockbuf` (8 MiB here), so a future bump past that would silently fail
because `Sources/CCurl/DMCurlSupport.c:112` discards the return value with `(void)`.

And on memory: `sbreserve` sets `sb_hiwat`, a **ceiling**, not an allocation — macOS socket buffers
are mbuf-backed and fill on demand, so pinning 2 MiB does not commit 2 MiB per connection. The real
difference between pinned and autotuned is the worst-case queueing bound, not resident memory. *(An
earlier draft of this document claimed "32 × 2 MiB = 64 MiB allocated"; that was wrong.)*
Recommendation 2 rests on the window-scale finding, not on a memory argument.

### `SO_NET_SERVICE_TYPE` — the repo's use of it contradicts Apple's own header

`Sources/CCurl/DMCurlSupport.c:101-109` sets `NET_SERVICE_TYPE_RD` with the comment *"Mark sockets
as high-priority interactive bulk transfers (Apple net service type) … closest equivalent to
IDM-style priority"* and *"Responsive Data — prefer over background apps"*.

**Claim 3.4 — This is the exact behaviour Apple's header tells you not to attempt.**
`MacOSX26.5.sdk/usr/include/sys/socket.h:210-222`, verbatim:

> There is no point in attempting to game the system and use a Network Service Type that does not
> correspond to the actual traffic characteristic but one that seems to have a higher precedence.
> The reason is that for service classes that have lower tolerance for delay and jitter, the queues
> size is lower than for service classes that are more tolerant to delay and jitter.
>
> For example using a voice service type for bulk data transfer will lead to disastrous results as
> soon as congestion happens because the voice queue overflows and packets get dropped.

**Claim 3.5 — `RD` is documented for interactive request/response traffic, not bulk transfer.**
Same header, `:241-245`: *"NET_SERVICE_TYPE_RD — "Responsive Data", a notch higher than "Best
Effort", medium delay tolerant, elastic & inelastic flow, bursty, long-lived. E.g. email, instant
messaging, for which there is a sense of interactivity and urgency (user waiting for output)."*
The service class that names Flow's workload is the one immediately above it, `:236-239`:
*"NET_SERVICE_TYPE_BK — "Background", high delay tolerant, loss tolerant. elastic flow, variable
size & long-lived. E.g: non-interactive network bulk transfer like synching or backup."*

**Claim 3.6 — the marking mostly does nothing anyway.** Same header, `:228-231`: *"When system
detects the outgoing interface belongs to a DiffServ domain that follows the recommendation of the
IETF draft "Guidelines for DiffServ to IEEE 802.11 Mapping", the packet will marked at layer 3 with
a DSCP value that corresponds to Network Service Type."* On an international transit path, DSCP is
routinely bleached or ignored, and `SO_NETSVC_MARKING_LEVEL` (`:288-292`) exists precisely because
system policy may restrict marking to `NETSVC_MRKNG_LVL_L3L2_BK`. Also note the classes derive from
RFC 4594 (<https://www.rfc-editor.org/rfc/rfc4594.html>), a *configuration guideline*, not a
guarantee any network honours.

**Verdict on `NET_SERVICE_TYPE_RD`:** the repo's belief that it buys "IDM-style priority" is not
supported by the header that defines it, and the header explicitly warns against the reasoning. The
honest options are (a) drop the call and take `BE` (best effort, the default, and the accurate
classification for a user-initiated large download), or (b) keep it only for a genuinely
user-visible foreground download and use `BK` for background/queued ones — which is what the
taxonomy is *for*. **Evidence: strong (Apple SDK header). The claim that it currently helps is
unsupported; I found no primary source showing measurable benefit. [NO PRIMARY SOURCE FOUND]**

### `TCP_NOTSENT_LOWAT`

**Claim 3.7 — send-side only; near-irrelevant to a download manager.**
`MacOSX26.5.sdk/usr/include/netinet/tcp.h:246`: `#define TCP_NOTSENT_LOWAT 0x201 /* Low water mark
for TCP unsent data */`. The xnu implementation `tcp_notsent_lowat_check`
(`xnu-12377.121.6:bsd/netinet/tcp_subr.c:3919+`) inspects unsent data in the **send** socket buffer
to decide writability. It controls how much unsent data an app keeps queued for *upload* — useful
for latency-sensitive senders, of no value to a downloader. Flow should not set it.
**Evidence: strong.** Worth stating explicitly so nobody adds it as cargo cult.

### Congestion control on macOS

**Claim 3.8 — CUBIC is the default; NewReno and LEDBAT are not.**
`xnu-12377.121.6:bsd/netinet/tcp_subr.c:1369-1385`:

```c
	if (tcp_use_newreno) {
		/* use newreno by default */
		tp->tcp_cc_index = TCP_CC_ALGO_NEWRENO_INDEX;
#if (DEVELOPMENT || DEBUG)
	} else if (tcp_use_ledbat) {
		/* use ledbat for testing */
		tp->tcp_cc_index = TCP_CC_ALGO_BACKGROUND_INDEX;
#endif
	} else {
		/* Set L4S state even if ifp might be NULL */
		tcp_set_l4s(tp, inp->inp_last_outifp);
		if (tp->l4s_enabled) {
			tp->tcp_cc_index = TCP_CC_ALGO_PRAGUE_INDEX;
		} else {
			tp->tcp_cc_index = TCP_CC_ALGO_CUBIC_INDEX;
		}
	}
```

Note the LEDBAT branch is `#if (DEVELOPMENT || DEBUG)` — **unreachable on a release kernel**, and
its own comment says *"use ledbat for testing"*. Apple labels the default in the header too —
`xnu-12377.121.6:bsd/netinet/tcp_cc.h:111` reads
`#define TCP_CC_ALGO_CUBIC_INDEX         3 /* default CC algorithm */`. Measured on this machine:
`net.inet.tcp.use_newreno = 0`, `net.inet.tcp.use_ledbat = 0`, and the live socket counters
`net.inet.tcp.cubic_sockets = 75` versus `net.inet.tcp.newreno_sockets = 0` — CUBIC in practice, as
the source predicts. The registered algorithm table is at
`xnu-12377.121.6:bsd/netinet/tcp_cc.c:66-70`: NONE, NEWRENO, BACKGROUND (LEDBAT), CUBIC, **PRAGUE**.
**Evidence: strong (source comment, source logic, and live counters all agree).**

**Claim 3.9 — Prague/L4S is present but only engages on an L4S-capable path.** `tcp_set_l4s()`
gates it, and `net.inet.tcp.ledbat_plus_plus = 1`, `net.inet.tcp.rledbat = 1` are present on this
machine. An international transit path is very unlikely to be L4S-enabled end to end, so assume
CUBIC. **Evidence: strong for the code path; whether any real path enables it is
[NO PRIMARY SOURCE FOUND].**

**Consequence:** CUBIC is a loss-based controller. Its recovery from loss is faster than NewReno's
on high-BDP paths, but it is still `~1/√p`-shaped and still halves-ish on loss. **A userspace app
cannot select a different congestion controller per socket on macOS** — there is no documented
`setsockopt` equivalent of Linux's `TCP_CONGESTION`; I checked `netinet/tcp.h` in the macOS 26.5 SDK
and no such option exists. This is the deep reason parallel connections are the *only* lever
available to Flow at the transport layer. **Evidence: strong (absence verified in the SDK header).**

---

## Area 4 — How real download managers pick connection counts and chunk sizes

Source quality varies enormously here and is flagged per tool. Only aria2 has a fully documented
policy; XDM's exists only in code; IDM's is vendor self-description; ADM's is marketing.

### aria2 — the only fully documented policy

All from <https://aria2.github.io/manual/en/html/aria2c.html>.

| option | default | documented range |
| --- | --- | --- |
| `-s, --split` | **5** | manual states none; source: unbounded |
| `-x, --max-connection-per-server` | **1** | manual states none; source: **hard-capped at 16** |
| `-k, --min-split-size` | **20M** | *"Possible Values: 1M - 1024M"* |
| `-j, --max-concurrent-downloads` | **5** | unbounded |
| `--piece-length` | **1M** | — |
| `--stream-piece-selector` | `default` | — |

**Claim 4.1 — aria2's out-of-box behaviour on a single URL is ONE connection.** `--split` defaults
to 5 but `--max-connection-per-server` defaults to 1, and the `--split` text says *"The number of
connections to the same host is restricted by the --max-connection-per-server option."* The `-s 5`
default only bites when you supply five distinct mirrors. **Evidence: strong (both defaults quoted
from the manual); the combined conclusion is an inference from the two, not a quoted sentence.**
Relevant to Flow mostly as a benchmarking warning: "aria2 with defaults" is a single-connection
baseline, not a segmented one.

**Claim 4.2 — the split rule is a documented minimum-size rule, and it is strict.**
> aria2 does not split less than 2*SIZE byte range. For example, let's consider downloading 20MiB
> file. If SIZE is 10M, aria2 can split file into 2 range [0-10MiB) and [10MiB-20MiB) and download
> it using 2 sources(if --split >= 2, of course). If SIZE is 15M, since 2*15M > 20MiB, aria2 does
> not split file and download it using 1 source.

Effective piece count ≈ `min(--split, floor(size / --min-split-size))`, then clamped per host by
`-x`. With stock settings **a file under 40 MiB is never split at all**. **Evidence: strong.**

**Claim 4.3 — `-x` is capped at 16, and that cap is undocumented in the manual.**
`src/OptionHandlerFactory.cc:439-441` —
`NumberOptionHandler(PREF_MAX_CONNECTION_PER_SERVER, TEXT_MAX_CONNECTION_PER_SERVER, "1", 1, 16, 'x')`,
where the signature is `(pref, description, defaultValue, min, max, shortName)`
(`OptionHandlerImpl.h:83-85`) and `-1` means unbounded (`OptionHandlerImpl.cc:165`). `--split` and
`-j` pass `-1` as max, i.e. no ceiling. **Evidence: strong (source), and worth flagging because the
manual alone would let you believe `-x` is unbounded.**

**Claim 4.4 — aria2's default piece selector optimises for *fewer* connections.**
> default — Select a piece to reduce the number of connections established. This is reasonable
> default behavior because establishing a connection is an expensive operation.

**Evidence: strong.** Note this is the opposite of Flow's goal on a high-RTT path, where connection
setup cost is dwarfed by the per-flow congestion ceiling.

**Claim 4.5 — aria2 documents no prose politeness guidance.** Grepping the manual for
`polite|abuse|overload|too many connection|servers may limit` returns nothing. Its restraint is
structural — the `-x 1` default and Metalink deference (*"if Metalink defines the maxconnections
attribute lower than N, then aria2 uses the value of this lower value instead of N"*). **Evidence:
strong for the absence.**

### XDM — undocumented, but the source is readable

Repo `subhra74/xdm`, pinned at `1ca5a25aae007826c859c81bea494e7c102e1242`.

**Claim 4.6 — defaults are 8 segments / 3 parallel downloads; the UI allows up to 64 segments.**
`app/XDM/XDM.Core/Config.cs:122` — `public int MaxSegments { get; set; } = 8;`;
`:104` — `MaxParallelDownloads = 3`. UI ceiling: `Enumerable.Range(1, 64)` in both the WPF
(`NetworkSettingsView.xaml.cs:29`) and GTK (`SettingsDialog.cs:91`) settings dialogs.
**Evidence: strong (source). The README documents none of it** — it offers only the unsourced
*"increase download speeds up to 500%"*. **[WEAK]** for any README claim.

**Claim 4.7 — XDM's chunking is dynamic halving of the largest remaining piece, with a 256 KiB
floor.** `app/XDM/XDM.Core/Downloader/Progressive/HTTPDownloaderBase.cs`: `FindMaxChunk()`
(`:405-422`) scans for the largest `Length - Downloaded` and returns it only if
`max > 256 * 1024`; `:439` refuses to split when `rem < 256 * 1024`; `:443` takes `var len = rem / 2`.
`CreatePiece()` is called on piece completion (`:265`, `:307`), so a freed connection immediately
re-splits the biggest laggard. Connection cap enforced at `:313`. **Evidence: strong (source).**

*Naming trap worth recording:* `XDM.Core/Downloader/Adaptive/` is HLS/DASH adaptive **bitrate**
streaming, not adaptive connection management.

### IDM — vendor-documented algorithm, recommended (not enforced) connection count

**Claim 4.8 — IDM documents the same algorithm as XDM: dynamic in-half division of the largest
segment.** <https://www.internetdownloadmanager.com/support/segmentation.html>:
> IDM divides downloaded file on file segments dynamically, unlike other download accelerators that
> divide downloaded file in segments once just before download process starts.
> … When new connection becomes available IDM finds the largest segment to download and divide it in
> half. … IDM won't divide the segment only when its size is too small for this connection type.

**Evidence: medium — vendor self-description of a closed-source product, unverifiable.** It is
concrete and mechanism-level, which is why it rates above marketing, but it cannot be checked.

**Claim 4.9 — IDM publishes no enforced maximum connection count; 16–32 is a recommendation.**
<https://secure.internetdownloadmanager.com/register/new_faq/functions8.html>: *"Try to set
"Default max. conn. number" to 16 or 32. If you are using Dial-Up, try to set 1 or 2."* Two other
FAQ pages recommend dropping to 1 (transparent proxy; slow IDE drive). A sweep of all 136 linked
FAQ pages found no stated cap. **Do not cite "IDM caps at 32" — that is a suggestion, not a limit.**
**Evidence: medium.** The *"accelerate downloads by up to 8 times"* claim on
`/features2.html` is **[WEAK — marketing, unsourced]**.

### ADM (Android) — marketing only

**Claim 4.10 — "16 parts", 5 simultaneous files.** Play Store listing
<https://play.google.com/store/apps/details?id=com.dv.adm>: *"downloading from internet up to five
files simultaneously"*, *"accelerated downloading by using multithreading (16 parts)"*. The listing
also claims a *"smart algorithm for increased speed of downloading"* with **no mechanism described**.
Closed source, nothing to verify. **[WEAK — marketing]. Do not read "smart algorithm" as adaptive.**

### Adaptive schemes — **no primary source found**

**Claim 4.11 — no download manager checked documents adding or removing connections based on
measured throughput at runtime.** This is a clean negative, checked against:

- **curl** (<https://curl.se/docs/manpage.html>) — `--parallel-max` default 50, max 65535;
  `--parallel-max-host` default 0/unlimited. Both apply to *multiple URLs*, not segments of one
  file; curl does not segment a single file at all. Grep for adaptive language: zero hits.
- **wget2** (<https://gitlab.com/gnuwget/wget2/-/blob/master/docs/wget2.md>) — `--chunk-size`
  *"By default it's set on 0/off"*, `--max-threads` default 5. Segmentation is off by default.
- **XDM source** — splitting is driven by **bytes remaining**, never by observed rate.
- **IDM** — *"helps other slowly working connections"* sounds adaptive, but the documented rule is
  *"dividing the largest segment in half"*: a remaining-bytes criterion that correlates with
  slowness without measuring it. **Do not cite IDM as throughput-adaptive.**
- **aria2** — three adjacent mechanisms, none of which is per-file adaptive connection count:
  - `--optimize-concurrent-downloads` (default `false`) adapts concurrent **jobs**, not connections
    within a file: *"aria2 uses the download speed observed in the previous downloads to adapt the
    number of downloads launched in parallel according to the rule N = A + B Log10(speed in Mbps)"*,
    *"The default values (A=5, B=25) lead to using typically 5 parallel downloads on 1Mbps networks
    and above 50 on 100Mbps networks."*
  - `--uri-selector` (default `feedback`) picks the fastest **mirror** by measured speed.
  - `--lowest-speed-limit` (default 0) drops a connection below a **static user threshold** — this
    is what Flow's `CURLOPT_LOW_SPEED_LIMIT` already does.

The closest documented precedent to throughput-driven concurrency anywhere is aria2's
`N = A + B·log₁₀(Mbps)`, and it governs job parallelism, not segment count. **If Flow wants adaptive
segment scaling, it would be building something none of these tools documents — there is no prior
art to copy, only a formula shape to borrow.** **Evidence: strong for the negative** (five sources
checked, including two open-source codebases).

### What the HTTP standards actually say about per-server connections

**Claim 4.12 — the "2 connections per server" rule was deleted in 2014 and is not in current HTTP.**
RFC 2616 §8.1.4 had it: *"A single-user client SHOULD NOT maintain more than 2 connections with any
server or proxy."* RFC 7230 Appendix A.2 removed it in one sentence:
> The limit of two connections per server has been removed.

(<https://www.rfc-editor.org/rfc/rfc7230.html#appendix-A.2>). **Evidence: strong.**

**Claim 4.13 — the current text is RFC 9112 §9.4, and it is advisory with an explicit congestion
warning.** <https://www.rfc-editor.org/rfc/rfc9112.html#section-9.4>:
> A client ought to limit the number of simultaneous open connections that it maintains to a given
> server.
>
> Previous revisions of HTTP gave a specific number of connections as a ceiling, but this was found
> to be impractical for many applications. As a result, this specification does not mandate a
> particular maximum number of connections but, instead, encourages clients to be conservative when
> opening multiple connections.
>
> … using multiple connections can cause undesirable side effects in congested networks. Using
> larger numbers of connections can also cause side effects in otherwise uncongested networks,
> because their aggregate and initially synchronized sending behavior can cause congestion that
> would not have been present if fewer parallel connections had been used.
>
> Note that a server might reject traffic that it deems abusive or characteristic of a
> denial-of-service attack, such as an excessive number of open connections from a single client.

**Note the citation correction: this is RFC 9112 (HTTP/1.1), §9.4 — *not* RFC 9110.** A grep of
RFC 9110 for `ought to limit`, `connections to a given server` and `per server` returns zero hits;
connection management is not in the Semantics document. **Evidence: strong.**

This cuts both ways for Flow. There is no numeric ceiling to comply with, so a 32-segment fan-out
violates no standard. But RFC 9112 §9.4 names exactly the two risks Flow should design against:
self-inflicted congestion from synchronised parallel senders, and servers treating the fan-out as
abusive. The `hostMaxSegments` clamp at `Sources/TransferCore/SegmentedTransfer.swift:36-37` is the
right shape of mitigation.

### The convergence worth noticing

**IDM's documented algorithm and XDM's source implement the same design, independently:** cap
concurrent connections at N; when a connection frees, find the piece with the most bytes
outstanding and split it in half; refuse to split below a floor (XDM: 256 KiB; IDM: unspecified,
*"too small for this connection type"*). Two independent primary sources — one with a concrete
constant — for **dynamic work-stealing over fixed upfront N-way division**.

Flow's design is a close cousin: it pre-tiles finely (≤1024 chunks, ≥4 MiB each,
`Sources/TransferCore/SegmentedTransfer.swift:55-63`) and refills idle connections from a pending
queue, which achieves the same "one slow connection only holds a small tile" property without
mid-flight splitting. The repo already knows the difference —
`SegmentedTransfer.swift:44-52` notes that taking the tail off a *live* connection needs a
safe-zone split, which libcurl's fixed `Range:` request makes a protocol change. **The one concrete
gap: Flow's minimum tile is 4 MiB; XDM's floor is 256 KiB — 16× finer.** At 0.6 MB/s a 4 MiB tile
is a ~7 s tail; a 256 KiB tile is ~0.4 s.

---

## Area 5 — libcurl options that materially affect bulk download throughput

### `CURLOPT_BUFFERSIZE` — the repo is half right and half wrong

Flow sets `curl_easy_setopt(easy, CURLOPT_BUFFERSIZE, 1024L * 1024L)` at
`Sources/CCurl/DMCurlSupport.c:120`.

**Claim 5.1 — 1 MiB is accepted, not clamped. The maximum in curl 8.21.0 is 10 MiB.**
`curl-8_21_0:lib/setopt.c:878-882`:

```c
  case CURLOPT_BUFFERSIZE:
    result = value_range(&arg, 0, READBUFFER_MIN, READBUFFER_MAX);
    if(!result)
      s->buffer_size = (unsigned int)arg;
```

`curl-8_21_0:lib/urldata.h:116-118` — `READBUFFER_SIZE CURL_MAX_WRITE_SIZE` (default),
`READBUFFER_MAX CURL_MAX_READ_SIZE`, `READBUFFER_MIN 1024`. And
`VendorBuild/prefix/arm64/include/curl/curl.h:255` — `#define CURL_MAX_READ_SIZE (10 * 1024 * 1024)`.
`value_range` (`curl-8_21_0:lib/setopt.c:810-819`) **clamps silently** rather than erroring, so an
over-large value would be capped without any signal. 1 MiB is comfortably inside 10 MiB.

The man page agrees: *"This buffer size is by default CURL_MAX_WRITE_SIZE (16kB). The maximum buffer
size allowed to be set is CURL_MAX_READ_SIZE (10MB). The minimum buffer size allowed to be set is
1024."* and *"This is treated as a request, not an order. You cannot be guaranteed to actually get
the given size."* (<https://curl.se/libcurl/c/CURLOPT_BUFFERSIZE.html>).
**Evidence: strong (source and docs agree).**

*Note for anyone carrying older curl knowledge: the same page's History section says "The maximum
size was 512kB until 7.88.0." That 512 KiB ceiling is what most existing writing about this option
describes, and it does not apply here.*

**Claim 5.2 — `CURLOPT_BUFFERSIZE` does NOT change the size passed to the write callback. If the
repo assumes it does, that assumption is wrong.**
`curl-8_21_0:lib/cw-out.c:148-157` — for body output the per-call maximum is hard-coded:

```c
  case CW_OUT_BODY:
  case CW_OUT_BODY_0LEN:
    *pwcb = data->set.fwrite_func;
    *pwcb_data = data->set.out;
    *pmax_write = CURL_MAX_WRITE_SIZE;
```

and `curl-8_21_0:lib/cw-out.c:255` applies it: `wlen = max_write ? CURLMIN(blen, max_write) : blen;`
with `CURL_MAX_WRITE_SIZE 16384` (`VendorBuild/prefix/arm64/include/curl/curl.h:265`).
**Body data reaches the write callback in ≤16 KiB chunks regardless of `CURLOPT_BUFFERSIZE`.**

The documentation does not contradict this — it simply never claims the converse, which is worth
recording because the absence is easy to misread as support. `CURLOPT_WRITEFUNCTION` states *"The
maximum amount of body data that is passed to the write callback is defined in the curl.h header
file: CURL_MAX_WRITE_SIZE (the usual default is 16K)"* and **never mentions `CURLOPT_BUFFERSIZE`**
(<https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html>). `CURLOPT_BUFFERSIZE`'s only statement
about the callback runs *downward only*: *"The main point of this would be that the write callback
gets called more often and with smaller chunks"* — i.e. a **smaller** buffer yields smaller
callbacks; there is no upward claim. Note also that `CURL_MAX_WRITE_SIZE` is a compile-time constant
in `curl.h`, not a runtime knob — the only way to change it is to rebuild libcurl.
**Evidence: strong (source is decisive; docs are consistent with it).**

**Claim 5.3 — What `CURLOPT_BUFFERSIZE` actually does is bound the network read size, as a
*ceiling*, not a target.** `curl-8_21_0:lib/transfer.c:842-853`:

```c
CURLcode Curl_xfer_recv(struct Curl_easy *data, char *buf, size_t blen, size_t *pnrcvd)
{
  …
  if(curlx_uitouz(data->set.buffer_size) < blen)
    blen = curlx_uitouz(data->set.buffer_size);
  return Curl_conn_recv(data, data->conn->recv_idx, buf, blen, pnrcvd);
```

The buffer itself is one shared allocation **per multi handle**, not per easy handle
(`curl-8_21_0:lib/multi.c:3989-4011`, `Curl_multi_xfer_buf_borrow`, guarded by
`xfer_buf_borrowed` so only one transfer holds it at a time). So 1 MiB costs 1 MiB per multi handle,
not 1 MiB × 32 segments — the memory objection does not apply. **Evidence: strong.**

**Claim 5.4 — checked: no code in Flow depends on the write-callback chunk size, so the wrong belief
costs nothing today.** `DMCurlWriteCallback` (`Sources/CCurl/DMCurlSupport.c:777-846`) is
chunk-size-agnostic. It takes `total = size * nmemb` and loops `pwrite(ctx->fd, cursor, remaining,
ctx->offset + ctx->written)` until the buffer is drained. There is no staging buffer, no assumption
about a minimum or maximum chunk, and nothing sized from 1 MiB. **The mistaken belief, if it exists,
lives in reasoning about the option — not in code that would break.** Evidence: strong (read the
callback).

One observation from reading it, offered as a lead rather than a finding: the callback invokes
`ctx->progressCallback(...)` **once per `pwrite`** (`:836`). At a 16 KiB delivery granularity and
~1.75 MB/s per segment that is roughly 110 progress hops per second per segment, or ~900/s across a
32-segment job. Whether that matters depends entirely on what `progressCallback` does — this
document did not trace it, and it is a profiling question, not a protocol one.
**[Not investigated — flagged only.]**

**Net effect for Flow:** setting `CURLOPT_BUFFERSIZE` to 1 MiB is harmless and cheap, and may save
a small number of `recv()` syscalls. It does **not** enlarge write-callback chunks. On HTTP/2
connections the data passes through curl's h2 filter, which works in 16 KiB units regardless
(`curl-8_21_0:lib/http2.c:58` — `#define H2_CHUNK_SIZE (16 * 1024)`). **This is a correctness fix to
a belief, not a throughput opportunity, and not a bug.**

### Options Flow already sets — assessment

| option | repo site | assessment |
| --- | --- | --- |
| `CURLOPT_TCP_NODELAY, 1` | `DMCurlSupport.c:121` | Redundant — default since 7.50.2. Harmless. Nagle only affects small *writes*; a downloader sends one request header. |
| `CURLOPT_TCP_KEEPALIVE/KEEPIDLE 30/KEEPINTVL 15` | `:134-136` | Sound, and a genuine change (curl defaults to keepalive **off**, 60 s/60 s). The stated rationale (NAT/CGNAT dropping idle mappings) is real. No throughput effect on an actively transferring socket. |
| `CURLOPT_LOW_SPEED_LIMIT 1024 / _TIME 10` | `:128-129` | Sound and well-reasoned for this workload — reclaims a stalled slot in 10 s. Interacts with Area 0: on a lossy path a *legitimately* slow flow can dip under 1 KiB/s briefly, so verify this is not killing recoverable segments. |
| `CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2TLS` | `:123` | See Claim 2.5 — costs a 127 ms window-opening RTT per segment for no multiplexing benefit. Worth A/B testing against `CURL_HTTP_VERSION_1_1`. |
| `CURLOPT_SHARE` | `:118-119` | Good, and correctly scoped — see below. |

### `CURLOPT_SHARE` — exactly two lock classes, and the omission is deliberate

`Sources/CCurl/DMCurlSupport.c:73-74` shares precisely `CURL_LOCK_DATA_DNS` and
`CURL_LOCK_DATA_SSL_SESSION`. **`CURL_LOCK_DATA_CONNECT` is deliberately not shared**, and the
comment at `:32-34` gives the reason: *"sharing the connection cache across threads serializes
handle setup, which is the opposite of what segmented transfers want."*

Two consequences worth stating precisely, because it is easy to over-claim what this buys:

- **DNS sharing is unambiguously a win** — one lookup instead of N.
- **TLS session sharing helps later waves, not the first.** If all N segments start concurrently,
  none has a cached session yet, so they all perform full handshakes. Resumption only pays for
  segments that start after an earlier one completed its handshake — which on a 32-segment,
  refill-from-pending design is most of them, but not the opening burst. The comment at `:28-30`
  claims the *probe* warms the cache first, which if true makes even the first wave resumable;
  that ordering is worth confirming against `SegmentedTransfer`'s actual sequence.
- **Every segment connection is therefore cold at the TCP layer** (no shared connection cache),
  which is exactly why Claim 2.5b's slow-start analysis applies to all of them.

**Evidence: strong (repo source read directly).**

### Connection-pool and multiplexing defaults, verified in curl 8.21.0 source

Flow sets none of these; these are the values in effect today.

| option | default in 8.21.0 | source |
| --- | --- | --- |
| `CURLMOPT_PIPELINING` | **`CURLPIPE_MULTIPLEX` (multiplexing ON)** since 7.62.0 | `lib/multi.c:264` — `multi->multiplexing = TRUE;`; [man page](https://curl.se/libcurl/c/CURLMOPT_PIPELINING.html) |
| `CURLMOPT_MAX_CONCURRENT_STREAMS` | `100` | `lib/multi.c:265` — `multi->max_concurrent_streams = 100;` |
| `CURLMOPT_MAXCONNECTS` (multi conn **cache**) | auto-sized: *"libcurl enlarges the size for each added easy handle to make it fit 4 times the number of added easy handles"* | [man page](https://curl.se/libcurl/c/CURLMOPT_MAXCONNECTS.html) |
| `CURLOPT_MAXCONNECTS` (easy) | `5`, **but inert under a multi handle** | `lib/url.c:423` → `lib/urldata.h:38` `DEFAULT_CONNCACHE_SIZE 5`; [man page](https://curl.se/libcurl/c/CURLOPT_MAXCONNECTS.html) |
| `CURLMOPT_MAX_HOST_CONNECTIONS` | `0` = unlimited | `lib/multi.c:3379`; [man page](https://curl.se/libcurl/c/CURLMOPT_MAX_HOST_CONNECTIONS.html) |
| `CURLMOPT_MAX_TOTAL_CONNECTIONS` | `0` = unlimited | `lib/multi.c:3383`; [man page](https://curl.se/libcurl/c/CURLMOPT_MAX_TOTAL_CONNECTIONS.html) |
| `CURLOPT_PIPEWAIT` | `0` (off) | [man page](https://curl.se/libcurl/c/CURLOPT_PIPEWAIT.html) |
| `CURLOPT_TCP_NODELAY` | **`1` — already on** since 7.50.2 | `lib/url.c:414` — `set->tcp_nodelay = TRUE;`; [man page](https://curl.se/libcurl/c/CURLOPT_TCP_NODELAY.html) |
| `CURLOPT_TCP_KEEPALIVE` | `0` (probes off) | [man page](https://curl.se/libcurl/c/CURLOPT_TCP_KEEPALIVE.html) |
| `CURLOPT_TCP_KEEPIDLE` / `KEEPINTVL` | `60` s / `60` s | [KEEPIDLE](https://curl.se/libcurl/c/CURLOPT_TCP_KEEPIDLE.html), [KEEPINTVL](https://curl.se/libcurl/c/CURLOPT_TCP_KEEPINTVL.html) |
| `CURLOPT_HTTP_VERSION` | `CURL_HTTP_VERSION_NONE` since 8.13.0 (was `_2TLS` from 7.62.0) | [man page](https://curl.se/libcurl/c/CURLOPT_HTTP_VERSION.html) |
| `CURLOPT_ALTSVC_CTRL` | `0` — *"Alt-Svc handling is disabled"* | [man page](https://curl.se/libcurl/c/CURLOPT_ALTSVC_CTRL.html) |

Consequences for Flow:

1. **`CURLMOPT_PIPELINING = CURLPIPE_NOTHING` at `Sources/CCurl/DMCurlSupport.c:1434` is an active
   and necessary override**, not a restatement of the default. The man page confirms: *"Since
   7.62.0, CURLPIPE_MULTIPLEX is enabled by default. Before that, default was CURLPIPE_NOTHING."*
   Removing that line silently collapses Flow's segments onto one connection.
2. **`CURLOPT_TCP_NODELAY, 1` at `DMCurlSupport.c:121` is redundant** — *"The option is set by
   default… The default was changed to 1 from 0 in 7.50.2."* Harmless, doing nothing.
3. **The keepalive settings at `:134-136` are real changes**, not restatements — curl defaults
   keepalive *off* with 60 s/60 s timings, so Flow's `1 / 30 / 15` is a deliberate tightening.
4. **`CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2TLS` at `:123` is an opt-in, not inertia.** The
   8.21.0 default is `CURL_HTTP_VERSION_NONE`. Flow actively chose h2 — which makes Claim 2.5 a
   decision to revisit rather than a default to inherit.
5. **`CURLOPT_PIPEWAIT` should stay at its default `0`.** Its stated purpose is the opposite of
   Flow's: *"libcurl instead waits for the connection to reveal if it is possible to multiplex on
   before it continues. This enables libcurl to much better keep the number of connections to a
   minimum."* Flow wants the maximum.
6. Because Flow sets no host/total connection caps, libcurl will not itself throttle a 32-segment
   fan-out. The binding limit is Flow's own `maxConcurrent` semaphore
   (`Sources/TransferCore/SegmentedTransfer.swift:697`). Note the queueing trap documented on both
   `CURLMOPT_MAX_HOST_CONNECTIONS` and `CURLMOPT_MAX_TOTAL_CONNECTIONS`, should Flow ever set them:
   *"the CURLOPT_TIMEOUT_MS timeout is counted inclusive of the waiting time, meaning that if you
   set a too narrow timeout the transfer might never even start before it times out."*

**Evidence: strong** — source at the vendored tag, cross-checked against the man pages.
*Caveat on the man pages: curl.se currently serves 8.22.0 docs. Every option above was checked for a
"changed in" note later than 8.21.0 and none has one.*

### Options Flow does not set

`CURLOPT_ALTSVC` (unset — Area 1) and `CURLOPT_MAX_RECV_SPEED_LARGE` (unset; note from
`curl-8_21_0:lib/http2.c:203-212` that a download rate limit would *shrink* curl's advertised h2
stream window below 64 KiB, so if Flow ever adds per-job rate limiting it will interact with
Claim 2.5).

---

## What this means for Flow

Ranked by expected impact on the 127 ms lossy path. Evidence grade is for the *claim*, not for the
predicted speedup — every speedup figure needs a benchmark.

### 1. Measure the connection-count curve and set the cap from data — **highest impact**

Area 0 says throughput ≈ (number of independent congestion controllers) × (per-flow loss-limited
rate), and the 8 → 14 MB/s datapoint shows the ceiling was not reached at 8.
`Sources/TransferCore/SegmentedTransfer.swift:33` caps at 32; the comment calls it an "IDM-class
aggressive default", which Area 4 shows is not quite what IDM documents — IDM *suggests* 16 or 32
and publishes no cap at all (Claim 4.9). For calibration, the per-host limits actually enforced by
comparable tools: **aria2 hard-caps at 16** (Claim 4.3), **XDM's UI allows up to 64** with a default
of 8 (Claim 4.6). So 32 is inside the range of prior art but was not derived from measurement.

The action is to **measure** the 8 / 16 / 32 / 48 curve on the real path and find the knee, then set
the cap from the data. Two constraints on raising it blindly: `hostMaxSegments`
(`SegmentedTransfer.swift:36-37`) must keep clamping observed-hostile hosts, and RFC 9112 §9.4 warns
that *"aggregate and initially synchronized sending behavior can cause congestion that would not
have been present if fewer parallel connections had been used"* — i.e. past some N, Flow starts
competing with itself.

**Evidence: strong for the mechanism, unknown for the specific number.** This is the only lever in
this document that plausibly moves throughput by a large factor.

### 1b. Lower the minimum tile below 4 MiB to shorten the straggler tail — **cheap, well-precedented**

`Sources/TransferCore/SegmentedTransfer.swift:56` sets `minChunk = 4 MiB`. XDM refuses to split only
below **256 KiB** (Claim 4.7) — 16× finer. Since a straggler holds exactly one tile, the tail costs
`tileSize / slowRate`: at the measured 0.6 MB/s that is **~7 s for a 4 MiB tile versus ~0.4 s for
256 KiB**. The repo already reasons in exactly these terms in the `chunkCount` doc comment, and
already raised `maxChunks` from 128 to 1024 for this reason — the floor is the remaining half of
that change. Cost is more `.segmap` JSON and more range requests; on a 127 ms path each extra
request also costs a round trip, so there is a real trade-off and the right floor is empirical.
**Evidence: strong that the precedent exists (XDM source) and that the tail scales with tile size;
the optimal floor for Flow is untested.** The existing straggler benchmark is the right instrument.

### 2. Delete the `SO_RCVBUF` call — **small but free, and removes a real ceiling**

`Sources/CCurl/DMCurlSupport.c:112`. It disables `SB_AUTOSIZE`
(`xnu:bsd/kern/uipc_socket.c:4893-4894`), pins the buffer at 2 MiB instead of autotuning to 4 MiB,
and *lowers* the negotiated window scale from 6 to 5 because `tcp_get_max_rwinscale` prefers
`sb_hiwat` over `tcp_autorcvbuf_max` when `SB_USRSIZE` is set
(`xnu:bsd/netinet/tcp_subr.c:3901-3902`). Doing nothing is strictly better on macOS.
**Evidence: strong.** Expected effect on *today's* numbers: approximately zero — it is not the
bottleneck. Expected effect on the good-path ceiling: doubles it, 16.5 → 33 MB/s per connection.
Do it because it is wrong, not because it is slow.

### 3. Reconsider `NET_SERVICE_TYPE_RD` — **correctness, not speed**

`Sources/CCurl/DMCurlSupport.c:109`. Apple's SDK header explicitly warns against choosing a service
type that does not match the traffic, and classifies bulk transfer as `BK`, not `RD`
(`sys/socket.h:210-222`, `:236-245`). The repo comment claiming "IDM-style priority" is not
supported by any primary source I found. Either drop the call (take `BE`) or map foreground →
`BE` / background-queued → `BK`. **Evidence: strong that the current justification is wrong;
no evidence either way that changing it moves throughput.**

### 4. Fix the two wrong beliefs in comments

- `Sources/CCurl/DMCurlSupport.c:120` — 1 MiB `BUFFERSIZE` does **not** mean 1 MiB write-callback
  chunks; body writes are capped at `CURL_MAX_WRITE_SIZE` = 16 KiB (`curl-8_21_0:lib/cw-out.c:153`,
  `:255`). Checked: no Flow code depends on chunk size (Claim 5.4), so this is a comment/mental-model
  fix, not a bug. The option is fine to keep.
- `Sources/CCurl/DMCurlSupport.c:1431-1433` — the `CURLPIPE_NOTHING` conclusion is **correct**, but
  the comment cites "per-connection throttles" when the load-bearing reason is that multiplexed
  streams share one TCP congestion window. Strengthen it so a future reader does not undo it.

**Evidence: strong for both.** No throughput change; this is RULE 2 maintenance.

### 5. A/B `CURL_HTTP_VERSION_1_1` against `CURL_HTTP_VERSION_2TLS` — **low expected value, run it last**

`Sources/CCurl/DMCurlSupport.c:123`. Flow gets no multiplexing benefit (it deliberately disables it)
and pays h2's 64 KiB initial stream window plus a SETTINGS exchange. This was initially ranked much
higher on the theory that the 64 KiB window costs a round trip per segment — **Claim 2.5b shows that
theory is wrong**: TCP slow start from IW10 keeps cwnd under 64 KiB for the first three round trips,
while curl raises the window to 10 MiB after the first (`xnu:tcp_cc.h:232`, `:284-288`;
`curl-8_21_0:lib/http2.c:70`, `:898`). The residual h2 overhead is small framing cost against h2's
header compression, and its sign is not obvious.
**Evidence: strong that the originally-suspected mechanism does not fire.** Still cheap to measure
with a rate-capped `TransferThroughputTests` fixture, but expect a null result.

### 6. HTTP/3 — do not build it for this problem

It would not fix a loss-limited per-flow ceiling: one QUIC connection is one congestion controller
(RFC 9002 §7), and QUIC's HOL-blocking win applies only to multiplexed streams, which Flow does not
use. If it is ever built for other reasons, the recipe is nghttp3 + ngtcp2 ≥ 1.12.0 against the
already-vendored OpenSSL 3.5.1, `--with-ngtcp2 --with-nghttp3`
(`curl-8_21_0:docs/HTTP3.md:38-52`, `:93`), ngtcp2 being the non-experimental backend (`:24-28`);
and it must be **H3 with N connections**, never H3 with N streams. Pair it with `CURLOPT_ALTSVC`
for discovery and `CURL_HTTP_VERSION_3` (not `_3ONLY`) so HTTPS eyeballing bounds the downside to
100–200 ms (`:259-289`). **Evidence: strong for the reasoning; the build recipe is curl's own.**

### Considered, and the evidence does not support it yet

**Throughput-adaptive connection scaling** (add a connection while aggregate throughput rises, drop
one when it does not). Intuitively appealing and it directly targets recommendation 1's unknown.
But **no download manager documents such a scheme** (Claim 4.11) — aria2, curl, wget2, XDM and IDM
were all checked; the closest is aria2's `N = A + B·log₁₀(Mbps)`, which sizes *job* parallelism from
*prior* downloads, not segment count within a live transfer. Flow would be building something with
no prior art to copy. That is not a reason not to do it, but it is a reason to do recommendation 1
first: a measured curve tells you whether an adaptive controller has anything to find, and gives you
the ground truth to validate it against. **Evidence: strong for the absence of prior art.**

### Not worth doing

- **`TCP_NOTSENT_LOWAT`** — send-side only (`netinet/tcp.h:246`; `xnu:tcp_subr.c:3919+`). No effect
  on downloads. *(strong)*
- **`CURLOPT_PIPEWAIT`** — its documented purpose is to *"keep the number of connections to a
  minimum"*, the exact opposite of what this path needs. Leave at default `0`. *(strong)*
- **Selecting a congestion control algorithm per socket** — macOS exposes no such option. CUBIC is
  the default (`xnu:bsd/netinet/tcp_subr.c:1369-1385`), and the complete list of `TCP_*` socket
  options in `MacOSX26.5.sdk/usr/include/netinet/tcp.h:218-246` is `TCP_NODELAY`, `TCP_MAXSEG`,
  `TCP_NOPUSH`, `TCP_NOOPT`, `TCP_KEEPALIVE`, `TCP_CONNECTIONTIMEOUT`, `TCP_RXT_CONNDROPTIME`,
  `TCP_RXT_FINDROP`, `TCP_KEEPINTVL`, `TCP_KEEPCNT`, `TCP_SENDMOREACKS`, `TCP_ENABLE_ECN`,
  `TCP_FASTOPEN`, `TCP_CONNECTION_INFO`, `TCP_NOTSENT_LOWAT` — **there is no `TCP_CONGESTION`**.
  *(strong — verified by enumerating the header, not by recall)*
- **Raising `CURLOPT_BUFFERSIZE` further** — already well past the point of diminishing returns; the
  h2 path works in 16 KiB units anyway (`curl-8_21_0:lib/http2.c:58`). *(strong)*

### Open questions this research could not close

1. The actual packet loss rate on the path — inferred at 0.02–0.06 % from the Mathis model, never
   measured. `netstat -s -p tcp` retransmit counters during a transfer would settle it.
2. Whether the ~14 MB/s at 8 connections is a client limit, a server per-client limit, or the
   bottleneck link. Distinguishing these decides whether recommendation 1 pays at all.
3. Whether `CURLOPT_LOW_SPEED_LIMIT 1024 / _TIME 10` is killing segments that would have recovered.
4. Quantified H3-vs-H2 bulk throughput at this loss rate — **no primary source found**.
5. What libcurl returns for `CURL_HTTP_VERSION_3` on a build without HTTP/3 — undocumented; the
   `CURLE_NOT_BUILT_IN` linkage is inference. Only matters if H3 is ever attempted.
6. Whether the international path in question passes UDP/443 at all — decides whether H3 is even
   testable there, independent of whether it would help.
7. Whether the range probe genuinely warms the shared TLS session cache *before* the segment burst
   (`DMCurlSupport.c:28-30` claims it does). If not, the opening wave of segments all pay a full
   handshake. Answerable by reading `SegmentedTransfer`'s ordering; not traced here.
8. What `progressCallback` costs at ~110 invocations/s/segment (Claim 5.4). A profiling question,
   not a protocol one, and out of scope for this document.
