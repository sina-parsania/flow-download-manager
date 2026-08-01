// SPDX-License-Identifier: GPL-3.0-or-later
#include "DMCurlSupport.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

/* Single definition so the two easy-handle setup paths cannot drift apart.
 * Keep in step with VERSION at release time (Documentation/release-checklist.md). */
#define DM_USER_AGENT "Flow/0.4.3"

#ifndef CURLE_RANGE_ERROR
#define CURLE_RANGE_ERROR ((CURLcode)63)
#endif

#ifndef CURLU_ALLOW_RELATIVE
#define CURLU_ALLOW_RELATIVE (1 << 10)
#endif

/* Process-wide share handle: every easy created here reuses one DNS cache and
 * one TLS session cache. Segmented downloads open N connections to the same
 * host at once; without this each one repeats the DNS lookup and a full TLS
 * handshake. With it the probe warms the cache and the segments resume
 * sessions, cutting a round trip off every segment's time-to-first-byte.
 *
 * CURL_LOCK_DATA_CONNECT is deliberately NOT shared: sharing the connection
 * cache across threads serializes handle setup, which is the opposite of what
 * segmented transfers want. */
static CURLSH *gDMCurlShare = NULL;
static pthread_mutex_t gDMCurlShareLocks[CURL_LOCK_DATA_LAST];

static void DMCurlShareLock(CURL *handle, curl_lock_data data, curl_lock_access access, void *userptr) {
    (void)handle;
    (void)access;
    (void)userptr;
    if ((int)data >= 0 && (int)data < CURL_LOCK_DATA_LAST) {
        (void)pthread_mutex_lock(&gDMCurlShareLocks[(int)data]);
    }
}

static void DMCurlShareUnlock(CURL *handle, curl_lock_data data, void *userptr) {
    (void)handle;
    (void)userptr;
    if ((int)data >= 0 && (int)data < CURL_LOCK_DATA_LAST) {
        (void)pthread_mutex_unlock(&gDMCurlShareLocks[(int)data]);
    }
}

static int gDMCurlShareLocksReady = 0;

CURLcode DMCurlGlobalInit(void) {
    CURLcode code = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (code != CURLE_OK) {
        return code;
    }
    if (gDMCurlShare == NULL) {
        if (!gDMCurlShareLocksReady) {
            for (int i = 0; i < CURL_LOCK_DATA_LAST; i++) {
                (void)pthread_mutex_init(&gDMCurlShareLocks[i], NULL);
            }
            gDMCurlShareLocksReady = 1;
        }
        gDMCurlShare = curl_share_init();
        if (gDMCurlShare != NULL) {
            curl_share_setopt(gDMCurlShare, CURLSHOPT_LOCKFUNC, DMCurlShareLock);
            curl_share_setopt(gDMCurlShare, CURLSHOPT_UNLOCKFUNC, DMCurlShareUnlock);
            curl_share_setopt(gDMCurlShare, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
            curl_share_setopt(gDMCurlShare, CURLSHOPT_SHARE, CURL_LOCK_DATA_SSL_SESSION);
        }
    }
    /* A share handle is an optimisation: if it could not be created the
     * transfer still works, just without cache reuse. Mutexes stay ready so a
     * later init never double-initialises them. */
    return CURLE_OK;
}

void DMCurlGlobalCleanup(void) {
    if (gDMCurlShare != NULL) {
        curl_share_cleanup(gDMCurlShare);
        gDMCurlShare = NULL;
    }
    if (gDMCurlShareLocksReady) {
        for (int i = 0; i < CURL_LOCK_DATA_LAST; i++) {
            (void)pthread_mutex_destroy(&gDMCurlShareLocks[i]);
        }
        gDMCurlShareLocksReady = 0;
    }
    curl_global_cleanup();
}

const curl_version_info_data *DMCurlVersionInfo(void) {
    return curl_version_info(CURLVERSION_NOW);
}

/// Classifies the socket for the host's queueing/scheduling.
///
/// It used to also set `SO_RCVBUF` to 2 MiB, described as "enlarging" the
/// receive buffer. It shrank it. Setting `SO_RCVBUF` clears `SB_AUTOSIZE`, so
/// the kernel stops growing the buffer, and the window scale is then derived
/// from the value the app set instead of `net.inet.tcp.autorcvbufmax` — which on
/// this machine is **4 MiB**, i.e. twice what the call asked for. Window scale is
/// negotiated in the SYN and cannot grow later, so the connection was pinned to
/// the smaller ceiling for its whole life.
///
/// Measured impact of removing it: none. At ~1.7 MB/s per connection over a
/// 127 ms path the window in use is ~220 KB, far below either ceiling — this path
/// is loss-limited, not window-limited. Removed because it was a real ceiling
/// downgrade resting on a false premise, not because it bought throughput.
static int DMCurlSockoptCallback(void *clientp, curl_socket_t curlfd, curlsocktype purpose) {
    (void)clientp;
    if (purpose != CURLSOCKTYPE_IPCXN) {
        return CURL_SOCKOPT_OK;
    }
    /* NOT a priority hack, whatever the old comment claimed. Apple's own header
     * says service types "do not represent priorities" and that classes with
     * lower delay tolerance get *smaller* queues — so mislabelling bulk traffic
     * to look urgent costs drops under congestion, which is exactly the link
     * this app runs on. RD ("a notch higher than Best Effort", elastic,
     * long-lived) is kept only because no measurement here separates it from BE
     * or BK; the A/B was swamped by 3x swings in link conditions. If anyone
     * revisits this, measure under congestion or delete the call and take the
     * documented default. */
    int serviceType = NET_SERVICE_TYPE_RD;
    (void)setsockopt(curlfd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &serviceType, sizeof(serviceType));
    return CURL_SOCKOPT_OK;
}

static void DMCurlApplyThroughputOptions(CURL *easy) {
    if (gDMCurlShare != NULL) {
        curl_easy_setopt(easy, CURLOPT_SHARE, gDMCurlShare);
    }
    /* Sizes curl's socket-read buffer only. It does NOT size the write callback:
     * body writes are capped at CURL_MAX_WRITE_SIZE (16 KiB, curl.h:265) whatever
     * this is set to — measured at runtime, max chunk 16384 with this at 1 MiB.
     * Anything reasoning about per-callback cost must use 16 KiB, not this. */
    curl_easy_setopt(easy, CURLOPT_BUFFERSIZE, 1024L * 1024L);
    curl_easy_setopt(easy, CURLOPT_TCP_NODELAY, 1L);
    curl_easy_setopt(easy, CURLOPT_SOCKOPTFUNCTION, DMCurlSockoptCallback);
    curl_easy_setopt(easy, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_2TLS);
    /* Fail transfers stalled below 1 KiB/s so the retry pass can re-split the
     * remaining bytes onto fresh connections. 10 s, not 30: on a lossy link a
     * stalled connection is a lost slot, and holding it three times longer than
     * necessary is three times the tail. */
    curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, 1024L);
    curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, 10L);
    /* NAT and carrier-grade NAT silently drop idle mappings. Without keepalive
     * curl sits waiting on a connection the peer forgot about, and only the
     * low-speed timer eventually notices. Probing keeps the mapping alive and
     * surfaces a genuinely dead peer as an error instead of a stall. */
    curl_easy_setopt(easy, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(easy, CURLOPT_TCP_KEEPIDLE, 30L);
    curl_easy_setopt(easy, CURLOPT_TCP_KEEPINTVL, 15L);
}

CURLUcode DMCurlURLSetString(CURLU *handle, CURLUPart part, const char *value, unsigned int flags) {
    return curl_url_set(handle, part, value, flags);
}

CURLUcode DMCurlURLGetString(const CURLU *handle, CURLUPart part, char **value, unsigned int flags) {
    return curl_url_get(handle, part, value, flags);
}

CURLUcode DMCurlURLSetURL(CURLU *handle, const char *url) {
    return curl_url_set(handle, CURLUPART_URL, url, CURLU_DEFAULT_SCHEME);
}

void DMCurlDownloadResultClear(DMCurlDownloadResult *result) {
    if (result == NULL) {
        return;
    }
    free(result->finalURL);
    free(result->contentType);
    free(result->etag);
    free(result->lastModified);
    free(result->acceptRanges);
    free(result->retryAfter);
    free(result->contentDisposition);
    free(result->contentRange);
    memset(result, 0, sizeof(*result));
    result->contentLength = -1;
}

struct DMCurlAbortFlag {
    atomic_int aborted;
};

DMCurlAbortFlag *DMCurlAbortFlagCreate(void) {
    DMCurlAbortFlag *flag = (DMCurlAbortFlag *)calloc(1, sizeof(DMCurlAbortFlag));
    if (flag != NULL) {
        atomic_init(&flag->aborted, 0);
    }
    return flag;
}

void DMCurlAbortFlagDestroy(DMCurlAbortFlag *flag) {
    free(flag);
}

void DMCurlAbortFlagRequest(DMCurlAbortFlag *flag) {
    if (flag != NULL) {
        atomic_store_explicit(&flag->aborted, 1, memory_order_release);
    }
}

int DMCurlAbortFlagIsSet(const DMCurlAbortFlag *flag) {
    return flag != NULL && atomic_load_explicit(&flag->aborted, memory_order_acquire);
}

int DMCurlAbortFlagIsSetHandle(const void *flag) {
    return DMCurlAbortFlagIsSet((const DMCurlAbortFlag *)flag);
}

void DMCurlAbortFlagReset(DMCurlAbortFlag *flag) {
    if (flag != NULL) {
        atomic_store_explicit(&flag->aborted, 0, memory_order_release);
    }
}

typedef struct {
    int fd;
    curl_off_t offset;
    curl_off_t written;
    curl_off_t expectedRangeStart;
    curl_off_t expectedRangeEnd;
    /* Expected body size for this easy (-1 unknown). Updated from XFERINFO
     * dltotal once libcurl learns Content-Length / Content-Range length. */
    curl_off_t knownTotal;
    curl_off_t bodyByteLimit;
    int writeError;
    int rangedTransfer;
    int rangeResponseInvalid;
    /* Opt-in, and only ever set on a request whose range starts at offset 0.
     *
     * A ranged request that is answered 200 means the server ignored Range and
     * is sending the whole body. Rejecting that wrote zero bytes and threw, so
     * the caller had to spend a second request — which on a one-shot link is one
     * request too many, and is why fragile URLs used to skip segmentation
     * entirely. With this set, such a response is accepted and written from
     * offset 0, so the opening chunk doubles as the range probe and costs
     * nothing when it fails.
     *
     * Offset 0 is load-bearing: a mid-file segment that accepted a 200 would
     * write the file's HEAD at its own offset and silently corrupt the download.
     * Mid-file segments keep strict validation, always. */
    int allowFullBodyOn200;
    /* Set by DMCurlEasyDownloadRequestStop. Distinct from abortFlag: that one
     * is job-wide and means "the user cancelled"; this one means "give your
     * remaining range back so it can be re-tiled". */
    volatile int32_t stopRequested;
    int bodyCapReached;
    DMCurlAbortFlag *abortFlag;
    DMCurlProgressCallback progressCallback;
    void *progressUserdata;
} DMCurlWriteCtx;

typedef struct {
    char *contentType;
    char *etag;
    char *lastModified;
    char *acceptRanges;
    char *contentDisposition;
    char *contentRange;
    char *location;
    /* Seconds the server asked us to wait (429/503). Parsed from the
     * delta-seconds form only — the HTTP-date form is rarer and needs a full
     * date parser to be worth trusting. */
    char *retryAfter;
    long responseStatus;
    int hasContentRange;
    int contentRangeMalformed;
    curl_off_t contentRangeStart;
    curl_off_t contentRangeEnd;
    curl_off_t contentRangeTotal;
} DMCurlHeaderCtx;

typedef struct {
    DMCurlWriteCtx *write;
    DMCurlHeaderCtx *header;
    int discardResponseBody;
} DMCurlEasyTransferCtx;

static char *DMCurlDupRange(const char *start, size_t length) {
    char *copy = (char *)malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, start, length);
    copy[length] = '\0';
    return copy;
}

static char *DMCurlDupCString(const char *value) {
    if (value == NULL) {
        return NULL;
    }
    return DMCurlDupRange(value, strlen(value));
}

static char *DMCurlDupOrNull(const char *value);

/// Builds a curl_slist from newline-separated "Name: Value" lines. Skips blanks.
static struct curl_slist *DMCurlBuildHeaderList(const char *extraHeaders) {
    if (extraHeaders == NULL || extraHeaders[0] == '\0') {
        return NULL;
    }
    struct curl_slist *list = NULL;
    const char *cursor = extraHeaders;
    while (*cursor != '\0') {
        const char *lineStart = cursor;
        while (*cursor != '\0' && *cursor != '\n' && *cursor != '\r') {
            cursor++;
        }
        size_t length = (size_t)(cursor - lineStart);
        while (length > 0 && (lineStart[length - 1] == ' ' || lineStart[length - 1] == '\t')) {
            length--;
        }
        if (length > 0) {
            char *line = DMCurlDupRange(lineStart, length);
            if (line == NULL) {
                curl_slist_free_all(list);
                return NULL;
            }
            struct curl_slist *next = curl_slist_append(list, line);
            free(line);
            if (next == NULL) {
                curl_slist_free_all(list);
                return NULL;
            }
            list = next;
        }
        while (*cursor == '\n' || *cursor == '\r') {
            cursor++;
        }
    }
    return list;
}

static void DMCurlAssignHeader(char **slot, const char *valueStart, size_t valueLength) {
    if (slot == NULL) {
        return;
    }
    free(*slot);
    *slot = DMCurlDupRange(valueStart, valueLength);
}

static int DMCurlHeaderEquals(const char *line, size_t lineLength, const char *name) {
    size_t nameLength = strlen(name);
    if (lineLength < nameLength + 1) {
        return 0;
    }
    for (size_t i = 0; i < nameLength; i++) {
        if (tolower((unsigned char)line[i]) != tolower((unsigned char)name[i])) {
            return 0;
        }
    }
    return line[nameLength] == ':';
}

static void DMCurlHeaderCtxClear(DMCurlHeaderCtx *ctx) {
    if (ctx == NULL) {
        return;
    }
    free(ctx->contentType);
    free(ctx->etag);
    free(ctx->lastModified);
    free(ctx->acceptRanges);
    free(ctx->contentDisposition);
    free(ctx->contentRange);
    free(ctx->location);
    free(ctx->retryAfter);
    memset(ctx, 0, sizeof(*ctx));
}

static int DMCurlIsRedirectStatus(long status) {
    return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
}

static int DMCurlParseHTTP1Status(const char *line, size_t len, long *statusOut) {
    if (len < 12 || strncmp(line, "HTTP/", 5) != 0) {
        return 0;
    }
    const char *p = line + 5;
    while (p < line + len && *p != ' ' && *p != '\r' && *p != '\n') {
        p++;
    }
    if (p >= line + len || *p != ' ') {
        return 0;
    }
    p++;
    char *end = NULL;
    long status = strtol(p, &end, 10);
    if (end == p || status < 100 || status > 599) {
        return 0;
    }
    *statusOut = status;
    return 1;
}

static int DMCurlParseNonnegativeOffT(const char **cursor, const char *end, curl_off_t *valueOut) {
    if (cursor == NULL || *cursor == NULL || valueOut == NULL || *cursor >= end ||
        !isdigit((unsigned char)**cursor)) {
        return 0;
    }
    curl_off_t value = 0;
    while (*cursor < end && isdigit((unsigned char)**cursor)) {
        int digit = **cursor - '0';
        if (value > ((curl_off_t)LLONG_MAX - digit) / 10) {
            return 0;
        }
        value = value * 10 + digit;
        (*cursor)++;
    }
    *valueOut = value;
    return 1;
}

static int DMCurlParseRequestedRange(
    const char *rangeHeader,
    curl_off_t *startOut,
    curl_off_t *endOut
) {
    if (rangeHeader == NULL || startOut == NULL || endOut == NULL) {
        return 0;
    }
    const char *cursor = rangeHeader;
    const char *end = rangeHeader + strlen(rangeHeader);
    curl_off_t start = 0;
    curl_off_t rangeEnd = 0;
    if (!DMCurlParseNonnegativeOffT(&cursor, end, &start) || cursor >= end || *cursor++ != '-' ||
        !DMCurlParseNonnegativeOffT(&cursor, end, &rangeEnd) || cursor != end || start > rangeEnd) {
        return 0;
    }
    *startOut = start;
    *endOut = rangeEnd;
    return 1;
}

static int DMCurlParseContentRange(
    const char *value,
    size_t length,
    curl_off_t *startOut,
    curl_off_t *endOut,
    curl_off_t *totalOut
) {
    const char *cursor = value;
    const char *end = value + length;
    if (length < 8 || strncmp(cursor, "bytes ", 6) != 0) {
        return 0;
    }
    cursor += 6;
    curl_off_t start = 0;
    curl_off_t rangeEnd = 0;
    curl_off_t total = 0;
    if (!DMCurlParseNonnegativeOffT(&cursor, end, &start) || cursor >= end || *cursor++ != '-' ||
        !DMCurlParseNonnegativeOffT(&cursor, end, &rangeEnd) || cursor >= end || *cursor++ != '/' ||
        !DMCurlParseNonnegativeOffT(&cursor, end, &total) || cursor != end || start > rangeEnd ||
        total <= rangeEnd) {
        return 0;
    }
    *startOut = start;
    *endOut = rangeEnd;
    *totalOut = total;
    return 1;
}

static int DMCurlRangeResponseIsValid(const DMCurlWriteCtx *writeCtx, const DMCurlHeaderCtx *headerCtx) {
    return writeCtx != NULL && headerCtx != NULL && writeCtx->rangedTransfer &&
           headerCtx->responseStatus == 206 && headerCtx->hasContentRange &&
           !headerCtx->contentRangeMalformed &&
           headerCtx->contentRangeStart == writeCtx->expectedRangeStart &&
           headerCtx->contentRangeEnd == writeCtx->expectedRangeEnd &&
           headerCtx->contentRangeTotal > headerCtx->contentRangeEnd;
}

typedef struct {
    char *scheme;
    char *host;
    int port;
} DMCurlOrigin;

static void DMCurlOriginClear(DMCurlOrigin *origin) {
    if (origin == NULL) {
        return;
    }
    free(origin->scheme);
    free(origin->host);
    memset(origin, 0, sizeof(*origin));
    origin->port = -1;
}

static char *DMCurlLowerDup(const char *value) {
    if (value == NULL) {
        return NULL;
    }
    size_t len = strlen(value);
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL) {
        return NULL;
    }
    for (size_t i = 0; i < len; i++) {
        copy[i] = (char)tolower((unsigned char)value[i]);
    }
    copy[len] = '\0';
    return copy;
}

static int DMCurlOriginFromURL(const char *url, DMCurlOrigin *out) {
    if (url == NULL || out == NULL) {
        return 0;
    }
    CURLU *parts = curl_url();
    if (parts == NULL) {
        return 0;
    }
    if (curl_url_set(parts, CURLUPART_URL, url, CURLU_DEFAULT_SCHEME) != CURLUE_OK) {
        curl_url_cleanup(parts);
        return 0;
    }
    char *scheme = NULL;
    char *host = NULL;
    char *portText = NULL;
    if (curl_url_get(parts, CURLUPART_SCHEME, &scheme, 0) != CURLUE_OK ||
        curl_url_get(parts, CURLUPART_HOST, &host, 0) != CURLUE_OK) {
        curl_free(scheme);
        curl_free(host);
        curl_url_cleanup(parts);
        return 0;
    }
    (void)curl_url_get(parts, CURLUPART_PORT, &portText, CURLU_DEFAULT_PORT);
    out->scheme = DMCurlLowerDup(scheme);
    out->host = DMCurlLowerDup(host);
    if (portText != NULL && portText[0] != '\0') {
        out->port = atoi(portText);
    } else {
        out->port = (out->scheme != NULL && strcmp(out->scheme, "https") == 0) ? 443 : 80;
    }
    curl_free(scheme);
    curl_free(host);
    curl_free(portText);
    curl_url_cleanup(parts);
    return out->scheme != NULL && out->host != NULL;
}

static int DMCurlOriginsEqual(const DMCurlOrigin *lhs, const DMCurlOrigin *rhs) {
    return lhs != NULL && rhs != NULL && lhs->scheme != NULL && rhs->scheme != NULL &&
           lhs->host != NULL && rhs->host != NULL && lhs->port == rhs->port &&
           strcmp(lhs->scheme, rhs->scheme) == 0 && strcmp(lhs->host, rhs->host) == 0;
}

static int DMCurlHeaderNameMatches(const char *name, const char *canonical) {
    if (name == NULL || canonical == NULL) {
        return 0;
    }
    while (*name != '\0' && *canonical != '\0') {
        if (tolower((unsigned char)*name) != tolower((unsigned char)*canonical)) {
            return 0;
        }
        name++;
        canonical++;
    }
    return *name == '\0' && *canonical == '\0';
}

static int DMCurlIsSensitiveHeaderName(const char *name) {
    static const char *kSensitive[] = {"Cookie", "Authorization", "Referer", "Origin"};
    for (size_t i = 0; i < sizeof(kSensitive) / sizeof(kSensitive[0]); i++) {
        if (DMCurlHeaderNameMatches(name, kSensitive[i])) {
            return 1;
        }
    }
    return 0;
}

static int DMCurlIsSafeHeaderName(const char *name) {
    static const char *kSafe[] = {"User-Agent", "Accept", "Accept-Language"};
    for (size_t i = 0; i < sizeof(kSafe) / sizeof(kSafe[0]); i++) {
        if (DMCurlHeaderNameMatches(name, kSafe[i])) {
            return 1;
        }
    }
    return 0;
}

static char *DMCurlFilterHeadersForRedirect(
    const char *payload,
    const DMCurlOrigin *source,
    const DMCurlOrigin *destination,
    CURLcode *errorOut
) {
    if (errorOut != NULL) {
        *errorOut = CURLE_OK;
    }
    if (payload == NULL || payload[0] == '\0') {
        return NULL;
    }
    if (source != NULL && destination != NULL && source->scheme != NULL &&
        destination->scheme != NULL && strcmp(source->scheme, "https") == 0 &&
        strcmp(destination->scheme, "http") == 0) {
        if (errorOut != NULL) {
            *errorOut = CURLE_UNSUPPORTED_PROTOCOL;
        }
        return NULL;
    }
    if (source != NULL && destination != NULL && DMCurlOriginsEqual(source, destination)) {
        return DMCurlDupCString(payload);
    }
    size_t capacity = strlen(payload) + 1;
    char *filtered = (char *)malloc(capacity);
    if (filtered == NULL) {
        return NULL;
    }
    filtered[0] = '\0';
    size_t used = 0;
    const char *cursor = payload;
    while (*cursor != '\0') {
        const char *lineStart = cursor;
        while (*cursor != '\0' && *cursor != '\n' && *cursor != '\r') {
            cursor++;
        }
        size_t lineLen = (size_t)(cursor - lineStart);
        while (lineLen > 0 && (lineStart[lineLen - 1] == ' ' || lineStart[lineLen - 1] == '\t')) {
            lineLen--;
        }
        const char *colon = NULL;
        for (size_t i = 0; i < lineLen; i++) {
            if (lineStart[i] == ':') {
                colon = lineStart + i;
                break;
            }
        }
        if (colon != NULL && colon > lineStart) {
            char nameBuf[128];
            size_t nameLen = (size_t)(colon - lineStart);
            if (nameLen < sizeof(nameBuf)) {
                memcpy(nameBuf, lineStart, nameLen);
                nameBuf[nameLen] = '\0';
                const char *value = colon + 1;
                while (*value == ' ' || *value == '\t') {
                    value++;
                }
                int keep = !DMCurlIsSensitiveHeaderName(nameBuf) && DMCurlIsSafeHeaderName(nameBuf) &&
                           value[0] != '\0';
                if (keep) {
                    size_t need = lineLen + 2;
                    if (used + need + 1 > capacity) {
                        capacity = (used + need + 1) * 2;
                        char *grown = (char *)realloc(filtered, capacity);
                        if (grown == NULL) {
                            free(filtered);
                            return NULL;
                        }
                        filtered = grown;
                    }
                    if (used > 0) {
                        filtered[used++] = '\n';
                    }
                    memcpy(filtered + used, lineStart, lineLen);
                    used += lineLen;
                    filtered[used] = '\0';
                }
            }
        }
        while (*cursor == '\n' || *cursor == '\r') {
            cursor++;
        }
    }
    if (used == 0) {
        free(filtered);
        return NULL;
    }
    return filtered;
}

static char *DMCurlResolveRedirectURL(const char *currentURL, const char *location) {
    if (currentURL == NULL || location == NULL || location[0] == '\0') {
        return NULL;
    }
    CURLU *parts = curl_url();
    if (parts == NULL) {
        return NULL;
    }
    if (curl_url_set(parts, CURLUPART_URL, currentURL, CURLU_DEFAULT_SCHEME) != CURLUE_OK) {
        curl_url_cleanup(parts);
        return NULL;
    }
    if (curl_url_set(parts, CURLUPART_URL, location, CURLU_DEFAULT_SCHEME | CURLU_ALLOW_RELATIVE) != CURLUE_OK) {
        curl_url_cleanup(parts);
        return NULL;
    }
    char *resolved = NULL;
    if (curl_url_get(parts, CURLUPART_URL, &resolved, 0) != CURLUE_OK) {
        curl_url_cleanup(parts);
        return NULL;
    }
    char *copy = DMCurlDupCString(resolved);
    curl_free(resolved);
    curl_url_cleanup(parts);
    return copy;
}

static void DMCurlNoteResponseStatus(DMCurlEasyTransferCtx *tctx, long status) {
    if (tctx == NULL || tctx->header == NULL) {
        return;
    }
    DMCurlHeaderCtxClear(tctx->header);
    tctx->header->responseStatus = status;
    tctx->discardResponseBody = DMCurlIsRedirectStatus(status);
}

static int DMCurlShouldAbort(const DMCurlWriteCtx *ctx) {
    return ctx != NULL && DMCurlAbortFlagIsSet(ctx->abortFlag);
}

static int DMCurlShouldStop(const DMCurlWriteCtx *ctx) {
    return ctx != NULL && ctx->stopRequested != 0;
}

static size_t DMCurlHeaderCallback(char *buffer, size_t size, size_t nitems, void *userdata) {
    size_t total = size * nitems;
    DMCurlEasyTransferCtx *tctx = (DMCurlEasyTransferCtx *)userdata;
    DMCurlHeaderCtx *ctx = tctx != NULL ? tctx->header : NULL;
    if (ctx == NULL || total < 2) {
        return total;
    }

    long status = 0;
    if (DMCurlParseHTTP1Status(buffer, total, &status)) {
        DMCurlNoteResponseStatus(tctx, status);
        return total;
    }

    const char *value = NULL;
    size_t valueLength = 0;
    for (size_t i = 0; i < total; i++) {
        if (buffer[i] == ':') {
            value = buffer + i + 1;
            while (value < buffer + total && (*value == ' ' || *value == '\t')) {
                value++;
            }
            valueLength = (size_t)((buffer + total) - value);
            while (valueLength > 0 &&
                   (value[valueLength - 1] == '\r' || value[valueLength - 1] == '\n' ||
                    value[valueLength - 1] == ' ' || value[valueLength - 1] == '\t')) {
                valueLength--;
            }
            break;
        }
    }
    if (value == NULL) {
        return total;
    }

    if (DMCurlHeaderEquals(buffer, total, ":status")) {
        char tmp[32];
        if (valueLength < sizeof(tmp)) {
            memcpy(tmp, value, valueLength);
            tmp[valueLength] = '\0';
            status = strtol(tmp, NULL, 10);
            if (status >= 100 && status <= 599) {
                DMCurlNoteResponseStatus(tctx, status);
            }
        }
        return total;
    }

    if (DMCurlHeaderEquals(buffer, total, "content-type")) {
        DMCurlAssignHeader(&ctx->contentType, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "etag")) {
        DMCurlAssignHeader(&ctx->etag, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "last-modified")) {
        DMCurlAssignHeader(&ctx->lastModified, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "accept-ranges")) {
        DMCurlAssignHeader(&ctx->acceptRanges, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "retry-after")) {
        DMCurlAssignHeader(&ctx->retryAfter, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "content-disposition")) {
        DMCurlAssignHeader(&ctx->contentDisposition, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "content-range")) {
        DMCurlAssignHeader(&ctx->contentRange, value, valueLength);
        curl_off_t rangeStart = 0;
        curl_off_t rangeEnd = 0;
        curl_off_t rangeTotal = 0;
        if (!DMCurlParseContentRange(value, valueLength, &rangeStart, &rangeEnd, &rangeTotal)) {
            ctx->contentRangeMalformed = 1;
        } else if (ctx->hasContentRange &&
                   (ctx->contentRangeStart != rangeStart || ctx->contentRangeEnd != rangeEnd ||
                    ctx->contentRangeTotal != rangeTotal)) {
            ctx->contentRangeMalformed = 1;
        } else {
            ctx->hasContentRange = 1;
            ctx->contentRangeStart = rangeStart;
            ctx->contentRangeEnd = rangeEnd;
            ctx->contentRangeTotal = rangeTotal;
        }
    } else if (DMCurlHeaderEquals(buffer, total, "location")) {
        DMCurlAssignHeader(&ctx->location, value, valueLength);
    }
    return total;
}

static size_t DMCurlWriteCallback(char *ptr, size_t size, size_t nmemb, void *userdata) {
    DMCurlEasyTransferCtx *tctx = (DMCurlEasyTransferCtx *)userdata;
    if (tctx == NULL || tctx->write == NULL) {
        return size * nmemb;
    }
    if (tctx->discardResponseBody) {
        return size * nmemb;
    }
    DMCurlWriteCtx *ctx = tctx->write;
    size_t total = size * nmemb;
    if (ctx == NULL || total == 0) {
        return total;
    }
    if (DMCurlShouldAbort(ctx) || DMCurlShouldStop(ctx)) {
        return 0;
    }
    if (ctx->rangedTransfer && !DMCurlRangeResponseIsValid(ctx, tctx->header)) {
        /* Server ignored Range and is sending the whole body from byte 0. The
         * caller asked for this to be kept, and the request starts at offset 0,
         * so the bytes are exactly what a plain GET would have produced: drop to
         * an unranged transfer and write them. Any other shape still fails. */
        if (ctx->allowFullBodyOn200 && ctx->expectedRangeStart == 0 &&
            tctx->header->responseStatus == 200 && !tctx->header->hasContentRange) {
            ctx->rangedTransfer = 0;
        } else {
            ctx->rangeResponseInvalid = 1;
            return 0;
        }
    }
    size_t remaining = total;
    if (ctx->bodyByteLimit > 0) {
        curl_off_t room = ctx->bodyByteLimit - ctx->written;
        if (room <= 0) {
            ctx->bodyCapReached = 1;
            return 0;
        }
        if ((curl_off_t)remaining > room) {
            remaining = (size_t)room;
        }
    }
    const char *cursor = ptr;
    while (remaining > 0) {
        if (DMCurlShouldAbort(ctx) || DMCurlShouldStop(ctx)) {
            return 0;
        }
        ssize_t wrote = pwrite(ctx->fd, cursor, remaining, ctx->offset + ctx->written);
        if (wrote <= 0) {
            ctx->writeError = 1;
            return 0;
        }
        ctx->written += (curl_off_t)wrote;
        cursor += wrote;
        remaining -= (size_t)wrote;
        if (ctx->progressCallback != NULL) {
            if (ctx->progressCallback(ctx->written, ctx->knownTotal, ctx->progressUserdata) != 0) {
                DMCurlAbortFlagRequest(ctx->abortFlag);
                return 0;
            }
        }
    }
    if (ctx->bodyByteLimit > 0 && ctx->written >= ctx->bodyByteLimit) {
        ctx->bodyCapReached = 1;
        return 0;
    }
    return total;
}

static int DMCurlXferInfoCallback(
    void *clientp,
    curl_off_t dltotal,
    curl_off_t dlnow,
    curl_off_t ultotal,
    curl_off_t ulnow
) {
    (void)dlnow;
    (void)ultotal;
    (void)ulnow;
    DMCurlWriteCtx *ctx = (DMCurlWriteCtx *)clientp;
    if (dltotal > 0) {
        ctx->knownTotal = dltotal;
    }
    if (DMCurlShouldAbort(ctx)) {
        return 1;
    }
    return 0;
}

CURLcode DMCurlEasyDownloadToFD(
    const char *url,
    int fd,
    curl_off_t fileOffset,
    const char *rangeHeader,
    long connectTimeoutMS,
    long transferTimeoutMS,
    long maxRedirects,
    DMCurlAbortFlag *abortFlag,
    DMCurlProgressCallback progressCallback,
    void *progressUserdata,
    const char *userpwd,
    const char *proxyURL,
    const char *cookieJarPath,
    const char *extraHeaders,
    curl_off_t bodyByteLimit,
    int allowFullBodyOn200,
    DMCurlDownloadResult *out
) {
    if (url == NULL || fd < 0 || out == NULL) {
        return CURLE_FAILED_INIT;
    }

    memset(out, 0, sizeof(*out));
    out->contentLength = -1;

    CURL *easy = curl_easy_init();
    if (easy == NULL) {
        out->code = CURLE_FAILED_INIT;
        return CURLE_FAILED_INIT;
    }

    DMCurlWriteCtx writeCtx = {
        .fd = fd,
        .offset = fileOffset,
        .written = 0,
        .expectedRangeStart = 0,
        .expectedRangeEnd = 0,
        .knownTotal = -1,
        .bodyByteLimit = bodyByteLimit > 0 ? bodyByteLimit : 0,
        .writeError = 0,
        .rangedTransfer = rangeHeader != NULL && rangeHeader[0] != '\0',
        .rangeResponseInvalid = 0,
        .allowFullBodyOn200 = allowFullBodyOn200 != 0,
        .stopRequested = 0,
        .bodyCapReached = 0,
        .abortFlag = abortFlag,
        .progressCallback = progressCallback,
        .progressUserdata = progressUserdata
    };
    if (writeCtx.rangedTransfer &&
        !DMCurlParseRequestedRange(rangeHeader, &writeCtx.expectedRangeStart, &writeCtx.expectedRangeEnd)) {
        out->code = CURLE_RANGE_ERROR;
        out->rangeResponseInvalid = 1;
        return out->code;
    }
    DMCurlHeaderCtx headerCtx = {0};
    DMCurlEasyTransferCtx transferCtx = {
        .write = &writeCtx,
        .header = &headerCtx,
        .discardResponseBody = 0,
    };
    char *urlCopy = DMCurlDupCString(url);
    char *extraHeadersCopy = DMCurlDupOrNull(extraHeaders);
    struct curl_slist *headerList = DMCurlBuildHeaderList(extraHeaders);
    int redirectHopCount = 0;

    curl_easy_setopt(easy, CURLOPT_URL, urlCopy != NULL ? urlCopy : url);
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https,ftp,ftps,sftp");
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "http,https,ftp,ftps,sftp");
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, connectTimeoutMS);
    if (transferTimeoutMS > 0) {
        curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, transferTimeoutMS);
    }
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, DMCurlWriteCallback);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &transferCtx);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, DMCurlHeaderCallback);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, &transferCtx);
    curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, DMCurlXferInfoCallback);
    curl_easy_setopt(easy, CURLOPT_XFERINFODATA, &writeCtx);
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(easy, CURLOPT_USERAGENT, DM_USER_AGENT);
    DMCurlApplyThroughputOptions(easy);
    if (rangeHeader != NULL && rangeHeader[0] != '\0') {
        curl_easy_setopt(easy, CURLOPT_RANGE, rangeHeader);
    }
    if (userpwd != NULL && userpwd[0] != '\0') {
        curl_easy_setopt(easy, CURLOPT_USERPWD, userpwd);
        curl_easy_setopt(easy, CURLOPT_HTTPAUTH, (long)CURLAUTH_ANY);
    }
    if (proxyURL != NULL && proxyURL[0] != '\0') {
        curl_easy_setopt(easy, CURLOPT_PROXY, proxyURL);
    }
    if (cookieJarPath != NULL && cookieJarPath[0] != '\0') {
        curl_easy_setopt(easy, CURLOPT_COOKIEFILE, cookieJarPath);
        curl_easy_setopt(easy, CURLOPT_COOKIEJAR, cookieJarPath);
    }
    if (headerList != NULL) {
        curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headerList);
    }

    CURLcode code = CURLE_OK;
    for (;;) {
        code = curl_easy_perform(easy);
        if (code != CURLE_OK) {
            break;
        }
        long status = headerCtx.responseStatus;
        if (status == 0) {
            curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status);
        }
        if (!DMCurlIsRedirectStatus(status) || headerCtx.location == NULL || headerCtx.location[0] == '\0') {
            break;
        }
        if (redirectHopCount >= maxRedirects) {
            break;
        }
        DMCurlOrigin source = {0};
        DMCurlOrigin destination = {0};
        const char *currentURL = urlCopy != NULL ? urlCopy : url;
        if (!DMCurlOriginFromURL(currentURL, &source)) {
            code = CURLE_URL_MALFORMAT;
            break;
        }
        char *nextURL = DMCurlResolveRedirectURL(currentURL, headerCtx.location);
        if (nextURL == NULL) {
            DMCurlOriginClear(&source);
            code = CURLE_URL_MALFORMAT;
            break;
        }
        if (!DMCurlOriginFromURL(nextURL, &destination)) {
            free(nextURL);
            DMCurlOriginClear(&source);
            code = CURLE_URL_MALFORMAT;
            break;
        }
        CURLcode policyError = CURLE_OK;
        char *filtered = DMCurlFilterHeadersForRedirect(extraHeadersCopy, &source, &destination, &policyError);
        DMCurlOriginClear(&source);
        DMCurlOriginClear(&destination);
        if (policyError != CURLE_OK) {
            free(filtered);
            free(nextURL);
            code = policyError;
            break;
        }
        free(extraHeadersCopy);
        extraHeadersCopy = filtered;
        curl_slist_free_all(headerList);
        headerList = DMCurlBuildHeaderList(extraHeadersCopy);
        free(urlCopy);
        urlCopy = nextURL;
        curl_easy_setopt(easy, CURLOPT_URL, urlCopy);
        if (headerList != NULL) {
            curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headerList);
        } else {
            curl_easy_setopt(easy, CURLOPT_HTTPHEADER, NULL);
        }
        DMCurlHeaderCtxClear(&headerCtx);
        transferCtx.discardResponseBody = 0;
        // Each hop is judged on its own response: a `rangedTransfer` cleared by
        // a full-body 200 must not carry over and disable validation for the
        // next hop's body.
        writeCtx.rangedTransfer = rangeHeader != NULL && rangeHeader[0] != '\0';
        redirectHopCount++;
    }
    out->code = code;
    out->bytesWritten = writeCtx.written;
    out->rangeResponseInvalid = writeCtx.rangeResponseInvalid;
    // Durability is owned by the Swift transfer layer (one fsync after the
    // map loop / single-stream finish). Per-easy fsync here serializes N
    // redundant full-file syncs when many segments share one fd.

    if (writeCtx.rangeResponseInvalid) {
        out->code = CURLE_RANGE_ERROR;
        code = CURLE_RANGE_ERROR;
    } else if (writeCtx.writeError != 0) {
        code = CURLE_WRITE_ERROR;
        out->code = code;
    } else if (writeCtx.bodyCapReached) {
        out->stoppedByBodyCap = 1;
        out->code = CURLE_OK;
        code = CURLE_OK;
    } else if (DMCurlShouldAbort(&writeCtx) && code != CURLE_OK) {
        code = CURLE_ABORTED_BY_CALLBACK;
        out->code = code;
    }

    long responseCode = headerCtx.responseStatus;
    if (responseCode == 0) {
        curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &responseCode);
    }
    out->httpStatus = responseCode;
    if (code == CURLE_OK) {
        curl_off_t contentLength = -1;
        if (curl_easy_getinfo(easy, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &contentLength) == CURLE_OK) {
            out->contentLength = contentLength;
        }
        free(out->finalURL);
        out->finalURL = urlCopy;
        urlCopy = NULL;
    }

    out->contentType = headerCtx.contentType;
    out->etag = headerCtx.etag;
    out->lastModified = headerCtx.lastModified;
    out->acceptRanges = headerCtx.acceptRanges;
    out->retryAfter = headerCtx.retryAfter;
    out->contentDisposition = headerCtx.contentDisposition;
    out->contentRange = headerCtx.contentRange;

    free(urlCopy);
    free(extraHeadersCopy);
    curl_slist_free_all(headerList);
    curl_easy_cleanup(easy);
    return out->code;
}

/* --- Multi / reusable easy download (FR-TRN-009) --- */

struct DMCurlEasyDownload {
    CURL *easy;
    DMCurlWriteCtx writeCtx;
    DMCurlHeaderCtx headerCtx;
    DMCurlEasyTransferCtx transferCtx;
    char *urlCopy;
    char *extraHeadersCopy;
    char *rangeHeaderCopy;
    char *userpwdCopy;
    char *proxyURLCopy;
    char *cookieJarPathCopy;
    struct curl_slist *headerList;
    long maxRedirects;
    int redirectHopCount;
};

static char *DMCurlDupOrNull(const char *value) {
    if (value == NULL || value[0] == '\0') {
        return NULL;
    }
    return DMCurlDupCString(value);
}

static void DMCurlApplyEasyDownloadOptions(
    CURL *easy,
    const char *url,
    DMCurlEasyTransferCtx *transferCtx,
    const char *rangeHeader,
    long connectTimeoutMS,
    long transferTimeoutMS,
    const char *userpwd,
    const char *proxyURL,
    const char *cookieJarPath,
    struct curl_slist *headerList
) {
    if (transferCtx == NULL || transferCtx->write == NULL || transferCtx->header == NULL) {
        return;
    }
    DMCurlWriteCtx *writeCtx = transferCtx->write;
    curl_easy_setopt(easy, CURLOPT_URL, url);
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https,ftp,ftps,sftp");
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "http,https,ftp,ftps,sftp");
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, connectTimeoutMS);
    if (transferTimeoutMS > 0) {
        curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, transferTimeoutMS);
    }
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, DMCurlWriteCallback);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, transferCtx);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, DMCurlHeaderCallback);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, transferCtx);
    curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, DMCurlXferInfoCallback);
    curl_easy_setopt(easy, CURLOPT_XFERINFODATA, writeCtx);
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(easy, CURLOPT_USERAGENT, DM_USER_AGENT);
    DMCurlApplyThroughputOptions(easy);
    if (rangeHeader != NULL && rangeHeader[0] != '\0') {
        curl_easy_setopt(easy, CURLOPT_RANGE, rangeHeader);
    }
    if (userpwd != NULL && userpwd[0] != '\0') {
        curl_easy_setopt(easy, CURLOPT_USERPWD, userpwd);
        curl_easy_setopt(easy, CURLOPT_HTTPAUTH, (long)CURLAUTH_ANY);
    }
    if (proxyURL != NULL && proxyURL[0] != '\0') {
        curl_easy_setopt(easy, CURLOPT_PROXY, proxyURL);
    }
    if (cookieJarPath != NULL && cookieJarPath[0] != '\0') {
        curl_easy_setopt(easy, CURLOPT_COOKIEFILE, cookieJarPath);
        curl_easy_setopt(easy, CURLOPT_COOKIEJAR, cookieJarPath);
    }
    if (headerList != NULL) {
        curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headerList);
    }
}

static void DMCurlFillDownloadResult(
    CURL *easy,
    DMCurlWriteCtx *writeCtx,
    DMCurlHeaderCtx *headerCtx,
    CURLcode code,
    DMCurlDownloadResult *out
) {
    memset(out, 0, sizeof(*out));
    out->contentLength = -1;
    out->code = code;
    out->bytesWritten = writeCtx->written;
    out->rangeResponseInvalid = writeCtx->rangeResponseInvalid;
    // See DMCurlEasyDownloadToFD: Swift owns the single post-pass fsync.
    if (writeCtx->rangeResponseInvalid) {
        out->code = CURLE_RANGE_ERROR;
    } else if (writeCtx->writeError != 0) {
        out->code = CURLE_WRITE_ERROR;
    } else if (writeCtx->bodyCapReached) {
        out->stoppedByBodyCap = 1;
        out->code = CURLE_OK;
    } else if (DMCurlShouldAbort(writeCtx) && code != CURLE_OK) {
        out->code = CURLE_ABORTED_BY_CALLBACK;
    } else if (DMCurlShouldStop(writeCtx)) {
        /* Stopping is a caller decision, not a failure. curl reports the
         * halted write as CURLE_WRITE_ERROR; bytesWritten above is the
         * authoritative count of what actually reached the file. */
        out->stoppedByRequest = 1;
        out->code = CURLE_OK;
    }
    long responseCode = headerCtx->responseStatus;
    if (responseCode == 0) {
        curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &responseCode);
    }
    out->httpStatus = responseCode;
    if (out->code == CURLE_OK) {
        curl_off_t contentLength = -1;
        if (curl_easy_getinfo(easy, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &contentLength) == CURLE_OK) {
            out->contentLength = contentLength;
        }
    }
    out->contentType = headerCtx->contentType;
    out->etag = headerCtx->etag;
    out->lastModified = headerCtx->lastModified;
    out->acceptRanges = headerCtx->acceptRanges;
    out->retryAfter = headerCtx->retryAfter;
    out->contentDisposition = headerCtx->contentDisposition;
    out->contentRange = headerCtx->contentRange;
    memset(headerCtx, 0, sizeof(*headerCtx));
}

DMCurlEasyDownload *DMCurlEasyDownloadCreate(
    const char *url,
    int fd,
    curl_off_t fileOffset,
    const char *rangeHeader,
    long connectTimeoutMS,
    long transferTimeoutMS,
    long maxRedirects,
    DMCurlAbortFlag *abortFlag,
    DMCurlProgressCallback progressCallback,
    void *progressUserdata,
    const char *userpwd,
    const char *proxyURL,
    const char *cookieJarPath,
    const char *extraHeaders
) {
    if (url == NULL || fd < 0) {
        return NULL;
    }
    DMCurlEasyDownload *download = (DMCurlEasyDownload *)calloc(1, sizeof(DMCurlEasyDownload));
    if (download == NULL) {
        return NULL;
    }
    download->easy = curl_easy_init();
    if (download->easy == NULL) {
        free(download);
        return NULL;
    }
    download->urlCopy = DMCurlDupCString(url);
    download->extraHeadersCopy = DMCurlDupOrNull(extraHeaders);
    download->rangeHeaderCopy = DMCurlDupOrNull(rangeHeader);
    download->userpwdCopy = DMCurlDupOrNull(userpwd);
    download->proxyURLCopy = DMCurlDupOrNull(proxyURL);
    download->cookieJarPathCopy = DMCurlDupOrNull(cookieJarPath);
    download->headerList = DMCurlBuildHeaderList(extraHeaders);
    download->maxRedirects = maxRedirects;
    download->redirectHopCount = 0;

    download->writeCtx.fd = fd;
    download->writeCtx.offset = fileOffset;
    download->writeCtx.written = 0;
    download->writeCtx.expectedRangeStart = 0;
    download->writeCtx.expectedRangeEnd = 0;
    download->writeCtx.knownTotal = -1;
    download->writeCtx.bodyByteLimit = 0;
    download->writeCtx.writeError = 0;
    download->writeCtx.rangedTransfer = rangeHeader != NULL && rangeHeader[0] != '\0';
    download->writeCtx.rangeResponseInvalid = 0;
    download->writeCtx.bodyCapReached = 0;
    download->writeCtx.stopRequested = 0;
    download->writeCtx.abortFlag = abortFlag;
    download->writeCtx.progressCallback = progressCallback;
    download->writeCtx.progressUserdata = progressUserdata;
    if (download->writeCtx.rangedTransfer &&
        !DMCurlParseRequestedRange(
            rangeHeader,
            &download->writeCtx.expectedRangeStart,
            &download->writeCtx.expectedRangeEnd
        )) {
        curl_easy_cleanup(download->easy);
        free(download->urlCopy);
        free(download->extraHeadersCopy);
        free(download->rangeHeaderCopy);
        free(download->userpwdCopy);
        free(download->proxyURLCopy);
        free(download->cookieJarPathCopy);
        curl_slist_free_all(download->headerList);
        free(download);
        return NULL;
    }
    download->transferCtx.write = &download->writeCtx;
    download->transferCtx.header = &download->headerCtx;
    download->transferCtx.discardResponseBody = 0;

    DMCurlApplyEasyDownloadOptions(
        download->easy,
        download->urlCopy,
        &download->transferCtx,
        download->rangeHeaderCopy,
        connectTimeoutMS,
        transferTimeoutMS,
        download->userpwdCopy,
        download->proxyURLCopy,
        download->cookieJarPathCopy,
        download->headerList
    );
    return download;
}

int DMCurlEasyDownloadFollowRedirectIfNeeded(DMCurlEasyDownload *download, CURLcode *errorOut) {
    if (errorOut != NULL) {
        *errorOut = CURLE_OK;
    }
    if (download == NULL || download->easy == NULL) {
        if (errorOut != NULL) {
            *errorOut = CURLE_FAILED_INIT;
        }
        return -1;
    }
    long status = download->headerCtx.responseStatus;
    if (status == 0) {
        curl_easy_getinfo(download->easy, CURLINFO_RESPONSE_CODE, &status);
    }
    if (!DMCurlIsRedirectStatus(status) || download->headerCtx.location == NULL ||
        download->headerCtx.location[0] == '\0') {
        return 0;
    }
    if (download->redirectHopCount >= download->maxRedirects) {
        return 0;
    }
    DMCurlOrigin source = {0};
    DMCurlOrigin destination = {0};
    if (!DMCurlOriginFromURL(download->urlCopy, &source)) {
        if (errorOut != NULL) {
            *errorOut = CURLE_URL_MALFORMAT;
        }
        return -1;
    }
    char *nextURL = DMCurlResolveRedirectURL(download->urlCopy, download->headerCtx.location);
    if (nextURL == NULL) {
        DMCurlOriginClear(&source);
        if (errorOut != NULL) {
            *errorOut = CURLE_URL_MALFORMAT;
        }
        return -1;
    }
    if (!DMCurlOriginFromURL(nextURL, &destination)) {
        free(nextURL);
        DMCurlOriginClear(&source);
        if (errorOut != NULL) {
            *errorOut = CURLE_URL_MALFORMAT;
        }
        return -1;
    }
    CURLcode policyError = CURLE_OK;
    char *filtered = DMCurlFilterHeadersForRedirect(
        download->extraHeadersCopy,
        &source,
        &destination,
        &policyError
    );
    DMCurlOriginClear(&source);
    DMCurlOriginClear(&destination);
    if (policyError != CURLE_OK) {
        free(filtered);
        free(nextURL);
        if (errorOut != NULL) {
            *errorOut = policyError;
        }
        return -1;
    }
    free(download->extraHeadersCopy);
    download->extraHeadersCopy = filtered;
    curl_slist_free_all(download->headerList);
    download->headerList = DMCurlBuildHeaderList(download->extraHeadersCopy);
    free(download->urlCopy);
    download->urlCopy = nextURL;
    curl_easy_setopt(download->easy, CURLOPT_URL, download->urlCopy);
    if (download->headerList != NULL) {
        curl_easy_setopt(download->easy, CURLOPT_HTTPHEADER, download->headerList);
    } else {
        curl_easy_setopt(download->easy, CURLOPT_HTTPHEADER, NULL);
    }
    DMCurlHeaderCtxClear(&download->headerCtx);
    download->transferCtx.discardResponseBody = 0;
    download->redirectHopCount++;
    return 1;
}

void DMCurlEasyDownloadRequestStop(DMCurlEasyDownload *download) {
    if (download != NULL) {
        download->writeCtx.stopRequested = 1;
    }
}

CURL *DMCurlEasyDownloadGetHandle(DMCurlEasyDownload *download) {
    if (download == NULL) {
        return NULL;
    }
    return download->easy;
}

void DMCurlEasyDownloadFinish(
    DMCurlEasyDownload *download,
    CURLcode performCode,
    DMCurlDownloadResult *out
) {
    if (download == NULL) {
        return;
    }
    if (out != NULL && download->easy != NULL) {
        DMCurlFillDownloadResult(
            download->easy,
            &download->writeCtx,
            &download->headerCtx,
            performCode,
            out
        );
        if (out->code == CURLE_OK && download->urlCopy != NULL) {
            free(out->finalURL);
            out->finalURL = DMCurlDupCString(download->urlCopy);
        }
    } else {
        DMCurlHeaderCtxClear(&download->headerCtx);
    }
    if (download->easy != NULL) {
        curl_easy_cleanup(download->easy);
    }
    free(download->urlCopy);
    free(download->extraHeadersCopy);
    free(download->rangeHeaderCopy);
    free(download->userpwdCopy);
    free(download->proxyURLCopy);
    free(download->cookieJarPathCopy);
    curl_slist_free_all(download->headerList);
    free(download);
}

CURLM *DMCurlMultiCreate(void) {
    CURLM *multi = curl_multi_init();
    if (multi != NULL) {
        /* Segmented ranges must each own a TCP connection: with the default
         * CURLPIPE_MULTIPLEX, HTTP/2 servers get all segments folded onto one
         * connection and per-connection throttles defeat the parallelism. */
        curl_multi_setopt(multi, CURLMOPT_PIPELINING, (long)CURLPIPE_NOTHING);
    }
    return multi;
}

CURLMcode DMCurlMultiAddEasy(CURLM *multi, CURL *easy) {
    if (multi == NULL || easy == NULL) {
        return CURLM_BAD_HANDLE;
    }
    return curl_multi_add_handle(multi, easy);
}

CURLMcode DMCurlMultiRemoveEasy(CURLM *multi, CURL *easy) {
    if (multi == NULL || easy == NULL) {
        return CURLM_BAD_HANDLE;
    }
    return curl_multi_remove_handle(multi, easy);
}

CURLMcode DMCurlMultiPerform(CURLM *multi, int *runningHandles) {
    if (multi == NULL || runningHandles == NULL) {
        return CURLM_BAD_HANDLE;
    }
    return curl_multi_perform(multi, runningHandles);
}

CURLMcode DMCurlMultiWait(CURLM *multi, int timeoutMS, int *numfds) {
    if (multi == NULL) {
        return CURLM_BAD_HANDLE;
    }
    int localFds = 0;
    int *outFds = numfds != NULL ? numfds : &localFds;
    return curl_multi_wait(multi, NULL, 0, timeoutMS, outFds);
}

CURLMsg *DMCurlMultiInfoRead(CURLM *multi, int *msgsLeft) {
    if (multi == NULL || msgsLeft == NULL) {
        return NULL;
    }
    return curl_multi_info_read(multi, msgsLeft);
}

void DMCurlMultiCleanup(CURLM *multi) {
    if (multi != NULL) {
        curl_multi_cleanup(multi);
    }
}
