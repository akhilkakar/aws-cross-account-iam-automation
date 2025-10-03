# AWS Cross‑Account S3 Access (Dev ➜ Prod) — Project README

_Last updated: 2025-10-03 15:16:09 AEST_

This repository provisions a **secure, auditable, cross‑account access path** from a Development account to a Production account’s S3 bucket. It uses:
- **CloudFormation** templates to create least‑privilege IAM roles, policies and the S3 bucket policy
- **AWS IAM Identity Center (SSO)** profiles for human access and CLI use
- **Shell scripts** for deployment (`deploy_script.sh`) and teardown (`cleanup_script.sh`)

> If you only want the CloudFormation steps, see **`sso_deployment_guide.md`** which contains the canonical deployment detail. This README focuses on **how to run the scripts and validate access**.

---

## 🗺️ Architecture (At a glance)

- **Account A — Development**  
  Developers assume a purpose‑built **cross‑account role** _in Production_ using their Dev SSO profile.
- **Account B — Production**  
  S3 bucket lives here. Its **bucket policy** trusts the Prod cross‑account role only. CloudTrail logs every access.

```
Dev User (SSO profile: admin-dev)
        │
        └── assumes ──▶  Prod Role (trusted to access the bucket)
                               │
                               └── allowed via bucket policy ──▶  S3 Bucket (in Prod)
```

---

## ✅ Prerequisites

- AWS CLI v2 installed and configured for SSO
- Two working SSO profiles, for example:
  - `Development` (Development account)
  - `Production` (Production account)
- Permission to create CloudFormation stacks in both accounts
- Bash (macOS/Linux)

> If your profile names differ, the scripts will prompt and let you type the right ones.

---

## 🚀 Quick Start (Scripts)

### 1) Deploy

```bash
# From repository root
chmod +x deploy_script.sh
./scripts/deploy_script.sh
```

The script will **prompt** you for:
- Dev SSO profile (default `Development`)
- Prod SSO profile (default `Production`)
- A **stack name prefix** (default `CrossAccountS3Access`)
- Optionally, parameter values the CloudFormation templates need

It will then:
1. Create/Update the **Prod** stack (role + bucket policy)
2. Create/Update the **Dev** stack (any required helper roles/policies)
3. Print the **role ARN** and **bucket name** you will use for testing

> The exact parameters and resources are defined in `sso_deployment_guide.md` and the CloudFormation templates referenced there.

### 2) Test cross‑account access (from Dev)

Create and upload a test object to the **Prod bucket** via the cross‑account role:

```bash
# Log in to SSO profiles if needed
aws sso login --profile Development
aws sso login --profile Production

# Replace with the bucket name printed by the deploy script
PROD_BUCKET="your-prod-bucket-name"

# Create a local test file
echo "hello from dev at $(date)" > test-object.txt

# Upload using your **Dev** profile (the bucket policy + trusted role enforce access)
aws s3 cp test-object.txt s3://$PROD_BUCKET/cross-account-tests/test-object.txt --profile Development

# Verify from Prod (optional)
aws s3 ls s3://$PROD_BUCKET/cross-account-tests/ --profile Production
```

Common variations:
- Upload a folder: `aws s3 cp ./test-folder s3://$PROD_BUCKET/cross-account-tests/ --recursive --profile Development`
- Download back (sanity): `aws s3 cp s3://$PROD_BUCKET/cross-account-tests/test-object.txt ./downloaded.txt --profile Development`

### 3) Clean up

```bash
chmod +x cleanup_script.sh
./scripts/cleanup_script.sh
```

The script asks for the same profiles and stack prefix, **confirms destructive action**, then deletes the CloudFormation stacks in the right order and removes temporary local files it created earlier. You’ll see friendly ✓/✗ messages as it proceeds.

---

## 🧭 Where things live

- `sso_deployment_guide.md` — **Authoritative** deployment guide for the CloudFormation stacks and parameters
- `deploy_script.sh` — Interactive wrapper around the CloudFormation workflow to stand everything up
- `cleanup_script.sh` — Safely tears down stacks and any helper artefacts it generated

---

## 🔧 Troubleshooting

**SSO session expired / invalid**  
Run `aws sso login --profile <your-profile>` and re‑run the command.

**Access denied to the Prod bucket**  
- Confirm the **bucket policy** includes the **Prod role ARN** that Dev assumes.
- Confirm the **trust policy** on the Prod role allows the Dev principal to assume it.
- Make sure you are using the **Dev profile** for the `aws s3` commands in tests.

**Wrong stack names**  
If you changed the *stack prefix*, use the same prefix when running `cleanup_script.sh`.

---

## 🧪 Useful CLI snippets

- List buckets in the target account:  
  `aws s3 ls --profile Production`
- Create a quick test file:  
  `echo "sample" > sample.txt`
- Upload a file to S3:  
  `aws s3 cp sample.txt s3://$PROD_BUCKET/cross-account-tests/ --profile Development`

---

## 📜 Security and auditability

- All access is via **assumed roles** with **least privilege** and **MFA‑backed SSO**.
- **CloudTrail** in each account records role assumption and S3 data events.
- Bucket policy **scopes access** to just the intended role principal.

For deeper explanation and trade‑offs (e.g., Identity Center Permission Sets vs bespoke roles), see the blog: [My Blog](https://akhilkakar.com/blog/cross-account-resource-access)
.
