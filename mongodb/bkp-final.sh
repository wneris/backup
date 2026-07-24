#!/bin/bash
#######################################################################################
#
## v1 - 16/12/2025 - redirecionamento de logs para /var/log/mongodb_backup.log
## v2 - 17/12/2025 - criacao do arquivo de variável .env
## v3 - 18/12/2025 - correção para funcionar via cron (caminho absoluto do .env)
## v4 - 18/12/2025 - adicionado verificação de espaço em disco, integridade do backup e rotação de logs
## v6 - 09/06/2026 - retenção local por quantidade: apenas os 2 arquivos .enc mais recentes
## v7 - 23/07/2026 - mongodump com conexão direta no nó de backup e --numParallelCollections=1
## v8 - 23/07/2026 - tentativa: lotes por ObjectId (revertido na v10)
## v9 - 23/07/2026 - tentativa: mais retries/lotes (revertido na v10)
## v10 - 23/07/2026 - dump simples neste nó SECONDARY dedicado (estilo legado, sem rs.status em outros nós)
#
#######################################################################################
#set +x

# --- 1. Configurações Essenciais ---
# Este script RODA no nó dedicado de backup (SECONDARY hidden, priority 0).
# O mongodump lê LOCALMENTE este nó (MONGO_HOSTS), sem descobrir outros SECONDARY do RS.

BACKUP_DIR_LOCAL="/backup/mongodb_temp"
BACKUP_DIR_REMOTO="/mnt/nfs/mongodb/daily/"
REMOTE_HOST="backup-server-ip"

# Host/porta do mongod NESTE nó de backup
MONGO_HOSTS="10.250.50.114:37017"
MONGO_BIN="${MONGO_BIN:-/usr/bin/mongo}"
MONGODUMP_BIN="${MONGODUMP_BIN:-/usr/bin/mongodump}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="mongodb_dump_$TIMESTAMP"
FINAL_FILE="$BACKUP_DIR_LOCAL/$BACKUP_NAME.tar"

RETENTION_ENCRYPTED_COUNT=2
MIN_DISK_SPACE_GB=70
LOG_FILE="/var/log/mongodb_backup.log"
LOG_MAX_SIZE_MB=100
LOG_BACKUP_COUNT=5

# Dump simples (padrão do script legado que funciona), neste nó
DUMP_MAX_RETRIES="${DUMP_MAX_RETRIES:-3}"
DUMP_RETRY_SLEEP_SEC="${DUMP_RETRY_SLEEP_SEC:-60}"
BACKUP_DB="${BACKUP_DB:-GARR_MONGO}"

# --- AWS ---
S3_BUCKET_NAME=backup-mongodb-superbid
S3_PATH=prd
S3_TARGET="s3://${S3_BUCKET_NAME}/${S3_PATH}/"
AWS_PROFILE=backup_mongodb

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "[ERRO] Arquivo .env não encontrado em $ENV_FILE"
    exit 1
fi

# Defaults após .env
DUMP_MAX_RETRIES="${DUMP_MAX_RETRIES:-3}"
DUMP_RETRY_SLEEP_SEC="${DUMP_RETRY_SLEEP_SEC:-60}"
BACKUP_DB="${BACKUP_DB:-GARR_MONGO}"
MONGO_BIN="${MONGO_BIN:-/usr/bin/mongo}"
MONGODUMP_BIN="${MONGODUMP_BIN:-/usr/bin/mongodump}"
MONGO_HOSTS="${MONGO_HOSTS:-10.250.50.114:37017}"

# Shell/mongodump antigos: --host e --port separados
MONGO_HOST_ONLY="${MONGO_HOSTS%%:*}"
MONGO_PORT_ONLY="${MONGO_HOSTS##*:}"
if [ "$MONGO_HOST_ONLY" = "$MONGO_HOSTS" ] || [ -z "$MONGO_PORT_ONLY" ]; then
  MONGO_PORT_ONLY="37017"
fi

# URI só para validação legada
MONGODB_URI="mongodb://${MONGO_USER}:${MONGO_PASS}@${MONGO_HOSTS}/?authSource=${AUTH_DB}"

if [ -z "$MONGODB_URI" ]; then
    echo "[ERRO] Variável MONGODB_URI não está definida"
    exit 1
fi

# --- 0. Configurações de Log e Rotação ---
if [ -f "$LOG_FILE" ]; then
    LOG_SIZE_MB=$(du -m "$LOG_FILE" 2>/dev/null | cut -f1)
    if [ -n "$LOG_SIZE_MB" ] && [ "$LOG_SIZE_MB" -gt "$LOG_MAX_SIZE_MB" ]; then
        for i in $(seq $((LOG_BACKUP_COUNT-1)) -1 1); do
            if [ -f "${LOG_FILE}.${i}" ]; then
                mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
            fi
        done
        mv "$LOG_FILE" "${LOG_FILE}.1"
        touch "$LOG_FILE"
    fi
fi

exec > >(tee -a "$LOG_FILE") 2>&1

echo "----------------------------------------------------"
echo "Início do Backup: $(date +'%Y-%m-%d %H:%M:%S')"
echo "----------------------------------------------------"

# ----------------------------------------------------
# 1. Verificação de Espaço em Disco
# ----------------------------------------------------
echo "Verificando espaço em disco disponível..."
if df -BG "$BACKUP_DIR_LOCAL" >/dev/null 2>&1; then
    AVAILABLE_SPACE_GB=$(df -BG "$BACKUP_DIR_LOCAL" | awk 'NR==2 {print $4}' | sed 's/G//')
else
    AVAILABLE_SPACE_KB=$(df -k "$BACKUP_DIR_LOCAL" | awk 'NR==2 {print $4}')
    AVAILABLE_SPACE_GB=$((AVAILABLE_SPACE_KB / 1024 / 1024))
fi

if [ -z "$AVAILABLE_SPACE_GB" ] || [ "$AVAILABLE_SPACE_GB" -lt "$MIN_DISK_SPACE_GB" ]; then
    echo "[ERRO] Espaço em disco insuficiente!"
    echo "   Espaço disponível: ${AVAILABLE_SPACE_GB}GB"
    echo "   Espaço mínimo necessário: ${MIN_DISK_SPACE_GB}GB"
    echo "   Abortando backup em $(date)."
    exit 1
fi
echo "[OK] Espaço em disco suficiente: ${AVAILABLE_SPACE_GB}GB disponível (mínimo: ${MIN_DISK_SPACE_GB}GB)"

# ----------------------------------------------------
# Helpers de dump (neste nó SECONDARY dedicado)
# ----------------------------------------------------
# #region agent log
DEBUG_LOG_FILE="${DEBUG_LOG_FILE:-$SCRIPT_DIR/.cursor/debug-d794e2.log}"
DEBUG_LOG_FILE_ALT="/tmp/mongodb_backup_debug-d794e2.log"
mkdir -p "$(dirname "$DEBUG_LOG_FILE")" 2>/dev/null || true
agent_debug_log() {
  local hypothesis_id="$1"
  local location="$2"
  local message="$3"
  local data_json="${4:-{}}"
  local ts
  ts=$(date +%s%3N 2>/dev/null || date +%s000)
  local line
  line=$(printf '{"sessionId":"d794e2","hypothesisId":"%s","location":"%s","message":"%s","data":%s,"timestamp":%s,"runId":"post-fix"}\n' \
    "$hypothesis_id" "$location" "$message" "$data_json" "$ts")
  printf '%s' "$line" >> "$DEBUG_LOG_FILE" 2>/dev/null || true
  printf '%s' "$line" >> "$DEBUG_LOG_FILE_ALT" 2>/dev/null || true
  echo "[DEBUG-AGENT] H=${hypothesis_id} ${location}: ${message} ${data_json}"
}
# #endregion

retry_cmd() {
  local attempt=1
  local rc=0
  local t0 t1 elapsed
  while [ "$attempt" -le "$DUMP_MAX_RETRIES" ]; do
    t0=$(date +%s)
    "$@"
    rc=$?
    t1=$(date +%s)
    elapsed=$((t1 - t0))
    if [ "$rc" -eq 0 ]; then
      # #region agent log
      agent_debug_log "H" "retry_cmd" "ok" "{\"attempt\":${attempt},\"elapsedSec\":${elapsed}}"
      # #endregion
      return 0
    fi
    # #region agent log
    agent_debug_log "H" "retry_cmd" "attempt_failed" "{\"attempt\":${attempt},\"maxRetries\":${DUMP_MAX_RETRIES},\"exitCode\":${rc},\"elapsedSec\":${elapsed}}"
    # #endregion
    if [ "$attempt" -ge "$DUMP_MAX_RETRIES" ]; then
      return "$rc"
    fi
    echo "[AVISO] Falha (exit $rc). Retry ${attempt}/${DUMP_MAX_RETRIES} em ${DUMP_RETRY_SLEEP_SEC}s..."
    sleep "$DUMP_RETRY_SLEEP_SEC"
    attempt=$((attempt + 1))
  done
  return "$rc"
}

# Dump simples neste nó (estilo legado): --host/--port/--db/--gzip
run_mongodump_local_secondary() {
  local out_dir="$1"
  local t0 t1 elapsed rc ping_ok

  echo "Nó de backup (SECONDARY dedicado): ${MONGO_HOST_ONLY}:${MONGO_PORT_ONLY}"
  echo ">>> mongodump --host ${MONGO_HOST_ONLY} --port ${MONGO_PORT_ONLY} --db ${BACKUP_DB} --gzip"
  # #region agent log
  agent_debug_log "H" "run_mongodump" "start" "{\"host\":\"${MONGO_HOST_ONLY}\",\"port\":\"${MONGO_PORT_ONLY}\",\"db\":\"${BACKUP_DB}\",\"mode\":\"local_dedicated_secondary\"}"
  # #endregion

  mkdir -p "$out_dir"
  t0=$(date +%s)
  retry_cmd "$MONGODUMP_BIN" \
    --host "${MONGO_HOST_ONLY}" \
    --port "${MONGO_PORT_ONLY}" \
    --db "${BACKUP_DB}" \
    --username "${MONGO_USER}" \
    --password "${MONGO_PASS}" \
    --authenticationDatabase "${AUTH_DB}" \
    --excludeCollection "system.users" \
    --gzip \
    --out "$out_dir"
  rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))

  if [ "$rc" -ne 0 ]; then
    ping_ok=$("$MONGO_BIN" --quiet \
      --host "${MONGO_HOST_ONLY}" \
      --port "${MONGO_PORT_ONLY}" \
      -u "${MONGO_USER}" \
      -p "${MONGO_PASS}" \
      --authenticationDatabase "${AUTH_DB}" \
      --eval 'print("PING="+db.runCommand({ping:1}).ok)' 2>/dev/null | grep -E '^PING=' | tail -1)
    # #region agent log
    agent_debug_log "A" "run_mongodump" "failed_probe" "{\"host\":\"${MONGO_HOST_ONLY}\",\"port\":\"${MONGO_PORT_ONLY}\",\"elapsedSec\":${elapsed},\"exitCode\":${rc},\"ping\":\"${ping_ok:-none}\"}"
    agent_debug_log "H" "run_mongodump" "failed" "{\"elapsedSec\":${elapsed},\"exitCode\":${rc}}"
    # #endregion
    return "$rc"
  fi

  # #region agent log
  agent_debug_log "H" "run_mongodump" "ok" "{\"host\":\"${MONGO_HOST_ONLY}\",\"port\":\"${MONGO_PORT_ONLY}\",\"elapsedSec\":${elapsed}}"
  # #endregion
  return 0
}

# ----------------------------------------------------
# 2. Execução do Backup
# ----------------------------------------------------
echo "Criando diretório local temporário: $BACKUP_DIR_LOCAL"
mkdir -p "$BACKUP_DIR_LOCAL"

echo "Iniciando dump neste nó SECONDARY dedicado (estilo legado)..."
echo "Target: ${MONGO_HOST_ONLY}:${MONGO_PORT_ONLY} db=${BACKUP_DB}"
# #region agent log
agent_debug_log "H" "main" "dump_start" "{\"db\":\"${BACKUP_DB}\",\"retries\":${DUMP_MAX_RETRIES},\"host\":\"${MONGO_HOST_ONLY}\",\"port\":\"${MONGO_PORT_ONLY}\"}"
echo "[DEBUG-AGENT] debug log files: ${DEBUG_LOG_FILE} and ${DEBUG_LOG_FILE_ALT}"
# #endregion

if ! run_mongodump_local_secondary "$BACKUP_DIR_LOCAL/$BACKUP_NAME"; then
  # #region agent log
  agent_debug_log "H" "main" "dump_aborted" "{\"when\":\"$(date -Iseconds 2>/dev/null || date)\"}"
  # #endregion
  echo "[ERRO] O mongodump falhou em $(date). Abortando script."
  echo "[DEBUG-AGENT] Copie /tmp/mongodb_backup_debug-d794e2.log para o workspace .cursor/debug-d794e2.log"
  exit 1
fi
echo "[OK] Backup concluído localmente."
# #region agent log
agent_debug_log "H" "main" "dump_ok" "{}"
# #endregion

# ----------------------------------------------------
# 3. Compactação
# ----------------------------------------------------
echo "Compactando backup..."
tar -cf "$FINAL_FILE" -C "$BACKUP_DIR_LOCAL" "$BACKUP_NAME"
rm -rf "$BACKUP_DIR_LOCAL/$BACKUP_NAME"

if [ $? -ne 0 ]; then
  echo "[ERRO] Falha na compactação em $(date). Abortando script."
  exit 1
fi
echo "[OK] Compactação concluída: $FINAL_FILE"

# ----------------------------------------------------
# 4. Criptografia do backup
# ----------------------------------------------------

echo "Criptografando backup..."
PASS_FILE="$SCRIPT_DIR/.openssl_pass"

if [ ! -f "$PASS_FILE" ]; then
  echo "[ERRO] Arquivo de senha não encontrado: $PASS_FILE"
  exit 1
fi

openssl enc -aes-256-cbc -salt -in "$FINAL_FILE" -out "$FINAL_FILE.enc" --pass file:"$PASS_FILE"

if [ $? -ne 0 ]; then
  echo "[ERRO] Falha na criptografia em $(date). Abortando script."
  exit 1
fi
echo "[OK] Criptografia concluída: $FINAL_FILE.enc"

rm -f "$FINAL_FILE"
echo "[OK] Arquivo original removido após criptografia."

# ----------------------------------------------------
# 5. Tranferência para o S3
# ----------------------------------------------------
echo "Transferindo para o S3 em $S3_TARGET..."

ENCRYPTED_FILE="$FINAL_FILE.enc"

LOCAL_FILE_SIZE=$(stat -f%z "$ENCRYPTED_FILE" 2>/dev/null || stat -c%s "$ENCRYPTED_FILE" 2>/dev/null)
LOCAL_MD5=$(md5sum "$ENCRYPTED_FILE" | cut -d' ' -f1)
echo "Tamanho do arquivo local: $(numfmt --to=iec-i --suffix=B $LOCAL_FILE_SIZE 2>/dev/null || echo "${LOCAL_FILE_SIZE} bytes")"
echo "MD5 local: $LOCAL_MD5"

/usr/local/bin/aws --region sa-east-1 s3 cp "$ENCRYPTED_FILE" "$S3_TARGET"

if [ $? -ne 0 ]; then
  echo "[ERRO] Falha no upload para o S3 em $(date)."
  exit 1
fi

echo "[OK] Upload para o S3 concluído com sucesso."

# ----------------------------------------------------
# 5.1. Verificação de Integridade do Backup no S3
# ----------------------------------------------------
echo "Verificando integridade do backup no S3..."
S3_FILE_PATH="${S3_TARGET}$(basename $ENCRYPTED_FILE)"

S3_FILE_INFO=$(/usr/local/bin/aws --region sa-east-1 s3api head-object --bucket "$S3_BUCKET_NAME" --key "${S3_PATH}/$(basename $ENCRYPTED_FILE)" 2>/dev/null)

if [ $? -ne 0 ]; then
  echo "[AVISO] Não foi possível verificar o arquivo no S3 (pode ser normal se o ETag não estiver disponível)"
else
  S3_FILE_SIZE=$(echo "$S3_FILE_INFO" | grep -o '"ContentLength": [0-9]*' | cut -d' ' -f2)
  S3_ETAG=$(echo "$S3_FILE_INFO" | grep -o '"ETag": "[^"]*"' | cut -d'"' -f4 | tr -d '"')

  echo "Tamanho do arquivo no S3: $(numfmt --to=iec-i --suffix=B $S3_FILE_SIZE 2>/dev/null || echo "${S3_FILE_SIZE} bytes")"

  if [ "$LOCAL_FILE_SIZE" -eq "$S3_FILE_SIZE" ]; then
    echo "[OK] Verificação de integridade: Tamanhos coincidem (${LOCAL_FILE_SIZE} bytes)"
  else
    echo "[ERRO] Tamanhos não coincidem!"
    echo "   Local: ${LOCAL_FILE_SIZE} bytes"
    echo "   S3: ${S3_FILE_SIZE} bytes"
    exit 1
  fi
fi

# ----------------------------------------------------
# 6. Limpeza local
# ----------------------------------------------------
echo "Limpando backups locais antigos (mantendo $RETENTION_ENCRYPTED_COUNT arquivos .enc)..."

find "$BACKUP_DIR_LOCAL" -maxdepth 1 -type d -name "mongodb_dump_*" -print -exec rm -rf {} +
find "$BACKUP_DIR_LOCAL" -maxdepth 1 -type f -name "mongodb_dump_*.tar" -print -delete

shopt -s nullglob
ENC_FILES=("$BACKUP_DIR_LOCAL"/mongodb_dump_*.tar.enc)
if [ ${#ENC_FILES[@]} -gt "$RETENTION_ENCRYPTED_COUNT" ]; then
  mapfile -t OLD_ENC_FILES < <(ls -t "${ENC_FILES[@]}" | tail -n +$((RETENTION_ENCRYPTED_COUNT + 1)))
  for f in "${OLD_ENC_FILES[@]}"; do
    echo "Removendo backup criptografado antigo: $f"
    rm -f "$f"
  done
fi
shopt -u nullglob

echo "[OK] Limpeza concluída."
echo "Fim do processo: $(date +'%Y-%m-%d %H:%M:%S')"
echo "----------------------------------------------------"
