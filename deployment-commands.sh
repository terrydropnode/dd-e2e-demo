# 1. Provision the infrastructure
cd terraform
export TF_VAR_dd_api_key="<YOUR_DD_API_KEY>"
export TF_VAR_dd_app_key="<YOUR_DD_APP_KEY>"

terraform init
terraform apply -auto-approve

# 2. Configure kubectl and create the Datadog Agent secret
$(terraform output -raw configure_kubectl)
kubectl create secret generic datadog-secret --from-literal api-key="$TF_VAR_dd_api_key"

# 3. Build and push the vulnerable app with Git metadata for Datadog Source Code Integration
export ECR_URL=$(terraform output -raw ecr_repository_url)
export AWS_REGION="us-east-1"

aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_URL

cd ../app
docker build \
  --build-arg DD_GIT_REPOSITORY_URL="$(git config --get remote.origin.url)" \
  --build-arg DD_GIT_COMMIT_SHA="$(git rev-parse HEAD)" \
  -t "$ECR_URL:1.0.0" .
docker push "$ECR_URL:1.0.0"

# 4. Deploy Datadog Agent and the order-processor workload
cd ..
helm repo add datadog https://helm.datadoghq.com
helm upgrade --install datadog-agent -f k8s/datadog-values.yaml datadog/datadog

sed -i.bak "s|<YOUR_ECR_OR_DOCKERHUB_REPO>/order-processor:1.0.0|$ECR_URL:1.0.0|g" k8s/deployment.yaml
kubectl apply -f k8s/deployment.yaml
