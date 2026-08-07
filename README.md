# SOC Home Lab with Wazuh (Docker Edition)

## Overview

I built a Security Operations Center (SOC) home lab from scratch using Wazuh as the core SIEM/XDR platform. Since I'm working on a low-end PC, I made the deliberate decision early on to run everything in **Docker containers instead of full virtual machines** - this was the single biggest architectural decision of the project and it shaped almost everything that came after.

The goal was to build a realistic, working detection pipeline: an attacker generating real malicious activity, a monitored victim machine, a SIEM collecting and analyzing the resulting telemetry, and a dashboard where I could actually see and investigate the alerts - the same basic loop a real SOC analyst works with every day.

This README documents the entire journey, including the parts that worked cleanly and the parts that genuinely fought me for hours. I'm keeping both in here because the debugging process taught me as much as the successes did, and I think that's worth preserving.

---

## Why Docker Instead of VMs

My initial plan (before I actually started building) was the "classic" SOC lab architecture: a hypervisor (Proxmox/VirtualBox), a pfSense/OPNsense router VM for network segmentation, a Windows victim with Sysmon, a Linux victim, Suricata, and TheHive for case management - all running as separate VMs.

I scrapped that almost immediately once I accounted for my hardware. VMs are heavy - each one reserves its own RAM, disk, and CPU allocation whether it's doing anything or not. Docker containers share the host kernel and only use what they actually need at any given moment, which made the whole thing feasible on my machine. The tradeoff, which I learned the hard way multiple times throughout this project, is that Docker containers are more restricted than VMs - they don't get full kernel access by default, which caused real problems later (more on that in the Firewall section).

I also dropped Windows/Sysmon entirely from the plan. Sysmon needs a real Windows kernel, and Windows containers aren't practical for this kind of lab. I accepted that trade-off and focused entirely on Linux-based detection engineering instead.

---

## Architecture

Here's what I ended up running. The Wazuh stack and attack containers all run on a single custom Docker bridge network (`single-node_default`, subnet `172.18.0.0/16`). Suricata runs directly on the host as a systemd service and sniffs the bridge interface.

| Component | Type | IP | Role |
|---|---|---|---|
| **Wazuh Manager** | Docker container | 172.18.0.4 | Brain: receives agent data, runs detection rules, generates alerts |
| **Wazuh Indexer** | Docker container | 172.18.0.2 | OpenSearch-based storage and indexing for all alert/log data |
| **Wazuh Dashboard** | Docker container | 172.18.0.3 | Web UI - the main interface for viewing and investigating alerts |
| **victim1** | Docker container | 172.18.0.6 | Ubuntu 22.04 with a Wazuh agent - the primary monitored host |
| **juice-shop** | Docker container | 172.18.0.5 | OWASP Juice Shop - deliberately vulnerable web app, the attack target |
| **Suricata** | Host systemd service | - | Network IDS sniffing `br-26b6c893bcfb` (the SOC Docker bridge) |
| **soc-firewall** | Docker container + host nftables | - | Network-level firewall enforcing access policy between containers |

I run everything on-demand rather than 24/7, since resource usage matters a lot on my hardware - I bring up what I'm actively working with and stop the rest.

---

## Setting Up Wazuh (Single-Node)

I used Wazuh's official `wazuh-docker` repo (v4.9.0), which ships a single-node Docker Compose setup for the Manager, Indexer, and Dashboard.

### The first real wall: `vm.max_map_count`

Before anything would even start, I had to bump this host-level kernel parameter, which OpenSearch (the Indexer's underlying engine) requires:

```bash
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
```

### The OutOfMemoryError saga

This was the first genuinely painful debugging session of the project. When I first brought the stack up, the Dashboard just said "Wazuh dashboard server is not ready yet" - completely unhelpful on its own. Digging into the Indexer's logs, I found it was crash-looping with:

```
java.lang.OutOfMemoryError: Cannot reserve 291650519 bytes of direct buffer memory
```

My first instinct (and initially my working theory) was that the JVM heap (`OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g`) was too large for my machine, so I lowered it to `-Xms512m -Xmx512m`. This was actually the **wrong direction** - it made things worse. The real issue wasn't the heap itself; it was `MaxDirectMemorySize` (a separate off-heap memory pool tied to the heap setting) being too small for OpenSearch's security plugin to even initialize and hash its certificate files. Shrinking the heap further shrank this pool too, making the crash worse, not better.

The actual fix was reverting to the default `-Xms1g -Xmx1g` (which gives ~512MB of direct memory headroom) and just confirming my machine had enough free RAM to support it. Once I did that, the Indexer started cleanly. This was a good early lesson: don't just throw memory limits down blindly when you see an OOM error - read what kind of memory it's actually complaining about.

### Finding the real login credentials

Small but annoying detour: I assumed the default OpenSearch/ELK convention of `admin:admin` would work for logging into the Indexer at `https://localhost:9200`. It didn't. The actual credentials for the `wazuh-docker` repo are hardcoded directly into environment variables inside `docker-compose.yml` (things like `INDEXER_PASSWORD`), not documented anywhere obvious. I had to grep the compose file directly to find them.

### Security not initialized

Even once the Indexer was up and responding on port 9200, hitting it in a browser just showed `"OpenSearch Security not initialized"`. This turned out to be expected - the security plugin's internal user/role config needs to be pushed into the index separately via `securityadmin.sh`, which the `wazuh-docker` setup is supposed to handle automatically but in my case needed a manual nudge.

Once I got past all of this, I finally had a working, logged-in Wazuh dashboard.

---

## Setting Up My First Victim (victim1)

I spun up a plain Ubuntu 22.04 container and installed the Wazuh agent manually inside it, pointed at the manager via Docker's internal DNS (`wazuh.manager`, the Compose service name).

### Version mismatch

First connection attempt failed with:

```
ERROR: Agent version must be lower or equal to manager version (from manager)
```

I'd installed whatever the latest agent version was from the repo, but my Manager was pinned at exactly `v4.9.0`. Wazuh enforces that agents can't be newer than the manager. I had to explicitly pin the agent install to match:

```bash
WAZUH_MANAGER='wazuh.manager' apt install -y wazuh-agent=4.9.0-1
```

### The MANAGER_IP placeholder

Before that, I'd also hit a config issue - I was trying to point the agent at my manager by editing `<address>` in `ossec.conf`, but there was no editor available in the minimal container (`nano`, `vi`, `vim` - none installed). Ended up using `sed` to swap the placeholder text directly:

```bash
sed -i "s/MANAGER_IP/wazuh.manager/" /var/ossec/etc/ossec.conf
```

Once the version mismatch was fixed and the address was correctly set, `victim1` connected and registered successfully, and I could see it as an Active agent in the dashboard.

---

## Deploying the Attack Target: OWASP Juice Shop

I deployed Juice Shop as a standalone container on the same Docker network:

```bash
docker run -d --name juice-shop --network single-node_default -p 3000:3000 bkimminich/juice-shop
```

I initially wanted to also install a Wazuh agent inside the Juice Shop container itself, to catch its own host-level activity. That turned out to be a dead end - the Juice Shop image is a minimal/distroless-style container with no shell at all (`exec: "sh": executable file not found in $PATH`), so there was no way to install anything inside it. I decided this wasn't worth fighting and moved on, relying instead on network-level visibility (Suricata) and my monitored victim1 host for detection.

---

## Setting Up Suricata (Network IDS)

Suricata runs directly on the host as a systemd service (`suricata.service`), not inside a container. This is intentional - it needs raw access to the host's bridge interface to sniff all container-to-container traffic, which isn't practical from inside a container without significant privilege escalation.

### Finding the right interface

My first attempt pointed Suricata at `docker0`, the default Docker bridge. That was wrong - `docker0` only carries traffic for containers on the *default* bridge network, but my whole Wazuh stack (including Juice Shop) was running on a custom network (`single-node_default`) with its own separate bridge interface. I had to find it manually:

```bash
docker network inspect single-node_default | grep -i "Subnet"
# 172.18.0.0/16

ip a | grep -B2 "172.18.0.1"
# br-26b6c893bcfb
```

Once I pointed Suricata at the correct interface (`br-26b6c893bcfb`), it started capturing real traffic immediately and I could see live HTTP events in `eve.json` when I curled Juice Shop.

### The Suricata → Wazuh integration rabbit hole

Getting Suricata's raw output visible on the host was the easy part. Getting it to actually show up **inside the Wazuh dashboard** turned into one of the longest debugging chains of the whole project. Roughly, in order:

1. I added a `<localfile>` entry pointing the Wazuh manager at `eve.json`, confirmed via the logs that `wazuh-logcollector` was actively reading the file - but nothing showed up as alerts.
2. Learned that plain `<localfile>` entries only generate indexed "alerts" when a rule actually matches the content. Suricata's raw JSON doesn't match any default Wazuh rule, so it was being read and silently dropped.
3. Tried enabling `logall`/`logall_json` to force full archiving of everything regardless of rule matches. This wrote data to `archives.json` on the manager correctly, but that data still wasn't reaching the Indexer - I learned that Filebeat (which ships manager data to the Indexer) only forwards **alerts** by default, not the raw archive log, and archive shipping needs to be explicitly enabled in Filebeat's own config (a separate file/module from Wazuh's own config).
4. Found and flipped `archives: enabled: true` in Filebeat's config, restarted the process, confirmed via `/proc/<pid>/fd` that Filebeat was genuinely holding `archives.json` open - but the `wazuh-archives-*` index still never got created in the Indexer.
5. At that point I made a conscious decision to stop chasing it. I'd confirmed the whole chain up to Filebeat correctly reading the file; the remaining gap was almost certainly an index-template initialization issue on the OpenSearch side, and diminishing returns had clearly set in for a home lab.

I did eventually revisit this later (documented further down) and discovered Suricata alerts *were* actually reaching `alerts.log` on the manager after all - visible directly when I grepped for specific strings - even though I still haven't confirmed they're reliably queryable/filterable in the dashboard the same way my agent-based alerts are. I'm treating this as a partially-solved problem: Suricata is running, capturing real traffic, and *some* of its output does reach Wazuh, but the pipeline isn't as clean or dashboard-friendly as I'd like.

Also worth noting: enabling `logall_json` had a nasty side effect I didn't catch right away - Suricata's deeply nested JSON overwhelmed Wazuh's JSON decoder and spammed `ERROR: Too many fields for JSON decoder` repeatedly in the logs. I eventually turned `logall`/`logall_json` back off to stop the noise, once I'd decided not to pursue the archives approach further.

### Custom Suricata rules

I wrote a set of custom Suricata rules targeting known Juice Shop attack patterns, saved at `/etc/suricata/rules/juice-shop-attacks.rules`. These cover:

- SQL injection in POST bodies and URIs (OR 1=1, UNION SELECT, comment sequences)
- XSS - script tags in URIs and bodies, URL-encoded variants
- Brute force login attempts against `/rest/user/login` (5+ POSTs in 10 seconds)
- Path traversal (`../`, `%2e%2e%2f`)
- Command injection patterns
- Admin panel access attempts (`/administration`)
- sqlmap user-agent detection

---

## Confirming End-to-End Detection Works

Before going further, I wanted hard proof that my core pipeline - file change on victim1 → agent → manager → indexer → dashboard - actually worked, independent of all the Suricata trouble.

I touched a test file inside `/etc` on victim1 (which File Integrity Monitoring watches by default) and lowered the syscheck scan frequency from the default 12 hours down to 60 seconds so I wouldn't have to wait to see results:

```bash
sed -i 's/<frequency>43200<\/frequency>/<frequency>60<\/frequency>/' /var/ossec/etc/ossec.conf
/var/ossec/bin/wazuh-control restart
```

My first test file actually didn't trigger anything - I later realized it was created *before* the post-restart baseline scan, so FIM treated it as pre-existing rather than new. Once I created a genuinely new file *after* a stable scan cycle, I confirmed the alert in `alerts.log` on the manager (`File '/etc/pwned_test2' added`).

### The dashboard search dead-end

Even with confirmed alert data sitting in `alerts.log`, and confirmed hits when I queried the Indexer directly with raw `curl` against port 9200, I genuinely could not find anything in the dashboard's Discover view for a long stretch. It turned out I was in the wrong part of the UI entirely - I'd been looking at generic OpenSearch Dashboards navigation (Discover, Visualize, etc.) rather than the actual Wazuh-specific plugin routes. The real Wazuh app lives at `/app/wz-home`, with its own dedicated sections like **Threat Hunting** (which replaced what I expected to be called "Security events" in this version). Once I found the right section and set a wide-enough time range, my alerts were all there - **190 total hits** for victim1, confirming the whole pipeline genuinely worked end to end.

---

## Attacking Juice Shop

With the pipeline confirmed, I moved into actually generating real attack traffic against Juice Shop from victim1:

```bash
# Port scan across the Docker network
nmap -sV juice-shop

# Vulnerability scan
nikto -h http://juice-shop:3000

# SQL injection attempt on the login endpoint
curl -X POST http://juice-shop:3000/rest/user/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@juice-sh.op'"'"' OR 1=1--","password":"x"}'
```

I learned an important limitation here: nmap run *from inside* victim1 against Juice Shop isn't something Wazuh's default configuration has any visibility into at all - my agent only watches file changes, rootkits, and system inventory by default, not outbound network connections. Without Suricata properly wired into the dashboard, purely network-based attacks (scans, HTTP requests to another container) were essentially invisible to Wazuh unless they happened to also touch something on the monitored host itself.

I confirmed my attacks were actually landing by checking Juice Shop's own built-in scoreboard (`/#/score-board`), which tracks completed challenges independently of any of my monitoring setup.

I also discovered - separately from all this - that some Suricata alerts genuinely were showing up correctly formatted in `alerts.log`, including a Suricata rule about "Curl User Agent" traffic and one about "Suspicious SSL/TLS traffic on unusual port," which suggests my earlier Suricata integration work wasn't entirely wasted even though I never fully closed the loop on it being reliably searchable.

---

## Stress-Testing With Rebuilds and Reboots

At one point my whole host machine restarted between working sessions, which taught me a few more practical lessons about running a Docker-based lab day to day:

- Containers without an explicit restart policy don't come back automatically after a reboot - I had to `docker compose start` / `docker start` everything manually.
- After a restart, victim1's Wazuh agent processes showed old/stale PID references (`wazuh-modulesd: Process 7968 not used by Wazuh, removing...`) - this looked alarming but was harmless; a plain `wazuh-control start` cleared it and reconnected fine.
- I confirmed reconnection cleanly by grepping for `"Connected to the server"` in the agent's log and checking the timestamp matched my actual restart time, rather than trusting a stale dashboard view that was still showing yesterday's alert count.

---

## Adding the Wazuh Community Ruleset

The default Wazuh ruleset is fairly limited. I downloaded the full community ruleset (a much larger, more actively maintained set of detection rules covering more attack patterns, with better MITRE ATT&CK mapping) and wrote a small script to keep it automatically updated going forward, rather than manually re-downloading it periodically.

---

## Integrating VirusTotal with File Integrity Monitoring

This was the most rewarding part of the project to get working, because it's a genuinely useful real-world SOC pattern: automatically checking file hashes against VirusTotal whenever FIM detects something new or changed.

### Setup

I added an `<integration>` block to the **manager's** `ossec.conf` (not the agent's - integrations run manager-side):

```xml
<integration>
  <name>virustotal</name>
  <api_key>YOUR_API_KEY_HERE</api_key>
  <group>syscheck</group>
  <alert_format>json</alert_format>
</integration>
```

One config headache here: there was no text editor available inside the manager container either (same problem as before with victim1), so I had to carefully use `sed` to insert this block right before the closing `</ossec_config>` tag - and I had to first double-check there was only **one** such closing tag in the file, since a blind `sed` replace would have broken the config if there'd been multiple.

### Testing with EICAR

To test the integration, I used the EICAR test file - a standardized, completely harmless string that every antivirus engine (including all of VirusTotal's scanners) is designed to flag as "malicious" for testing purposes:

```bash
curl -o /etc/eicar.com https://secure.eicar.org/eicar.com
```

### It worked

After a syscheck cycle picked up the new file, I found this in the manager's alert log:

```
Rule: 87105 (level 12) -> 'VirusTotal: Alert - /etc/eicar.com - 65 engines detected this file'
```

Complete with the full VirusTotal verdict (65 out of 67 engines flagged it), file hashes, and a permalink to the actual VirusTotal report. This confirmed the full loop: file appears on disk → FIM detects it → Wazuh manager computes its hash → VirusTotal is queried automatically → verdict comes back → a properly classified, high-severity alert is generated - all without me touching anything after the initial file drop.

---

## Adding a Network Firewall (nftables)

With detection working, the next logical step was enforcement: actually blocking lateral movement between containers rather than just observing it.

### Why not a firewall container

My first instinct was to run an nftables container on the Docker network and let it act as a gateway. That doesn't work the way you'd expect in Docker's bridge networking model - container-to-container traffic is forwarded by the **host kernel** through the bridge interface, not routed through other containers. A firewall container only controls traffic in its own network namespace, not the bridge.

The correct approach is to apply nftables rules directly on the host, in the kernel's forward path. Docker provides a dedicated `DOCKER-USER` chain in iptables/nftables for exactly this purpose - it's processed before Docker's own rules and is explicitly left empty for user-defined policy.

The additional requirement is `br_netfilter` - a kernel module that makes bridged (layer-2) traffic visible to the layer-3 netfilter hooks. Without it loaded, the nftables forward chain never sees container-to-container packets.

### Enforced policy

The rules live in a dedicated `ip soc_rules` table at `/home/becem69/wazuh-docker/single-node/config/firewall/soc-firewall-host.nft` and hook into the forward path at priority -1 (before Docker's own chains):

| Source | Destination | Port | Action |
|---|---|---|---|
| victim1 (172.18.0.6) | juice-shop (172.18.0.5) | 3000 | ALLOW |
| victim1 | wazuh.manager (172.18.0.4) | 1514, 1515 | ALLOW (agent comms) |
| victim1 | dashboard / indexer / manager | any other | **BLOCK + LOG** |
| SOC internal | SOC internal | any | ALLOW |

All blocked packets are logged to the kernel log with the prefix `SOC-FW-BLOCK:`, so they're visible via `dmesg` and capturable by Suricata.

### Traffic counters

The rules maintain named counters, readable at any time:

```bash
sudo nft list table ip soc_rules
```

Sample output after some traffic:

```
counter victim_to_juiceshop { packets 1 bytes 60 }
counter victim_blocked      { packets 9 bytes 540 }
counter soc_internal        { packets 0 bytes 0 }
```

### Persistence

Three things make this survive a reboot:

1. **`/etc/systemd/system/soc-firewall.service`** - applies the rules after Docker starts, enabled at boot via `systemctl enable soc-firewall`.
2. **`/etc/modules-load.d/soc-firewall.conf`** - loads `br_netfilter` on boot.
3. **`/etc/sysctl.d/soc-firewall.conf`** - sets `net.bridge.bridge-nf-call-iptables=1` and `net.ipv4.ip_forward=1` persistently.

### Useful commands

```bash
# Check live counters and active rules
sudo nft list table ip soc_rules

# See what victim1 tried to reach and was blocked
dmesg | grep SOC-FW-BLOCK

# Reload rules after editing the .nft file
sudo systemctl reload soc-firewall.service

# Edit the firewall policy
nano /home/becem69/wazuh-docker/single-node/config/firewall/soc-firewall-host.nft
```

---

## Current State of the Lab

**Fully working:**
- Wazuh Manager + Indexer + Dashboard, single-node, in Docker
- victim1 (Ubuntu 22.04) with a connected Wazuh agent - FIM, rootcheck, and syscollector all functioning
- Juice Shop deployed as a live attack target
- Suricata running on the host, capturing real network traffic, with custom rules for Juice Shop attack patterns - partially integrated into Wazuh's alert log
- Wazuh community ruleset installed with automatic updates
- VirusTotal integration fully working end-to-end via FIM
- **nftables firewall enforcing network segmentation between containers - victim1 is isolated from SOC infrastructure**

**Not attempted / explicitly parked:**
- Full Suricata → Wazuh dashboard searchability (the archives/Filebeat indexing gap)
- TheHive for case management
- Custom-written Wazuh detection rules (currently running on the community ruleset as-is)

This is where the project stands - a genuinely functioning home SOC detection pipeline that I built, broke, and fixed myself, one layer at a time.
