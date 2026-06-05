#!/bin/bash
# Reset a GitLab user password via the admin API
# Usage: ./gitlab-reset-password.sh <username> [new_password]
# If no password is provided, the common_password is retrieved from Vault.

set -euo pipefail

USERNAME="${1:-}"
NEW_PASSWORD="${2:-}"

if [ -z "$USERNAME" ]; then
  echo "Usage: $0 <username> [new_password]"
  echo "  username     GitLab username to reset (e.g. user1)"
  echo "  new_password New password (optional, defaults to Vault common_password)"
  exit 1
fi

# --- Retrieve root token ---
ROOT_TOKEN=$(oc get secret root-user-personal-token -n gitlab \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)

if [ -z "$ROOT_TOKEN" ]; then
  echo "❌ Could not retrieve GitLab root token (secret root-user-personal-token not found in namespace gitlab)"
  exit 1
fi

# --- Retrieve GitLab host ---
GITLAB_HOST=$(oc get route gitlab -n gitlab -o jsonpath='{.spec.host}' 2>/dev/null)

if [ -z "$GITLAB_HOST" ]; then
  echo "❌ Could not find GitLab route in namespace gitlab"
  exit 1
fi

# --- Retrieve password from Vault if not provided ---
if [ -z "$NEW_PASSWORD" ]; then
  echo "ℹ️  No password provided — retrieving common_password from Vault..."
  VAULT_TOKEN=$(oc get secret vault-token -n vault \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
  NEW_PASSWORD=$(oc exec -n vault vault-0 -- \
    env VAULT_TOKEN="$VAULT_TOKEN" vault kv get -field=password \
    kv/secrets/rhdh/common_password 2>/dev/null | tr -d '[:space:]')
  if [ -z "$NEW_PASSWORD" ]; then
    echo "❌ Could not retrieve common_password from Vault"
    exit 1
  fi
  echo "ℹ️  Using password from Vault"
fi

# --- Find user ID ---
USER_JSON=$(curl -sk \
  -H "PRIVATE-TOKEN: $ROOT_TOKEN" \
  "https://$GITLAB_HOST/api/v4/users?username=$USERNAME")

USER_ID=$(echo "$USER_JSON" | python3 -c \
  "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')" 2>/dev/null)

if [ -z "$USER_ID" ]; then
  echo "❌ User '$USERNAME' not found in GitLab"
  exit 1
fi

echo "ℹ️  Found user '$USERNAME' (id=$USER_ID)"

# --- Reset password ---
RESPONSE=$(curl -sk -o /dev/null -w "%{http_code}" -X PUT \
  -H "PRIVATE-TOKEN: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"$NEW_PASSWORD\", \"skip_reconfirmation\": true, \"password_expires_at\": null}" \
  "https://$GITLAB_HOST/api/v4/users/$USER_ID")

if [ "$RESPONSE" = "200" ]; then
  echo "✅ Password reset successfully for '$USERNAME'"
  echo "   URL:      https://$GITLAB_HOST"
  echo "   Username: $USERNAME"
  echo "   Password: $NEW_PASSWORD"
else
  echo "❌ Password reset failed (HTTP $RESPONSE)"
  echo "   Trying gitlab-rails runner as fallback..."
  GITLAB_POD=$(oc get pod -n gitlab -l app=gitlab --no-headers 2>/dev/null | awk 'NR==1{print $1}')
  oc exec -n gitlab "$GITLAB_POD" -- gitlab-rails runner \
    "u = User.find_by_username('$USERNAME'); u.password = '$NEW_PASSWORD'; u.password_confirmation = '$NEW_PASSWORD'; u.password_automatically_set = false; u.password_expires_at = nil; u.save!(validate: false); puts 'ok'" \
    2>/dev/null && echo "✅ Password reset via gitlab-rails runner" || echo "❌ Both methods failed"
fi
