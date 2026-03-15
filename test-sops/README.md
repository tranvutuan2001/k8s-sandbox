# SOPS + Helm Secrets — Local Hands-On Lab

A complete, beginner-friendly guide to encrypting Kubernetes secrets with **SOPS + PGP (GnuPG)**,
deploying them with **helm-secrets**, and verifying decryption inside a running Nginx pod.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Install Tooling](#2-install-tooling)
3. [Generate a PGP Key](#3-generate-a-pgp-key)
4. [Configure SOPS](#4-configure-sops)
5. [Encrypt the Secrets File](#5-encrypt-the-secrets-file)
6. [Inspect the Encrypted File](#6-inspect-the-encrypted-file)
7. [Helm Chart Overview](#7-helm-chart-overview)
8. [Deploy with helm-secrets](#8-deploy-with-helm-secrets)
9. [Verify Decryption](#9-verify-decryption)
10. [Tear Down](#10-tear-down)

---

## 1. Prerequisites

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| `kubectl` | 1.28+ | Interact with the cluster |
| `helm` | 3.12+ | Package manager for Kubernetes |
| A running cluster | — | `kind`, `minikube`, Docker Desktop, etc. |

Verify basics:

```bash
kubectl cluster-info
helm version
```

> **Cluster recommendation (macOS):** If you don't have a cluster yet, install
> [kind](https://kind.sigs.k8s.io/) and run `kind create cluster`.

---

## 2. Install Tooling

### 2a. Install SOPS

```bash
# macOS (Homebrew)
brew install sops

# Verify
sops --version
```

### 2b. Install GnuPG

GnuPG (`gpg`) is the PGP implementation used by SOPS.

```bash
# macOS (Homebrew)
brew install gnupg

# Verify
gpg --version
```

### 2c. Install the helm-secrets plugin

The plugin registers a **getter/downloader** for the `secrets://` URI scheme so
that Helm v4 decrypts encrypted value files on-the-fly when you pass
`-f secrets://path`. Nothing plain-text ever touches disk during the deploy.

```bash
helm plugin install https://github.com/jkroepke/helm-secrets --verify=false

# Verify the plugin is registered (TYPE should be getter/v1)
helm plugin list
```

> **Helm v4 note:** The old `helm secrets install` subcommand was removed in
> Helm v4. Use `helm install … -f secrets://secrets.yaml` directly instead.

---

## 3. Generate a PGP Key

SOPS uses GPG's **key fingerprint** to identify which key to use for encryption.

### 3a. Generate a new GPG key pair

```bash
gpg --full-generate-key
```

When prompted:
- **Kind of key:** `1` (RSA and RSA)
- **Key size:** `4096`
- **Expiry:** `0` (does not expire) — or set a date if you prefer
- **Name / Email / Comment:** fill in as you like
- **Passphrase:** set a strong passphrase (or leave empty for a local lab)

### 3b. Retrieve the fingerprint

```bash
gpg --list-secret-keys --keyid-format LONG
```

Example output:

```
sec   rsa4096/3AA5C34371567BD2 2026-03-10 [SC]
      A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2
uid           [ultimate] Your Name <you@example.com>
ssb   rsa4096/42B317FD4BA89E7A 2026-03-10 [E]
```

**Copy the 40-character fingerprint** on the line below `sec` —
`A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2` in the example above.

> GPG stores the private key securely in your system keyring (`~/.gnupg/`). No
> extra environment variable export is required — SOPS finds it automatically.

---

## 4. Configure SOPS

The [`.sops.yaml`](.sops.yaml) file in this directory tells SOPS which key to
use when it encrypts any file matching `secrets.yaml`:

```yaml
creation_rules:
  - path_regex: secrets\.yaml$
    pgp: "REPLACE_WITH_YOUR_GPG_FINGERPRINT"
```

**Edit `.sops.yaml` now** and replace `REPLACE_WITH_YOUR_GPG_FINGERPRINT` with the
40-character fingerprint you copied in step 3:

```bash
# Quick in-place substitution (replace the placeholder):
sed -i '' 's|REPLACE_WITH_YOUR_GPG_FINGERPRINT|<YOUR_40_CHAR_FINGERPRINT>|' .sops.yaml
```

---

## 5. Encrypt the Secrets File

The plain-text [`secrets.yaml`](secrets.yaml) currently contains:

```yaml
nginx_secret_value: "Decrypted-By-Helm-Secrets"
```

Encrypt it **in-place** (SOPS replaces the file with its encrypted form):

```bash
# Run from the test-sops/ directory
sops --encrypt --in-place secrets.yaml
```

> SOPS detects the `.sops.yaml` rule, uses your GPG public key for encryption,
> and rewrites `secrets.yaml` with ciphertext.

---

## 6. Inspect the Encrypted File

```bash
cat secrets.yaml
```

The file now looks similar to this — the value is completely opaque, but the
SOPS **metadata block** at the bottom is always present in plain text:

```yaml
nginx_secret_value: ENC[AES256_GCM,data:XyZ...==,type:str]
sops:
    kms: []
    gcp_kms: []
    azure_kv: []
    hc_vault: []
    age: []
    pgp:
        - created_at: "2026-03-10T09:00:00Z"
          enc: |
              -----BEGIN PGP MESSAGE-----
              ...
              -----END PGP MESSAGE-----
          fp: A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2
    lastmodified: "2026-03-10T09:00:00Z"
    mac: ENC[AES256_GCM,data:...==,tag:...,type:str]
    version: 3.8.1
```

Key things to notice:
- `nginx_secret_value` value is replaced by `ENC[...]` ciphertext.
- `sops.pgp[].fp` records **which GPG fingerprint** can decrypt it.
- Without the matching private key in your GPG keyring, this file is unreadable.

---

## 7. Helm Chart Overview

```
nginx-chart/
├── Chart.yaml                  # Chart metadata
├── values.yaml                 # Non-secret defaults
└── templates/
    ├── _helpers.tpl            # Named template helpers
    ├── secret.yaml             # K8s Secret — value injected from encrypted file
    └── deployment.yaml         # Nginx Deployment — mounts Secret as env var
```

### `templates/secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "nginx-chart.fullname" . }}-secret
type: Opaque
stringData:
  TEST_SECRET: {{ .Values.nginx_secret_value | quote }}
```

`helm-secrets` merges the decrypted `secrets.yaml` values into `.Values` before
templating, so `.Values.nginx_secret_value` resolves to `"Decrypted-By-Helm-Secrets"`.

### `templates/deployment.yaml`

```yaml
env:
  - name: TEST_SECRET
    valueFrom:
      secretKeyRef:
        name: {{ include "nginx-chart.fullname" . }}-secret
        key: TEST_SECRET
```

The Nginx container receives `TEST_SECRET` as a standard environment variable,
sourced from the K8s Secret.

---

## 8. Deploy with helm-secrets

Make sure your GPG key is available in your keyring (it is, as long as you are
on the same machine where you generated it in Step 3), then run:

```bash
# From the test-sops/ directory
helm install nginx-demo ./nginx-chart \
  --namespace default \
  -f secrets://secrets.yaml
```

> **Why no `helm secrets` prefix?** In Helm v4 the subcommand dispatch was
> removed. The plugin now works as a **getter/downloader**: when Helm sees
> `-f secrets://…` it calls the plugin to decrypt the file on-the-fly, with no
> wrapper command required.

### What happens under the hood

1. Helm encounters `-f secrets://secrets.yaml` and invokes the registered
   `secrets://` downloader from the helm-secrets plugin.
2. The plugin calls SOPS with your GPG key to **decrypt the file in memory**.
3. The decrypted YAML is streamed back to Helm as a standard `-f` values override.
4. Helm renders the templates with the plain-text value populated.
5. The resulting K8s Secret object (base64-encoded by K8s) is applied to the cluster.
6. No decrypted file is ever written to disk.

Check the rollout:

```bash
kubectl rollout status deployment/nginx-demo-nginx-chart
```

---

## 9. Verify Decryption

### 9a. Find the running pod name

```bash
POD=$(kubectl get pod -l app.kubernetes.io/instance=nginx-demo \
      -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD"
```

### 9b. Exec into the pod and grep the environment

```bash
kubectl exec "$POD" -- env | grep TEST_SECRET
```

Expected output:

```
TEST_SECRET=Decrypted-By-Helm-Secrets
```

This confirms the full chain worked:
- SOPS encrypted the value with your GPG public key.
- `helm-secrets` decrypted it on-the-fly using your GPG private key from the system keyring.
- Helm stored it as a K8s Secret.
- Kubernetes injected it into the Nginx container as an environment variable.

---

## 10. Tear Down

```bash
helm uninstall nginx-demo --namespace default
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `sops: error: could not retrieve PGP key` | GPG private key not in keyring | Run `gpg --list-secret-keys` to confirm; re-import with `gpg --import key.gpg` if needed |
| `Error: no pgp recipients found` | `.sops.yaml` still contains the placeholder | Replace `REPLACE_WITH_YOUR_GPG_FINGERPRINT` in `.sops.yaml` |
| `gpg: decryption failed: No secret key` | Wrong key or missing passphrase entry | Re-run `gpg --list-secret-keys` and confirm the fingerprint matches `.sops.yaml` |
| `helm secrets: plugin not found` or `unknown command "secrets"` | Running on Helm v4 — subcommand was removed | Use `helm install … -f secrets://secrets.yaml` directly (no `helm secrets` prefix) |
| Plugin install fails with verification error | Helm v4 signature check | Add `--verify=false`: `helm plugin install … --verify=false` |
| `ErrImagePull` for nginx | No internet access in cluster | Use `docker pull nginx:1.25.0` then load into kind: `kind load docker-image nginx:1.25.0` |
| `nil pointer evaluating` in template | `nginx_secret_value` key missing | Ensure the encrypted `secrets.yaml` is passed with `-f secrets://secrets.yaml` |
