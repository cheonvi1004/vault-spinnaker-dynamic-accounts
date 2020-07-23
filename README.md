# vault-spinnaker-dynamic-accounts

## Introduction

The following instructions have been created to allow a Spinnaker Operator to configure their Spinnaker deployment to utilize dynamic accounts through HashCorp Vault including tha ability to add new accounts using a collection of a Run Job Manifest turned into Custom Job Stage, example Terraform git repositories for creating infrastructure and storing credentials within vault, and Spinnaker Pipelines designed specifically for the Spinnaker Operators to use to add new accounts without having to re-deploy Spinnaker through Halyard and able to utilize through automation!

## Table of Contents

<!-- TOC -->
- [Introduction](#introduction)
- [Table of Contents](#table-of-contents)
- [Goals](#goals)
- [Prerequisites](#prerequisites)
- [Relatively easy Vault-Helm Example Installation](#relatively-easy-vault-helm-example-installation)
	- [Description](#description)
	- [Instructions](#instructions)
- [Configure Vault](#configure-vault)
	- [Login to vault](#login-to-vault)
	- [Create policies for dynamic accounts](#create-policies-for-dynamic-accounts)
	- [Create read-only app role for Spinnaker](#create-read-only-app-role-for-spinnaker)
	- [Create read-write approle for Spinnaker](#create-read-write-approle-for-spinnaker)
	- [Setup Kubernetes Authentication within Vault](#setup-kubernetes-authentication-within-vault)
		- [Description](#description)
		- [Vault Kubernetes Authentication Installation Instructions](#vault-kubernetes-authentication-installation-instructions)
	- [Populate the Vault Dynamic Account Secret](#populate-the-vault-dynamic-account-secret)
- [Configure Spinnaker](#configure-spinnaker)
<!-- /TOC -->

## Goals

1. Relatively simple install of Vault on Kubernetes using the awesome [vault-helm](https://github.com/hashicorp/vault-helm) project
1. Configure Vault for Spinnaker dynamic accounts by creating secret stores, policies, roles, authentication methods, and AppRoles to be used for authentication
1. Configure Spinnaker to utilize vault for dynamic accounts
1. Create an example Terraform repo to create new infrastructure and add details into Vault secret
1. Create Custom Job Stage from Run Job Manifest to facilitate adding new account into dynamic accounts by the Spinnaker Operators by pulling newly added infrastructure credentials to the master dynamic accounts credential list

## Prerequisites

1. Have HashiCorp Vault up and running with Vault Agent Injector or use the [Relatively easy Vault-Helm Example Installation](#relatively-easy-vault-helm-example-installation)
1. Have Spinnaker up and running

## Relatively easy Vault-Helm Example Installation

### Description

The included vault-helm values file will setup a vault server in HA mode with Raft as the backend. It is not ideal for production due to the secrets being stored in the cluster rather than stored externally but good enough to see how to "connect the lego pieces" and continue with the demonstration

### Instructions

Create the vault namespace

`kubectl create ns vault`

Load your TLS certs into a secret into the vault namespace (you can get this from Let's Encrypt *outside the scope of this tutorial)

```sh
cat <<SECRET_EOF | kubectl -n vault apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vault-tls
  namespace: vault
type: Opaque
data:
  vault.pem: $(cat /path/to/certbot/cert_wildcard.crt | base64 -w 0)
  vault.key: $(cat /path/to/certbot/cert_wildcard.key | base64 -w 0)
SECRET_EOF
```

Install helm locally

`brew install helm`

Add HashiCorp repo to local Helm installation

`helm repo add hashicorp https://helm.releases.hashicorp.com`

Modify the example helm values file to suit your needs then install the helm chart

```sh
helm install vault hashicorp/vault \
  --version 0.6.0 \
  --values=example-vault-helm-values/vault-helm-values.yml \
  --namespace vault
```

Follow the rest of the setup instruction from [here](https://www.vaultproject.io/docs/platform/k8s/helm/examples/ha-with-raft#highly-available-vault-cluster-with-integrated-storage-raft) (after the install command) to complete the Vault configuration. IMPORTANT NOTE: Make sure you keep the unseal keys and the initial root token safe because you will need that!

You now have a vault server up and running, congrats!

## Configure Vault

### Login to vault

You can install the vault cli locally through brew or you can log into your vault instance

`brew install vault`

Setup environment variables for `VAULT_ADDR` and `VAULT_TOKEN` to point to your vault installation

You may need to log into your vault if you haven't already

`vault login`

### Create policies for dynamic accounts

Create the vault secret location for dynamic accounts

```sh
vault secrets enable \
    -version=1 \
    -path="secret" \
    -default-lease-ttl=0 \
    -max-lease-ttl=0 \
    kv
```

Create read-write vault policy for dynamic accounts

```sh
cat << VAULT_POLICY | vault policy write dynamic_accounts_ro_policy -
# For K/V v1 secrets engine
path "secret/dynamic_accounts/*" {
    capabilities = ["read", "list"]
}
# For K/V v2 secrets engine
path "secret/data/dynamic_accounts/*" {
    capabilities = ["read", "list"]
}
VAULT_POLICY
```

Create read-write vault policy for dynamic accounts

```sh
cat << VAULT_POLICY | vault policy write dynamic_accounts_rw_policy -
# For K/V v1 secrets engine
path "secret/dynamic_accounts/*" {
    capabilities = ["read", "list", "create", "update", "delete"]
}
# For K/V v2 secrets engine
path "secret/data/dynamic_accounts/*" {
    capabilities = ["read", "list", "create", "update", "delete"]
}
VAULT_POLICY
```

Enable approle authentication within Vault to generate token to be used by Spinnaker to access the dynamic accounts secret (NEVER USE THE ROOT TOKEN FOR ANYTHING OTHER THAN SETTING UP BETTER OPTIONS) and for approle to be used by 

```sh
vault auth enable approle
```

### Create read-only app role for Spinnaker

```sh
vault write \
    auth/approle/role/dynamic_accounts_ro_role \
    token_policies="dynamic_accounts_ro_policy" \
    token_max_ttl="1600h" \
    token_num_uses=0 \
    secret_id_num_uses=0
```
Get role-id for dynamic accounts read-only approle
Note: We use `jq` for convenience below but you could just as well grab the results from the vault output

```sh
vault read -format=json auth/approle/role/dynamic_accounts_ro_role/role-id \
    | jq -r '.data.role_id' > .dynamic-accounts-ro-role-id
```

Get secret-id for dynamic accounts read-only approle

```sh
vault write -format=json -force auth/approle/role/dynamic_accounts_ro_role/secret-id \
    | jq -r '.data.secret_id' > .dynamic-accounts-ro-role-secret-id
```

Get a token for the read-only approle by using the role-id and the secret-id

```sh
vault write \
    -format=json auth/approle/login \
    role_id="$(cat .dynamic-accounts-ro-role-id)" \
    secret_id="$(cat .dynamic-accounts-ro-role-secret-id)" \
    | jq -r '.auth.client_token' > .dynamic-accounts-ro-token
```

### Create read-write approle for Spinnaker

```sh
vault write \
    auth/approle/role/dynamic_accounts_rw_role \
    token_policies="dynamic_accounts_rw_policy" \
    token_max_ttl="1600h" \
    token_num_uses=0 \
    secret_id_num_uses=0
```
Get role-id for dynamic accounts read-write approle

```sh
vault read -format=json auth/approle/role/dynamic_accounts_rw_role/role-id \
    | jq -r '.data.role_id' > .dynamic-accounts-rw-role-id
```

Get secret-id for dynamic accounts read-write approle

```sh
vault write -format=json -force auth/approle/role/dynamic_accounts_rw_role/secret-id \
    | jq -r '.data.secret_id' > .dynamic-accounts-rw-role-secret-id
```

Get a token for the read-write approle by using the role-id and the secret-id

```sh
vault write \
    -format=json auth/approle/login \
    role_id="$(cat .dynamic-accounts-rw-role-id)" \
    secret_id="$(cat .dynamic-accounts-rw-role-secret-id)" \
    | jq -r '.auth.client_token' > .dynamic-accounts-rw-token
```

### Setup Kubernetes Authentication within Vault

#### Description

The following commands are mostly pulled from [this location](https://docs.armory.io/docs/spinnaker-install-admin-guides/secrets/vault-k8s-configuration/)

Assumption is kubectl is configured to point to your Spinnaker deployment cluster

#### Vault Kubernetes Authentication Installation Instructions

Create the vault-auth service account that Vault will use to verify the authenticity of kubernetes service accounts

```sh
kubectl -n default \
  create serviceaccount vault-auth
```

Setup Cluster Role Binding to allow vault to validate any kubernetes service account in any namespace

```sh
cat << VAULT_AUTH_SVC_ACCT | kubectl -n default apply --filename -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: role-tokenreview-binding
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-auth
  namespace: default
VAULT_AUTH_SVC_ACCT
```

Enable the Kubernetes authentication for Vault

```sh
vault auth enable \
    --path="kubernetes-spinnaker" \
    kubernetes
```

Getting information from Kubernetes to complete auth method for vault

```sh
kubectl -n default get sa vault-auth \
    -o jsonpath="{.secrets[*]['name']}" > .dynamic-accounts-vault-auth-sa-name
kubectl -n default get secret $(cat .dynamic-accounts-vault-auth-sa-name) \
    -o jsonpath="{.data.token}" | base64 --decode > .dynamic-accounts-vault-auth-sa-jwt-token
kubectl -n default get secret $(cat .dynamic-accounts-vault-auth-sa-name) \
    -o jsonpath="{.data['ca\.crt']}" | base64 --decode > .dynamic-accounts-vault-auth-sa-ca-crt
# Assumption is the kubeconfig file ONLY has the required server in the list. If the required 
#   server is not the first entry this may not return the correct server address so adjust accordingly
kubectl config view \
    -o jsonpath="{.clusters[0].cluster.server}" > .dynamic-accounts-vault-auth-k8s-host
```

Creating Kubernetes auth config so that vault will be able to validate JWTs for kubernetes service accounts looking to log into vault to access secrets

```sh
vault write \
    auth/kubernetes-spinnaker/config \
    token_reviewer_jwt="$(cat .dynamic-accounts-vault-auth-sa-jwt-token)" \
    kubernetes_host="$(cat .dynamic-accounts-vault-auth-k8s-host)" \
    kubernetes_ca_cert="$(cat .dynamic-accounts-vault-auth-sa-ca-crt)"
```

Create kubernetes service account to be used to write to the dynamic accounts secret

```sh
kubectl -n spinnaker \
  create serviceaccount spinnaker-dyn-acct-rw
```

Setup kubernetes auth for service account to map policy and role to specific kubernetes service account in specific namespace

```sh
vault write \
    auth/kubernetes-spinnaker/role/dynamic-account-rw-role \
    bound_service_account_names="spinnaker-dyn-acct-rw" \
    bound_service_account_namespaces="spinnaker" \
    policies="dynamic_accounts_rw_policy" \
    ttl="1680h"
```

### Populate the Vault Dynamic Account Secret

You will need a JSON representation of the existing kubeconfig file that Spinnaker is currently using to deploy because when you enable dynamic accounts the contents of the vault secret will take the place of any configuration halyard may have previously set under the `kubernetes.account` configuration. Vault only supports JSON objects so you will need to convert the existing yaml for the kubeconfig into JSON.

A pretty nice YAML to JSON converter can be [found here](https://codebeautify.org/yaml-to-json-xml-csv)

We need to get the existing account configuration(s) from your halyard config file and convert that/them from YAML into JSON.

Here is an example of the relevant parts of the halyard config:

We can copy everything from the `kubernetes` section all the way until before the `primaryAccount` and it should look like this:

```yaml
    kubernetes:
      enabled: true
      accounts:
      - name: spin-cluster-account
        requiredGroupMembership: []
        providerVersion: V2
        permissions:
          READ:
          - spingo-spinnaker-admins
          WRITE:
          - spingo-spinnaker-admins
        dockerRegistries:
        - accountName: docker-registry
          namespaces: []
        configureImagePullSecrets: true
        cacheThreads: 1
        namespaces: []
        omitNamespaces: []
        kinds: []
        omitKinds: []
        customResources: []
        cachingPolicies: []
        kubeconfigFile: /spinnaker/.kube/spinnaker-us-east1.config
        oAuthScopes: []
        onlySpinnakerManaged: true
```

But YAML very much cares about alignment so we need to line up the `kubernetes` element with the beginning of the line like this:

```yaml
kubernetes:
  enabled: true
  accounts:
  - name: spin-cluster-account
    requiredGroupMembership: []
    providerVersion: V2
    permissions:
      READ:
      - spingo-spinnaker-admins
      WRITE:
      - spingo-spinnaker-admins
    dockerRegistries:
    - accountName: docker-registry
      namespaces: []
    configureImagePullSecrets: true
    cacheThreads: 1
    namespaces: []
    omitNamespaces: []
    kinds: []
    omitKinds: []
    customResources: []
    cachingPolicies: []
    kubeconfigFile: /spinnaker/.kube/spinnaker-us-east1.config
    oAuthScopes: []
    onlySpinnakerManaged: true
```

Vault doesn't have the ability to read from files so the existing `kubeconfigFile` will not work. Luckily, there is a little-known property we can utilize called `kubeconfigContents` and we can place the contents of the kubeconfig file under this property like this (replace the redacted information with the correct information):

```yaml
kubernetes:
  enabled: true
  accounts:
    - name: spin-cluster-account
      requiredGroupMembership: []
      providerVersion: V2
      permissions:
        READ:
          - spingo-spinnaker-admins
        WRITE:
          - spingo-spinnaker-admins
      dockerRegistries:
        - accountName: docker-registry
          namespaces: []
      configureImagePullSecrets: true
      cacheThreads: 1
      namespaces: []
      omitNamespaces: []
      kinds: []
      omitKinds: []
      customResources: []
      cachingPolicies: []
      kubeconfigContents: "{\"apiVersion\":\"v1\",\"clusters\":[{\"cluster\":{\"certificate-authority-data\":\"....REDACTED....\",\"server\":\"https://....REDACTED....\"},\"name\":\"....REDACTED....\"}],\"contexts\":[{\"context\":{\"cluster\":\"....REDACTED....\",\"namespace\":\"default\",\"user\":\"spinnaker-user\"},\"name\":\"....REDACTED....\"}],\"current-context\":\"....REDACTED....\",\"kind\":\"Config\",\"preferences\":{},\"users\":[{\"name\":\"spinnaker-user\",\"user\":{\"token\":\"....REDACTED....\"}}]}"
```

So, once we convert to JSON for storage into vault we see this:

```json
{
	"kubernetes": {
		"enabled": true,
		"accounts": [
			{
				"name": "spin-cluster-account",
				"requiredGroupMembership": [],
				"providerVersion": "V2",
				"permissions": {
					"READ": [
						"spingo-spinnaker-admins"
					],
					"WRITE": [
						"spingo-spinnaker-admins"
					]
				},
				"dockerRegistries": [
					{
						"accountName": "docker-registry",
						"namespaces": []
					}
				],
				"configureImagePullSecrets": true,
				"cacheThreads": 1,
				"namespaces": [],
				"omitNamespaces": [],
				"kinds": [],
				"omitKinds": [],
				"customResources": [],
				"cachingPolicies": [],
				"kubeconfigContents": "{\"apiVersion\":\"v1\",\"clusters\":[{\"cluster\":{\"certificate-authority-data\":\"....REDACTED....\",\"server\":\"https://....REDACTED....\"},\"name\":\"....REDACTED....\"}],\"contexts\":[{\"context\":{\"cluster\":\"....REDACTED....\",\"namespace\":\"default\",\"user\":\"spinnaker-user\"},\"name\":\"....REDACTED....\"}],\"current-context\":\"....REDACTED....\",\"kind\":\"Config\",\"preferences\":{},\"users\":[{\"name\":\"spinnaker-user\",\"user\":{\"token\":\"....REDACTED....\"}}]}"
			}
		]
	}
}
```

Your dynamic account secret will need to reside inside vault under the location of the policy we created previously

```sh
cat << DYN_ACCT_START | vault kv put secret/dynamic_accounts/spinnaker -
{
	"kubernetes": {
		"enabled": true,
		"accounts": [
			{
				"name": "spin-cluster-account",
				"requiredGroupMembership": [],
				"providerVersion": "V2",
				"permissions": {
					"READ": [
						"spingo-spinnaker-admins"
					],
					"WRITE": [
						"spingo-spinnaker-admins"
					]
				},
				"dockerRegistries": [
					{
						"accountName": "docker-registry",
						"namespaces": []
					}
				],
				"configureImagePullSecrets": true,
				"cacheThreads": 1,
				"namespaces": [],
				"omitNamespaces": [],
				"kinds": [],
				"omitKinds": [],
				"customResources": [],
				"cachingPolicies": [],
				"kubeconfigContents": "{\"apiVersion\":\"v1\",\"clusters\":[{\"cluster\":{\"certificate-authority-data\":\"....REDACTED....\",\"server\":\"https://....REDACTED....\"},\"name\":\"....REDACTED....\"}],\"contexts\":[{\"context\":{\"cluster\":\"....REDACTED....\",\"namespace\":\"default\",\"user\":\"spinnaker-user\"},\"name\":\"....REDACTED....\"}],\"current-context\":\"....REDACTED....\",\"kind\":\"Config\",\"preferences\":{},\"users\":[{\"name\":\"spinnaker-user\",\"user\":{\"token\":\"....REDACTED....\"}}]}"
			}
		]
	}
}

DYN_ACCT_START
```

## Configure Spinnaker

Now that we have our dynamic accounts secret properly configured we can configure Spinnaker to point to that secret to use for dynamic account purposes. Wherever we have run halyard to setup the account we need to access that deployment and add a new file. In the example code below we are still using the standard deployment name of default but if you are using a different location then use that name instead.

Configure the address to your vault server in

```sh
VAULT_ADDR="" # example would be VAULT_ADDR="https://vault.spinnaker.example.com"
VAULT_TOKEN="" # example would be the value of the .dynamic-accounts-ro-token file we created above
SPINNAKER_DEPLOYMENT_NAME="default" # change this is you are not deploying to deployment called default
tee /path/to/halyard-directory/.hal/"$SPINNAKER_DEPLOYMENT_NAME"/profiles/spinnakerconfig.yml << EOF
spring:
  profiles:
    include: vault
  cloud:
    config:
      server:
        vault:
          host: $VAULT_ADDR
          port: 443
          scheme: https
          backend: secret/dynamic_accounts
          kvVersion: 1
          default-key: spinnaker
          token: $VAULT_TOKEN
EOF

```

Once that file is added you can then do a `hal deploy apply` which should configure the Spinnaker deployment to use dynamic accounts vault secret for all supported account types (Kubernetes/Cloud Foundry)
