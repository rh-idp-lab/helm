#!/bin/bash
# Platform Health Check Script
# Checks all IDP components and reports status

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Statuses considered healthy (running or finished successfully)
HEALTHY_STATUSES="Running|Completed|Succeeded"

# Component namespaces (lookup map)
declare -A COMPONENTS=(
  ["OpenShift GitOps"]="openshift-gitops"
  ["GitLab"]="gitlab"
  ["Vault"]="vault"
  ["Keycloak"]="keycloak"
  ["OpenShift Pipelines"]="openshift-pipelines"
  ["Red Hat Quay"]="quay-registry"
  ["External Secrets"]="external-secrets"
  ["RHDH GitOps"]="rhdh-gitops"
  ["Dev Spaces"]="openshift-devspaces"
  ["Trusted Artifact Signer"]="trusted-artifact-signer"
  ["Red Hat Developer Hub"]="rhdh"
)

# Display order (bash associative arrays don't preserve insertion order)
COMPONENTS_ORDER=(
  "OpenShift GitOps"
  "GitLab"
  "Vault"
  "Keycloak"
  "OpenShift Pipelines"
  "Red Hat Quay"
  "External Secrets"
  "RHDH GitOps"
  "Dev Spaces"
  "Trusted Artifact Signer"
  "Red Hat Developer Hub"
)

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Internal Developer Platform - Health Check${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

TOTAL_COMPONENTS=${#COMPONENTS[@]}
HEALTHY_COMPONENTS=0
HEALTHY_CONFIGS=0
TOTAL_CONFIGS=0

check_namespace_health() {
  local name=$1
  local namespace=$2

  # Check if namespace exists
  if ! oc get namespace "$namespace" &>/dev/null; then
    echo -e "${YELLOW}⚪ $name${NC} - Namespace not found (not deployed yet)"
    return
  fi

  # Get all pods
  local all_pods
  all_pods=$(oc get pods -n "$namespace" --no-headers 2>/dev/null || true)

  if [ -z "$all_pods" ]; then
    echo -e "${YELLOW}⚪ $name${NC} - No pods found (deployment pending)"
    return
  fi

  local total_pods
  total_pods=$(echo "$all_pods" | wc -l | tr -d ' ')

  # Count healthy pods: Running (with all containers ready) + Completed + Succeeded
  local running_ready
  running_ready=$(echo "$all_pods" | awk '$3 == "Running" && $2 ~ /\// {split($2, a, "/"); if (a[1] == a[2]) c++} END {print c+0}')

  local completed
  completed=$(echo "$all_pods" | awk '$3 == "Completed" || $3 == "Succeeded" {c++} END {print c+0}')

  local healthy_pods=$((running_ready + completed))

  # Unhealthy = not Running-ready, not Completed, not Succeeded
  local unhealthy_pods=$((total_pods - healthy_pods))

  if [ "$unhealthy_pods" -eq 0 ]; then
    local detail="${running_ready} running"
    if [ "$completed" -gt 0 ]; then
      detail="${detail}, ${completed} completed"
    fi
    echo -e "${GREEN}✅ $name${NC} - All healthy (${detail})"
    HEALTHY_COMPONENTS=$((HEALTHY_COMPONENTS + 1))
  else
    echo -e "${RED}❌ $name${NC} - ${unhealthy_pods} pod(s) unhealthy (${healthy_pods}/${total_pods} ok)"

    # Show only truly problematic pods
    echo -e "   ${YELLOW}Issues:${NC}"
    echo "$all_pods" | awk -v hs="$HEALTHY_STATUSES" '
      BEGIN { split(hs, arr, "|"); for (i in arr) ok[arr[i]]=1 }
      {
        status = $3
        if (status == "Running" && $2 ~ /\//) {
          split($2, a, "/")
          if (a[1] == a[2]) next
          print "   - " $1 " (containers " $2 ")"
          next
        }
        if (!(status in ok)) print "   - " $1 " (" status ")"
      }
    ' || true
  fi
}

check_vault_secret() {
  local secret_path=$1
  local label=$2
  TOTAL_CONFIGS=$((TOTAL_CONFIGS + 1))

  # Vault namespace must exist
  if ! oc get namespace vault &>/dev/null; then
    echo -e "${YELLOW}⚪ $label${NC} - Vault not deployed yet"
    return
  fi

  # Vault pod must be running
  local vault_pod
  vault_pod=$(oc get pod vault-0 -n vault --no-headers 2>/dev/null | awk '{print $3}')
  if [ "$vault_pod" != "Running" ]; then
    echo -e "${YELLOW}⚪ $label${NC} - Vault pod not ready"
    return
  fi

  # Get Vault token
  local vault_token
  vault_token=$(oc get secret vault-token -n vault -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)
  if [ -z "$vault_token" ]; then
    echo -e "${RED}❌ $label${NC} - Vault token secret not found"
    return
  fi

  # Try to read the secret
  local result
  set +e
  result=$(oc exec -n vault vault-0 -- env VAULT_TOKEN="$vault_token" \
    vault kv get -format=json "$secret_path" 2>/dev/null)
  local vault_exit=$?
  set -e

  if [ $vault_exit -eq 0 ] && [ -n "$result" ]; then
    echo -e "${GREEN}✅ $label${NC} - Secret found (${secret_path})"
    HEALTHY_CONFIGS=$((HEALTHY_CONFIGS + 1))
  else
    echo -e "${RED}❌ $label${NC} - Secret not found at ${secret_path}"
    echo -e "   ${YELLOW}Fix:${NC} Run the Vault secrets step in Module 3"
  fi
}

# Check each component in defined order
for component in "${COMPONENTS_ORDER[@]}"; do
  check_namespace_health "$component" "${COMPONENTS[$component]}"
done

check_rhdh_templates() {
  TOTAL_CONFIGS=$((TOTAL_CONFIGS + 1))
  local label="RHDH — Software Templates in catalog"

  if ! oc get namespace rhdh &>/dev/null; then
    echo -e "${YELLOW}⚪ $label${NC} - Developer Hub not deployed yet"
    return
  fi

  local rhdh_host=""
  # Try known route names for RHDH (operator version dependent)
  rhdh_host=$(oc get route backstage-developer-hub -n rhdh -o jsonpath='{.spec.host}' 2>/dev/null) || true
  if [ -z "$rhdh_host" ]; then
    rhdh_host=$(oc get route backstage -n rhdh -o jsonpath='{.spec.host}' 2>/dev/null) || true
  fi
  if [ -z "$rhdh_host" ]; then
    # Fallback: pick the first route in the namespace
    rhdh_host=$(oc get route -n rhdh -o jsonpath='{.items[0].spec.host}' 2>/dev/null) || true
  fi
  if [ -z "$rhdh_host" ]; then
    echo -e "${YELLOW}⚪ $label${NC} - Developer Hub route not found"
    return
  fi

  # Derive Keycloak host from the RHDH route (same cluster domain, sso. prefix)
  local cluster_domain="${rhdh_host#backstage-rhdh.}"
  local keycloak_host="sso.${cluster_domain}"

  # Get common_password from Vault
  local vault_token="" common_pass="" access_token="" template_count=""

  vault_token=$(oc get secret vault-token -n vault \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null) || true

  if [ -n "$vault_token" ]; then
    common_pass=$(oc exec -n vault vault-0 -- \
      env VAULT_TOKEN="$vault_token" vault kv get -field=password \
      kv/secrets/rhdh/common_password 2>/dev/null | tr -d '[:space:]') || true
  fi

  if [ -z "$common_pass" ]; then
    echo -e "${YELLOW}⚪ $label${NC} - Could not retrieve password from Vault"
    return
  fi

  # Get a user token via Keycloak password grant
  local token_response=""
  token_response=$(curl -sk --max-time 10 -X POST \
    "https://${keycloak_host}/realms/sso/protocol/openid-connect/token" \
    -d "client_id=backstage&client_secret=${common_pass}&username=user1&password=${common_pass}&grant_type=password" \
    2>/dev/null) || true

  access_token=$(echo "$token_response" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

  if [ -z "$access_token" ]; then
    echo -e "${YELLOW}⚪ $label${NC} - Could not authenticate against Keycloak"
    return
  fi

  # Query Backstage catalog for Template entities
  local catalog_response=""
  catalog_response=$(curl -sk --max-time 10 \
    -H "Authorization: Bearer $access_token" \
    "https://${rhdh_host}/api/catalog/entities?filter=kind=Template&limit=10" \
    2>/dev/null) || true

  template_count=$(echo "$catalog_response" | \
    python3 -c "import sys,json; items=json.load(sys.stdin); print(len(items) if isinstance(items,list) else 0)" \
    2>/dev/null) || true

  # Guard: ensure template_count is a valid integer
  if ! echo "$template_count" | grep -qE '^[0-9]+$'; then
    template_count=0
  fi

  if [ "$template_count" -gt 0 ]; then
    echo -e "${GREEN}✅ $label${NC} - ${template_count} template(s) registered"
    HEALTHY_CONFIGS=$((HEALTHY_CONFIGS + 1))
  else
    echo -e "${RED}❌ $label${NC} - No templates found in catalog"
    echo -e "   ${YELLOW}Fix:${NC} Import templates in RHDH (Module 6 → Import Software Templates)"
  fi
}

# Configuration checks
echo ""
echo -e "${BLUE}--- Configuration Checks ---${NC}"
check_vault_secret    "kv/secrets/rhdh/common_password" "Vault — common_password secret"
check_vault_secret    "kv/secrets/rhdh/gitlab"          "Vault — GitLab token secret"
check_rhdh_templates

echo ""
echo -e "${BLUE}========================================${NC}"

# Calculate health percentage (namespace components + config checks)
TOTAL_ALL=$((TOTAL_COMPONENTS + TOTAL_CONFIGS))
HEALTHY_ALL=$((HEALTHY_COMPONENTS + HEALTHY_CONFIGS))
HEALTH_PERCENT=$((HEALTHY_ALL * 100 / TOTAL_ALL))

if [ "$HEALTH_PERCENT" -eq 100 ]; then
  echo -e "${GREEN}Platform Health: ${HEALTH_PERCENT}% (${HEALTHY_COMPONENTS}/${TOTAL_COMPONENTS} components, ${HEALTHY_CONFIGS}/${TOTAL_CONFIGS} config checks)${NC}"
  echo -e "${GREEN}✅ All components are healthy!${NC}"
elif [ "$HEALTH_PERCENT" -ge 75 ]; then
  echo -e "${YELLOW}Platform Health: ${HEALTH_PERCENT}% (${HEALTHY_COMPONENTS}/${TOTAL_COMPONENTS} components, ${HEALTHY_CONFIGS}/${TOTAL_CONFIGS} config checks)${NC}"
  echo -e "${YELLOW}⚠️  Some components need attention.${NC}"
else
  echo -e "${RED}Platform Health: ${HEALTH_PERCENT}% (${HEALTHY_COMPONENTS}/${TOTAL_COMPONENTS} components, ${HEALTHY_CONFIGS}/${TOTAL_CONFIGS} config checks)${NC}"
  echo -e "${RED}❌ Multiple components are not healthy. Review deployment status.${NC}"
fi

echo -e "${BLUE}========================================${NC}"
echo ""

# Recommendations
if [ "$HEALTH_PERCENT" -lt 100 ]; then
  echo -e "${BLUE}Recommendations:${NC}"
  echo "  • Check ArgoCD UI for application sync status"
  echo "  • Review pod logs: oc logs -n <namespace> <pod-name>"
  echo "  • Check events: oc get events -n <namespace> --sort-by='.lastTimestamp'"
  echo ""
fi

exit 0
