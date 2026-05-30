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

# Component namespaces
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
  echo -e "${GREEN}✅ All components are healthy!${NC}"
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
