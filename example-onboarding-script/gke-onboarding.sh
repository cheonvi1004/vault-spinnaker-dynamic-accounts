#!/bin/bash



# Inspired by: https://stackoverflow.com/questions/42170380/how-to-add-users-to-kubernetes-kubectl
# this script creates a service account (spinnaker-user) on a Kubernetes cluster (tested with AWS EKS 1.9)
# prereqs: a kubectl ver 1.10 installed and proper configuration of the heptio authenticator
# this has been tested on Linux in a Cloud9 environment (for MacOS the syntax may be slightly different)

echo    "#########################################################################################"
echo    "This script will create a new 'spinnaker' service account on the GKE cluster with admin"
echo    "permissions and upload the credentials to Vault for use by spinnaker dynamic accounts"
echo -e "##########################################################################################\n\n"


# Optionally namespace name can be provided as input with options -n|--namespace
# If not, service account will be created in default namespace
NAMESPACE="default"
while test $# -gt 0; do
  case "$1" in
    -h|--help)
      echo "Usage: $0 [-n|--namespace <name>]"
      echo '"default" namespace will be used if no arguments given'
      exit
      ;;
    -n|--namespace)
      test ! -z $2 && NAMESPACE=$2
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Limit the access to namespace level if provided
if [ $NAMESPACE == "default" ]; then
  ROLEBINDING="ClusterRoleBinding"
else
  ROLEBINDING="RoleBinding"
fi

echo "Using the namespace \"$NAMESPACE\""

####################################################
########             Dependencies           ########
####################################################

# ensure that the required commands are present needed to run this script
die() { echo "$*" 1>&2 ; exit 1; }

need() {
    which "$1" &>/dev/null || die "Binary '$1' is missing but required"
}

need "jq"
need "vault"
need "base64"
need "kubectl"
need "curl"

# make sure that a ~/.kube/config file exists or $KUBECONFIG is set before moving forward
if ! { [ -n "$KUBECONFIG" ] || [ -f ~/.kube/config ]; } ; then
  echo "Error: no ~/.kube/config file is present or \$KUBECONFIG is not set. cannot continue"
  echo "You can run the 'gcloud container clusters get-credentials' command to retrieve the gke credentials"
  exit 1
fi

# base64 operates differently in OSX vs linux
if [[ "$OSTYPE" == "darwin"* ]] && [[ ! -f /usr/local/bin/base64 ]]; then
    BASE64_DECODE="-D"
else
    BASE64_DECODE="-d"
fi


####################################################
########           Create an account        ########
####################################################
# Checking the existence of namespace
kubectl get namespace $NAMESPACE &> /dev/null || die "namespace \"$NAMESPACE\" does not exist"
# Create service account for user spinnaker-user
kubectl create sa spinnaker-user --namespace $NAMESPACE
# Get related secret
secret=$(kubectl get sa spinnaker-user --namespace $NAMESPACE -o json | jq -r '.secrets[].name')
# Get ca.crt from secret
kubectl get secret "$secret" --namespace $NAMESPACE -o json | jq -r '.data["ca.crt"]' | base64 "$BASE64_DECODE" > ca.crt
# Get service account token from secret
user_token=$(kubectl get secret "$secret" --namespace $NAMESPACE -o json | jq -r '.data["token"]' | base64 "$BASE64_DECODE")
# Get information from your kubectl config (current-context, server..)
# get current context
c=$(kubectl config current-context)
# get cluster name of context
name=$(kubectl config get-contexts "$c" | awk '{print $3}' | tail -n 1)
# get endpoint of current context
endpoint=$(kubectl config view -o jsonpath="{.clusters[?(@.name == \"$name\")].cluster.server}")

# Create the yaml to bind the cluster admin role to spinnaker-user
# cluster-admin role:
# When used in a ClusterRoleBinding, it gives full control over every resource in the cluster and in all namespaces.
# When used in a RoleBinding, it gives full control over every resource in the rolebinding's namespace, including the namespace itself
# Ref: https://kubernetes.io/docs/reference/access-authn-authz/rbac/#user-facing-roles
cat <<EOF >> rbac-config-spinnaker-user.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: $ROLEBINDING
metadata:
  name: spinnaker-user
  namespace: $NAMESPACE
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: spinnaker-user
    namespace: $NAMESPACE
EOF

# Apply the policy to spinnaker-user
## nota bene: this command is running against the GKE admin account (defaulting to a reference in ~/.kube/config)
kubectl apply -f rbac-config-spinnaker-user.yaml
if [[ "$?" -eq 0 ]]; then
  rm rbac-config-spinnaker-user.yaml
else
  echo "There was an error applying the $ROLEBINDING"
  rm rbac-config-spinnaker-user.yaml
  exit 1
fi


####################################################
########         Consume the account        ########
####################################################


echo -e "Getting current gcloud project configured\n"
PROJECT=$(gcloud config list --format 'value(core.project)' 2>/dev/null)
echo -e "Current project is : $PROJECT \n"
echo -e "Getting current user \n"
CURRENT_USER_ACCOUNT=$(gcloud config list account --format "value(core.account)" 2>/dev/null)
echo -e "Getting cluster information \n"
CLUSTER_ENDPOINT_IP=$(echo "$endpoint" | sed 's/https:\/\///')
CLUSTER_LOCATION=$(gcloud container clusters list --filter="endpoint:$CLUSTER_ENDPOINT_IP" --format="value(location)" 2>/dev/null)
CLUSTER_NAME=$(gcloud container clusters list --filter="endpoint:$CLUSTER_ENDPOINT_IP" --format="value(name)" 2>/dev/null)

CLUSTER_ID="gke_${PROJECT}_${CLUSTER_LOCATION}_${CLUSTER_NAME}_${NAMESPACE}"
CONFIG_FILE="$CLUSTER_ID.config"

cat << EOF | vault kv put secret/dynamic_accounts/intake/"$CLUSTER_ID" -
{
  "ca_cert": "$(< ca.crt)",
  "k8s_host": "$endpoint",
  "k8s_name": "$CLUSTER_ID",
  "k8s_username": "spinnaker-user",
  "user_token": "$user_token"
}

EOF
```

if [ "$?" -eq 0 ]; then
    echo "Uploaded details to Vault intake location"
else
    echo "Unable to upload details to Vault intake location"
    exit 1
fi


