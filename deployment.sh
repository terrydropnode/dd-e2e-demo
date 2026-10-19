#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 0. PRE-FLIGHT CHECKS
# ==============================================================================
: "${TF_VAR_dd_api_key:?ERROR: Please export TF_VAR_dd_api_key before running.}"
: "${TF_VAR_dd_app_key:?ERROR: Please export TF_VAR_dd_app_key before running.}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export DD_SITE="${TF_VAR_dd_site:-datadoghq.com}"

echo "==> [1/6] Verifying AWS credentials..."
aws sts get-caller-identity >/dev/null

# ==============================================================================
# 1. TERRAFORM INFRASTRUCTURE DEPLOYMENT
# ==============================================================================
echo "==> [2/6] Provisioning AWS EKS & Datadog Integration via Terraform..."
pushd terraform >/dev/null
terraform init -upgrade
terraform apply -auto-approve

export ECR_URL=$(terraform output -raw ecr_repository_url)
export TARGET_S3_BUCKET=$(terraform output -raw sensitive_s3_bucket_name)
KUBECONFIG_CMD=$(terraform output -raw configure_kubectl)
popd >/dev/null

# ==============================================================================
# 2. CONFIGURE KUBECTL CONTEXT (Fixes localhost:8080 connection refused)
# ==============================================================================
echo "==> [3/6] Updating kubeconfig for EKS cluster..."
eval "$KUBECONFIG_CMD"
kubectl get nodes

# ==============================================================================
# 3. BUILD & PUSH APP IMAGE TO ECR (Fixes InvalidImageName / ImagePullBackOff)
# ==============================================================================
echo "==> [4/6] Building and pushing order-processor image to $ECR_URL..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_URL"

GIT_REPO_URL=$(git config --get remote.origin.url 2>/dev/null || echo "https://github.com/demo/dd-unified-sec-lab")
GIT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "1000000000000000000000000000000000000000")

export ECR_IMAGE_URI="${ECR_URL}:1.0.0"

docker build --platform linux/amd64 \
  --build-arg DD_GIT_REPOSITORY_URL="$GIT_REPO_URL" \
  --build-arg DD_GIT_COMMIT_SHA="$GIT_SHA" \
  -t "$ECR_IMAGE_URI" ./app

docker push "$ECR_IMAGE_URI"

# ==============================================================================
# 4. DEPLOY DATADOG AGENT VIA HELM
# ==============================================================================
echo "==> [5/6] Deploying Datadog Secret & Helm Chart (APM, ASM, CWS, CSPM)..."
kubectl create secret generic datadog-secret \
  --from-literal api-key="$TF_VAR_dd_api_key" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add datadog https://helm.datadoghq.com --force-update
helm repo update
helm upgrade --install datadog-agent -f k8s/datadog-values.yaml \
  --set datadog.site="$DD_SITE" \
  datadog/datadog

# ==============================================================================
# 5. RENDER & DEPLOY APPLICATION MANIFEST
# ==============================================================================
echo "==> [6/6] Deploying order-processor with image: $ECR_IMAGE_URI..."
sed -e "s|\${ECR_IMAGE_URI}|${ECR_IMAGE_URI}|g" \
    -e "s|\${TARGET_S3_BUCKET}|${TARGET_S3_BUCKET}|g" \
    k8s/deployment.yaml | kubectl apply -f -

echo "==> Waiting for order-processor pod to reach Ready state..."
kubectl rollout status deployment/order-processor --timeout=120s

echo "==> Waiting for AWS LoadBalancer hostname..."
for i in {1..30}; do
  LB_HOST=$(kubectl get svc order-processor-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "$LB_HOST" ]]; then
    break
  fi
  sleep 5
done

echo "=============================================================================="
echo "DEPLOYMENT COMPLETE!"
echo "App URL          : http://${LB_HOST}"
echo "Target S3 Bucket : s3://${TARGET_S3_BUCKET}"
echo "Test Health      : curl http://${LB_HOST}/health"
echo "=============================================================================="
