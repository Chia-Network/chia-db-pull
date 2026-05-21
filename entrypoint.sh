#!/bin/sh
set -e

NETWORK="${NETWORK:-mainnet}"
CHIA_ROOT="${CHIA_ROOT:-$HOME/.chia/mainnet}"
MIN_HEIGHT="${MIN_HEIGHT:-2000}"

if [ -z "$S3_PREFIX" ]; then
    echo "ERROR: S3_PREFIX is not set"
    exit 1
fi

while [ "${S3_PREFIX%/}" != "$S3_PREFIX" ]; do
    S3_PREFIX="${S3_PREFIX%/}"
done

# Optional role chaining: if AWS_ASSUME_ROLE_ARN is set, the script's S3
# calls will run as that role. This requires the standard AWS Web Identity
# env vars (AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE) to be present;
# common sources are EKS IRSA, GitHub Actions OIDC, and other
# AssumeRoleWithWebIdentity setups. The Web Identity role must be permitted
# to sts:AssumeRole into AWS_ASSUME_ROLE_ARN, and the latter's trust policy
# must allow the Web Identity role as a principal.
if [ -n "$AWS_ASSUME_ROLE_ARN" ]; then
    if [ -z "$AWS_ROLE_ARN" ] || [ -z "$AWS_WEB_IDENTITY_TOKEN_FILE" ]; then
        echo "ERROR: AWS_ASSUME_ROLE_ARN is set but the AWS Web Identity" \
             "env vars (AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE) are not" \
             "present"
        exit 1
    fi

    echo "Configuring AWS profile to chain Web Identity role into ${AWS_ASSUME_ROLE_ARN}"

    AWS_CONFIG_FILE="$(mktemp)"
    export AWS_CONFIG_FILE
    cat > "$AWS_CONFIG_FILE" <<EOF
[profile chia-db-pull]
role_arn = ${AWS_ASSUME_ROLE_ARN}
source_profile = chia-db-pull-source
role_session_name = chia-db-pull

[profile chia-db-pull-source]
web_identity_token_file = ${AWS_WEB_IDENTITY_TOKEN_FILE}
role_arn = ${AWS_ROLE_ARN}
role_session_name = chia-db-pull-source
EOF

    # Unset the Web Identity env vars so the SDK uses the profile config we
    # just wrote (env-var credentials win over profile config otherwise).
    unset AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_SESSION_NAME
    export AWS_PROFILE=chia-db-pull
fi

DB_DIR="${CHIA_ROOT}/db"
DB_FILE="blockchain_v2_${NETWORK}.sqlite"
DB_PATH="${DB_DIR}/${DB_FILE}"

if [ "$NETWORK" = "mainnet" ]; then
    CACHE_SUFFIX=""
else
    CACHE_SUFFIX="-${NETWORK}"
fi

get_local_height() {
    local_height=$(sqlite3 "$DB_PATH" "SELECT MAX(height) FROM full_blocks where in_main_chain=1;" 2>/dev/null || echo "")

    if [ -z "$local_height" ]; then
        echo "0"
        return
    fi

    echo "$local_height"
}

delete_db_files() {
    echo "Removing existing DB and cache files..."
    rm -f "$DB_PATH" "${DB_PATH}-shm" "${DB_PATH}-wal"
    rm -f "${DB_DIR}/height-to-hash" "${DB_DIR}/height-to-hash${CACHE_SUFFIX}"
    rm -f "${DB_DIR}/sub-epoch-summaries" "${DB_DIR}/sub-epoch-summaries${CACHE_SUFFIX}"
}

download_cache_files() {
    mkdir -p "$DB_DIR"

    echo "Downloading cache files from S3..."
    aws s3 cp "${S3_PREFIX}/height-to-hash" "${DB_DIR}/height-to-hash${CACHE_SUFFIX}" || \
        echo "WARNING: Failed to download height-to-hash, node will regenerate it"
    aws s3 cp "${S3_PREFIX}/sub-epoch-summaries" "${DB_DIR}/sub-epoch-summaries${CACHE_SUFFIX}" || \
        echo "WARNING: Failed to download sub-epoch-summaries, node will regenerate it"
}

download_db() {
    mkdir -p "$DB_DIR"

    echo "Downloading blockchain DB from S3..."
    aws s3 cp "${S3_PREFIX}/${DB_FILE}" "$DB_PATH"
}

echo "=== Chia DB Pull ==="
echo "Network:    ${NETWORK}"
echo "CHIA_ROOT:  ${CHIA_ROOT}"
echo "DB path:    ${DB_PATH}"
echo "S3 prefix:  ${S3_PREFIX}"
echo "Min height: ${MIN_HEIGHT}"
echo ""

if [ -f "$DB_PATH" ]; then
    echo "Found existing DB at ${DB_PATH}"

    local_height=$(get_local_height)
    echo "Local block height: ${local_height}"

    if [ "$local_height" -ge "$MIN_HEIGHT" ]; then
        echo "Local DB has sufficient blocks (${local_height} >= ${MIN_HEIGHT}), no action needed"
        echo "Done"
        exit 0
    fi

    echo "Local height ${local_height} is below minimum ${MIN_HEIGHT}, re-downloading..."
else
    echo "No existing DB found at ${DB_PATH}"
fi

delete_db_files
download_cache_files
download_db
echo "Done"
