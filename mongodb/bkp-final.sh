#!/bin/bash
#######################################################################################
#
## v1 - 16/12/2025 - redirecionamento de logs para /var/log/mongodb_backup.log
## v2 - 17/12/2025 - criacao do arquivo de variável .env
## v3 - 18/12/2025 - correção para funcionar via cron (caminho absoluto do .env)
## v4 - 18/12/2025 - adicionado verificação de espaço em disco, integridade do backup e rotação de logs
## v6 - 09/06/2026 - retenção local por quantidade: apenas os 2 arquivos .enc mais recentes
## v7 - 23/07/2026 - mongodump com conexão direta no nó de backup e --numParallelCollections=1
## v8 - 23/07/2026 - dump por collection com retry; collections grandes em lotes por _id (ObjectId)
## v9 - 23/07/2026 - aumenta retries/intervalo e NUM_CHUNKS para reduzir falha no fim dos lotes
#
#######################################################################################
#set +x

# --- 1. Configurações Essenciais ---

BACKUP_DIR_LOCAL="/backup/mongodb_temp"
BACKUP_DIR_REMOTO="/mnt/nfs/mongodb/daily/"
REMOTE_HOST="backup-server-ip"

MONGO_HOSTS="10.250.50.114:37017"
MONGO_BIN="${MONGO_BIN:-/usr/bin/mongo}"
MONGODUMP_BIN="${MONGODUMP_BIN:-/usr/bin/mongodump}"
MONGODB_URI="mongodb://${MONGO_USER}:${MONGO_PASS}@${MONGO_HOSTS}/?authSource=${AUTH_DB}&replicaSet=${REPLICA_SET_NAME}&readPreference=secondary"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="mongodb_dump_$TIMESTAMP"
FINAL_FILE="$BACKUP_DIR_LOCAL/$BACKUP_NAME.tar"

RETENTION_ENCRYPTED_COUNT=2  # Número de arquivos .tar.enc a manter localmente
MIN_DISK_SPACE_GB=70  # Espaço mínimo necessário em GB
LOG_FILE="/var/log/mongodb_backup.log"
LOG_MAX_SIZE_MB=100   # Tamanho máximo do log em MB antes de rotacionar
LOG_BACKUP_COUNT=5    # Número de logs de backup a manter

# Dump resiliente
DUMP_MAX_RETRIES="${DUMP_MAX_RETRIES:-15}"
DUMP_RETRY_SLEEP_SEC="${DUMP_RETRY_SLEEP_SEC:-120}"
CHUNKED_COLLECTIONS="${CHUNKED_COLLECTIONS:-loginAudit logRoot}"
CHUNK_DOC_THRESHOLD="${CHUNK_DOC_THRESHOLD:-10000000}"  # auto-chunk se estimated count >= este valor
NUM_CHUNKS="${NUM_CHUNKS:-96}"  # lotes por faixa temporal de ObjectId (mais lotes = faixas menores)
BACKUP_DATABASES="${BACKUP_DATABASES:-admin GARR_MONGO}"  # fallback se listDatabases falhar
# mongo shell antigo: --host e --port separados
MONGO_HOST_ONLY="${MONGO_HOSTS%%:*}"
MONGO_PORT_ONLY="${MONGO_HOSTS##*:}"
if [ "$MONGO_HOST_ONLY" = "$MONGO_HOSTS" ] || [ -z "$MONGO_PORT_ONLY" ]; then
  MONGO_PORT_ONLY="27017"
fi

# --- AWS ---
S3_BUCKET_NAME=backup-mongodb-superbid
S3_PATH=prd
S3_TARGET="s3://${S3_BUCKET_NAME}/${S3_PATH}/"
AWS_PROFILE=backup_mongodb

# Obter o diretório onde o script está localizado
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Carregar variáveis de ambiente do arquivo .env
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "[ERRO] Arquivo .env não encontrado em $ENV_FILE"
    exit 1
fi

# Validar se MONGODB_URI está definida
if [ -z "$MONGODB_URI" ]; then
    echo "[ERRO] Variável MONGODB_URI não está definida"
    exit 1
fi

# --- 0. Configurações de Log e Rotação ---
# Rotacionar log se exceder o tamanho máximo (antes do redirecionamento)
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

exec > >(tee -a "$LOG_FILE") 2>&1  # Redireciona STDOUT e STDERR para o arquivo e para o console

echo "----------------------------------------------------"
echo "Início do Backup: $(date +'%Y-%m-%d %H:%M:%S')"
echo "----------------------------------------------------"

# ----------------------------------------------------
# 1. Verificação de Espaço em Disco
# ----------------------------------------------------
echo "Verificando espaço em disco disponível..."
# Usar df com opção -BG (GNU) ou calcular manualmente
if df -BG "$BACKUP_DIR_LOCAL" >/dev/null 2>&1; then
    AVAILABLE_SPACE_GB=$(df -BG "$BACKUP_DIR_LOCAL" | awk 'NR==2 {print $4}' | sed 's/G//')
else
    # Fallback para sistemas sem -BG: obter em KB e converter
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
# Helpers de dump (retry + lotes por _id)
# ----------------------------------------------------
mongo_eval() {
  local js="$1"
  local raw err rc
  raw=$(mktemp)
  err=$(mktemp)

  # Shell antigo: --host e --port separados (não usar host:port).
  "$MONGO_BIN" --quiet \
    --host "${MONGO_HOST_ONLY}" \
    --port "${MONGO_PORT_ONLY}" \
    --username "${MONGO_USER}" \
    --password "${MONGO_PASS}" \
    --authenticationDatabase "${AUTH_DB}" \
    --eval "$js" >"$raw" 2>"$err"
  rc=$?

  grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$raw" | grep -vE '^[[:space:]]*$' || true

  if [ "$rc" -ne 0 ] && [ -s "$err" ]; then
    echo "[AVISO] mongo --eval exit=$rc; stderr:" >&2
    tail -n 15 "$err" >&2
  fi
  rm -f "$raw" "$err"
  return "$rc"
}

list_databases() {
  # Usuário de backup muitas vezes não tem listDatabases; usamos lista explícita.
  echo "[INFO] Databases do backup: ${BACKUP_DATABASES}" >&2
  echo "$BACKUP_DATABASES" | tr ' ' '\n' | grep -vE '^[[:space:]]*$'
}

list_collections() {
  local db_name="$1"
  local listed
  listed=$(mongo_eval "
    print('__COLL_START__');
    try {
      db.getSiblingDB('${db_name}').getCollectionNames().forEach(function(c) {
        if (c.indexOf('system.') === 0 && c !== 'system.users' && c !== 'system.roles' && c !== 'system.version') {
          return;
        }
        print(c);
      });
    } catch (e) {
      print('__COLL_ERROR__');
      print(e);
    }
    print('__COLL_END__');
  " | sed -n '/__COLL_START__/,/__COLL_END__/p' \
    | grep -vE '^__(COLL_START|COLL_END|COLL_ERROR)__$' \
    | grep -vE '@src/mongo' \
    | grep -vE '^[[:space:]]*$' \
    | grep -E '^[A-Za-z0-9._-]+$' || true)

  if [ -n "$listed" ]; then
    echo "$listed"
    return 0
  fi

  # Fallback: só as collections grandes conhecidas (serão dumpadas em lotes)
  echo "[AVISO] getCollectionNames falhou em ${db_name}; usando CHUNKED_COLLECTIONS" >&2
  echo "$CHUNKED_COLLECTIONS" | tr ' ' '\n' | grep -vE '^[[:space:]]*$'
}

retry_cmd() {
  local attempt=1
  local rc=0
  while [ "$attempt" -le "$DUMP_MAX_RETRIES" ]; do
    # Não usar `if cmd; then` — o exit code do if vira 0 e mascara a falha real.
    "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    if [ "$attempt" -ge "$DUMP_MAX_RETRIES" ]; then
      return "$rc"
    fi
    echo "[AVISO] Falha (exit $rc). Retry ${attempt}/${DUMP_MAX_RETRIES} em ${DUMP_RETRY_SLEEP_SEC}s..."
    sleep "$DUMP_RETRY_SLEEP_SEC"
    attempt=$((attempt + 1))
  done
  return "$rc"
}

should_chunk_collection() {
  local coll="$1"
  local count="$2"
  local c
  for c in $CHUNKED_COLLECTIONS; do
    if [ "$c" = "$coll" ]; then
      return 0
    fi
  done
  if [ -n "$count" ] && [ "$count" -ge "$CHUNK_DOC_THRESHOLD" ] 2>/dev/null; then
    return 0
  fi
  return 1
}

mongodump_collection() {
  local db_name="$1"
  local coll_name="$2"
  local out_dir="$3"
  shift 3
  # args extras: --query '...'
  "$MONGODUMP_BIN" \
    --host "${MONGO_HOSTS}" \
    --username "${MONGO_USER}" \
    --password "${MONGO_PASS}" \
    --authenticationDatabase "${AUTH_DB}" \
    --db "$db_name" \
    --collection "$coll_name" \
    --out "$out_dir" \
    "$@"
}

dump_collection_simple() {
  local db_name="$1"
  local coll_name="$2"
  local out_dir="$3"

  echo ">>> Dump: ${db_name}.${coll_name}"
  retry_cmd mongodump_collection "$db_name" "$coll_name" "$out_dir" --gzip
}

# Gera linhas: <epoch_start> <epoch_end_exclusive>
oid_time_chunks() {
  local db_name="$1"
  local coll_name="$2"
  mongo_eval "
    print('__CHUNK_START__');
    var coll = db.getSiblingDB('${db_name}').getCollection('${coll_name}');
    var minDoc = coll.find().sort({_id: 1}).limit(1).toArray()[0];
    var maxDoc = coll.find().sort({_id: -1}).limit(1).toArray()[0];
    if (!minDoc || !maxDoc || !minDoc._id || !minDoc._id.getTimestamp) {
      print('__CHUNK_END__');
      quit(0);
    }
    var t0 = Math.floor(minDoc._id.getTimestamp().getTime() / 1000);
    var t1 = Math.floor(maxDoc._id.getTimestamp().getTime() / 1000) + 1;
    var n = ${NUM_CHUNKS};
    var step = Math.max(1, Math.ceil((t1 - t0) / n));
    for (var t = t0; t < t1; t += step) {
      var end = t + step;
      if (end > t1) end = t1;
      print(t + ' ' + end);
    }
    print('__CHUNK_END__');
  " | sed -n '/__CHUNK_START__/,/__CHUNK_END__/p' | grep -E '^[0-9]+ [0-9]+$' || true
}

oid_hex_from_time() {
  # ObjectId.createFromTime equivalent: 4-byte time + 8 zero bytes
  printf '%08x0000000000000000' "$1"
}

dump_collection_chunked() {
  local db_name="$1"
  local coll_name="$2"
  local out_dir="$3"
  local chunk_tmp query start_hex end_hex start_ts end_ts chunk_idx chunk_out
  local bson_src metadata_src bson_dst metadata_dst
  local chunks_file

  echo ">>> Dump em lotes (_id/ObjectId): ${db_name}.${coll_name} (${NUM_CHUNKS} faixas alvo)"

  chunks_file=$(mktemp)
  if ! oid_time_chunks "$db_name" "$coll_name" > "$chunks_file"; then
    echo "[AVISO] Não foi possível calcular lotes por ObjectId para ${db_name}.${coll_name}. Fallback dump simples."
    rm -f "$chunks_file"
    dump_collection_simple "$db_name" "$coll_name" "$out_dir"
    return $?
  fi

  if [ ! -s "$chunks_file" ]; then
    echo "[AVISO] Collection vazia ou _id sem ObjectId: ${db_name}.${coll_name}. Fallback dump simples."
    rm -f "$chunks_file"
    dump_collection_simple "$db_name" "$coll_name" "$out_dir"
    return $?
  fi

  chunk_tmp=$(mktemp -d)
  mkdir -p "${out_dir}/${db_name}"
  bson_dst="${out_dir}/${db_name}/${coll_name}.bson"
  metadata_dst="${out_dir}/${db_name}/${coll_name}.metadata.json"
  rm -f "$bson_dst" "${bson_dst}.gz" "$metadata_dst"
  : > "$bson_dst"

  chunk_idx=0
  while read -r start_ts end_ts; do
    [ -z "$start_ts" ] && continue
    chunk_idx=$((chunk_idx + 1))
    start_hex=$(oid_hex_from_time "$start_ts")
    end_hex=$(oid_hex_from_time "$end_ts")
    query=$(printf '{"_id":{"$gte":{"$oid":"%s"},"$lt":{"$oid":"%s"}}}' "$start_hex" "$end_hex")
    chunk_out="${chunk_tmp}/chunk_${chunk_idx}"
    rm -rf "$chunk_out"
    mkdir -p "$chunk_out"

    echo "    lote ${chunk_idx}: _id >= ${start_hex} < ${end_hex}"
    if ! retry_cmd mongodump_collection "$db_name" "$coll_name" "$chunk_out" --query "$query"; then
      echo "[ERRO] Falha no lote ${chunk_idx} de ${db_name}.${coll_name}"
      rm -rf "$chunk_tmp" "$chunks_file"
      return 1
    fi

    bson_src="${chunk_out}/${db_name}/${coll_name}.bson"
    metadata_src="${chunk_out}/${db_name}/${coll_name}.metadata.json"

    if [ -f "$bson_src" ]; then
      cat "$bson_src" >> "$bson_dst"
    fi
    if [ -f "$metadata_src" ] && [ ! -f "$metadata_dst" ]; then
      cp "$metadata_src" "$metadata_dst"
    fi
    rm -rf "$chunk_out"
  done < "$chunks_file"

  rm -f "$chunks_file"
  rm -rf "$chunk_tmp"

  if [ -f "$bson_dst" ]; then
    gzip -f "$bson_dst"
  fi
  echo "[OK] Lotes concluídos: ${db_name}.${coll_name} (${chunk_idx} lotes)"
  return 0
}

mongodump_db() {
  local db_name="$1"
  local out_dir="$2"
  shift 2

  echo ">>> Dump DB: ${db_name} $*"
  retry_cmd "$MONGODUMP_BIN" \
    --host "${MONGO_HOSTS}" \
    --username "${MONGO_USER}" \
    --password "${MONGO_PASS}" \
    --authenticationDatabase "${AUTH_DB}" \
    --db "$db_name" \
    --numParallelCollections=1 \
    --gzip \
    --out "$out_dir" \
    "$@"
}

mongodump_db_excluding() {
  local db_name="$1"
  local out_dir="$2"
  shift 2
  local exclude_args=()
  local coll
  for coll in "$@"; do
    [ -n "$coll" ] || continue
    exclude_args+=(--excludeCollection "$coll")
  done
  mongodump_db "$db_name" "$out_dir" "${exclude_args[@]}"
}

dump_all_collections() {
  local out_dir="$1"
  local db_name coll_name
  local db_list

  db_list=$(list_databases)
  if [ -z "$db_list" ]; then
    echo "[ERRO] Não foi possível obter lista de databases."
    return 1
  fi
  echo "Databases: $(echo $db_list | tr '\n' ' ')"

  mkdir -p "$out_dir"

  for db_name in $db_list; do
    if [ "$db_name" = "admin" ]; then
      if ! mongodump_db "$db_name" "$out_dir"; then
        echo "[ERRO] Falha no dump de ${db_name}"
        return 1
      fi
      continue
    fi

    # App DB: dump normal excluindo collections gigantes, depois lotes nelas
    echo "[INFO] ${db_name}: dump base excluindo [${CHUNKED_COLLECTIONS}], depois lotes nas grandes"
    # shellcheck disable=SC2086
    if ! mongodump_db_excluding "$db_name" "$out_dir" $CHUNKED_COLLECTIONS; then
      echo "[ERRO] Falha no dump base de ${db_name}"
      return 1
    fi

    for coll_name in $CHUNKED_COLLECTIONS; do
      echo "Collection grande: ${db_name}.${coll_name}"
      if ! dump_collection_chunked "$db_name" "$coll_name" "$out_dir"; then
        return 1
      fi
    done
  done
  return 0
}

# ----------------------------------------------------
# 2. Execução do Backup
# ----------------------------------------------------
echo "Criando diretório local temporário: $BACKUP_DIR_LOCAL"
mkdir -p "$BACKUP_DIR_LOCAL"

echo "Iniciando dump resiliente (conexão direta, 1 collection por vez, retry=${DUMP_MAX_RETRIES}, lotes=${NUM_CHUNKS})..."
echo "Collections forçadas em lotes: ${CHUNKED_COLLECTIONS}"
echo "Auto-lote se count >= ${CHUNK_DOC_THRESHOLD}"

if ! dump_all_collections "$BACKUP_DIR_LOCAL/$BACKUP_NAME"; then
  echo "[ERRO] O mongodump falhou em $(date). Abortando script."
  exit 1
fi
echo "[OK] Backup concluído localmente."

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

# Verificar se o arquivo de senha existe
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

# Remover o arquivo original não criptografado após criptografia bem-sucedida
rm -f "$FINAL_FILE"
echo "[OK] Arquivo original removido após criptografia."

# ----------------------------------------------------
# 5. Tranferência para o S3
# ----------------------------------------------------
echo "Transferindo para o S3 em $S3_TARGET..."

# Usar o arquivo criptografado para upload
ENCRYPTED_FILE="$FINAL_FILE.enc"

# Calcular checksum MD5 do arquivo local antes do upload
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

# Obter informações do arquivo no S3
S3_FILE_INFO=$(/usr/local/bin/aws --region sa-east-1 s3api head-object --bucket "$S3_BUCKET_NAME" --key "${S3_PATH}/$(basename $ENCRYPTED_FILE)" 2>/dev/null)

if [ $? -ne 0 ]; then
  echo "[AVISO] Não foi possível verificar o arquivo no S3 (pode ser normal se o ETag não estiver disponível)"
else
  S3_FILE_SIZE=$(echo "$S3_FILE_INFO" | grep -o '"ContentLength": [0-9]*' | cut -d' ' -f2)
  S3_ETAG=$(echo "$S3_FILE_INFO" | grep -o '"ETag": "[^"]*"' | cut -d'"' -f4 | tr -d '"')
  
  echo "Tamanho do arquivo no S3: $(numfmt --to=iec-i --suffix=B $S3_FILE_SIZE 2>/dev/null || echo "${S3_FILE_SIZE} bytes")"
  
  # Comparar tamanhos
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

# Remover subpastas e arquivos .tar órfãos (mantém apenas .enc)
find "$BACKUP_DIR_LOCAL" -maxdepth 1 -type d -name "mongodb_dump_*" -print -exec rm -rf {} +
find "$BACKUP_DIR_LOCAL" -maxdepth 1 -type f -name "mongodb_dump_*.tar" -print -delete

# Manter apenas os últimos N arquivos criptografados
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

