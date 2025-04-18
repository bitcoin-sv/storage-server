#!/bin/bash

if [[ "$NODE_ENV" == "production" || "$NODE_ENV" == "staging" ]]; then
  npm run build
  echo "$GCP_STORAGE_CREDS" > /app/out/storage-creds.json
  node --max-http-header-size=512000 ./out/src/index.js
else
  npm run dev
fi
