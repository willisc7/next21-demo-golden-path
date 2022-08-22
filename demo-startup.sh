#!/bin/bash

# Enable APIs we will be using

gcloud services enable sourcerepo.googleapis.com \
    cloudbuild.googleapis.com \
    clouddeploy.googleapis.com \
    container.googleapis.com \
    redis.googleapis.com \
    cloudresourcemanager.googleapis.com \
    servicenetworking.googleapis.com

# Give the Cloud Build service account permission to modify Cloud Deploy 
# resources and create releases to deploy on GKE. These permissions are 
# necessary for our cloudbuild.yaml file to function properly

PROJECT_NUMBER=$(gcloud projects describe "$(gcloud config get-value project)" --format="value(projectNumber)")
gcloud projects add-iam-policy-binding --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role roles/clouddeploy.admin $(gcloud config get-value project)
gcloud projects add-iam-policy-binding --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role roles/container.developer $(gcloud config get-value project)
gcloud projects add-iam-policy-binding --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role roles/iam.serviceAccountUser $(gcloud config get-value project)
gcloud projects add-iam-policy-binding --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role roles/clouddeploy.jobRunner $(gcloud config get-value project)

# Give the Cloud Deploy service account permission to deploy to GKE

gcloud projects add-iam-policy-binding --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role roles/container.admin $(gcloud config get-value project)

# Create the k8s clusters we will be using

gcloud container clusters create staging \
    --release-channel regular \
    --addons ConfigConnector \
    --workload-pool=$(gcloud config get-value project).svc.id.goog \
    --enable-stackdriver-kubernetes \
    --machine-type e2-standard-4 \
    --node-locations us-central1-c \
    --region us-central1 \
    --enable-ip-alias
gcloud container clusters create prod \
    --release-channel regular \
    --addons ConfigConnector \
    --workload-pool=$(gcloud config get-value project).svc.id.goog \
    --enable-stackdriver-kubernetes \
    --machine-type e2-standard-4 \
    --node-locations us-central1-c \
    --region us-central1 \
    --enable-ip-alias

# Create a service account the staging and prod clusters will use to authenticate 
# with Config Connector to create redis instances for the application to use:

gcloud iam service-accounts create sample-app-config-connector
gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
    --member="serviceAccount:sample-app-config-connector@$(gcloud config get-value project).iam.gserviceaccount.com" \
    --role="roles/owner"
gcloud iam service-accounts add-iam-policy-binding \
    sample-app-config-connector@$(gcloud config get-value project).iam.gserviceaccount.com \
    --member="serviceAccount:$(gcloud config get-value project).svc.id.goog[cnrm-system/cnrm-controller-manager]" \
    --role="roles/iam.workloadIdentityUser"

# Deploy the Config Connector to the staging and prod clusters and wire them up 
# to the default namespaces in each cluster using the appropriate annotation:

cat > config-connector.yaml <<EOF
apiVersion: core.cnrm.cloud.google.com/v1beta1
kind: ConfigConnector
metadata:
  name: configconnector.core.cnrm.cloud.google.com
spec:
 mode: cluster
 googleServiceAccount: "sample-app-config-connector@$(gcloud config get-value project).iam.gserviceaccount.com"
EOF
kubectl apply -f config-connector.yaml --context gke_$(gcloud config get-value project)_us-central1_staging
kubectl annotate namespace default cnrm.cloud.google.com/project-id=$(gcloud config get-value project) \
                --context gke_$(gcloud config get-value project)_us-central1_staging
kubectl apply -f config-connector.yaml --context gke_$(gcloud config get-value project)_us-central1_prod
kubectl annotate namespace default cnrm.cloud.google.com/project-id=$(gcloud config get-value project) \
                --context gke_$(gcloud config get-value project)_us-central1_prod
rm config-connector.yaml

# Create a network sample-app can use to connect privately to their redis instance:

cat > default-network.yaml <<EOF
---
apiVersion: compute.cnrm.cloud.google.com/v1beta1
kind: ComputeNetwork
metadata:
  name: default
spec:
  routingMode: REGIONAL
  autoCreateSubnetworks: true
EOF
kubectl apply -f default-network.yaml --context gke_$(gcloud config get-value project)_us-central1_staging
kubectl apply -f default-network.yaml --context gke_$(gcloud config get-value project)_us-central1_prod
gcloud compute addresses create sample-app \
    --global \
    --purpose=VPC_PEERING \
    --prefix-length=16 \
    --description="Sample App range" \
    --network=default
gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges=sample-app \
    --network=default \
    --project=$(gcloud config get-value project)
rm default-network.yaml

# Create the Artiface Registry
gcloud artifacts repositories create sample-app-repo --repository-format=Docker --location us-central1