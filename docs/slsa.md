# Integrating DriftZero with SLSA

> **Goal:** Extend SLSA’s artifact-level provenance to include environment-level trust, forming a continuous chain of verifiable integrity.

---

## 🧭 Overview

**SLSA** (Supply-chain Levels for Software Artifacts) ensures you can trust *what* was built.  
**DriftZero** (EnvSecOps) ensures you can trust *where* and *how* it was built, deployed, and run.

Together they provide full lifecycle assurance:
```

Source → Build (SLSA) → Attest (DriftZero) → Deploy (DriftZero) → Runtime Audit

````

---

## 🧩 Integration Model

| Aspect | SLSA | DriftZero |
|---------|------|-----------|
| **Scope** | Artifact provenance | Environment attestation |
| **Focus** | What was produced | Where it was executed |
| **Format** | `provenance.json` (in-toto/SLSA spec) | `dz-attestation.json` (DriftZero Open Spec) |
| **Verifier** | Provenance validators (in-toto, Sigstore) | DriftZero control plane (`/attest`, `/audit/events`) |
| **Outcome** | Verifies artifact integrity | Verifies environment and credential integrity |

---

## ⚙️ Implementation Flow

### 1. **Attest the Build Environment**

Before your build job runs, the CI runner proves its identity to DriftZero:

```yaml
steps:
  - name: Attest environment
    run: dzctl attest --out attestation.json
````

This produces a signed `attestation.json` like:

```json
{
  "manifest_id": "dz://env/build-slsa-level3",
  "manifest_hash": "sha256:1122aabbcc",
  "attestation_id": "3c5f4c35-0c16-46a9-9b84-5f8e1aa8498b",
  "trust_level": "full",
  "issued_at": "2025-10-31T15:40:00Z"
}
```

---

### 2. **Generate SLSA Provenance**

After a successful build, generate a SLSA provenance statement:

```bash
slsa-provenance-generate \
  --builder driftzero/build-runner \
  --material repo@commit \
  --output provenance.json
```

---

### 3. **Link the Two**

Append the DriftZero attestation ID to the SLSA provenance metadata:

```bash
jq '.metadata.attestation_id = "3c5f4c35-0c16-46a9-9b84-5f8e1aa8498b"' provenance.json > provenance-linked.json
```

Result:

```json
{
  "_type": "https://slsa.dev/provenance/v1",
  "builder": { "id": "driftzero/build-runner" },
  "metadata": {
    "attestation_id": "3c5f4c35-0c16-46a9-9b84-5f8e1aa8498b",
    "buildInvocationID": "build-12345",
    "completeness": { "parameters": true }
  }
}
```

---

### 4. **Publish to DriftZero Ledger**

Post both files to the control plane for audit correlation:

```bash
dzctl audit publish --provenance provenance-linked.json --attestation attestation.json
```

Behind the scenes, the control plane stores a signed event:

```json
{
  "audit_id": "cf99aa8b-f01c-4b5a-8cd8-2e2f81a07ff7",
  "action": "CREDENTIAL_ISSUE",
  "result": "VERIFIED",
  "slsa_provenance": "sha256:abcd1234…"
}
```

---

### 5. **Deploy with Provenance Verification**

When requesting deploy credentials, DriftZero verifies both environment and artifact provenance:

```bash
dzctl credentials request \
  --target prod \
  --scope deploy \
  --require-provenance slsa
```

Example control-plane policy:

```yaml
policy_id: dz://policy/deploy-prod
allow_actions: [deploy]
conditions:
  required_provenance_level: 3
  required_environment_trust: full
```

If the build lacks valid provenance or the deploy env is unverified → **DENIED**.

---

## 🔐 Trust Chain Diagram

```
┌──────────────────────┐
│  Source Repository   │
└─────────┬────────────┘
          │ commit
┌─────────▼────────────┐
│  Build (SLSA+DZ)     │
│  dzctl attest         │
│  slsa-provenance-gen  │
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│  Provenance +        │
│  Environment Proof   │
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│  DriftZero Control   │
│  Plane / Ledger      │
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│  Verified Deploy Env │
│  dzctl credentials   │
└──────────────────────┘
```

---

## 🧾 Benefits

* **End-to-End Traceability:** Each build and deploy is tied to an attested environment.
* **Non-Repudiation:** Every credential issuance references both attestation and provenance IDs.
* **Compliance Friendly:** Provides machine-verifiable audit data satisfying NIST 800-218 and OSSF best practices.
* **Defense in Depth:** Even if one layer (artifact or environment) is compromised, the other still enforces integrity.

---

## 🧱 Future Work

| Milestone | Description                                                                        |
| --------- | ---------------------------------------------------------------------------------- |
| `v0.2`    | Integrate DriftZero attestation schema into `slsa-framework/provenance` extension. |
| `v0.3`    | `dzctl verify provenance` CLI command for artifact validation.                     |
| `v1.0`    | Bidirectional attestation between SLSA provenance and DriftZero ledger entries.    |

---

**References**

* [SLSA Specification](https://slsa.dev/spec/v1.0)
* [DriftZero Open Spec](https://github.com/driftzero/spec)
* [in-toto Framework](https://in-toto.io)
* [Sigstore](https://sigstore.dev)

---

> “SLSA secures *what* you build.
> DriftZero secures *where* you build, *how* you deploy, and *who* can act.”
> — *EnvSecOps Working Group, v0.1.0*

```

