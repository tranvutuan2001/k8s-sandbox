#!/bin/bash

# Configuration - Change these to match your environment!
ARGOCD_NAMESPACE="argocd"
GIT_REPO_URL="https://github.com/tranvutuan2001/k8s-sandbox.git"
GIT_REPO_PATH="apps" # The folder inside your repo where apps are defined
GIT_REPO_REVISION="HEAD"
NEW_ADMIN_PASSWORD="changeme123"
LOCAL_PORT=8080

# This function runs whenever the script exits
cleanup() {
    echo "🧹 Cleaning up port-forward (PID: $PF_PID)..."
    kill $PF_PID 2>/dev/null
}

# 'EXIT' triggers the function when the script finishes or is interrupted
trap cleanup EXIT

echo "🚀 Installing Argo CD..."
kubectl create namespace $ARGOCD_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n $ARGOCD_NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 1. Wait for all Argo CD components to be fully rolled out
echo "⏳ Waiting for Argo CD deployments to complete..."
kubectl rollout status deployment/argocd-server -n $ARGOCD_NAMESPACE
kubectl rollout status deployment/argocd-repo-server -n $ARGOCD_NAMESPACE
kubectl rollout status deployment/argocd-applicationset-controller -n $ARGOCD_NAMESPACE

# 2. Expose the server via port-forwarding in the background
echo "🔌 Exposing Argo CD server on http://localhost:$LOCAL_PORT..."
kubectl port-forward svc/argocd-server -n $ARGOCD_NAMESPACE $LOCAL_PORT:443 > /dev/null 2>&1 &
PF_PID=$!

# Give the port-forward a second to initialize
sleep 3

# 3. Retrieve initial admin password
echo "🔑 Retrieving initial admin password..."
INITIAL_ADMIN_PASSWORD=$(kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# 4. Login via CLI
echo "🔐 Logging into Argo CD CLI..."
argocd login localhost:$LOCAL_PORT \
  --username admin \
  --password "$INITIAL_ADMIN_PASSWORD" \
  --insecure

# 5. Change the admin password
echo "🔄 Updating admin password..."
argocd account update-password \
  --current-password "$INITIAL_ADMIN_PASSWORD" \
  --new-password "$NEW_ADMIN_PASSWORD"

# 4. Deploy the Root Application (App-of-Apps)
echo "🌿 Applying Root Application..."

cat <<EOF | kubectl apply -f ./root-app.yaml

echo "✅ Setup Complete!"
echo "---------------------------------------------------"
echo "To get your initial admin password, run:"
echo "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d; echo"
echo "---------------------------------------------------"