#
# Script intended for use on an AWS t3.medium with 20GB HDD
# This file:
# - Installs k3s, Dynatrace OneAgent and Istio
# - Creates 6 namespaces: dynatrace, keptn, jenkins, customer-a, customer-b and customer-c
# - 6 deployments & services: prod-web and staging-web
# - Exposes 6 web UI frontends. 3 for production: http://customera.VMIP.nip.io, http://customerb.VMIP.nip.io and http://customerc.VMIP.nip.io
#   and 3 for staging: http://staging.customera.VMIP.nip.io, http://staging.customerb.VMIP.nip.io, http://staging.customerc.VMIP.nip.io
# - Exposes Keptn on: http://keptn.VMIP.nip.io
# - Exposes Jenkins on: http://jenkins.<VMIP>.nip.io
# customera is using v1 of the website (blue banner)
# customerb is using v1 of the website (blue banner)
# customerc is using v2 of the website (green banner)

export DT_API_TOKEN=***
export DT_PAAS_TOKEN=***
export DT_ENVIRONMENT_ID=***

# DO NOT MODIFY ANYTHING BELOW THIS LINE
export VM_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
export DT_TENANT=$DT_ENVIRONMENT_ID.live.dynatrace.com

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

# Install Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Get Keptn Creds and Install Keptn
echo '{ "clusterName": "default" }' | tee keptn-creds.json > /dev/null
curl -sL https://get.keptn.sh | sudo -E bash
keptn install --creds keptn-creds.json

# Install Dynatrace OneAgent
cd
kubectl create namespace dynatrace
kubectl -n dynatrace create secret generic oneagent --from-literal="apiToken=$DT_API_TOKEN" --from-literal="paasToken=$DT_PAAS_TOKEN"
kubectl apply -f https://github.com/Dynatrace/dynatrace-oneagent-operator/releases/latest/download/kubernetes.yaml
curl -o cr.yaml https://raw.githubusercontent.com/Dynatrace/dynatrace-oneagent-operator/master/deploy/cr.yaml
sed -i "s/https:\/\/ENVIRONMENTID.live.dynatrace.com\/api/https:\/\/$DT_ENVIRONMENT_ID.live.dynatrace.com\/api/g" cr.yaml
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

# Deploy Jenkins
# TODO
# wget https://gist.githubusercontent.com/Dynatrace-Adam-Gardner/1bcb7051ded2b562f1028db0afd6972d/raw/8f510dac9758459941705240d6f4e55380efb437/jenkins-prereqs.yaml
# kubectl apply -f jenkins-prereqs.yaml
# wget https://gist.githubusercontent.com/Dynatrace-Adam-Gardner/1290759bd71d0fdac955c26fc4e32719/raw/d52fe2d2665ad17a5fc6f0089ae45e32954bd2b5/jenkins-values.yaml
# helm repo add jenkinsci https://charts.jenkins.io && helm repo update
# helm install jenkins -n jenkins -f jenkins-values.yaml jenkinsci/jenkins

# Deploy Production Istio VirtualService
# Provides routes to customers from http://customera.VMIP.nip.io, http://customerb.VMIP.nip.io and http://customerc.VMIP.nip.io
wget https://gist.githubusercontent.com/Dynatrace-Adam-Gardner/6670f3ac60ae8421ed230b8ce5e8b924/raw/3e4a6b86c58a3fd49f9952a32247fae440261ffc/production-istio-vs.yaml
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

# Deploy Jenkins Istio VirtualService
# Provides routes to http://jenkins.VMIP.nip.io
sed -i "s@- \"jenkins.INGRESSPLACEHOLDER\"@- \"jenkins.$VM_IP.nip.io\"@g" jenkins-vs.yaml
kubectl apply -f jenkins-vs.yaml

# Authorise Keptn
KEPTN_API_TOKEN=$(kubectl get secret keptn-api-token -n keptn -ojsonpath={.data.keptn-api-token} | base64 --decode)
KEPTN_ENDPOINT=http://keptn.127.0.0.1.nip.io/api
keptn auth --endpoint=$KEPTN_ENDPOINT --api-token=$KEPTN_API_TOKEN

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

# Print output
echo "----------------------------"
echo "INSTALLATION COMPLETED"
echo "Customer A Staging Environment available at: http://staging.customera.$VM_IP.nip.io"
echo "Customer A Production Environment available at: http://customera.$VM_IP.nip.io"
echo "Customer B Staging Environment available at: http://staging.customerb.$VM_IP.nip.io"
echo "Customer B Production Environment available at: http://customerb.$VM_IP.nip.io"
echo "Customer C Staging Environment available at: http://staging.customerc.$VM_IP.nip.io"
echo "Customer C Production Environment available at: http://customerc.$VM_IP.nip.io"
echo "Jenkins available at: http://jenkins.$VM_IP.nip.io"
echo "Keptn's API available at: http://keptn.$VM_IP.nip.io/api"
echo "Keptn's Bridge available at: http://keptn.$VM_IP.nip.io/bridge"
echo "Keptn's API Token: $KEPTN_API_TOKEN"
echo -e "Keptn's Bridge Credentials: \n$(keptn configure bridge --output)"
echo "----------------------------"