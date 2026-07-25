// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DM_CURL_SUPPORT_H
#define DM_CURL_SUPPORT_H
#include <curl/curl.h>
#include <stdint.h>
CURLcode DMCurlGlobalInit(void);
void DMCurlGlobalCleanup(void);
const curl_version_info_data *DMCurlVersionInfo(void);
CURLUcode DMCurlURLSetString(CURLU *handle, CURLUPart part, const char *value, unsigned int flags);
CURLUcode DMCurlURLGetString(const CURLU *handle, CURLUPart part, char **value, unsigned int flags);
CURLUcode DMCurlURLSetURL(CURLU *handle, const char *url);
typedef struct DMCurlDownloadResult {
    CURLcode code; long httpStatus; curl_off_t bytesWritten; int stoppedByRequest; int stoppedByBodyCap; int rangeResponseInvalid;
    curl_off_t contentLength; char *finalURL; char *contentType; char *etag; char *lastModified;
    char *acceptRanges; char *contentDisposition; char *contentRange;
} DMCurlDownloadResult;
void DMCurlDownloadResultClear(DMCurlDownloadResult *result);
typedef struct DMCurlAbortFlag DMCurlAbortFlag;
DMCurlAbortFlag *DMCurlAbortFlagCreate(void);
void DMCurlAbortFlagDestroy(DMCurlAbortFlag *flag);
void DMCurlAbortFlagRequest(DMCurlAbortFlag *flag);
int DMCurlAbortFlagIsSet(const DMCurlAbortFlag *flag);
int DMCurlAbortFlagIsSetHandle(const void *flag);
void DMCurlAbortFlagReset(DMCurlAbortFlag *flag);
typedef int (*DMCurlProgressCallback)(curl_off_t written, curl_off_t total, void *userdata);
CURLcode DMCurlEasyDownloadToFD(const char *url,int fd,curl_off_t fileOffset,const char *rangeHeader,long connectTimeoutMS,long transferTimeoutMS,long maxRedirects,DMCurlAbortFlag *abortFlag,DMCurlProgressCallback progressCallback,void *progressUserdata,const char *userpwd,const char *proxyURL,const char *cookieJarPath,const char *extraHeaders,curl_off_t bodyByteLimit,DMCurlDownloadResult *out);
typedef struct DMCurlEasyDownload DMCurlEasyDownload;
DMCurlEasyDownload *DMCurlEasyDownloadCreate(const char *url,int fd,curl_off_t fileOffset,const char *rangeHeader,long connectTimeoutMS,long transferTimeoutMS,long maxRedirects,DMCurlAbortFlag *abortFlag,DMCurlProgressCallback progressCallback,void *progressUserdata,const char *userpwd,const char *proxyURL,const char *cookieJarPath,const char *extraHeaders);
CURL *DMCurlEasyDownloadGetHandle(DMCurlEasyDownload *download);
void DMCurlEasyDownloadRequestStop(DMCurlEasyDownload *download);
int DMCurlEasyDownloadFollowRedirectIfNeeded(DMCurlEasyDownload *download, CURLcode *errorOut);
void DMCurlEasyDownloadFinish(DMCurlEasyDownload *download,CURLcode performCode,DMCurlDownloadResult *out);
CURLM *DMCurlMultiCreate(void);
CURLMcode DMCurlMultiAddEasy(CURLM *multi,CURL *easy);
CURLMcode DMCurlMultiRemoveEasy(CURLM *multi,CURL *easy);
CURLMcode DMCurlMultiPerform(CURLM *multi,int *runningHandles);
CURLMcode DMCurlMultiWait(CURLM *multi,int timeoutMS,int *numfds);
CURLMsg *DMCurlMultiInfoRead(CURLM *multi,int *msgsLeft);
void DMCurlMultiCleanup(CURLM *multi);
#endif
