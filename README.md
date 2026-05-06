# chia-db-pull

A container and shell script that pre-seeds a [Chia](https://www.chia.net/) full node's blockchain database from an S3 bucket. It is intended to run before a Chia full_node starts so the node can resume from a recent snapshot instead of syncing from genesis.

## Behavior

On startup, `entrypoint.sh`:

1. Checks for an existing blockchain SQLite DB at `${CHIA_ROOT}/db/blockchain_v2_${NETWORK}.sqlite`.
2. If the DB exists, queries the maximum block height in the main chain.
   - If the local height is `>= MIN_HEIGHT`, exits successfully without doing anything.
   - If the local height is below `MIN_HEIGHT`, treats the DB as stale and re-downloads.
3. If the DB is missing or stale, removes any existing DB and cache files, then downloads from S3:
   - `blockchain_v2_${NETWORK}.sqlite` → main blockchain DB
   - `height-to-hash` → height-to-hash cache
   - `sub-epoch-summaries` → sub-epoch summaries cache

The cache files are downloaded best-effort. If a cache download fails, the container logs a warning and continues; the Chia node will regenerate them on first run.

## Configuration

Configuration is via environment variables.

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `S3_PREFIX` | yes | — | S3 URI prefix containing the DB and cache files (e.g. `s3://my-bucket/chia/mainnet`). |
| `NETWORK` | no | `mainnet` | Chia network name. Used in the DB filename and cache suffix. |
| `CHIA_ROOT` | no | `$HOME/.chia/mainnet` | Chia root directory. The DB is written under `${CHIA_ROOT}/db`. |
| `MIN_HEIGHT` | no | `2000` | Minimum local block height considered "fresh enough". Below this, the DB is re-downloaded. |

AWS credentials must be available to the AWS CLI in the usual ways (env vars, instance/IRSA role, mounted credentials file, etc.). The S3 bucket must contain the following objects under `S3_PREFIX`:

- `${S3_PREFIX}/blockchain_v2_${NETWORK}.sqlite`
- `${S3_PREFIX}/height-to-hash`
- `${S3_PREFIX}/sub-epoch-summaries`
