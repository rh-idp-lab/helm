#!/bin/bash
# Platform Health Check Script
# Checks all IDP components and reports status

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Component namespaces
declare -A COMPONENTS=(
  ["OpenShift GitOps"]="openshift-gitops"
  ["GitLab"]="gitlab"
  ["Vault"]="vault"
  ["NooBaa"]="openshift-storage"
  ["Keycloak"]="sso"
  ["OpenShift Pipelines"]="openshift-pipelines"
  ["Red Hat Quay"]="quay-registry"
  ["External Secrets"]="external-secrets"
  ["RHDH GitOps"]="rhdh-gitops"
  ["Dev Spaces"]="openshift-devspaces"
  ["Trusted Artifact Signer"]="trusted-artifact-signer"
  ["Red Hat Developer Hub"]="rhdh"
)

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Internal Developer Platform - Health Check${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

TOTAL_COMPONENTS=${#COMPONENTS[@]}
HEALTHY_COMPONENTS=0

check_namespace_health() {
  local name=$1
  local namespace=$2

  # Check if namespace exists
  if ! oc get namespace "$namespace" &>/dev/null; then
    echo -e "${YELLOW}⚪ $name${NC} - Namespace not found (not deployed yet)"
    return
  fi

  # Get pod status
  local total_pods=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [ "$total_pods" -eq 0 ]; then
    echo -e "${YELLOW}⚪ $name${NC} - No pods found (deployment pending)"
    return
  fi

  local ready_pods=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | awk '$3 == "Running" && $2 ~ /\// {split($2, a, "/"); if (a[1] == a[2]) print $0}' | wc -l | tr -d ' ')

  if [ "$ready_pods" -eq "$total_pods" ]; then
    echo -e "${GREEN}✅ $name${NC} - All pods running ($ready_pods/$total_pods)"
    ((HEALTHY_COMPONENTS++))
  else
    echo -e "${RED}❌ $name${NC} - Some pods not ready ($ready_pods/$total_pods)"

    # Show pods that are not ready
    echo -e "   ${YELLOW}Not Ready:${NC}"
    oc get pods -n "$namespace" --no-headers 2>/dev/null | awk '$3 != "Running" || $2 !~ /\// {print "   - " $1 " (" $3 ")"}' || true
    oc get pods -n "$namespace" --no-headers 2>/dev/null | awk '$3 == "Running" && $2 ~ /\// {split($2, a, "/"); if (a[1] != a[2]) print "   - " $1 " (" $2 ")"}' || true
  fi
}

# Check each component
for component in "${!COMPONENTS[@]}"; do
  check_namespace_health "$component" "${COMPONENTS[$component]}"
done

echo ""
echo -e "${BLUE}========================================${NC}"

# Calculate health percentage
HEALTH_PERCENT=$((HEALTHY_COMPONENTS * 100 / TOTAL_COMPONENTS))

if [ "$HEALTH_PERCENT" -eq 100 ]; then
  echo -e "${GREEN}Platform Health: ${HEALTH_PERCENT}% (${HEALTHY_COMPONENTS}/${TOTAL_COMPONENTS} components healthy)${NC}"
  echo -e "${GREEN}✅ All components are healthy and running!${NC}"
elif [ "$HEALTH_PERCENT" -ge 75 ]; then
  echo -e "${YELLOW}Platform Health: ${HEALTH_PERCENT}% (${HEALTHY_COMPONENTS}/${TOTAL_COMPONENTS} components healthy)${NC}"
  echo -e "${YELLOW}⚠️  Some components need attention.${NC}"
else
  echo -e "${RED}Platform Health: ${HEALTH_PERCENT}% (${HEALTHY_COMPONENTS}/${TOTAL_COMPONENTS} components healthy)${NC}"
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
