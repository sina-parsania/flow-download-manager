// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DM_CURL_SUPPORT_H
#define DM_CURL_SUPPORT_H

#include <curl/curl.h>
#include <stdint.h>

/// Narrow C helpers so Swift does not depend on curl macros that Clang modules
/// do not always re-export into the Swift overlay.
CURLcode DMCurlGlobalInit(void);
void DMCurlGlobalCleanup(void);
const curl_version_info_data *DMCurlVersionInfo(void);

CURLUcode DMCurlURLSetString(CURLU *handle, CURLUPart part, const char *value, unsigned int flags);
CURLUcode DMCurlURLGetString(const CURLU *handle, CURLUPart part, char **value, unsigned int flags);
CURLUcode DMCurlURLSetURL(CURLU *handle, const char *url);

/// Result of a blocking easy transfer. String fields are owned and must be
/// released with @c DMCurlDownloadResultClear.
typedef struct DMCurlDownloadResult {
    CURLcode code;
    long httpStatus;
    curl_off_t bytesWritten;
    curl_off_t contentLength; /* -1 if unknown */
    char *finalURL;
    char *contentType;
    char *etag;
    char *lastModified;
    char *acceptRanges;
    char *contentDisposition;
    char *contentRange;
} DMCurlDownloadResult;

void DMCurlDownloadResultClear(DMCurlDownloadResult *result);

/// Optional progress callback. @c written is bytes written in this transfer
/// (not including @c fileOffset). Return non-zero to abort.
typedef int (*DMCurlProgressCallback)(curl_off_t written, void *userdata);

/// Blocking GET (or ranged GET when @c rangeHeader is non-NULL, e.g. "0-1023")
/// writing body bytes with @c pwrite at @c fileOffset. @c fd must be open for write.
/// When @c abortFlag is non-NULL and becomes non-zero, the transfer aborts with
/// @c CURLE_ABORTED_BY_CALLBACK.
/// @c userpwd may be "user:password" or NULL. @c proxyURL may be a proxy URL or NULL.
/// @c cookieJarPath may be a Netscape cookie-jar path (COOKIEFILE + COOKIEJAR) or NULL.
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
);

/// Opaque easy download handle for use with curl_multi (heap-owned write context).
typedef struct DMCurlEasyDownload DMCurlEasyDownload;

/// Creates a configured easy handle that writes to @c fd. Does not perform.
/// Caller must eventually call @c DMCurlEasyDownloadFinish (after multi remove).
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
);

CURL *DMCurlEasyDownloadGetHandle(DMCurlEasyDownload *download);

/// Fills @c out using @c performCode from multi (or easy_perform), then frees @c download.
void DMCurlEasyDownloadFinish(
    DMCurlEasyDownload *download,
    CURLcode performCode,
    DMCurlDownloadResult *out
);

/// curl_multi wrappers (FR-TRN-009 foundation).
CURLM *DMCurlMultiCreate(void);
CURLMcode DMCurlMultiAddEasy(CURLM *multi, CURL *easy);
CURLMcode DMCurlMultiRemoveEasy(CURLM *multi, CURL *easy);
CURLMcode DMCurlMultiPerform(CURLM *multi, int *runningHandles);
/// Wait up to @c timeoutMS for activity. @c numfds may be NULL.
CURLMcode DMCurlMultiWait(CURLM *multi, int timeoutMS, int *numfds);
CURLMsg *DMCurlMultiInfoRead(CURLM *multi, int *msgsLeft);
void DMCurlMultiCleanup(CURLM *multi);

#endif /* DM_CURL_SUPPORT_H */
