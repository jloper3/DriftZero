# Integrating DriftZero with Sigstore

> Goal: Make environment attestations publicly verifiable and tamper-evident using Sigstore tooling (Fulcio, Cosign, Rekor).

---

## 🔍 Why Sigstore + DriftZero?

- **Sigstore** gives us:  
  - Keyless signing (Fulcio issues short-lived certs tied to identity)
  - Public, append-only transparency logs (Rekor)
  - cosign-style signature verification flows

- **DriftZero** gives us:  
  - Strong statements about *where* code is running (environment attestation)
  - Credential gating based on those statements
  - Audit trails for who tried to act and what they were allowed to do

Together:
- We can make an environment say “this is who I am and what I’m allowed to do,”
- Sign that claim,
- Publish it to a transparency log,
- And prove to anyone later that we didn’t lie.

This is how we evolve “Zero Trust” from “trust my network perimeter” to “trust my math.”

---

## 🧠 High-Level Model

1. `dz-agent` generates an **environment attestation** (DriftZero format).
2. Instead of only sending it privately to `dz-control`, it is also **signed with Sigstore**.
3. That signed attestation is published to **Rekor**.
4. `dz-control` references the Rekor entry (log index / UUID) in its own audit trail.
5. Anyone (auditors, partners, downstream consumers, tooling) can verify:
   - The environment claim,
   - The signer,
   - The fact that it was publicly logged.

This gives you transparent, third-party-verifiable environment identity.

---

## 🧾 DriftZero Environment Attestation (before Sigstore)

A typical DriftZero environment attestation payload (produced by `dz-agent`) looks like this:

```json
{
  "manifest_id": "dz://env/build-release",
  "manifest_hash": "sha256:1122aabbcc...",
  "manifest_version": "2.4",
  "nonce": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2025-10-31T15:40:00Z",
  "agent_version": "1.2.0",
  "hardware_anchor": {
    "type": "tpm2",
    "evidence": "base64-pcrs-snapshot"
  },
  "actor": {
    "type": "pipeline",
    "id": "github.com/org/repo/.github/workflows/deploy.yml@refs/heads/main"
  }
}
````

Normally, `dz-agent` signs this with its own key material (TPM-backed key, KMS key in CI, etc.) and sends it to `dz-control` for `/attest`.

With Sigstore, we level up.

---

## 🔐 Step 1. Sign the Attestation with Sigstore (cosign keyless)

Instead of holding long-lived signing keys, `dz-agent` can request a short-lived certificate from Fulcio that ties the signer to workload identity (GitHub OIDC, SPIFFE, etc.).

Then we sign the attestation document:

```bash
cosign sign-blob \
  --keyless \
  --fulcio-url https://fulcio.sigstore.dev \
  --rekor-url https://rekor.sigstore.dev \
  --output-signature attestation.sig \
  attestation.json
```

This does a few things:

* Generates (ephemeral) keypair
* Gets cert for that keypair tied to identity (OIDC, workload ID, etc.)
* Signs `attestation.json`
* Uploads the signature + cert hash to Rekor

`cosign sign-blob --keyless` returns:

* The signature (`attestation.sig`)
* A Rekor log entry UUID/index

That Rekor entry publicly anchors the claim that “this environment existed in this state at this time.”

---

## 📤 Step 2. Publish Rekor Reference to DriftZero Control Plane

Now `dzctl` can call `dz-control` `/attest` like normal — but with Sigstore metadata included:

```json
{
  "environment": {
    "manifest_id": "dz://env/build-release",
    "manifest_hash": "sha256:1122aabbcc...",
    "manifest_version": "2.4"
  },
  "attestation": {
    "nonce": "550e8400-e29b-41d4-a716-446655440000",
    "timestamp": "2025-10-31T15:40:00Z",
    "agent_version": "1.2.0",
    "hardware_anchor": {
      "type": "tpm2",
      "evidence": "base64-pcrs-snapshot"
    },
    "signature": "base64(attestation.sig)",
    "sigstore": {
      "rekor_log_index": 1872341,
      "rekor_uuid": "4c72a9608a2a4bf1b2d9d4fbf7488a8c",
      "fulcio_certificate": "base64-der-cert"
    }
  },
  "actor": {
    "type": "pipeline",
    "id": "github.com/org/repo/.github/workflows/deploy.yml@refs/heads/main"
  }
}
```

### What changed?

We attached:

* the detached signature,
* the cert that proves *who* signed,
* and the Rekor position that proves it’s publicly logged.

Now DriftZero isn’t asking you to “trust dz-agent,” it’s asking you to “trust math + transparency.”

---

## 🧾 Step 3. Control Plane Writes a Sigstore-Aware Audit Event

When `dz-control` evaluates this attestation and either issues or denies credentials, it logs an audit event (available later via `/audit/events`) like:

```json
{
  "audit_id": "3c5f4c35-0c16-46a9-9b84-5f8e1aa8498b",
  "timestamp": "2025-10-31T15:41:12Z",
  "actor": "github.com/org/repo/.github/workflows/deploy.yml@refs/heads/main",
  "environment": {
    "manifest_id": "dz://env/build-release",
    "manifest_version": "2.4",
    "manifest_hash": "sha256:1122aabbcc..."
  },
  "policy": "dz://policy/deploy-prod",
  "action": "CREDENTIAL_ISSUE",
  "result": "ISSUED",
  "target": "aws-prod-account-1234",
  "ttl_seconds": 900,
  "sigstore": {
    "rekor_uuid": "4c72a9608a2a4bf1b2d9d4fbf7488a8c",
    "rekor_log_index": 1872341
  },
  "control_plane_signature": "MEQCIFG2s1L4v5y...=="
}
```

That’s the compliance mic drop:

* We didn’t just issue credentials.
* We can show: to whom, from what environment state, under which policy, for how long.
* And there’s a **public transparency entry** proving this wasn’t forged after the fact.

Regulators love that. Your postmortems love that. Your incident commanders really love that.

---

## 🔄 Step 4. Downstream / External Verification

Now an external verifier (auditor, another org, M&A security due-diligence team, etc.) can:

1. Pull the audit event from `/audit/events`.
2. Pull the referenced Rekor log entry.
3. Verify:

   * The attestation content hash matches what Rekor logged.
   * The cert in Rekor matches expected workload identity (e.g. “this was our build runner”).
   * The DriftZero policy allowed only a bounded TTL and scope.
   * The requested scope matches what we say we allowed.

This is huge. You’ve now got portable, cryptographically provable trust evidence that survives outside your cluster, your cloud account, and your company.

---

## 🧪 Threat Model Wins

Why this matters in reality:

* **CI runner compromise**
  Attacker spins up their own “fake runner”, tries to deploy.
  → DriftZero refuses creds because environment attestation doesn’t match any approved manifest.

* **Insider abuse**
  Malicious engineer tries to mint long-lived prod creds.
  → Request is logged to `/audit/events` with TTL and target. Anything outside policy is `DENIED` with a signed denial event.

* **Post-breach forensics**
  Security team can prove the prod deploy at 02:37 came from a known build environment, with a known manifest, via a specific short-lived lease, brokered under an approved policy, and that the environment identity + action were publicly logged to Rekor at that time.

That last sentence is how you stop getting wrecked in board meetings.

---

## 📦 Reference Flow (End-to-End)

```text
[dz-agent]        generate attestation.json
    │
    │ cosign sign-blob --keyless
    ▼
[Rekor]           append entry, return UUID/log index
    │
    │ dzctl attest --include-sigstore
    ▼
[dz-control]      verify env + sigstore
    │
    │ dzctl credentials request --scope deploy
    ▼
[dz-control]      issue short-lived creds
                   log signed audit event
                   link Rekor UUID
```

---

## 🛠 Recommendations for v0.2

To make Sigstore first-class in DriftZero:

### 1. dz-agent:

* Add `--sigstore-keyless` mode to generate Sigstore-backed signatures by default.
* Embed Fulcio/OPAQUE cert chain in `attestation.sig` bundle.

### 2. dz-control:

* Add `sigstore` block as a **first-class field** in `/attest` request schema (not just optional metadata).
* Add optional `require_sigstore: true` to policy, meaning:
  “This environment must present a Rekor-backed attestation, not just local signing.”

### 3. dzctl:

* Add `dzctl attest --publish-sigstore` which:

  * Produces attestation.json
  * Signs via Sigstore
  * Publishes to Rekor
  * Submits to DriftZero control plane
  * Prints resulting Rekor UUID so CI logs capture it

---

## 🔮 Why This Matters Strategically

This is what makes DriftZero more than “your company’s internal guardrails.”

* Sigstore already has gravity in the supply chain security ecosystem.
* By integrating with Sigstore, DriftZero positions EnvSecOps as the **runtime counterpart** to Sigstore + SLSA.
* In CNCF / OSSF language:

  * SLSA = “secure what you build.”
  * Sigstore = “prove it was you.”
  * DriftZero = “prove where and how it ran when it asked for power.”

In other words: we’re not competing with Sigstore — we’re completing it.

---

## TL;DR

* DriftZero environment attestations can be signed and anchored in Sigstore/Rekor.
* DriftZero audit events reference Rekor UUIDs so they’re externally verifiable.
* Policies can require Sigstore-backed attestations for high-risk scopes.
* This gives you portable, cryptographically provable ops trust.

> “Sigstore proves it was you.
> DriftZero proves you were clean when you did it.”

— EnvSecOps Working Group, v0.1.0

```

