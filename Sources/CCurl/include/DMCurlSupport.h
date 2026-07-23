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

#endif /* DM_CURL_SUPPORT_H */
