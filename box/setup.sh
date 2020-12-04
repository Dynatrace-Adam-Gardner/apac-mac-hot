#
# Script intended for use on an AWS Ubuntu 18.04 t3.medium with 30GB HDD
# DT_TENANT variable is either (WITHOUT https:// and TRAILING SLASH):
# Dynatrace SaaS tenant: {your-environment-id}.live.dynatrace.com
# Dynatrace-managed tenant: {your-domain}/e/{your-environment-id}
# This file:
# - Downloads monaco 1.0.1 as ./monaco
# - Installs k3s, Dynatrace OneAgent and Istio
# - Creates 6 namespaces: dynatrace, keptn, customer-a, customer-b and customer-c
# - 6 deployments & services: prod-web and staging-web
# - Exposes 6 web UI frontends. 3 for production: http://customera.VMIP.nip.io, http://customerb.VMIP.nip.io and http://customerc.VMIP.nip.io
#   and 3 for staging: http://staging.customera.VMIP.nip.io, http://staging.customerb.VMIP.nip.io, http://staging.customerc.VMIP.nip.io
# - Exposes Keptn on: http://keptn.VMIP.nip.io
# customera is using v1 of the website (blue banner)
# customerb is using v1 of the website (blue banner)
# customerc is using v1 of the website (blue banner)
# Docker image is https://hub.docker.com/repository/docker/adamgardnerdt/perform-demo-app/tags
# v1 = No delay (blue banner)
# v2 = 1s delay (green banner)
# v3 = 250ms delay (orange banner)

export DT_API_TOKEN=***
export DT_PAAS_TOKEN=***
export DT_TENANT=***

# DO NOT MODIFY ANYTHING BELOW THIS LINE
export VM_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
cd

# Download Monaco
wget https://github.com/dynatrace-oss/dynatrace-monitoring-as-code/releases/download/v1.0.1/monaco-linux-amd64 -O ~/monaco
chmod +x ~/monaco

git clone https://github.com/Dynatrace-Adam-Gardner/apac-mac-hot
cd ~/apac-mac-hot/box

# Install k3s
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.18.3+k3s1 K3S_KUBECONFIG_MODE="644" sh -s - --no-deploy=traefik
echo "Waiting 30s for kubernetes nodes to be available..."
sleep 30
# Use k3s as we haven't setup kubectl properly yet
k3s kubectl wait --for=condition=ready nodes --all --timeout=60s
# Force generation of ~/.kube
kubectl get nodes
# Configure kubectl so we can use "kubectl" and not "k3 kubectl"
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config

# Install Istio
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.7.4 sh -
cd istio-1.7.4
export PATH=$PWD/bin:$PATH
istioctl install --set profile=demo

# Get Keptn Creds and Install Keptn
cd ~/apac-mac-hot/box
echo '{ "clusterName": "default" }' | tee keptn-creds.json > /dev/null
curl -sL https://get.keptn.sh | sudo -E bash
keptn install --creds keptn-creds.json

# Install Dynatrace OneAgent
kubectl create namespace dynatrace
kubectl -n dynatrace create secret generic oneagent --from-literal="apiToken=$DT_API_TOKEN" --from-literal="paasToken=$DT_PAAS_TOKEN"
kubectl apply -f https://github.com/Dynatrace/dynatrace-oneagent-operator/releases/latest/download/kubernetes.yaml
curl -o cr.yaml https://raw.githubusercontent.com/Dynatrace/dynatrace-oneagent-operator/master/deploy/cr.yaml
sed -i "s@https:\/\/ENVIRONMENTID.live.dynatrace.com\/api@https:\/\/$DT_TENANT\/api@g" cr.yaml
kubectl apply -f cr.yaml

# Wait for Dynatrace pods to signal Ready
echo "Waiting for Dynatrace resources to be available..."
kubectl wait --for=condition=ready pod --all -n dynatrace --timeout=60s

echo "Waiting 1 minute for Dynatrace to properly start..."
sleep 60

# Deploy Customers A, B and C
echo "Deploying customer resources..."
kubectl apply -f deploy-customer-a.yaml -f deploy-customer-b.yaml -f deploy-customer-c.yaml

# Deploy Istio Gateway
kubectl apply -f istio-gateway.yaml

# Deploy Production Istio VirtualService
# Provides routes to customers from http://customera.VMIP.nip.io, http://customerb.VMIP.nip.io and http://customerc.VMIP.nip.io
sed -i "s@- \"customera.INGRESSPLACEHOLDER\"@- \"customera.$VM_IP.nip.io\"@g" production-istio-vs.yaml
sed -i "s@- \"customerb.INGRESSPLACEHOLDER\"@- \"customerb.$VM_IP.nip.io\"@g" production-istio-vs.yaml
sed -i "s@- \"customerc.INGRESSPLACEHOLDER\"@- \"customerc.$VM_IP.nip.io\"@g" production-istio-vs.yaml
kubectl apply -f production-istio-vs.yaml

# Deploy Staging Istio VirtualService
# Provides routes to customers from http://staging.customera.VMIP.nip.io, http://staging.customerb.VMIP.nip.io and http://staging.customerc.VMIP.nip.io
sed -i "s@- \"staging.customera.INGRESSPLACEHOLDER\"@- \"staging.customera.$VM_IP.nip.io\"@g" staging-istio-vs.yaml
sed -i "s@- \"staging.customerb.INGRESSPLACEHOLDER\"@- \"staging.customerb.$VM_IP.nip.io\"@g" staging-istio-vs.yaml
sed -i "s@- \"staging.customerc.INGRESSPLACEHOLDER\"@- \"staging.customerc.$VM_IP.nip.io\"@g" staging-istio-vs.yaml
kubectl apply -f staging-istio-vs.yaml

# Deploy Keptn Istio VirtualService
# Provides routes to http://keptn.VMIP.nip.io/api and http://keptn.VMIP.nip.io/bridge
sed -i "s@- \"keptn.INGRESSPLACEHOLDER\"@- \"keptn.$VM_IP.nip.io\"@g" keptn-vs.yaml
kubectl apply -f keptn-vs.yaml

# Authorise Keptn
export KEPTN_API_TOKEN=$(kubectl get secret keptn-api-token -n keptn -ojsonpath={.data.keptn-api-token} | base64 --decode)
export KEPTN_ENDPOINT=http://keptn.127.0.0.1.nip.io/api
keptn auth --endpoint=$KEPTN_ENDPOINT --api-token=$KEPTN_API_TOKEN

# Configure Bridge Credentials
keptn configure bridge --user=keptn --password=dynatrace

# Allow Dynatrace access to create tags from labels and annotations in each NS
kubectl -n customer-a create rolebinding default-view --clusterrole=view --serviceaccount=customer-a:default
kubectl -n customer-b create rolebinding default-view --clusterrole=view --serviceaccount=customer-b:default
kubectl -n customer-c create rolebinding default-view --clusterrole=view --serviceaccount=customer-c:default

# Scale deployments to create tags from k8s labels (tags only created during pod startup)
kubectl scale deployment staging-web -n customer-a --replicas=0 && kubectl scale deployment staging-web -n customer-a --replicas=1
kubectl scale deployment prod-web -n customer-a --replicas=0 && kubectl scale deployment prod-web -n customer-a --replicas=1
kubectl scale deployment staging-web -n customer-b --replicas=0 && kubectl scale deployment staging-web -n customer-b --replicas=1
kubectl scale deployment prod-web -n customer-b --replicas=0 && kubectl scale deployment prod-web -n customer-b --replicas=1
kubectl scale deployment staging-web -n customer-c --replicas=0 && kubectl scale deployment staging-web -n customer-c --replicas=1
kubectl scale deployment prod-web -n customer-c --replicas=0 && kubectl scale deployment prod-web -n customer-c --replicas=1

# Start Load Gen against customer sites
echo "Starting Load Generator for Customers A, B & C"
chmod +x ~/apac-mac-hot/box/loadGen.sh
nohup ~/apac-mac-hot/box/loadGen.sh &
echo

# Print output
echo "----------------------------" >> ~/installOutput.txt
echo "INSTALLATION COMPLETED" >> ~/installOutput.txt
echo "Customer A Staging Environment available at: http://staging.customera.$VM_IP.nip.io" >> ~/installOutput.txt
echo "Customer A Production Environment available at: http://customera.$VM_IP.nip.io" >> ~/installOutput.txt
echo "Customer B Staging Environment available at: http://staging.customerb.$VM_IP.nip.io" >> ~/installOutput.txt
echo "Customer B Production Environment available at: http://customerb.$VM_IP.nip.io" >> ~/installOutput.txt
echo "Customer C Staging Environment available at: http://staging.customerc.$VM_IP.nip.io" >> ~/installOutput.txt
echo "Customer C Production Environment available at: http://customerc.$VM_IP.nip.io" >> ~/installOutput.txt
echo "Keptn's API available at: http://keptn.$VM_IP.nip.io/api" >> ~/installOutput.txt
echo "Keptn's Bridge available at: http://keptn.$VM_IP.nip.io/bridge" >> ~/installOutput.txt
echo "Keptn's API Token: $KEPTN_API_TOKEN" >> ~/installOutput.txt
echo "Keptn's Bridge Username: keptn" >> ~/installOutput.txt
echo "Keptn's Bridge Password: dynatrace" >> ~/installOutput.txt
echo "----------------------------" >> ~/installOutput.txt
