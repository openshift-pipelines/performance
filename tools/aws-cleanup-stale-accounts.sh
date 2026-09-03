#!/bin/bash

set -euo pipefail

THRESHOLD_DAYS=100
TODAY=$(date +%s)

for USER in $(aws iam list-users --query 'Users[*].UserName' --output text); do
  LAST_ACTIVITY_EPOCH=0

  # Check PasswordLastUsed
  PW_LAST_USED=$(aws iam get-user --user-name "$USER" --query 'User.PasswordLastUsed' --output text 2>/dev/null)
  if [ "$PW_LAST_USED" != "None" ] && [ -n "$PW_LAST_USED" ]; then
    PW_EPOCH=$(date -d "$PW_LAST_USED" +%s 2>/dev/null)
    if [ "$PW_EPOCH" -gt "$LAST_ACTIVITY_EPOCH" ]; then
      LAST_ACTIVITY_EPOCH=$PW_EPOCH
    fi
  fi

  # Check last used date of each access key
  for KEY_ID in $(aws iam list-access-keys --user-name "$USER" --query 'AccessKeyMetadata[*].AccessKeyId' --output text); do
    KEY_LAST_USED=$(aws iam get-access-key-last-used --access-key-id "$KEY_ID" --query 'AccessKeyLastUsed.LastUsedDate' --output text)
    if [ "$KEY_LAST_USED" != "None" ] && [ -n "$KEY_LAST_USED" ]; then
      KEY_EPOCH=$(date -d "$KEY_LAST_USED" +%s 2>/dev/null)
      if [ "$KEY_EPOCH" -gt "$LAST_ACTIVITY_EPOCH" ]; then
        LAST_ACTIVITY_EPOCH=$KEY_EPOCH
      fi
    fi
  done

  # Calculate inactivity
  if [ "$LAST_ACTIVITY_EPOCH" -eq 0 ]; then
    DIFF_DAYS=9999  # Never been active
  else
    DIFF_DAYS=$(( (TODAY - LAST_ACTIVITY_EPOCH) / 86400 ))
  fi

  if [ "$DIFF_DAYS" -gt "$THRESHOLD_DAYS" ]; then
    echo "🪄 Processing user: $USER (inactive for $DIFF_DAYS days)"

    # Detach managed policies
    for POLICY in $(aws iam list-attached-user-policies --user-name "$USER" --query 'AttachedPolicies[*].PolicyArn' --output text); do
      aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY"
    done

    # Delete inline policies
    for POLICY in $(aws iam list-user-policies --user-name "$USER" --query 'PolicyNames[*]' --output text); do
      aws iam delete-user-policy --user-name "$USER" --policy-name "$POLICY"
    done

    # Remove from groups
    for GROUP in $(aws iam list-groups-for-user --user-name "$USER" --query 'Groups[*].GroupName' --output text); do
      aws iam remove-user-from-group --user-name "$USER" --group-name "$GROUP"
    done

    # Delete access keys
    for KEY_ID in $(aws iam list-access-keys --user-name "$USER" --query 'AccessKeyMetadata[*].AccessKeyId' --output text); do
      aws iam delete-access-key --user-name "$USER" --access-key-id "$KEY_ID"
    done

    # Delete login profile (console password)
    aws iam delete-login-profile --user-name "$USER" 2>/dev/null

    # Delete MFA devices
    for MFA in $(aws iam list-mfa-devices --user-name "$USER" --query 'MFADevices[*].SerialNumber' --output text); do
      aws iam deactivate-mfa-device --user-name "$USER" --serial-number "$MFA"
      aws iam delete-virtual-mfa-device --serial-number "$MFA" 2>/dev/null
    done

    # Delete signing certificates
    for CERT in $(aws iam list-signing-certificates --user-name "$USER" --query 'Certificates[*].CertificateId' --output text); do
      aws iam delete-signing-certificate --user-name "$USER" --certificate-id "$CERT"
    done

    # Finally, delete the user
    aws iam delete-user --user-name "$USER"
    echo "✅ Deleted user: $USER"
  fi
done
