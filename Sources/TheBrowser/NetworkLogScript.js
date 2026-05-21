(() => {
    if (window.__theBrowserNetworkLog?.installed) {
        return;
    }

    const HANDLER = "__THEBROWSER_NETWORK_HANDLER__";
    const BODY_LIMIT_BYTES = 256 * 1024;
    const FLUSH_DELAY_MS = 250;
    const queue = [];
    let flushTimer = null;

    // This is a best-effort shim, not HAR capture. WKWebView does not expose
    // a public HAR API, so this cannot observe websockets, sendBeacon, full
    // service-worker traffic, requests that race ahead of script injection,
    // or all subresources that WebKit starts before atDocumentStart runs.
    function enqueue(event) {
        queue.push({
            ts: Date.now(),
            pageURL: safePageURL(),
            ...event
        });
        scheduleFlush();
    }

    function scheduleFlush() {
        if (flushTimer !== null) {
            return;
        }
        flushTimer = setTimeout(flushNow, FLUSH_DELAY_MS);
    }

    function flushNow() {
        if (flushTimer !== null) {
            clearTimeout(flushTimer);
            flushTimer = null;
        }
        if (queue.length === 0) {
            return;
        }
        const events = queue.splice(0, queue.length);
        try {
            window.webkit?.messageHandlers?.[HANDLER]?.postMessage({ events });
        } catch (_) {}
    }

    function safePageURL() {
        try {
            return String(location.href || "");
        } catch (_) {
            return "";
        }
    }

    function absoluteURL(value) {
        try {
            return new URL(String(value), document.baseURI || location.href).href;
        } catch (_) {
            return String(value || "");
        }
    }

    function headersFrom(value) {
        const out = {};
        if (!value) {
            return out;
        }
        try {
            if (typeof Headers !== "undefined" && value instanceof Headers) {
                value.forEach((headerValue, headerName) => {
                    out[headerName] = String(headerValue);
                });
                return out;
            }
            if (Array.isArray(value)) {
                for (const pair of value) {
                    if (Array.isArray(pair) && pair.length >= 2) {
                        out[String(pair[0])] = String(pair[1]);
                    }
                }
                return out;
            }
            if (typeof value === "object") {
                for (const key of Object.keys(value)) {
                    out[key] = String(value[key]);
                }
            }
        } catch (_) {}
        return out;
    }

    function rawHeadersToObject(raw) {
        const out = {};
        if (!raw) {
            return out;
        }
        for (const line of String(raw).split(/\r?\n/)) {
            const index = line.indexOf(":");
            if (index <= 0) {
                continue;
            }
            const name = line.slice(0, index).trim();
            const value = line.slice(index + 1).trim();
            if (name) {
                out[name] = value;
            }
        }
        return out;
    }

    function byteLength(text) {
        try {
            return new TextEncoder().encode(text).byteLength;
        } catch (_) {
            return String(text).length;
        }
    }

    function capText(text) {
        if (text === null || text === undefined) {
            return null;
        }
        const string = String(text);
        if (byteLength(string) <= BODY_LIMIT_BYTES) {
            return string;
        }
        return string.slice(0, BODY_LIMIT_BYTES) + "\n[thebrowser: body truncated at 256KB]";
    }

    function bodyToTextSync(body) {
        if (body === null || body === undefined) {
            return null;
        }
        if (typeof body === "string") {
            return capText(body);
        }
        if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) {
            return capText(body.toString());
        }
        if (typeof Blob !== "undefined" && body instanceof Blob) {
            return body.size <= BODY_LIMIT_BYTES ? "[Blob body omitted by content script]" : null;
        }
        if (typeof FormData !== "undefined" && body instanceof FormData) {
            return "[FormData body omitted by content script]";
        }
        if (typeof ArrayBuffer !== "undefined" && body instanceof ArrayBuffer) {
            return body.byteLength <= BODY_LIMIT_BYTES ? "[ArrayBuffer body omitted by content script]" : null;
        }
        return null;
    }

    function looksTextual(contentType) {
        const type = String(contentType || "").toLowerCase();
        return type.includes("text/")
            || type.includes("json")
            || type.includes("xml")
            || type.includes("javascript")
            || type.includes("x-www-form-urlencoded")
            || type.includes("svg");
    }

    async function limitedResponseText(response) {
        const contentLength = Number(response.headers?.get?.("content-length") || 0);
        const contentType = response.headers?.get?.("content-type") || "";
        if (contentLength > BODY_LIMIT_BYTES || !looksTextual(contentType)) {
            return null;
        }

        if (!response.body?.getReader) {
            const text = await response.text();
            return capText(text);
        }

        const reader = response.body.getReader();
        const chunks = [];
        let received = 0;
        let truncated = false;
        while (true) {
            const { done, value } = await reader.read();
            if (done) {
                break;
            }
            received += value.byteLength;
            if (received > BODY_LIMIT_BYTES) {
                truncated = true;
                try {
                    await reader.cancel();
                } catch (_) {}
                break;
            }
            chunks.push(value);
        }

        const merged = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0));
        let offset = 0;
        for (const chunk of chunks) {
            merged.set(chunk, offset);
            offset += chunk.byteLength;
        }
        const text = new TextDecoder("utf-8", { fatal: false }).decode(merged);
        return truncated ? text + "\n[thebrowser: body truncated at 256KB]" : text;
    }

    function normalizeFetch(input, init) {
        let url = "";
        let method = "GET";
        let headers = {};
        try {
            if (typeof Request !== "undefined" && input instanceof Request) {
                url = input.url;
                method = input.method || method;
                headers = headersFrom(input.headers);
            } else {
                url = absoluteURL(input);
            }
            if (init) {
                if (init.method) {
                    method = String(init.method);
                }
                headers = { ...headers, ...headersFrom(init.headers) };
            }
        } catch (_) {}

        return {
            url,
            method: method.toUpperCase(),
            requestHeaders: headers,
            requestBody: init ? bodyToTextSync(init.body) : null
        };
    }

    const originalFetch = window.fetch;
    if (typeof originalFetch === "function") {
        window.fetch = async function theBrowserFetch(input, init) {
            const meta = normalizeFetch(input, init);
            const started = performance.now();
            try {
                const response = await originalFetch.apply(this, arguments);
                const event = {
                    source: "fetch",
                    type: "fetch",
                    method: meta.method,
                    url: meta.url || response.url || "",
                    status: response.status,
                    requestHeaders: meta.requestHeaders,
                    responseHeaders: headersFrom(response.headers),
                    requestBody: meta.requestBody,
                    durationMs: performance.now() - started
                };

                limitedResponseText(response.clone())
                    .then((body) => {
                        if (body !== null) {
                            event.responseBody = body;
                        }
                        enqueue(event);
                    })
                    .catch(() => enqueue(event));

                return response;
            } catch (error) {
                enqueue({
                    source: "fetch",
                    type: "fetch",
                    method: meta.method,
                    url: meta.url,
                    requestHeaders: meta.requestHeaders,
                    requestBody: meta.requestBody,
                    durationMs: performance.now() - started,
                    responseBody: String(error)
                });
                throw error;
            }
        };
    }

    const xhrPrototype = window.XMLHttpRequest?.prototype;
    if (xhrPrototype) {
        const originalOpen = xhrPrototype.open;
        const originalSend = xhrPrototype.send;
        const originalSetRequestHeader = xhrPrototype.setRequestHeader;

        xhrPrototype.open = function theBrowserXHROpen(method, url) {
            this.__theBrowserArchive = {
                method: String(method || "GET").toUpperCase(),
                url: absoluteURL(url),
                requestHeaders: {},
                started: 0
            };
            return originalOpen.apply(this, arguments);
        };

        xhrPrototype.setRequestHeader = function theBrowserXHRSetHeader(name, value) {
            if (this.__theBrowserArchive) {
                this.__theBrowserArchive.requestHeaders[String(name)] = String(value);
            }
            return originalSetRequestHeader.apply(this, arguments);
        };

        xhrPrototype.send = function theBrowserXHRSend(body) {
            const meta = this.__theBrowserArchive || {
                method: "GET",
                url: "",
                requestHeaders: {},
                started: 0
            };
            meta.requestBody = bodyToTextSync(body);
            meta.started = performance.now();

            this.addEventListener("loadend", () => {
                let status = null;
                let responseHeaders = {};
                let responseBody = null;
                try {
                    status = this.status;
                    responseHeaders = rawHeadersToObject(this.getAllResponseHeaders());
                } catch (_) {}
                try {
                    const responseType = this.responseType || "text";
                    const contentType = responseHeaders["content-type"] || responseHeaders["Content-Type"] || "";
                    if ((responseType === "text" || responseType === "") && looksTextual(contentType)) {
                        responseBody = capText(this.responseText || "");
                    }
                } catch (_) {}

                enqueue({
                    source: "xhr",
                    type: "xmlhttprequest",
                    method: meta.method,
                    url: meta.url,
                    status,
                    requestHeaders: meta.requestHeaders,
                    responseHeaders,
                    requestBody: meta.requestBody,
                    responseBody,
                    durationMs: performance.now() - meta.started
                });
            }, { once: true });

            return originalSend.apply(this, arguments);
        };
    }

    try {
        const seen = new Set();
        const observe = (entries) => {
            for (const entry of entries) {
                const key = `${entry.name}|${entry.startTime}|${entry.duration}`;
                if (seen.has(key)) {
                    continue;
                }
                seen.add(key);
                enqueue({
                    source: "performance",
                    type: entry.initiatorType || "resource",
                    method: "GET",
                    url: entry.name,
                    durationMs: entry.duration
                });
            }
        };
        observe(performance.getEntriesByType("resource"));
        const observer = new PerformanceObserver((list) => observe(list.getEntries()));
        observer.observe({ type: "resource", buffered: true });
    } catch (_) {}

    window.__theBrowserNetworkLog = {
        installed: true,
        flushNow
    };
})();
