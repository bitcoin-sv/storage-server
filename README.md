
# UHRP Storage Server – Deployment Guide

This guide walks you through deploying **UHRP Storage Server** on Google Cloud Platform (GCP) with continuous delivery via GitHub Actions. When you finish, you’ll have:

-   A single‑region **Cloud Storage bucket** that stores all UHRP data.
    
-   A **Cloud Run** service that handles uploads, billing, and API requests.

- A **Cloud Run** service that handles the broadcasting and advertising of your UHRP data.
    
-   An **HTTP Load Balancer** that fronts both the bucket (static files) and Cloud Run (dynamic API) behind a custom HTTPS domain.
    
-   A GitHub Actions workflow (`deploy.yaml`) that rebuilds and redeploys automatically whenever you push to the `master` or `production` branch.
    

> **Security note** The IAM roles in this tutorial are intentionally permissive to minimise friction. Feel free to tighten them once everything works.

----------

## Prerequisites

**GCP Project with billing**
Create a new Project on Google Cloud Platform that you have owner or editor access and is funded

**GitHub account & repo**
You will fork/clone and push the code to your own repository.

**Domain name**
Optional but recommended for the HTTPS front‑end (e.g. `storage.example.com`).

**gcloud CLI**
Only required for the few shell commands shown below. Everything else uses the Cloud Console UI.

----------

## 1 Get the code into your GitHub

1.  **Fork** the original repository or clone and push:
    
    ```bash
    git clone https://github.com/bitcoin-sv/storage-server.git
    cd storage-server
    git remote remove origin
    git remote add origin <your‑github‑repo‑url.git>
    git push origin master   # or production for your mainnet branch
    ```
    
2.  Verify that your repo contains `.github/workflows/deploy.yaml`. All future pushes to **`master`** or **`production`** will trigger this workflow.

----------

## 2 Google Cloud setup (Console UI)

### 2.1 Create a single‑region bucket

1.  **Storage > Buckets > Create bucket**.
    
2.  **Name**  `<unique‑bucket‑name>` (e.g. `my‑uhrp‑bucket`).
    
3.  **Region**  Select a _single_ region (e.g. `us‑west1`).

4.  **Storage class**  Choose **Autoclass**.  
    GCS will now shift each object between **Standard** and **Nearline** automatically, giving you the lowest possible storage cost when access patterns change.

5.  **Data protection**  Turn the extras **off**:  

    - **Soft delete policy**  Unchecked 
      → We don’t keep 7‑day recovery copies; deletes are immediate.
      
    - **Object versioning**  Unchecked 
    
    - **Retention**  Unchecked

6.  **Access control** Default; make sure **Public access prevention** is **Off**.
    
7.  **Create**
    
8.  **Apply CORS rules**:
    Run these commands from a terminal in the root of your cloned storage‑server repository (e.g., your local shell or Cloud Shell).
    
    ```bash
    gcloud auth login
    gcloud config set project <id>
    gsutil cors set bucket-cors-config.json gs://<your-bucket-name>
    ```
    
`bucket-cors-config.json` is provided in the repo root; edit it if you need to restrict origins.
    

### 2.2 Enable required APIs

Open **APIs & Services > Library**, search each API, click **Enable**. Open **APIs & Services > Library**, search each API, click **Enable**:

| API | Why it’s needed |
|--|--|
| **Cloud Run Admin API** | Create, update, and route traffic to the Cloud Run service.|
| **Cloud Functions API** | Deploys the notifier function used for on‑chain events. |
| **Cloud Logging API** | Captures structured logs from Cloud Run and the load balancer. |
| **Cloud Pub/Sub API** | Delivers bucket‑create events (and other messages) to the notifier. |
| **Eventarc API** | Connects Cloud Storage events to Cloud Run/Functions reliably. |
| **Artifact Registry API** | Hosts container images built by GitHub Actions. |
| **Cloud Build API** | Builds the Docker image inside GCP when you deploy from source. |
| **Service Usage API** | Lets other services (and the GitHub SA) enable additional APIs programmatically. |
| **Cloud Resource Manager API** | Allows IAM policy updates at the project level. |
| **Identity and Access Management (IAM) API** | Grants and tests roles for service accounts. |
| **Compute Engine API** | Backs load balancer & VPC resources under the hood. |

*It can take a minute or two for each API to flip to **Enabled**.*

### 2.3 Initial IAM policy bindings (required for Eventarc)

Run these two commands before assigning roles to service accounts. They give Eventarc and Pub/Sub the bucket/project access they need.

```bash
gcloud storage buckets add-iam-policy-binding gs://<your-bucket-name> \
  --member=serviceAccount:service-$(gcloud projects describe <your-project-name> --format="value(projectNumber)")@gcp-sa-eventarc.iam.gserviceaccount.com \
  --role=roles/storage.legacyBucketReader

gcloud projects add-iam-policy-binding <your-project-name> \
  --member=serviceAccount:service-$(gcloud projects describe <your-project-name> --format="value(projectNumber)")@gs-project-accounts.iam.gserviceaccount.com \
  --role=roles/pubsub.publisher
```

Replace `<your-bucket-name>` / `<your-project-name>` with your bucket & project.

### 2.4 Service accounts and roles

#### 2.4.1 GitHub Actions **deployer** service account

-   Create **IAM & Admin > Service accounts > Create** → `uhrp-github-deployer`.
    
-   Grant roles:
    
    -   **Cloud Run Admin**

	-	**Cloud Functions Admin**
        
    -   **Cloud Build Editor**
        
    -   **Artifact Registry Administrator**
        
    -   **Storage Object Admin**
        
    -   **Service Account User**
        
-   **Keys tab > Add key > JSON** – download and keep safe. You’ll paste this into a GitHub secret.
    

#### 2.4.2 Default Compute Engine service account

- Find it at `IAM & Admin > IAM` (email ends with `compute@developer.gserviceaccount.com`). 

- Give it all of these roles:

	- **Artifact Registry Administrator**
	    
	-   **Cloud Run Admin**
	    
	-   **Eventarc Admin**
	    
	-   **Logs Writer**
	    
	-   **Service Account Admin**
	    
	-   **Service Account User**
	    
	-   **Storage Object Admin**
    

This SA becomes the **runtime identity** for Cloud Run, so the bucket permissions propagate automatically.

----------

## 3 Add GitHub repository secrets

> The examples below use the **`STAGING_`** prefix. For a production deployment create the same secrets with `PROD_` instead and push to the `production` branch.

| Secret | What it's for | Example |
| -- | -- | -- |
| **STAGING_ADMIN_TOKEN** | Bearer token granting admin API calls (e.g., content migration) | `super‑secret‑admin‑token` |
| **STAGING_BSV_NETWORK** | Which Bitcoin SV network the server talks to | `testnet` or `mainnet`|
| **STAGING_GCP_BUCKET_NAME** | The Cloud Storage bucket you created | `my-uhrp-bucket` |
| **STAGING_GOOGLE_PROJECT_ID** | Your GCP project ID | `my‑gcp‑project` |
| **STAGING_GCR_HOST** | Container registry host (`gcr.io`, `us.gcr.io`, or Artifact Registry host) | `us.gcr.io` |
| **STAGING_GCR_IMAGE_NAME** | Repository/image name for the container | `uhrp/uhrp-storage` |
| **STAGING_GCP_STORAGE_CREDS** | _Raw_ JSON for the **runtime** service account that Cloud Run uses to access the bucket | `{ "type": "service_account", ... }` |
| **STAGING_GCR_PUSH_KEY** | **Base64‑encoded** JSON of the **deployer** service‑account key (used by the Action to push the image) | `ewogICJ0eXBlIjogInNlcnZpY2VfYWNjb3VudCIsIC4uLn0=` |
| **STAGING_HOSTING_DOMAIN** | Public HTTPS domain for your load balancer | `storage.example.com` |
| **STAGING_HTTP_PORT** | Port your app listens on inside the container | `3104` |
| **STAGING_MIN_HOSTING_MINUTES** | Minimum retention billed per upload | `15` |
| **STAGING_NODE_ENV** | Node environment string passed to the app | `staging` or `production` |
| **STAGING_PRICE_PER_GB_MO** | Monthly price (USD) per GB stored | `0.03` |
| **STAGING_SERVER_PRIVATE_KEY** | 32‑byte hex private key used to sign on‑chain ops | `58d23bd395c55041c65d415357b524fc2f07802c58d23bd395c55041c65d4153` |
| **STAGING_WALLET_STORAGE_URL** | URL of the Toolbox Wallet storage server | `https://staging-storage.babbage.systems` |

Add them in **GitHub Settings > Secrets and variables > Actions**.

----------

## 4 Understand the GitHub Actions workflow

`deploy.yaml` will:

1.  Authenticate to GCP using `STAGING_GCR_PUSH_KEY` and `STAGING_GOOGLE_PROJECT_ID`.
    
2.  Build & push the Docker image `<GCR_HOST>/<PROJECT>/<IMAGE_NAME>:branch‑sha`.
    
3.  Generate a `service.<branch>.yaml` manifest with all environment variables.
    
4.  Deploy/replace the Cloud Run service in the bucket’s region.
    
5.  Deploy the notifier Cloud Function.
    

Every push to **`master`** triggers the staging deployment. A push to **`production`** does the same but reads the `PROD_*` secrets.

----------

## 5 Trigger the first deployment

1.  Commit any change and push to `master`.
    
2.  Watch **GitHub > Actions** → _Deployment_ run. Green check = success.
    
3.  In GCP **Cloud Run > Services**, verify a new service appears in your chosen region. Click its URL to confirm the server responds.
    
4. The initial deploy is private, so you may see **403 Forbidden**. Grant public invoke rights:

    ```
    gcloud run services add-iam-policy-binding <SERVICE_NAME> \
      --region <REGION> \
      --platform managed \
      --member="allUsers" \
      --role="roles/run.invoker"
    ```
    
Replace `<SERVICE_NAME>` with the Cloud Run service name and `<REGION>` with your region (e.g., `us‑west1`). After a minute, loading the service URL should return a JSON status instead of 403.

----------

## 6 Create an HTTPS load balancer

### 6.1 Frontend configuration

| Setting | Value |
| -- | -- |
| **Protocol** | HTTPS |
| **IP version** | IPv4 |
| **IP address** | **Create a new static IP** (e.g., `staging-uhrp-ingress-ip`)|
| **Port** | 443 | 
| **Certificate** | **Create new → Google‑managed** (enter `STAGING_HOSTING_DOMAIN`, e.g., `storage.example.com`) |
| **Redirect** | Enable **HTTP → HTTPS** redirect |

### 6.2 Backend configuration

#### 6.2.1 Backend Service → Cloud Run
| Field | Value |
| -- | -- |
| **Backend type** | Serverless network endpoint group (SNEG) |
| **Serverless network endpoint groups** | Create new |
| **Cloud Run region** | Same region as your bucket |
| **Cloud Run service** | Select the service deployed by GitHub Actions (the main storage service, **not** the notifier) |
| **Cloud CDN** | **Disabled** |
| **Security policy** | **Default** |

Save to create the backend service (e.g., `uhrp-backend-service`).

#### 6.2.2 Backend **bucket** → Cloud Storage
| Field | Value |
| -- | -- |
| **Bucket** | Your previously created bucket  |
| **Cloud CDN** | **Enabled** (leave defaults) |

### 6.3 Host & path rules

Add a rule that routes CDN requests to the bucket and everything else to Cloud Run:

| Host | Path | Backend
| -- | -- | -- |
| `*` | `/cdn/*` | **Backend bucket** |

### 6.4 Create and test

Click **Create** and wait a few minutes. Then:

1.  Create an **A record** pointing your hosting domain to the load‑balancer IP (This may take a few hours).
    
2.  Wait for DNS propagation. The Google‑managed certificate will turn **Active** automatically.
    
3.  Test: Go to https://uhrp-ui.bapp.dev/ and test uploading and downloading with your hosting domain. 

Everything is now live, secure, and fronted by a global HTTPS load balancer.

----------

## 7 Next steps & hardening

-   Restrict Cloud Run to accept traffic **only** from the load balancer’s identity instead of `allUsers`.
    
-   Replace broad roles with narrower ones (e.g., Storage Object Viewer instead of Admin). Be sure to update the bucket IAM accordingly.
        
-   Set up monitoring & alerts in **Cloud Monitoring**.
    

----------

© 2025 – Feel free to adapt, improve, and PR!
