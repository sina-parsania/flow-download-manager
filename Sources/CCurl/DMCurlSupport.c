// SPDX-License-Identifier: GPL-3.0-or-later
#include "DMCurlSupport.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

CURLcode DMCurlGlobalInit(void) {
    return curl_global_init(CURL_GLOBAL_DEFAULT);
}

void DMCurlGlobalCleanup(void) {
    curl_global_cleanup();
}

const curl_version_info_data *DMCurlVersionInfo(void) {
    return curl_version_info(CURLVERSION_NOW);
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
    free(result->contentDisposition);
    free(result->contentRange);
    memset(result, 0, sizeof(*result));
    result->contentLength = -1;
}

typedef struct {
    int fd;
    curl_off_t offset;
    curl_off_t written;
    int writeError;
    volatile int32_t *abortFlag;
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
} DMCurlHeaderCtx;

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

static int DMCurlShouldAbort(const DMCurlWriteCtx *ctx) {
    return ctx != NULL && ctx->abortFlag != NULL && *(ctx->abortFlag) != 0;
}

static size_t DMCurlHeaderCallback(char *buffer, size_t size, size_t nitems, void *userdata) {
    size_t total = size * nitems;
    DMCurlHeaderCtx *ctx = (DMCurlHeaderCtx *)userdata;
    if (ctx == NULL || total < 2) {
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

    if (DMCurlHeaderEquals(buffer, total, "content-type")) {
        DMCurlAssignHeader(&ctx->contentType, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "etag")) {
        DMCurlAssignHeader(&ctx->etag, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "last-modified")) {
        DMCurlAssignHeader(&ctx->lastModified, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "accept-ranges")) {
        DMCurlAssignHeader(&ctx->acceptRanges, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "content-disposition")) {
        DMCurlAssignHeader(&ctx->contentDisposition, value, valueLength);
    } else if (DMCurlHeaderEquals(buffer, total, "content-range")) {
        DMCurlAssignHeader(&ctx->contentRange, value, valueLength);
    }
    return total;
}

static size_t DMCurlWriteCallback(char *ptr, size_t size, size_t nmemb, void *userdata) {
    DMCurlWriteCtx *ctx = (DMCurlWriteCtx *)userdata;
    size_t total = size * nmemb;
    if (ctx == NULL || total == 0) {
        return total;
    }
    if (DMCurlShouldAbort(ctx)) {
        return 0;
    }
    size_t remaining = total;
    const char *cursor = ptr;
    while (remaining > 0) {
        if (DMCurlShouldAbort(ctx)) {
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
            if (ctx->progressCallback(ctx->written, ctx->progressUserdata) != 0) {
                if (ctx->abortFlag != NULL) {
                    *(ctx->abortFlag) = 1;
                }
                return 0;
            }
        }
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
    (void)dltotal;
    (void)dlnow;
    (void)ultotal;
    (void)ulnow;
    DMCurlWriteCtx *ctx = (DMCurlWriteCtx *)clientp;
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
    volatile int32_t *abortFlag,
    DMCurlProgressCallback progressCallback,
    void *progressUserdata,
    const char *userpwd,
    const char *proxyURL,
    const char *cookieJarPath,
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
        .writeError = 0,
        .abortFlag = abortFlag,
        .progressCallback = progressCallback,
        .progressUserdata = progressUserdata
    };
    DMCurlHeaderCtx headerCtx = {0};

    curl_easy_setopt(easy, CURLOPT_URL, url);
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, maxRedirects);
    curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https,ftp,ftps,sftp");
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "http,https,ftp,ftps,sftp");
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, connectTimeoutMS);
    if (transferTimeoutMS > 0) {
        curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, transferTimeoutMS);
    }
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, DMCurlWriteCallback);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &writeCtx);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, DMCurlHeaderCallback);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, &headerCtx);
    curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, DMCurlXferInfoCallback);
    curl_easy_setopt(easy, CURLOPT_XFERINFODATA, &writeCtx);
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(easy, CURLOPT_USERAGENT, "DownloadManager/0.1");
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

    CURLcode code = curl_easy_perform(easy);
    out->code = code;
    out->bytesWritten = writeCtx.written;
    if (writeCtx.written > 0) {
        (void)fsync(fd);
    }

    if (writeCtx.writeError != 0) {
        code = CURLE_WRITE_ERROR;
        out->code = code;
    } else if (DMCurlShouldAbort(&writeCtx) && code != CURLE_OK) {
        code = CURLE_ABORTED_BY_CALLBACK;
        out->code = code;
    }

    if (code == CURLE_OK) {
        curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &out->httpStatus);
        curl_off_t contentLength = -1;
        if (curl_easy_getinfo(easy, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &contentLength) == CURLE_OK) {
            out->contentLength = contentLength;
        }
        char *effective = NULL;
        if (curl_easy_getinfo(easy, CURLINFO_EFFECTIVE_URL, &effective) == CURLE_OK) {
            out->finalURL = DMCurlDupCString(effective);
        }
    }

    out->contentType = headerCtx.contentType;
    out->etag = headerCtx.etag;
    out->lastModified = headerCtx.lastModified;
    out->acceptRanges = headerCtx.acceptRanges;
    out->contentDisposition = headerCtx.contentDisposition;
    out->contentRange = headerCtx.contentRange;

    curl_easy_cleanup(easy);
    return out->code;
}

/* --- Multi / reusable easy download (FR-TRN-009) --- */

struct DMCurlEasyDownload {
    CURL *easy;
    DMCurlWriteCtx writeCtx;
    DMCurlHeaderCtx headerCtx;
    char *rangeHeaderCopy;
    char *userpwdCopy;
    char *proxyURLCopy;
    char *cookieJarPathCopy;
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
    DMCurlWriteCtx *writeCtx,
    DMCurlHeaderCtx *headerCtx,
    const char *rangeHeader,
    long connectTimeoutMS,
    long transferTimeoutMS,
    long maxRedirects,
    const char *userpwd,
    const char *proxyURL,
    const char *cookieJarPath
) {
    curl_easy_setopt(easy, CURLOPT_URL, url);
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, maxRedirects);
    curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https,ftp,ftps,sftp");
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "http,https,ftp,ftps,sftp");
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, connectTimeoutMS);
    if (transferTimeoutMS > 0) {
        curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, transferTimeoutMS);
    }
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, DMCurlWriteCallback);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, writeCtx);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, DMCurlHeaderCallback);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, headerCtx);
    curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, DMCurlXferInfoCallback);
    curl_easy_setopt(easy, CURLOPT_XFERINFODATA, writeCtx);
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(easy, CURLOPT_USERAGENT, "DownloadManager/0.1");
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
    if (writeCtx->written > 0) {
        (void)fsync(writeCtx->fd);
    }
    if (writeCtx->writeError != 0) {
        out->code = CURLE_WRITE_ERROR;
    } else if (DMCurlShouldAbort(writeCtx) && code != CURLE_OK) {
        out->code = CURLE_ABORTED_BY_CALLBACK;
    }
    if (out->code == CURLE_OK) {
        curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &out->httpStatus);
        curl_off_t contentLength = -1;
        if (curl_easy_getinfo(easy, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &contentLength) == CURLE_OK) {
            out->contentLength = contentLength;
        }
        char *effective = NULL;
        if (curl_easy_getinfo(easy, CURLINFO_EFFECTIVE_URL, &effective) == CURLE_OK) {
            out->finalURL = DMCurlDupCString(effective);
        }
    }
    out->contentType = headerCtx->contentType;
    out->etag = headerCtx->etag;
    out->lastModified = headerCtx->lastModified;
    out->acceptRanges = headerCtx->acceptRanges;
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
    volatile int32_t *abortFlag,
    DMCurlProgressCallback progressCallback,
    void *progressUserdata,
    const char *userpwd,
    const char *proxyURL,
    const char *cookieJarPath
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
    download->rangeHeaderCopy = DMCurlDupOrNull(rangeHeader);
    download->userpwdCopy = DMCurlDupOrNull(userpwd);
    download->proxyURLCopy = DMCurlDupOrNull(proxyURL);
    download->cookieJarPathCopy = DMCurlDupOrNull(cookieJarPath);

    download->writeCtx.fd = fd;
    download->writeCtx.offset = fileOffset;
    download->writeCtx.written = 0;
    download->writeCtx.writeError = 0;
    download->writeCtx.abortFlag = abortFlag;
    download->writeCtx.progressCallback = progressCallback;
    download->writeCtx.progressUserdata = progressUserdata;

    DMCurlApplyEasyDownloadOptions(
        download->easy,
        url,
        &download->writeCtx,
        &download->headerCtx,
        download->rangeHeaderCopy,
        connectTimeoutMS,
        transferTimeoutMS,
        maxRedirects,
        download->userpwdCopy,
        download->proxyURLCopy,
        download->cookieJarPathCopy
    );
    return download;
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
    } else {
        free(download->headerCtx.contentType);
        free(download->headerCtx.etag);
        free(download->headerCtx.lastModified);
        free(download->headerCtx.acceptRanges);
        free(download->headerCtx.contentDisposition);
        free(download->headerCtx.contentRange);
    }
    if (download->easy != NULL) {
        curl_easy_cleanup(download->easy);
    }
    free(download->rangeHeaderCopy);
    free(download->userpwdCopy);
    free(download->proxyURLCopy);
    free(download->cookieJarPathCopy);
    free(download);
}

CURLM *DMCurlMultiCreate(void) {
    return curl_multi_init();
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
