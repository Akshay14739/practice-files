# HTTP & HTTPS
*The stateless request/response language of the web — how one "GET" becomes a page, a status code, or a 502 from a dead pod.*

---

## 🪜 Rung 0 — The Setup

**What am I learning?**
You already know how bytes get from machine to machine: IP finds the host, ports find the process, TCP makes the stream reliable, TLS encrypts it. This rung teaches what those bytes actually *say* once they arrive. **HTTP** (HyperText Transfer Protocol) is a **stateless, text-based, client-server request/response protocol** carried over TCP. A client sends a **request** ("GET me `/pods`"), a server sends back a **response** ("200 OK, here's the JSON"), and the connection remembers nothing afterward. **HTTPS** is that exact same protocol wrapped inside a **TLS** encrypted tunnel — nothing more, nothing less. Everything above Layer 4 that you touch daily — the Kubernetes API, an ALB routing rule, a liveness probe, a `curl`, a gRPC call — is HTTP.

**Why did it land on my desk?**
Picture a Wednesday incident on your EKS cluster. Users report the app is "down." You open the ALB and see it returning **502 Bad Gateway** on some requests and **503 Service Unavailable** on others. `kubectl get pods` shows two pods `CrashLoopBackOff` and one `Running` but `0/1 READY`. You check the Ingress: it routes `api.shop.com/orders` to one Service and `/` to another by **host and path** — both HTTP-layer decisions. A teammate asks why the readiness probe is failing when the pod "looks up," and you realize the probe is an **HTTP GET** to `/healthz` that's coming back **500**. Then someone points out the API server itself is just an **HTTPS REST API** on `:6443`, and every `kubectl` command you've ever run is HTTP requests with status codes. Every symptom in this incident is an HTTP fact. If HTTP is fuzzy, L7 troubleshooting stays guesswork.

**What do I already know?**
- **TCP** gives you a reliable, ordered byte stream (SYN/SYN-ACK/ACK handshake, port 80/443).
- **Ports:** HTTP defaults to **80**, HTTPS to **443**; the API server listens on **6443**.
- **TLS** encrypts a connection and proves server identity with a certificate (covered in depth in the next file).
- `curl`, `kubectl`, Ingress, ALB, liveness/readiness probes are already in your vocabulary.

Hold those. HTTP sits directly on top of TCP (and TLS for HTTPS). We're about to fill in what travels *inside* that reliable stream.

---

## 🔥 Rung 1 — The Pain

**The problem that forced HTTP to exist:** machines could move bytes, but there was no *agreed grammar* for "ask for a document and get a reliable answer with a machine-readable outcome."

Rewind to the late 1980s. TCP could carry a stream between two hosts, but every application invented its own ad-hoc conversation. If you wanted to fetch a research paper from another university, you needed a bespoke client that spoke that server's private dialect. There was **no universal way** to say:
- "Give me *this specific resource*" (a path/URL),
- "Here's *how* I want to interact with it" (a method/verb),
- "Here's *metadata* about my request" (headers),
- and crucially, "*did it work?*" in a way a program — not just a human — could branch on (a status code).

Before HTTP, a client had no standard signal to distinguish "the thing you asked for isn't here" from "you're not allowed" from "the server is broken." A failed transfer just... hung, or dumped garbage. Automation was nearly impossible because software couldn't reliably tell success from failure.

**What people did before, and why it hurt:** protocols like Gopher and FTP existed, but they were rigid — FTP needs *two* TCP connections (control + data) and holds session state, making it painful through firewalls and NAT. Gopher was menu-driven with no rich metadata. Neither gave you a clean, extensible, one-request-one-response model with a standardized outcome code and free-form headers. Adding a new capability meant a new protocol.

**Who feels this pain most today?** You do, every time L7 matters:
- An **ALB or Ingress** can only route by host and path *because* HTTP puts the `Host` header and request path in a standard place. Without HTTP's structure, an L7 load balancer is impossible — you'd be stuck at L4 (IP:port only).
- A **liveness/readiness probe** needs a machine-readable "healthy?" answer. HTTP status codes give it one: `200` = ready, anything else = not. No status codes, no HTTP health checks.
- A **502/503** from your ALB is only meaningful because the status-code *classes* are standardized — `5xx` unambiguously means "the server side broke," pointing you at the pod, not the client.
- Every **REST API** (including `kube-apiserver`) leans on methods (GET/POST/PUT/DELETE) and status codes as its entire contract.

Without HTTP's agreed grammar, none of the web's L7 machinery — CDNs, API gateways, service meshes, REST — can exist.

> **Check yourself before Rung 2:** An ALB inspects an incoming connection and decides to send `shop.com/orders` to Service A and `shop.com/images` to Service B. A plain L4 load balancer (IP:port only) cannot do this. What *specific pieces of information* must HTTP put in a standard, readable place for the ALB to make that routing decision?

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Memorize it word for word:

> **HTTP is a stateless request/response protocol: the client sends a `METHOD + PATH + headers (+body)`, the server replies with a `STATUS CODE + headers (+body)`, and each exchange stands completely alone — HTTPS is that same exchange sealed inside a TLS tunnel.**

That's the whole concept. Everything else is derivable:

- **Why methods (GET/POST/PUT/DELETE/PATCH)?** Because "request" needs a *verb* — what do you want done to the resource? Read it, create it, replace it, remove it, patch it. The verb is the first word of every request.
- **Why status codes, grouped in classes?** Because "response" needs a *machine-readable outcome*, and outcomes fall into five natural buckets: informational (1xx), success (2xx), "go elsewhere" (3xx), "you messed up" (4xx), "I messed up" (5xx). The first digit *is* the category — you can triage from that digit alone.
- **Why headers?** Because both sides need *metadata* about the message that isn't the body itself: which host, what content type, who's authorized, how to cache. Headers are the labeled envelope; the body is the letter inside.
- **Why cookies and sessions?** Because the protocol is **stateless** — the server forgets you the instant it replies. If you need "logged-in-ness" to persist across requests, *something* must carry state back and forth. That something is a **cookie** the server hands you (`Set-Cookie`) and you present on every later request. State is bolted on *because* the core is stateless.
- **Why HTTP/2 and HTTP/3?** Because the *semantics* above (methods, statuses, headers) are timeless, but the *wire encoding and transport* underneath can be optimized: HTTP/1.1 is text over one-request-at-a-time TCP; HTTP/2 is binary and multiplexed over one TCP connection; HTTP/3 moves onto QUIC over UDP to kill head-of-line blocking. Same grammar, faster delivery.

If you get lost below, come back to this sentence and re-derive. The rest is that sentence unfolded.

---

## ⚙️ Rung 3 — The Machinery

> ### 🧸 Plain-English first (read this before the technical version)
>
> **HTTP is just the words of a conversation** — the web's standard way of phrasing "please send me this page" and "here it is." It doesn't worry about how the words get delivered; a lower service (TCP — think certified mail that guarantees everything arrives complete and in order) handles delivery, and for secure sites an extra sealed envelope (TLS encryption) keeps eavesdroppers out. HTTP just fills that reliable pipe with a structured message.
>
> **What a request looks like.** It's a short, rigidly formatted letter: an opening line ("GET this page, using this version of the language"), then labeled notes ("here's who I am," "here's the format I'd like back"), then a blank line meaning "notes finished," then — only when you're sending something in — the actual contents.
>
> **What a reply looks like.** The mirror image: a verdict line with a result number ("200 OK"), then notes describing what's attached, a blank line, then the attachment itself.
>
> **The verbs.** Requests start with an action word: GET (just read it), POST (submit something new), PUT (replace it), PATCH (edit part of it), DELETE (remove it), HEAD (send only the notes, not the contents). A key idea: some actions are safe to *repeat* — deleting twice is the same as deleting once — but submitting twice creates two things. That decides what a system may automatically retry.
>
> **The result numbers.** The first digit tells the whole story: 2xx "it worked," 3xx "it moved, go over there," 4xx "*you* made a mistake" (401 "who are you?" — no valid ID; 403 "I know who you are, and no"; 404 "no such thing here"), 5xx "*we* broke." Two cousins worth separating: 502 means the doorman reached the office but got gibberish back; 503 means there was *nobody* healthy to hand the request to at all.
>
> **The server has no memory.** Each request is a fresh encounter — the clerk forgets you the moment you leave. Staying "logged in" works via a claim ticket (a **cookie**): the server hands you a ticket once, your browser attaches it to every later request, and the clerk looks the ticket up. The forgetfulness is a feature — any of ten identical clerks can serve you.
>
> **Three delivery generations, same language.** Version 1.1 handles one request at a time per line, like a single-file checkout queue. Version 2 interleaves many conversations over one line at once. Version 3 rebuilds the delivery layer itself so one lost package no longer holds up all the other conversations sharing the line.

*Now the original technical deep-dive — the same ideas, in precise form:*

This is the rung to go slow on. Let's open the hood on what an HTTP exchange *actually looks like on the wire.*

### HTTP rides inside the TCP stream

HTTP is an **application-layer (L7)** protocol. It assumes a working, reliable byte stream beneath it and just writes text (HTTP/1.x) or binary frames (HTTP/2+) into it. The layering:

```
   ┌─────────────────────────────────────────────────────────────┐
   │  HTTP  (L7)   "GET /pods HTTP/1.1 ... 200 OK ..."            │  ← the words
   ├─────────────────────────────────────────────────────────────┤
   │  TLS   (L6-ish, HTTPS only)  encrypts everything above       │  ← the seal
   ├─────────────────────────────────────────────────────────────┤
   │  TCP   (L4)   reliable ordered stream, port 80 / 443         │  ← the pipe
   ├─────────────────────────────────────────────────────────────┤
   │  IP    (L3)   which machine (10.0.1.5 → 10.0.2.9)            │  ← the address
   ├─────────────────────────────────────────────────────────────┤
   │  Ethernet/link (L2/L1)   frames on the wire                  │
   └─────────────────────────────────────────────────────────────┘

   For plain HTTP, the TLS layer is simply absent: HTTP sits directly on TCP.
```

The key insight: **HTTP does not manage delivery, ordering, or retransmission.** TCP already guarantees the bytes arrive whole and in order. HTTP just fills the pipe with a structured message. That's *why* HTTP can be so simple — it stands on TCP's shoulders.

### Anatomy of a REQUEST

An HTTP/1.1 request is plain text with a rigid shape. Here's a real one, byte for byte:

```text
GET /api/v1/namespaces/default/pods?limit=100 HTTP/1.1   ← request line: METHOD  PATH?QUERY  VERSION
Host: kubernetes.default.svc                              ← headers (name: value), one per line
Authorization: Bearer eyJhbGciOi...                      ←   who am I / am I allowed
Accept: application/json                                  ←   what content type I want back
User-Agent: kubectl/v1.29.0
Connection: keep-alive                                    ←   keep the TCP conn open for reuse
                                                         ← ONE BLANK LINE = "headers end, body begins"
(no body for a GET)
```

Four parts, always in this order:
1. **Request line:** `METHOD  PATH(+?query)  HTTP-VERSION`. The verb, the resource, the protocol version.
2. **Headers:** zero or more `Name: Value` lines carrying metadata.
3. **Blank line (CRLF):** the mandatory separator that says "headers are done."
4. **Body (optional):** the payload — present for POST/PUT/PATCH, absent for GET/DELETE/HEAD.

A request *with* a body (creating a pod):

```text
POST /api/v1/namespaces/default/pods HTTP/1.1
Host: kubernetes.default.svc
Content-Type: application/json          ← what the BODY is
Content-Length: 152                     ← how many body bytes follow
Authorization: Bearer eyJhbGciOi...

{"apiVersion":"v1","kind":"Pod","metadata":{"name":"web"}, ...}   ← the body
```

### Anatomy of a RESPONSE

The server answers with the mirror image:

```text
HTTP/1.1 200 OK                          ← status line: VERSION  CODE  REASON-PHRASE
Content-Type: application/json           ← headers describing the response
Content-Length: 4213
Cache-Control: no-store                  ← may this be cached? (no)
Set-Cookie: session=ab12cd; HttpOnly     ← "remember this token and send it back"
                                        ← blank line
{"kind":"PodList","apiVersion":"v1","items":[ ... ]}     ← the body
```

Three parts:
1. **Status line:** `HTTP-VERSION  STATUS-CODE  REASON-PHRASE` (e.g. `HTTP/1.1 404 Not Found`).
2. **Headers:** metadata about the response.
3. **Body:** the returned resource (or an error page/JSON).

### The methods (verbs) and what they *mean*

```
   ┌─────────┬───────────────────────────────────┬──────┬────────────┐
   │ METHOD  │ Intent                            │ Body │ Idempotent?│
   ├─────────┼───────────────────────────────────┼──────┼────────────┤
   │ GET     │ Read a resource (no side effects) │  no  │ yes (safe) │
   │ HEAD    │ Like GET but headers only, no body│  no  │ yes (safe) │
   │ POST    │ Create / submit; server decides   │ yes  │ NO         │
   │ PUT     │ Create-or-REPLACE at a known URL  │ yes  │ yes        │
   │ PATCH   │ Partially modify a resource       │ yes  │ (usually)  │
   │ DELETE  │ Remove a resource                 │  no* │ yes        │
   │ OPTIONS │ Ask what methods/CORS are allowed │  no  │ yes (safe) │
   └─────────┴───────────────────────────────────┴──────┴────────────┘
```

- **Idempotent** = doing it twice has the same effect as doing it once. `PUT`/`DELETE`/`GET` are idempotent; `POST` is not (POST twice → two resources). This is why load balancers and clients can safely *retry* a GET or PUT but must be careful retrying a POST.
- **Safe** = no server-side change at all (GET, HEAD, OPTIONS).
- In Kubernetes REST terms: `kubectl get` = **GET**, `kubectl create` = **POST**, `kubectl apply`/`replace` ≈ **PUT/PATCH**, `kubectl delete` = **DELETE**, and `kubectl patch` = **PATCH**. The API server *is* a REST server speaking exactly these verbs.

### Status codes — the first digit is the whole triage

```
   1xx  INFORMATIONAL   "still going" (100 Continue, 101 Switching Protocols)
   2xx  SUCCESS         "it worked"   (200 OK, 201 Created, 204 No Content)
   3xx  REDIRECT        "go elsewhere"(301 Moved Permanently, 302 Found, 304 Not Modified)
   4xx  CLIENT ERROR    "YOU messed up"(400,401,403,404,409,429)
   5xx  SERVER ERROR    "*I* messed up"(500,502,503,504)
```

The ones you must know cold, and what they mean in a cluster:

| Code | Name | Means | Cluster/cloud context |
|---|---|---|---|
| **200** | OK | Success, body follows | Healthy probe, successful `kubectl get` |
| **301** | Moved Permanently | Resource lives at a new URL (in `Location`) | HTTP→HTTPS redirects at the ALB/Ingress |
| **400** | Bad Request | Malformed request, client's fault | Bad JSON in a POST to the API server |
| **401** | Unauthorized | *Not authenticated* — no/invalid credentials | Missing/expired Bearer token to `:6443` |
| **403** | Forbidden | *Authenticated but not allowed* (RBAC) | Valid token, but RBAC denies the verb |
| **404** | Not Found | No such resource at this path | Wrong Ingress path; deleted object |
| **500** | Internal Server Error | The app itself threw/crashed | Your pod's code blew up |
| **502** | Bad Gateway | A proxy got a **bad/garbage reply from upstream** | ALB/Ingress reached a pod that closed the conn or spoke garbage |
| **503** | Service Unavailable | **No healthy upstream** to send to | No READY pods behind the Service; all probes failing |

Burn in the **401 vs 403** distinction: 401 = "*who are you?*" (authentication), 403 = "*I know who you are, and no*" (authorization). And the **502 vs 503** distinction is the single most useful cluster-debugging fact in this file:

```
   Client ──► ALB / Ingress ──► (Service) ──► Pod
                   │                            │
   502 Bad Gateway │  proxy DID reach an upstream, but the upstream
                   │  returned a broken/invalid response (pod crashed
                   │  mid-response, wrong port, spoke HTTP badly).
                   │
   503 Unavailable │  proxy had NO healthy upstream to try at all
                   │  (0 READY pods, all endpoints removed, overloaded).
```

### Statelessness, and how cookies bolt state on

HTTP is **stateless**: the server keeps no memory of you between requests. Request #2 does not know request #1 happened. This is a *feature* — it's why you can put ten identical pods behind a Service and any pod can answer any request. But "log in once, stay logged in" needs memory. The fix:

```
   1. You POST /login with credentials.
   2. Server verifies, creates a SESSION, and replies:
          Set-Cookie: session=ab12cd34; HttpOnly; Secure; SameSite=Lax
   3. Your browser stores that cookie.
   4. On EVERY later request, the browser automatically adds:
          Cookie: session=ab12cd34
   5. Server looks up "ab12cd34" in its session store → "ah, this is Alice."
```

The cookie is a **claim check**; the **session** is the coat it redeems on the server side. Statelessness is preserved on the wire — each request still carries everything needed to identify you (the cookie), so the server can still be one of many interchangeable replicas. (Note: server-side session storage *does* create shared state behind the scenes — which is exactly why you either use *sticky sessions* on the LB or a *shared* session store like Redis when you scale to many pods. Stateless protocol, but your app can smuggle state in.)

### HTTP/1.1 vs HTTP/2 vs HTTP/3 — same words, different delivery

The semantics (methods, statuses, headers) are identical across versions. What changes is the *encoding and transport*:

```
  HTTP/1.1  ── text, one request-at-a-time per TCP connection ─────────────
     conn1: [req A]──────►[resp A]  then  [req B]──────►[resp B]
     Head-of-line blocking: B waits for A. Browsers open 6 parallel TCP
     conns per host to fake concurrency. keep-alive reuses a conn for
     several sequential requests (Connection: keep-alive).

  HTTP/2  ── BINARY framing, MULTIPLEXED over ONE TCP connection ──────────
     one TCP conn, many interleaved "streams":
       ══[A1][B1][A2][C1][B2]══►   all in flight at once, reassembled by
     stream-id. Header compression (HPACK). Server push (mostly deprecated).
     BUT: still one TCP conn, so TCP packet loss stalls ALL streams
     (transport-level head-of-line blocking remains).

  HTTP/3  ── HTTP/2 semantics over QUIC, and QUIC runs on UDP ─────────────
     QUIC = reliable, multiplexed, encrypted transport built on UDP (443/udp).
     Each stream is independent AT THE TRANSPORT LAYER, so one lost packet
     stalls only its own stream, not the others. TLS 1.3 is baked in.
     Faster connection setup (0-RTT/1-RTT). No more TCP head-of-line blocking.
```

- **HTTP/1.1:** human-readable text, one outstanding request per connection, `keep-alive` to reuse a connection for sequential requests. Simple, still everywhere.
- **HTTP/2:** binary frames, **multiplexing** many concurrent streams over a *single* TCP connection, header compression. This is why **gRPC runs on HTTP/2** — it needs many concurrent, long-lived, bidirectional streams over one connection. Kubernetes uses gRPC (hence HTTP/2) between the API server and etcd, and for CRI/CNI/CSI plugins.
- **HTTP/3:** the same multiplexing but over **QUIC**, which is a reliable transport built on **UDP (port 443/udp)**. By moving stream management out of TCP and into QUIC, a single lost packet no longer stalls every other stream — it kills TCP's transport-level head-of-line blocking.

**Everything the app never sees** happens in these lower mechanics: TCP handshakes, TLS negotiation, HTTP/2 frame interleaving, connection pooling. Your code just says "GET this" and gets a response object.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **HTTP** | Stateless L7 request/response protocol over TCP | The words inside the TCP stream |
| **HTTPS** | HTTP carried inside a TLS tunnel (port 443) | Adds the TLS encryption layer under HTTP |
| **Request line** | `METHOD PATH?query HTTP-version` — first line of a request | Top of every request |
| **Status line** | `HTTP-version CODE reason` — first line of a response | Top of every response |
| **Method / verb** | GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS — the intent | Request line; REST semantics |
| **Status code** | 3-digit outcome; first digit = class (1xx–5xx) | Status line; machine-readable result |
| **Header** | `Name: Value` metadata line | Between the start line and the body |
| **Body / payload** | The actual content bytes after the blank line | End of request/response |
| **Host header** | Which virtual host the request is for | How one IP/LB serves many domains; ALB host routing |
| **Content-Type** | MIME type of the body (`application/json`) | Tells the receiver how to parse the body |
| **Accept** | MIME type(s) the client *wants* back | Content negotiation |
| **Authorization** | Credentials, e.g. `Bearer <token>` | Auth; API server token, drives 401/403 |
| **Cache-Control** | Caching directives (`no-store`, `max-age=…`) | CDN/browser/proxy caching behavior |
| **Connection: keep-alive** | Reuse this TCP conn for more requests | Connection reuse in HTTP/1.1 |
| **Set-Cookie / Cookie** | Server-issued token / client-returned token | Bolts state onto a stateless protocol |
| **Session** | Server-side record keyed by a cookie | The state the cookie redeems |
| **URL** | `scheme://host:port/path?query#frag` | The full address of a resource |
| **Query string** | `?key=value&…` after the path | Parameters; part of the request line |
| **Multiplexing (HTTP/2)** | Many concurrent streams on one TCP conn | Binary framing layer |
| **QUIC (HTTP/3)** | Reliable multiplexed transport over UDP | Replaces TCP under HTTP/3 |
| **Idempotent** | Repeating the request has the same effect | Method semantics; safe retries |

**Same kind of thing, different names — don't let these confuse you:**

- **"The outcome":** status code, response code, and "HTTP status" all name the same 3-digit number on the status line.
- **"Authentication vs authorization":** `401 Unauthorized` is really *un-authenticated* (misnamed in the spec); `403 Forbidden` is the *authorization* failure. Two different gates, adjacent codes.
- **"Bad upstream" codes:** `502 Bad Gateway`, `503 Service Unavailable`, and `504 Gateway Timeout` are all a *proxy* complaining about the *upstream* — bad reply, no healthy target, and too-slow target respectively. Same finger, pointing at the backend.
- **"Verb / method / operation":** all name the same first token of a request (GET, POST…).
- **"Body / payload / entity / content":** all name the bytes after the blank line.
- **"HTTP over TLS":** HTTPS, "HTTP secure," "TLS-terminated HTTP" — same thing: HTTP inside a TLS tunnel.

---

## 🔬 Rung 5 — The Trace

Let's follow **one** concrete action end to end: **you run `curl -v https://api.shop.com/orders/42` and it flows through an AWS ALB and an EKS Ingress to a pod — and comes back `200 OK`.**

Assume: `api.shop.com` resolves to an ALB, which fronts an Ingress that routes host `api.shop.com` + path `/orders/*` to Service `orders-svc` (port 80) → pod listening on `containerPort: 8080`, IP `10.244.1.12`.

```
 STEP 1  DNS: curl resolves api.shop.com → the ALB's IP (e.g. 52.1.2.3).
         (See the DNS file — this is a prerequisite, not part of HTTP.)

 STEP 2  TCP: curl opens a TCP connection to 52.1.2.3 : 443
         (SYN → SYN-ACK → ACK). Now a reliable stream exists.

 STEP 3  TLS: curl and the ALB do the TLS handshake. The ALB presents the
         cert for api.shop.com; an encrypted tunnel is established.
         (HTTPS = HTTP + this tunnel. TLS is the next file.)

 STEP 4  HTTP REQUEST: curl writes into the tunnel:
             GET /orders/42 HTTP/1.1
             Host: api.shop.com          ← the ALB reads THIS to pick a rule
             Accept: application/json
             Authorization: Bearer <token>

 STEP 5  ALB (L7) parses the HTTP request. It reads the Host header
         (api.shop.com) and the path (/orders/42), matches its listener
         rule, and forwards to the target group → an EKS node's NodePort.

 STEP 6  Ingress controller (e.g. AWS LB Controller / nginx / Envoy) or
         kube-proxy DNATs toward Service orders-svc, which load-balances
         to a READY endpoint: pod 10.244.1.12 : 8080.

 STEP 7  The app in the pod handles GET /orders/42, fetches order 42,
         and writes an HTTP RESPONSE:
             HTTP/1.1 200 OK
             Content-Type: application/json
             {"id":42,"status":"shipped"}

 STEP 8  Response retraces the path: pod → Service → Ingress → ALB → (still
         inside the TLS tunnel) → curl. curl prints headers (-v) and body.
```

Visual of the round trip:

```
  curl                ALB (L7)            Ingress/kube-proxy        Pod
  api.shop.com        52.1.2.3:443        Service orders-svc:80     10.244.1.12:8080
    │                     │                      │                       │
    │ TCP+TLS to :443     │                      │                       │
    ├────────────────────►│                      │                       │
    │ GET /orders/42      │  reads Host + path,  │                       │
    │ Host: api.shop.com  │  matches rule ───────►  DNAT to READY pod ──►│
    ├────────────────────►│                      │                       │ app runs
    │                     │                      │                       │ GET handler
    │       200 OK  {"id":42,"status":"shipped"} │◄──────────────────────┤
    │◄────────────────────┤◄─────────────────────┤                       │
    │                     │                      │                       │
  L7 decision lives at the ALB.   L4 DNAT lives at kube-proxy.   App logic in the pod.
```

Now the failure variants that make the codes concrete:

```
  • Pod crashed mid-response / wrong containerPort  → ALB returns 502 Bad Gateway
  • Zero READY pods (all probes failing)            → ALB returns 503 Service Unavailable
  • Path /orderz/42 has no Ingress rule             → 404 Not Found
  • Missing/expired Bearer token                    → 401 Unauthorized
  • Token valid but RBAC denies                     → 403 Forbidden
  • App threw an unhandled exception                → 500 Internal Server Error
```

Notice where each decision lives: the **Host header and path** decide routing *at the ALB* (L7); the **Service/kube-proxy** does L4 DNAT to a pod; the **status code** is minted by whichever component failed — proxy (502/503) or app (500).

---

## ⚖️ Rung 6 — The Contrast

**The older/alternative approach: raw TCP sockets and bespoke protocols (or FTP/Gopher).** Before HTTP, and still today for some systems, applications talked over raw TCP with a private, hand-rolled message format. What does HTTP give you that raw TCP or FTP cannot — and vice versa?

| | **HTTP (L7 request/response)** | **Raw TCP / bespoke protocol** | **FTP (the old file protocol)** |
|---|---|---|---|
| Message structure | Standardized (method, path, headers, status) | Whatever you invent | Command/response, but no rich metadata |
| Machine-readable outcome | Yes — status codes & classes | You must design one | Numeric reply codes, but file-centric |
| Metadata | Free-form headers (auth, type, cache) | None built in | Very limited |
| L7 routing (host/path) | Native — enables Ingress/ALB/CDN | Impossible (no L7 fields) | No |
| Statelessness | Yes — easy to scale/replicate | Depends; often stateful | Stateful (control + data conns) |
| Firewall/NAT friendliness | Excellent (one conn, well-known ports) | Varies | Painful (separate data connection) |
| Raw throughput / latency floor | Slight overhead (headers, text in 1.1) | Leanest possible | Heavier |
| Encryption | HTTPS (TLS) standard, ubiquitous tooling | Roll your own / add TLS | FTPS/SFTP bolt-ons |

**What raw TCP can do that HTTP cannot (well):** truly custom, ultra-low-overhead, long-lived streaming where the request/response framing gets in the way — think a database wire protocol (Postgres on 5432, MySQL on 3306) or a real-time game protocol. Those keep their own bespoke formats *on purpose*. HTTP's structure is overhead you don't want when you control both ends and need every microsecond.

**When would I NOT use HTTP?**
- **Pure L4 load balancing** where you don't care about (or can't see, due to encryption) the content — an **NLB** or a Kubernetes `type: LoadBalancer`/`ClusterIP` Service just forwards IP:port and never parses HTTP. If you don't need host/path routing, stay at L4; it's faster and simpler.
- **Database and non-web protocols** — Postgres, MySQL, Redis, Kafka speak their own wire protocols over TCP, not HTTP.
- **Latency-critical internal streaming** where you'd reach for raw gRPC/HTTP-2 or even UDP-based transports.

**Why HTTP over raw TCP (for web/APIs):** because a standardized method + path + headers + status code turns "some bytes arrived" into "a routable, cacheable, retryable, machine-triageable operation" — which is the entire foundation Ingress, ALB, REST APIs, CDNs, and health probes are built on.

> **Check yourself before Rung 7:** Your ALB returns `502` for one route and `503` for another at the same moment. Both are `5xx`, both point at "the server side." Using only the *mechanism* behind each code, what different underlying pod/endpoint condition does each one imply, and which would `kubectl get endpoints` help you confirm?

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction **out loud before running the command.** The learning is in the gap between what you predicted and what you saw.

### Example 1 — Normal case: watch a real request/response with `curl -v`

**Prediction:** *If I run `curl -v https://example.com`, then I'll see the request line + my request headers (lines prefixed `>`), then the status line + response headers (lines prefixed `<`), then the body, BECAUSE `curl -v` prints the raw HTTP conversation and HTTP is just this structured text exchanged over the (TLS) TCP stream. I expect `HTTP/2 200` and a `content-type` header.*

```bash
curl -v https://example.com 2>&1 | head -30
```

```text
*   Trying 93.184.216.34:443...
* Connected to example.com (93.184.216.34) port 443
* using HTTP/2                                   ← ALPN negotiated HTTP/2 over TLS
> GET / HTTP/2                                   ← '>' = what WE sent (request line)
> Host: example.com                              ← the Host header
> User-Agent: curl/8.5.0
> Accept: */*                                    ← we accept any content type
>                                                ← blank line = end of headers
< HTTP/2 200                                     ← '<' = what SERVER sent (status line)
< content-type: text/html; charset=UTF-8         ← body is HTML
< cache-control: max-age=604800                   ← cacheable for 7 days
< content-length: 1256
<
<!doctype html> ...                              ← the body
```

**Verify:** The `>` lines are your request (method/path/version + headers), the `<` lines are the response (status line + headers), and a blank line separates headers from body in each. Confirm you see a `2xx` and a `Content-Type`. A **wrong result** — say `HTTP/1.1` instead of `HTTP/2` — teaches you the server (or your curl) doesn't negotiate HTTP/2; a `301`/`302` with a `Location:` header teaches you the resource redirected elsewhere.

### Example 2 — Edge/failure case: prove statelessness, then add state with a cookie; and read status codes deliberately

**Prediction A (statelessness):** *If I request the same URL twice over separate connections with no cookie, the server treats them as total strangers, BECAUSE HTTP keeps no memory between requests — nothing on the wire ties request 2 to request 1 unless I carry it myself.*

**Prediction B (headers only / status codes):** *If I use `curl -I` I get ONLY the response headers and status line and NO body, BECAUSE `-I` sends a `HEAD` request, whose defined semantics are "give me the headers a GET would return, but not the body." And if I hit a nonexistent path I'll get `404`, while a broken server-side gives `5xx`.*

```bash
# -I sends HEAD: status line + headers, no body
curl -I https://example.com
```

```text
HTTP/2 200
content-type: text/html; charset=UTF-8
content-length: 1256
# ...no body printed — that's HEAD doing its job.
```

```bash
# Deliberately request a missing resource → expect 404
curl -s -o /dev/null -w "%{http_code}\n" https://example.com/definitely-not-here
# 404

# Watch cookies bolt state on: httpbin issues a Set-Cookie, then we send it back.
curl -s -c jar.txt  https://httpbin.org/cookies/set/session/ab12cd  -o /dev/null
cat jar.txt                       # shows the stored 'session=ab12cd' cookie
curl -s -b jar.txt  https://httpbin.org/cookies
# {"cookies": {"session": "ab12cd"}}   ← the server "remembers" us ONLY because we resent the cookie
```

**Verify:** `curl -I` shows no body (HEAD). The `404` proves the status code is a machine-readable outcome you can branch on (`%{http_code}` captures just the number). The cookie round-trip proves the point of Rung 3: **without** `-b jar.txt` the second request would report empty cookies — the server has no memory; state exists *only* because you carried the cookie back. A **wrong result** — cookies persisting without you sending them — would mean curl reused a connection/jar you didn't expect, reinforcing that state is *always* client-carried.

### Example 3 — Kubernetes-flavored: an HTTP readiness probe, and diagnosing 502 vs 503

**Prediction:** *If I deploy a pod whose readiness probe is an HTTP GET to `/healthz` and I make that endpoint return `500`, then the pod goes `0/1 READY`, its endpoint is removed from the Service, and traffic through an Ingress returns `503` (no healthy upstream) — not `502` — BECAUSE the probe's non-2xx status tells the kubelet the pod isn't ready, so kube-proxy has nothing to send to. If instead the pod IS ready but crashes mid-response or listens on the wrong port, I'd get `502` (bad reply from a reachable upstream).*

```yaml
# probe-demo.yaml — readiness/liveness via HTTP GET
apiVersion: apps/v1
kind: Deployment
metadata: { name: web }
spec:
  replicas: 1
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
        - name: web
          image: registry.k8s.io/e2e-test-images/agnhost:2.47
          args: ["netexec", "--http-port=8080"]
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:                 # kubelet does an HTTP GET — 2xx/3xx = ready
              path: /healthz
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata: { name: web }
spec:
  selector: { app: web }
  ports: [{ port: 80, targetPort: 8080 }]
```

```bash
kubectl apply -f probe-demo.yaml
kubectl get pods -w                       # watch it become 1/1 READY (probe returns 200)

# The probe is literally an HTTP GET. Prove it from inside the cluster:
kubectl run t --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -o /dev/null -w "healthz -> %{http_code}\n" http://web.default.svc:80/healthz
# healthz -> 200

# Now break readiness: make the pod fail its probe (agnhost can be told to fail).
# Simulate "no healthy upstream": scale to zero and watch endpoints vanish.
kubectl scale deploy/web --replicas=0
kubectl get endpoints web                 # ENDPOINTS column becomes <none>
# A request through an Ingress/LB now returns 503 — no upstream to route to.
```

**Verify:** While the probe returns `200`, `kubectl get endpoints web` lists the pod IP:8080 and the Service routes fine. When the pod is not READY (or scaled to 0), `kubectl get endpoints web` shows `<none>` and an L7 proxy returns **503 Service Unavailable** — *because there's no healthy upstream*, exactly matching the mechanism. To see a **502** instead, point `targetPort` at a port nothing listens on (e.g. `targetPort: 9999`): the proxy *reaches* an "endpoint" but gets a broken/refused reply → **502 Bad Gateway**. That contrast — `503` = nobody home, `502` = somebody home but broken — is the single most useful HTTP fact for cluster debugging, and `kubectl get endpoints` is how you tell them apart.

### Example 4 (bonus) — See HTTP versions and negotiate them explicitly

**Prediction:** *If I force `curl --http1.1` vs let ALPN pick, I can observe the version on the status line, and if I query the API server I'll be speaking HTTPS to a REST endpoint on 6443, BECAUSE HTTP version is negotiated during the TLS handshake (ALPN) and the API server is nothing but an HTTPS REST API.*

```bash
# Force HTTP/1.1, then compare with default (often HTTP/2)
curl -s -o /dev/null -w "%{http_version}\n" --http1.1 https://example.com   # 1.1
curl -s -o /dev/null -w "%{http_version}\n"            https://example.com   # 2 (or 3)

# The Kubernetes API server is an HTTPS REST API on 6443 — hit it raw:
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
TOKEN=$(kubectl create token default 2>/dev/null || echo "<token>")
curl -s -o /dev/null -w "GET /api -> %{http_code}\n" \
  --cacert /path/to/ca.crt -H "Authorization: Bearer $TOKEN" "$APISERVER/api"
# GET /api -> 200   (drop the token → 401; valid token but no RBAC → 403)
```

**Verify:** `%{http_version}` prints `1.1`, `2`, or `3`, proving the version is a negotiated wire detail while the *semantics* (GET, 200) are unchanged. Hitting `$APISERVER/api` returns `200` with a token, `401` without one, and `403` with a valid-but-unauthorized token — directly demonstrating that `kubectl` is just HTTPS requests and that 401 (who are you?) and 403 (you're not allowed) are different gates. A **wrong result** — a TLS/cert error — teaches you the `--cacert` chain must match, which is exactly the next file's topic.

---

## 🏔️ Capstone — Compress It

**One-sentence summary:**
HTTP is a stateless protocol where a client sends `method + path + headers (+body)` and the server replies with a `status code + headers (+body)` over TCP, HTTPS is that exchange wrapped in TLS, and everything L7 in a cluster — Ingress host/path routing, health probes, the API server, 502/503 diagnosis — is this one request/response grammar in action.

**Explain it to a beginner (3 sentences):**
When your browser or `kubectl` wants something from a server, it sends a short structured message that says what it wants (a method like GET and a path like `/orders/42`) plus some labeled metadata called headers, and the server sends back a three-digit status code (200 = worked, 404 = not found, 500/502/503 = server side broke) plus the content. The server forgets you the instant it answers — that's "stateless" — so to stay logged in your browser carries a cookie the server gave it on every future request. HTTPS is the exact same conversation, just sealed inside an encrypted TLS tunnel so nobody in between can read or tamper with it.

**Sub-parts mapped to the one core idea** ("request = method+path+headers+body; response = status+headers+body; stateless; HTTPS = HTTP+TLS"):
- *Methods (GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS)* → the verb half of the request; REST semantics and safe-retry rules.
- *Status classes 1xx–5xx (200/301/400/401/403/404/500/502/503)* → the machine-readable outcome half of the response; first digit triages.
- *Headers (Host, Content-Type, Accept, Authorization, Cache-Control, Connection)* → the labeled metadata on both messages; drive routing, auth, caching, keep-alive.
- *Cookies (Set-Cookie) + sessions* → state deliberately bolted onto a stateless core.
- *HTTP/1.1 vs /2 (multiplexing, binary) vs /3 (QUIC/UDP)* → same grammar, faster wire encoding and transport; why gRPC needs HTTP/2.
- *URL (scheme://host:port/path?query)* → the full address that the request line and Host header are built from.

**Which rung to revisit hands-on:**
Go back to **Rung 7, Example 3** on a real (or `kind`/`minikube`) cluster and *deliberately* create both failures: break `targetPort` to force a **502**, then scale to zero (or fail the readiness probe) to force a **503**, checking `kubectl get endpoints` each time. Feeling the 502-vs-503 distinction in your hands is worth more than any amount of re-reading. If the request/response *anatomy* still feels abstract, sit with **Rung 3's** request/response byte-dumps next to **Rung 1's** `curl -v` output until you can point at the request line, headers, blank line, and body without thinking.

---

## Related concepts

- [Transport layer: TCP & UDP](07-transport-layer-tcp-udp.md) — the reliable stream (and the SYN/ACK/FIN handshake) that HTTP rides on; UDP is what QUIC/HTTP-3 uses.
- [DNS](09-dns.md) — resolves the host in the URL to an IP before any HTTP request can leave.
- [TLS / SSL — encryption in transit](11-tls-ssl-encryption-in-transit.md) — the tunnel that turns HTTP into HTTPS; certs, the handshake, and mTLS.
- [Load balancing](18-load-balancing.md) — L4 vs L7, health checks, and how ALBs parse HTTP to route by host/path.
- [Kubernetes Ingress & Gateway API](27-kubernetes-ingress-gateway-api.md) — L7 routing, TLS termination, and where 502/503 are minted.
- [Application-layer protocols](12-application-layer-protocols.md) — the other L7 protocols (SMTP, SSH, NTP…) that sit beside HTTP.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** An ALB routes `shop.com/orders` to Service A and `shop.com/images` to Service B, which a plain L4 load balancer cannot do. What specific pieces of information must HTTP put in a standard, readable place for the ALB to make that decision?

**A:** Two pieces, both in standardized positions in every request: the **`Host` header** (`Host: shop.com`), which says which virtual host/domain the request is for, and the **request path** (`/orders` or `/images`), which sits in the request line as `METHOD PATH HTTP-VERSION`. Because HTTP guarantees these always appear in the same place — the path on the first line, `Host:` among the headers — an L7 load balancer can parse them and match a routing rule. An L4 balancer sees only IP addresses and ports; both requests arrive at the same `IP:443`, so without HTTP's standard structure there is literally nothing to distinguish them by. (For HTTPS, the ALB must also terminate TLS first so it can read those fields — which is why L7 routing implies TLS termination at the proxy.)

### Before Rung 7
**Q:** Your ALB returns `502` for one route and `503` for another at the same moment. Using the mechanism behind each code, what different underlying pod/endpoint condition does each imply, and which would `kubectl get endpoints` help you confirm?

**A:** A **502 Bad Gateway** means the proxy *did reach an upstream* but got a broken/invalid reply — the pod is registered as an endpoint but crashed mid-response, listens on the wrong `targetPort`, or is speaking garbage instead of valid HTTP. A **503 Service Unavailable** means the proxy had *no healthy upstream to try at all* — zero READY pods behind that route's Service, so all endpoints were removed (failing readiness probes, or scaled to zero). `kubectl get endpoints` confirms the **503** case: the route's Service will show `<none>` in the ENDPOINTS column (nobody home), whereas the 502 route's Service will still list an endpoint IP:port — somebody is home but broken, so you go inspect that pod's port and logs instead.
