# Application-Layer Protocols (Email, SSH, ICMP, NTP)

*The other tenants of Layer 7 — the protocols that move mail, shells, pings, and clocks, and how each one quietly picks TCP or UDP underneath.*

---

## 🧗 Rung 0 — The Setup

**What am I learning?** You already know HTTP and HTTPS live at the application layer — the top of the stack, the part humans and apps actually speak. But HTTP is only one tenant on that floor. This file is a guided tour of the *other* application-layer protocols you meet constantly as a platform engineer but rarely stop to understand:

- **The email trio** — SMTP, POP3, IMAP — and the choreography that carries one message from a sender's app to a receiver's inbox.
- **SSH** — the encrypted remote shell you type `ssh` into a hundred times a week — and its dead ancestor **Telnet**.
- **FTP vs SFTP** — file transfer, insecure vs secure.
- **ICMP** — the odd one out that isn't TCP *or* UDP, the protocol hiding behind `ping` and `traceroute`.
- **NTP** — the protocol that keeps every clock in your fleet agreeing, and why disagreement is a security incident, not a nuisance.

The unifying thread: **every application protocol is a set of rules for a conversation, and each one deliberately rides on either TCP (reliability) or UDP (speed) — or, for ICMP, neither.**

**Why did it land on your desk?** A very ordinary Tuesday on your EKS platform:

- A node goes `NotReady`. Your first move is to **SSH into the worker node** to look at the kubelet logs — but which port, which key, and why is SSH safe to expose when Telnet never was?
- Two pods can't talk. You reach for **`ping`** to test reachability — and get a surprise, because ICMP behaves differently than the TCP traffic your app actually uses.
- A batch of pods start throwing `x509: certificate has expired or is not yet valid` even though the cert is clearly fine. The real culprit is **clock skew** — a node whose **NTP** sync drifted.
- Someone files a ticket: "our app can't send email from the cluster." You discover the cloud provider **blocks outbound port 25**. Now you need to know *why* SMTP has two ports and which one to use.

**What do you already know that transfers here?**

- **Ports and sockets** ([04-ports-sockets-multiplexing.md](04-ports-sockets-multiplexing.md)) — every protocol below is "an app listening on a well-known port."
- **TCP vs UDP** ([07-transport-layer-tcp-udp.md](07-transport-layer-tcp-udp.md)) — the reliability-vs-speed trade-off that each protocol resolves.
- **TLS** ([11-tls-ssl-encryption-in-transit.md](11-tls-ssl-encryption-in-transit.md)) — because "secure" versions (SFTP, SMTPS, IMAPS) are mostly "the old protocol wrapped in TLS or SSH."
- **The OSI model** ([06-osi-and-tcpip-models.md](06-osi-and-tcpip-models.md)) — these all sit at Layer 7, except ICMP, which is a Layer 3 oddity we'll dwell on.

---

## 🔥 Rung 1 — The Pain

Rewind to a network with **no agreed application protocols**. TCP can carry a reliable byte stream between two ports — but a byte stream is just noise unless *both ends agree what the bytes mean*. If my mail server sends `354 End data with <CR><LF>.<CR><LF>` and your mail server has never heard of that convention, the mail never lands. **The pain that forced these protocols to exist is the need for a shared grammar on top of the transport.**

Let's feel each specific pain:

**Email pain.** Before SMTP (1981), moving mail between different systems meant every pair of hosts inventing its own hack. You couldn't send from a Berkeley Unix box to an MIT mainframe without a custom gateway. SMTP standardized "how one mail server hands a message to another." But SMTP is a *push* protocol — it shoves mail *toward* a destination server. That's great for delivery, useless for *reading*. Your laptop isn't always online; it can't sit waiting for pushes. So you need a *pull* protocol to fetch mail from your server on demand — that pain birthed **POP3** (download and delete) and later **IMAP** (download and keep in sync across all your devices). Three protocols because there are genuinely three different jobs: **server-to-server handoff, and two flavors of client-fetch.**

**Remote-shell pain.** In the 1980s and 90s you administered a remote machine with **Telnet** — and Telnet sends everything, *including your password*, in cleartext. Anyone with a tap on the wire (a shared hub, a compromised router, a coffee-shop network) could read your root password character by character. The pain was catastrophic: remote administration was fundamentally insecure. **SSH** (1995) fixed it by encrypting the entire session and adding public-key authentication so you never even send a password. Who felt this pain most? Exactly your persona — the sysadmin logging into remote servers. Today that's you SSHing into an EKS worker node from a bastion host.

**File-transfer pain.** Same story: **FTP** sends credentials and data in cleartext (and uses a bewildering two-connection control/data design that firewalls hate). **SFTP** — which is really "file transfer *over an SSH channel*" — encrypts everything on one connection.

**Diagnostics pain.** When a packet doesn't arrive, TCP and UDP have no built-in way to tell you *why* or *where* it died. There was no standard "the network itself reports a problem" channel. **ICMP** exists to be that channel — the router that drops your packet because its TTL hit zero sends back an ICMP "Time Exceeded" message. Without ICMP, `ping` and `traceroute` could not exist, and diagnosing "why can't pod A reach pod B" would be pure guesswork.

**Time pain.** Every computer has a clock, and every clock drifts. In isolation, a few seconds' drift is harmless. In a distributed system it's poison: TLS certificates have "not before / not after" timestamps, Kerberos tickets expire, **etcd's Raft consensus** assumes bounded clock differences, and log correlation across nodes becomes impossible if their clocks disagree. Before **NTP**, keeping a fleet's clocks aligned was manual and hopeless. NTP synchronizes clocks over the network to within milliseconds.

> **Check yourself before Rung 2:** Email needs *three* protocols but web browsing needs essentially *one* (HTTP). What is structurally different about the email problem that forces the split into "send" and "fetch," and why doesn't the web have that split?

---

## 💡 Rung 2 — The One Idea

Here is the sentence to memorize:

> **An application-layer protocol is just an agreed conversation grammar spoken on a well-known port, and each one deliberately chooses TCP when it needs reliability, UDP when it needs speed — or ICMP when it isn't carrying app data at all but reporting on the network itself.**

Everything else is derived from that:

- **Why does each protocol have a fixed port?** So a client knows where to knock without asking. SMTP=25, POP3=110, IMAP=143, SSH=22, Telnet=23, NTP=123. (Derived from: a server must *listen* somewhere predictable — see [ports](04-ports-sockets-multiplexing.md).)
- **Why do SMTP/POP3/IMAP/SSH/FTP ride TCP?** Because a lost byte corrupts a mail, a shell command, or a file. They need TCP's ordered, acknowledged, retransmitted stream. (Derived from: "reliability over speed.")
- **Why does NTP ride UDP?** Because a time sample is a tiny, self-contained request, and TCP's handshake + retransmission delays would *distort the very measurement* NTP is trying to make. A dropped sample is fine — just send another. (Derived from: "speed over reliability, and latency itself is the payload.")
- **Why is ICMP neither?** Because it's not an application talking to another application — it's the *network layer reporting about itself*. It has no ports at all. (Derived from: "reporting on the network, not carrying app data.")
- **Why is there a "secure" version of everything (SSH, SFTP, SMTPS, IMAPS)?** Because the original grammars were designed in a trusting era with no encryption, and the fix was to run the same grammar *inside* an encrypted channel. (Derived from: [TLS](11-tls-ssl-encryption-in-transit.md).)

If you can regenerate every fact below from that one sentence, you understand the layer.

> **Check yourself before Rung 3:** NTP could technically run over TCP. Using only the One Idea, argue why that would make NTP *worse at its own job*, not just marginally slower.

---

## ⚙️ Rung 3 — The Machinery (the important one)

Let's open the hood on each protocol. Go slow here.

### 3.1 The layer these live on

```
   ┌─────────────────────────────────────────────────────────────┐
   │ L7 APPLICATION   SMTP · POP3 · IMAP · SSH · FTP/SFTP · NTP   │
   │                  HTTP · DNS  ← neighbors you already know    │
   ├─────────────────────────────────────────────────────────────┤
   │ L4 TRANSPORT     TCP (25,110,143,22,21) ·  UDP (123)         │
   │                  ── ICMP is NOT here; it has no L4 at all ── │
   ├─────────────────────────────────────────────────────────────┤
   │ L3 NETWORK       IP  ← ICMP rides directly on top of IP here │
   ├─────────────────────────────────────────────────────────────┤
   │ L2 / L1          Ethernet / veth / ENI / physical            │
   └─────────────────────────────────────────────────────────────┘
```

Note the oddity already: **ICMP is drawn at L3, not L7.** ICMP packets are carried directly inside IP packets (IP protocol number 1), with *no TCP or UDP header and no port number*. That's why an ICMP firewall rule looks different from a TCP rule — there's no port to match on, only a *type* and *code*.

### 3.2 Email — the three-server dance

The single most important thing to internalize: **sending mail and reading mail are different protocols with different verbs.** Watch one message travel from Alice to Bob.

```
                         THE EMAIL RELAY PATH

  Alice's laptop                                       Bob's laptop
  (Mail app / MUA)                                     (Mail app / MUA)
        │                                                    ▲
        │ 1. SMTP SUBMISSION                                 │ 4. IMAP/POP3
        │    port 587 (or 465)                               │    fetch
        │    "here is my outgoing mail,                       │    "give me my
        │     I am authenticated"                             │     new mail"
        ▼                                                    │
  ┌──────────────────┐   2. SMTP RELAY    ┌──────────────────┐
  │ Alice's SMTP      │   port 25         │ Bob's SMTP        │
  │ server (MTA)      │ ────────────────► │ server (MTA)      │
  │ smtp.alice.com    │  server-to-server │ mx.bob.com        │
  └──────────────────┘                    └────────┬─────────┘
        ▲                                          │ 3. deposit into
        │ MX lookup via DNS                         ▼    Bob's mailbox
        │ ("who accepts mail for bob.com?")   ┌──────────────────┐
        └──────────────────────────────────► │ Bob's mailbox     │
                                              │ store (on server) │
                                              └──────────────────┘
```

Trace the verbs:

1. **Submission (SMTP, port 587).** Alice's mail app hands the outgoing message to *her own* mail server. This is the **submission** port, 587 — authenticated, meant for clients. (Port **25** is meant for server-to-server relay; more below. Port **465** is SMTPS, implicit-TLS submission.)
2. **Relay (SMTP, port 25).** Alice's server looks up Bob's domain's **MX record** in DNS ([09-dns.md](09-dns.md)) — "who is the mail exchanger for `bob.com`?" — then opens a TCP connection to Bob's mail server *on port 25* and relays the message. **Port 25 is the server-to-server language.**
3. **Delivery.** Bob's server writes the message into Bob's mailbox on the server. Mail is now *waiting on the server*, not on Bob's laptop.
4. **Retrieval (POP3 110 or IMAP 143).** Whenever Bob's laptop or phone comes online, it *pulls* the mail down:
   - **POP3** (Post Office Protocol, port **110**): download the message to this device and (classically) **delete it from the server**. Great for one device, terrible for many — read it on your laptop and it's gone from your phone.
   - **IMAP** (Internet Message Access Protocol, port **143**): the message **stays on the server** and the client keeps a synchronized view. Read it on your laptop, it shows as read on your phone. This is why every modern multi-device setup uses IMAP, not POP3.

The push/pull split is the whole architecture: **SMTP pushes mail toward its destination; POP3/IMAP pull it out of the destination mailbox.** All three ride TCP because a corrupted mail is unacceptable.

> **Cloud tie-in — why port 25 is blocked.** A compromised VM or pod that can open outbound connections to arbitrary servers on port 25 is a *spam cannon* — it can relay junk mail directly into the world's mail servers. So AWS, GCP, and Azure **block or heavily throttle outbound TCP port 25 by default** from your instances. That's why "my app in EKS can't send email" is almost always this: you must send through an authenticated relay (SES, SendGrid, Mailgun) over **587/465**, not talk port 25 directly. The block is anti-abuse, not a bug.

### 3.3 SSH — the encrypted shell, and why key auth beats passwords

SSH (Secure Shell, port **22**) does three things Telnet never could:

1. **Encrypts the whole session** — it runs a key-exchange (Diffie-Hellman) to derive a shared symmetric key, then everything (your keystrokes, the output, your password if you use one) is ciphertext on the wire.
2. **Authenticates the server** — the client remembers the server's host key (that `known_hosts` prompt: "The authenticity of host ... can't be established"). This stops a man-in-the-middle impersonating your server.
3. **Authenticates you with public-key crypto** — you hold a **private key**; the server holds your **public key** in `~/.ssh/authorized_keys`. You prove you own the private key without ever transmitting a secret. No password crosses the wire at all.

```
        SSH PUBLIC-KEY AUTH (simplified)

  Client                                 Server (worker node)
  holds: id_rsa (PRIVATE)                holds: authorized_keys (your PUBLIC key)
    │                                        │
    │  1. TCP connect to :22                 │
    │ ─────────────────────────────────────►│
    │  2. exchange keys, derive session key  │
    │ ◄────────  encrypted tunnel  ─────────►│
    │  3. "I claim to be ec2-user"           │
    │ ─────────────────────────────────────►│
    │  4. server: "sign THIS random nonce    │
    │      with the private key matching     │
    │      the public key I have on file"    │
    │ ◄─────────────────────────────────────│
    │  5. client signs nonce with PRIVATE    │
    │ ─────────────────────────────────────►│
    │  6. server verifies signature with     │
    │      the stored PUBLIC key → grants    │
    │ ◄────────────  shell  ────────────────►│
```

The private key never leaves your laptop. Compare Telnet (port **23**): steps 3-6 collapse into "type your password," and that password travels *in cleartext* over an *unencrypted* connection. Anyone sniffing sees it. That single difference is why Telnet is extinct for administration and SSH is universal.

> **Cloud tie-in.** When you `ssh -i my-key.pem ec2-user@10.0.3.14` into an EKS worker node to read kubelet logs, that `-i my-key.pem` is the private key; AWS injected the matching public key into the instance at launch. Real clusters usually put nodes in **private subnets** ([20-aws-vpc.md](20-aws-vpc.md)) with no public IP, so you SSH through a **bastion host** in a public subnet (or use **SSM Session Manager**, which tunnels a shell with no open port 22 at all). **SFTP** (SSH File Transfer Protocol) rides this same port-22 SSH channel — that's why `scp`/`sftp` "just work" wherever SSH works, needing no extra firewall rule.

### 3.4 ICMP — the network's own diagnostic voice

ICMP (Internet Control Message Protocol) is the one that breaks the pattern. It carries **no application data**. Its job is for hosts and routers to report *network conditions* back to a sender. Two mechanisms power almost everything you do with it:

**Echo Request / Echo Reply (the engine of `ping`).** Your `ping` sends an ICMP packet of **type 8 (Echo Request)**. If the target is reachable and willing, it answers with **type 0 (Echo Reply)**. Round-trip time = latency. No reply = unreachable *or* ICMP is filtered.

**TTL Exceeded (the engine of `traceroute`).** Every IP packet carries a **TTL** (Time To Live, called *hop limit* in IPv6) — a counter that **every router decrements by 1** as it forwards the packet ([08-routing-and-forwarding.md](08-routing-and-forwarding.md)). When TTL hits **0**, the router *drops the packet* and sends back an **ICMP Time Exceeded (type 11)** message naming itself. `traceroute` exploits this deviously:

```
        HOW TRACEROUTE USES TTL + ICMP

  You send a probe with TTL=1:
     ┌────┐  TTL 1→0   ┌────────┐
     │ you│ ─────────► │ router1│  drops it, replies:
     └────┘            └────────┘  "ICMP Time Exceeded, I am router1"   ← hop 1

  You send a probe with TTL=2:
     ┌────┐  TTL 2→1   ┌────────┐  TTL 1→0  ┌────────┐
     │ you│ ─────────► │ router1│ ────────► │ router2│  "Time Exceeded"  ← hop 2
     └────┘            └────────┘           └────────┘

  ...increment TTL each round until a probe finally reaches the DESTINATION,
  which replies differently (Echo Reply, or ICMP Port Unreachable) → done.
```

So `traceroute` is just "send packets with deliberately too-small TTLs and collect the ICMP death notices from each router in turn." Elegant.

**Why ICMP has no port:** it isn't multiplexing between applications — it *is* the network layer talking. This is why security groups treat ICMP as its own protocol choice ("All ICMP - IPv4") rather than a port range.

> **Cloud tie-in — the ping gotcha.** When you `ping` one pod from another to test reachability, remember: **ping tests ICMP, not your app's TCP.** A pod can be perfectly reachable on TCP 8080 while `ping` fails, because a **NetworkPolicy** ([28-kubernetes-network-policies.md](28-kubernetes-network-policies.md)) or **Security Group** ([17-firewalls-security-groups-nacls.md](17-firewalls-security-groups-nacls.md)) allowed the TCP port but never allowed ICMP. AWS Security Groups *don't* allow ICMP by default — you must add an explicit rule. So "ping fails" ≠ "no connectivity." Always confirm with the actual protocol/port your app uses (`nc -zv pod-ip 8080`).

### 3.5 NTP — keeping the fleet's clocks honest

NTP (Network Time Protocol, port **123/UDP**) synchronizes a machine's clock to reference time sources arranged in a hierarchy of **strata**:

```
        NTP STRATUM HIERARCHY

   Stratum 0:  atomic clocks / GPS  (reference, not on the network)
                       │
   Stratum 1:  servers directly attached to stratum 0
                       │
   Stratum 2:  sync from stratum 1  ← public pool servers live around here
                       │
   Stratum 3:  your nodes sync from stratum 2 ...
```

A client sends a tiny UDP request and gets back the server's timestamps; using four timestamps (when I sent, when server received, when server replied, when I received) it computes both the **offset** (how wrong my clock is) and the **round-trip delay**, then *slews* (gently speeds/slows) its clock to converge. It runs over **UDP** precisely because **the network delay is part of the measurement** — TCP retransmission and buffering would inject unpredictable latency into the very number NTP needs to be clean.

**Why clock skew is dangerous — not annoying, dangerous:**

- **TLS breaks.** Certificates have `notBefore`/`notAfter` timestamps. A node whose clock jumped forward will reject a valid cert as "expired"; a clock behind will reject it as "not yet valid." Suddenly pods across a node throw `x509: certificate has expired or is not yet valid` and nothing connects.
- **etcd Raft breaks.** etcd (the Kubernetes datastore, port **2379**) uses timeouts for leader election and lease expiry. Large clock skew between control-plane members causes spurious leader elections, lease flapping, and API-server instability.
- **Auth tokens break.** JWTs, Kubernetes ServiceAccount tokens, and AWS SigV4 signatures all embed timestamps with tight validity windows. Skew → `token used before issued` or signature-expired rejections.
- **Logs lie.** Correlating an incident across nodes is impossible if their timestamps disagree by seconds.

Modern Linux uses **`chrony`** (the `chronyd` daemon, queried with `chronyc`) or the older `ntpd` (queried with `ntpq`). On AWS, instances typically sync to the **Amazon Time Sync Service** at the link-local address `169.254.169.123` — no internet egress needed.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which machinery it touches | Transport / Port |
|---|---|---|---|
| **SMTP** | Simple Mail Transfer Protocol — pushes mail toward its destination | Submission (client→server) and relay (server→server) | TCP **25** (relay), **587** (submission), 465 (SMTPS) |
| **POP3** | Post Office Protocol — download-and-delete retrieval | Client pulls mail off its server, one device | TCP **110** (995 = POP3S) |
| **IMAP** | Internet Message Access Protocol — synced retrieval | Client keeps mail on server, many devices in sync | TCP **143** (993 = IMAPS) |
| **MUA** | Mail User Agent | The email *client* (Outlook, Thunderbird, your app) | — |
| **MTA** | Mail Transfer Agent | The email *server* that relays via SMTP | — |
| **MX record** | Mail eXchanger DNS record | Tells a sending MTA which server accepts a domain's mail | DNS (see [09-dns.md](09-dns.md)) |
| **SSH** | Secure Shell — encrypted remote shell + tunneling | Key exchange, host-key check, public-key auth | TCP **22** |
| **Telnet** | Cleartext remote shell (obsolete) | Same shell idea, *no encryption, no key auth* | TCP **23** |
| **Public/Private key** | Asymmetric keypair | You prove identity by signing a nonce with the private key | (in SSH auth) |
| **known_hosts** | Client's memory of server host keys | Server authentication / MITM defense | (SSH) |
| **FTP** | File Transfer Protocol — cleartext, two-connection | Old file transfer; firewall-hostile | TCP **21** (control), 20 (data) |
| **SFTP** | SSH File Transfer Protocol | File transfer *inside the SSH channel* | TCP **22** |
| **ICMP** | Internet Control Message Protocol | Network *reports on itself*; no app payload | IP proto **1** — **no port** |
| **Echo Request/Reply** | ICMP type **8** / type **0** | The engine behind `ping` | ICMP |
| **Time Exceeded** | ICMP type **11** | Sent when TTL hits 0; engine behind `traceroute` | ICMP |
| **TTL / hop limit** | A per-packet counter decremented by each router | Loop prevention; enables traceroute | IP header (L3) |
| **NTP** | Network Time Protocol — clock sync | Offset/delay calc, clock slewing, stratum hierarchy | UDP **123** |
| **Clock skew** | Difference between a clock and true time | Breaks TLS validity, etcd Raft, tokens, logs | (consequence, not a protocol) |
| **chrony / ntpd** | The daemons that *implement* NTP on Linux | Query with `chronyc` / `ntpq` | — |
| **Stratum** | Distance (in hops) from a reference clock | NTP hierarchy | (NTP) |

**Same kind of thing, different names — group them:**

- **"Encrypted successor of an old cleartext protocol":** SSH↔Telnet, SFTP↔FTP, IMAPS/POP3S/SMTPS↔IMAP/POP3/SMTP. Pattern = *wrap the old grammar in TLS or SSH*.
- **"Fetch my mail" protocols:** POP3 and IMAP — same job (client pulls from mailbox), different sync philosophy (delete vs sync).
- **"Push vs pull" in email:** SMTP is push (toward destination); POP3/IMAP are pull (out of mailbox).
- **"Client vs server roles":** MUA (client) ↔ MTA (server); `ssh` client ↔ `sshd` server; NTP client ↔ NTP server.
- **"Diagnostic, not data-carrying":** ICMP stands alone — it's the only one here that doesn't multiplex apps over ports.

---

## 🔬 Rung 5 — The Trace

Let's follow **one email**, end to end, from Alice's app in a cluster to Bob reading it on his phone. This stitches SMTP, DNS, and IMAP together.

```
  STEP-BY-STEP: alice@corp.com  ──►  bob@example.com

  [1] Alice's app (MUA) builds the message, opens TCP to its relay
      smtp.corp.com : 587  (SUBMISSION port, authenticated)
              │
              ▼
  [2] smtp.corp.com (MTA) accepts it. To find Bob's server it asks DNS:
      "MX record for example.com?"  ──►  returns  mx.example.com  (pri 10)
              │
              ▼
  [3] smtp.corp.com opens TCP to  mx.example.com : 25  (RELAY port)
      and speaks SMTP:
          HELO smtp.corp.com
          MAIL FROM:<alice@corp.com>
          RCPT TO:<bob@example.com>
          DATA ... <the message> ... .
          250 OK: queued            ← accepted
              │
              ▼
  [4] mx.example.com writes the message into Bob's server-side mailbox.
      The mail now WAITS on the server. Nothing pushed to Bob's phone.
              │
              ▼
  [5] Later, Bob's phone (MUA) opens TCP to  imap.example.com : 143
      IMAP: "list new messages in INBOX" → downloads Alice's mail,
      leaves it ON THE SERVER so his laptop sees it too.
              │
              ▼
  [6] Bob reads it. If he'd used POP3 (:110) instead, the message would
      typically be DELETED from the server after download — invisible
      to his laptop. That's the IMAP-vs-POP3 difference, made concrete.
```

Every hop names its component: **MUA → (SMTP 587) → MTA → (DNS MX) → (SMTP 25) → MTA → mailbox → (IMAP 143) → MUA.** Notice the transport underneath every arrow except the DNS lookup is **TCP** — mail cannot tolerate loss.

Now a second, tiny trace — **an ICMP `ping`** — to cement how different the diagnostic path is:

```
  ping 10.0.3.20  (pod-to-pod reachability test)

  [1] your pod builds an ICMP Echo Request (type 8), no port number
  [2] IP layer wraps it, sends to 10.0.3.20 via the CNI veth/route
  [3] target pod's kernel sees Echo Request, replies Echo Reply (type 0)
  [4] your pod measures round-trip time  →  "64 bytes ... time=0.3 ms"

  If step 3 is silenced by a NetworkPolicy/SecurityGroup that only
  permitted TCP 8080, you get "100% packet loss" — yet TCP 8080 works.
  The ping failing taught you about ICMP filtering, not real outage.
```

---

## ⚖️ Rung 6 — The Contrast

The sharpest contrasts here are **secure vs insecure** and **TCP-choice vs UDP-choice**.

### SSH vs Telnet

| | **Telnet (port 23)** | **SSH (port 22)** |
|---|---|---|
| Encryption | None — cleartext | Full session encryption |
| Password on wire | Sent in plaintext | Never sent (key auth) or sent inside encrypted tunnel |
| Server authentication | None | Host key verified (`known_hosts`) |
| Auth method | Password only | Public-key, password, MFA, certificates |
| File transfer sibling | none | SFTP/SCP on the same channel |
| Use today | Legacy device consoles on isolated networks only | Universal for remote admin |

**Why SSH over Telnet:** SSH gives you Telnet's remote shell *plus* confidentiality, server identity, and passwordless auth — there is no scenario on a routed network where Telnet's cleartext is acceptable.

### POP3 vs IMAP

| | **POP3 (110)** | **IMAP (143)** |
|---|---|---|
| Server copy after read | Deleted (classic default) | Kept |
| Multi-device sync | No | Yes |
| Offline storage | All mail local | Cached, source of truth on server |
| Best for | One device, minimal server storage | Everything modern |

**Why IMAP over POP3:** you read mail on a laptop *and* a phone; only IMAP keeps them in sync.

### The transport choice, protocol by protocol

| Protocol | Transport | Why that transport |
|---|---|---|
| SMTP / POP3 / IMAP | **TCP** | A lost byte corrupts a message — need ordered, reliable delivery |
| SSH / SFTP / FTP | **TCP** | A shell/file must arrive intact and in order |
| HTTP/1.1, HTTP/2 | **TCP** | Reliable document delivery |
| **NTP** | **UDP** | Time samples are tiny and self-contained; TCP delay would *distort the measurement* |
| DNS (query) | **UDP** (mostly) | Small, fast, one-shot — retry on loss |
| **ICMP** | **neither** | Not app data — it's the network reporting on itself; no ports |

**When would you NOT reach for these?**
- Don't use `ping`/ICMP as your *definitive* reachability test for a TCP service — a green ping doesn't prove your port is open, and a red ping doesn't prove it's closed (ICMP is often filtered). Test the actual port with `nc -zv`.
- Don't run your own SMTP relay from a cluster to send transactional email — the port-25 block and deliverability reputation make a managed service (SES/SendGrid) the right call.
- Don't disable NTP "to save a daemon." Clock sync is load-bearing infrastructure.

> **Check yourself before Rung 7:** You add a Security Group rule allowing TCP 22 to a node and confirm `ssh` works, but `ping` to that same node still times out. Using Rung 3, explain in one sentence why both facts are simultaneously true.

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction *out loud* before you run the command. A wrong prediction is the most valuable thing that can happen here.

### Prediction 1 (normal case) — `ping` and `traceroute` reveal TTL in action

**Prediction:** *If I ping a reachable host, I'll see ICMP Echo Replies with a round-trip time and a TTL value; if I traceroute it, each hop will appear one at a time BECAUSE each router along the path decrements TTL to 0 and returns an ICMP Time Exceeded naming itself.*

```bash
ping -c 4 1.1.1.1
# 64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=11.2 ms
# ttl=57 here is what's LEFT after routers decremented from the sender's start (often 64)

traceroute 1.1.1.1        # Linux/mac; on Windows it's: tracert 1.1.1.1
#  1  192.168.1.1   1.1 ms      ← TTL=1 probe died here, router1 replied
#  2  10.20.0.1     3.4 ms      ← TTL=2 probe died at router2
#  3  ...           ...         ← each line = one ICMP Time Exceeded
```

**Verify:** You should see replies with a `ttl=` field and traceroute hops appearing sequentially. The starting TTL minus the number of hops roughly equals the `ttl=` you see returned. **A wrong result** — e.g. traceroute shows `* * *` for every hop — teaches you that ICMP Time Exceeded is being *filtered* on the path (common in clouds), not that the host is unreachable.

### Prediction 2 (edge/failure case) — a port is open on TCP but silent on ICMP

**Prediction:** *If a host allows TCP 22 but blocks ICMP, then `ping` will show 100% packet loss while `nc -zv host 22` succeeds, BECAUSE ping tests ICMP Echo and `nc` tests an actual TCP handshake — two independent protocols governed by two independent firewall rules.*

```bash
# Test ICMP reachability
ping -c 3 <host>
# --- <host> ping statistics ---
# 3 packets transmitted, 0 received, 100% packet loss     ← ICMP filtered

# Test the TCP port that actually matters
nc -zv <host> 22
# Connection to <host> 22 port [tcp/ssh] succeeded!        ← service is UP

# Confirm what's really listening locally, for comparison:
ss -tlnp | grep ':22'
# LISTEN 0 128 0.0.0.0:22 0.0.0.0:*   users:(("sshd",...)) ← sshd bound to 22
```

**Verify:** The contradiction is the lesson — loss on `ping` but success on `nc`. If both fail, the host really is unreachable (routing/SG problem). If both succeed, ICMP simply wasn't filtered. **This is the single most common false alarm in cluster debugging:** never declare an outage on a failed ping alone.

### Prediction 3 (Kubernetes/cloud case) — SSH into a node, then check clock sync

**Prediction:** *If I SSH into an EKS worker node with my key and query chrony, I'll see it synchronized to a time source with a tiny offset, BECAUSE the node runs chronyd against the Amazon Time Sync Service; if the offset were large, TLS and etcd would start failing across the node.*

```bash
# SSH in with the private key (through a bastion if the node is private)
ssh -i ~/.ssh/eks-node.pem ec2-user@10.0.3.14
#  -i selects the PRIVATE key; the node holds the matching PUBLIC key

# Once on the node, inspect clock synchronization (chrony is default on Amazon Linux)
chronyc tracking
# Reference ID    : A9FEA97B (169.254.169.123)   ← Amazon Time Sync (link-local)
# Stratum         : 4
# System time     : 0.000012 sec fast of NTP time ← offset is microseconds = healthy
# Leap status     : Normal

chronyc sources -v
# ^* 169.254.169.123  3  ...  +/-  100us          ← '*' = currently synced source

# On systems using ntpd instead of chrony, the equivalent is:
# ntpq -p
```

**Verify:** `Leap status : Normal` and a `System time` offset in micro/milliseconds means the clock is healthy. A `System time : 45.2 sec slow of NTP time`, or `Leap status: Not synchronised`, is your smoking gun for the `x509: certificate has expired or is not yet valid` errors and etcd leader flapping described in Rung 3 — fix the NTP sync and the "cert" and "token expired" errors vanish.

### Prediction 4 (protocol-grammar case) — watch SMTP's port-25 block, and speak the grammar by hand

**Prediction:** *If I try to open a raw connection from a cloud VM to an external mail server on port 25, it will hang/time out BECAUSE the provider blocks outbound 25 to curb spam — but the submission port 587 (to my authorized relay) will connect.*

```bash
# Outbound 25 from a cloud instance — expect a timeout (provider block)
nc -zv -w 5 gmail-smtp-in.l.google.com 25
# nc: connect to ... port 25 (tcp) timed out: Operation now in progress

# The authenticated submission path your app should use instead:
nc -zv -w 5 email-smtp.us-east-1.amazonaws.com 587
# Connection ... 587 port [tcp/submission] succeeded!

# Speak SMTP by hand against a relay you're allowed to reach, to SEE the grammar:
nc mail.example.com 25   # (works on-prem / where 25 isn't blocked)
# 220 mail.example.com ESMTP        ← server greeting
HELO test.local                      # you type this
# 250 mail.example.com
MAIL FROM:<me@test.local>            # you type this
# 250 2.1.0 Ok
RCPT TO:<you@example.com>            # you type this
# 250 2.1.5 Ok
QUIT
# 221 Bye
```

**Verify:** The port-25 timeout from a cloud instance *is* the expected, correct result — it confirms the anti-spam egress block, not a broken network. The `220`/`250` numeric replies are SMTP's grammar (Rung 3): a `250` means "OK," and seeing them proves you're speaking a real application-layer protocol by hand. **Wrong result** — 25 connects instantly from your cloud VM — teaches you this account/VPC has been explicitly *unblocked* for 25 (a request you'd have had to file with the provider).

---

## 🏔️ Capstone — Compress It

**One sentence (no notes):** Application-layer protocols are agreed conversation grammars on well-known ports — SMTP(25/587)/POP3(110)/IMAP(143) for mail, SSH(22) for encrypted shells, ICMP for network self-diagnosis, NTP(123) for clock sync — each riding TCP for reliability, UDP for speed, or (ICMP) neither because it reports on the network itself.

**Three-sentence beginner explanation:** Above TCP/UDP sits a floor of protocols that give bytes their meaning: email uses SMTP to *send* and POP3/IMAP to *read*, SSH gives you an encrypted remote shell (replacing cleartext Telnet), ICMP powers `ping` and `traceroute` by carrying the network's own error reports, and NTP keeps every machine's clock in agreement. Each protocol lives on a fixed port so clients know where to knock, and each deliberately chooses TCP (when losing a byte is unacceptable) or UDP (when speed and small samples matter more), while ICMP uses neither because it isn't carrying application data at all. As a cloud engineer you meet these daily — SSHing into nodes, pinging pods, chasing TLS failures back to clock skew, and hitting the provider's port-25 block.

**Sub-parts mapped to the One Idea** ("agreed grammar on a port, choosing TCP/UDP/neither"):

- SMTP/POP3/IMAP → grammar for mail; **TCP** because a corrupted message is fatal; split into push (SMTP) vs pull (POP3/IMAP).
- SSH/SFTP vs Telnet/FTP → grammar for remote shell/files; **TCP**; the secure ones wrap the old grammar in encryption.
- ICMP → grammar for the *network reporting on itself*; **neither TCP nor UDP**, no ports.
- NTP → grammar for time sync; **UDP** because network delay is part of the measurement.

**Which rung to revisit hands-on:** **Rung 7, Predictions 2 and 3.** The ping-vs-`nc` false-alarm and the SSH-then-`chronyc` clock check are the two you will *actually* perform under incident pressure — muscle-memory them now so you don't misdiagnose a filtered ICMP as an outage or miss clock skew behind a wall of TLS errors.

---

## Related concepts

- [Ports, sockets & multiplexing](04-ports-sockets-multiplexing.md) — the well-known ports (22/25/110/143/123) every protocol here listens on.
- [Transport layer: TCP & UDP](07-transport-layer-tcp-udp.md) — the reliability-vs-speed choice each protocol makes.
- [Routing & forwarding](08-routing-and-forwarding.md) — TTL/hop-limit decrement, the mechanism traceroute and ICMP Time Exceeded exploit.
- [DNS](09-dns.md) — MX-record lookup that lets a sending SMTP server find the receiver's mail server.
- [TLS/SSL — encryption in transit](11-tls-ssl-encryption-in-transit.md) — why clock skew breaks certificate validity, and how "secure" protocol variants work.
- [Firewalls, security groups & NACLs](17-firewalls-security-groups-nacls.md) — why ICMP needs its own rule and how outbound port 25 gets blocked.
- [Kubernetes network policies](28-kubernetes-network-policies.md) — how a policy can permit TCP while silently dropping ICMP, producing the ping false alarm.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Email needs *three* protocols but web browsing needs essentially *one* (HTTP). What is structurally different about the email problem, and why doesn't the web have that split?

**A:** Email is **asynchronous store-and-forward between parties that are not online at the same time**: the sender's server must *push* the message toward the destination server (SMTP, server-to-server relay), where it waits in a mailbox; then the recipient's device — which may have been offline the whole time — must later *pull* it out (POP3 or IMAP). Those are genuinely different jobs — server-to-server handoff versus client-fetch — so "send" and "fetch" need different grammars, and the fetch job itself splits again into download-and-delete (POP3) versus keep-and-sync-across-devices (IMAP). The web has no such split because browsing is a **synchronous pull**: the client and server are both online at the moment of the request, the browser asks and the server answers on the same connection, so one request-response grammar (HTTP) covers the whole interaction. There is no intermediary mailbox where content waits for an offline recipient.

### Before Rung 3
**Q:** NTP could technically run over TCP. Using only the One Idea, argue why that would make NTP *worse at its own job*, not just marginally slower.

**A:** The One Idea says a protocol picks UDP when speed matters and, for NTP specifically, when **latency itself is the payload**: NTP computes clock offset from the round-trip timing of a tiny, self-contained sample. TCP's handshake, buffering, and — critically — retransmission would inject unpredictable, variable delay into the very measurement NTP is trying to take: a retransmitted time sample arrives late and carries a stale timestamp, so TCP wouldn't just slow NTP down, it would *corrupt the offset and delay calculation* — the protocol's entire job. Loss is the one failure TCP protects against, and NTP simply doesn't care: a dropped sample costs nothing, just send another. So TCP would add distortion in exchange for a guarantee NTP has no use for.

### Before Rung 7
**Q:** You add a Security Group rule allowing TCP 22 and confirm `ssh` works, but `ping` to that same node still times out. Explain in one sentence why both facts are simultaneously true.

**A:** `ssh` and `ping` use two independent protocols governed by two independent firewall rules — SSH is TCP on port 22, while ping is ICMP Echo Request/Reply, which has no port at all and rides directly on IP (protocol 1) — so your TCP-22 rule says nothing about ICMP, and AWS Security Groups don't allow ICMP by default, meaning the node is perfectly reachable for SSH while Echo Requests are silently dropped until you add an explicit ICMP rule.
