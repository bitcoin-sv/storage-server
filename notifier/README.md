# UHRP Storage Notifier

This is a simple Google Cloud Function that is triggered whenever a new object is finalized in the Cloud Storage bucket.

The function calculates the hash of the new object, determines which storage contract it relates to (based on the Object ID), and then calls the HTTP route that makes a UHRP advertisement.

NOTE: This is not currently covered by the automated CI/CD pipeline. If a new revision of the function is needed, it must be deployed locally with the `gcloud` command line.

This is usually a one-time setup process per storage deployment.
