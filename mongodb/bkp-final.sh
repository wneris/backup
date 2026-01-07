#!/bin/bash
#######################################################################################
#
## v1 - 16/12/2025 - redirecionamento de logs para /var/log/mongodb_backup.log
## v2 - 17/12/2025 - criacao do arquivo de variável .env
## v3 - 18/12/2025 - correção para funcionar via cron (caminho absoluto do .env)
## v4 - 18/12/2025 - adicionado verificação de espaço em disco, integridade do backup e rotação de logs
#
#######################################################################################
#set +x

# --- 1. Configurações Essenciais ---

BACKUP_DIR_LOCAL="/backup/mongodb_temp"
BACKUP_DIR_REMOTO="/mnt/nfs/mongodb/daily/"
REMOTE_HOST="backup-server-ip"

MONGO_HOSTS="10.250.50.114:37017"
MONGODB_URI="mongodb://${MONGO_USER}:${MONGO_PASS}@${MONGO_HOSTS}/?authSource=${AUTH_DB}&replicaSet=${REPLICA_SET_NAME}&readPreference=secondary"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="mongodb_dump_$TIMESTAMP"
FINAL_FILE="$BACKUP_DIR_LOCAL/$BACKUP_NAME.tar"

RETENTION_DAYS=2
MIN_DISK_SPACE_GB=70  # Espaço mínimo necessário em GB
LOG_FILE="/var/log/mongodb_backup.log"
LOG_MAX_SIZE_MB=100   # Tamanho máximo do log em MB antes de rotacionar
LOG_BACKUP_COUNT=5    # Número de logs de backup a manter

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
# 2. Execução do Backup
# ----------------------------------------------------
echo "Criando diretório local temporário: $BACKUP_DIR_LOCAL"
mkdir -p "$BACKUP_DIR_LOCAL"

echo "Iniciando mongodump no nó Secundário..."
/usr/bin/mongodump  \
  --host "${RS_NAME}/${MONGO_HOSTS}" \
  --username "${MONGO_USER}" \
  --password "${MONGO_PASS}" \
  --authenticationDatabase "${AUTH_DB}" \
  --readPreference secondary \
  --gzip \
  --out "$BACKUP_DIR_LOCAL/$BACKUP_NAME"
  #--db "GARR_MONGO" \
  #--excludeCollection "logRoot" \
  #--out "$BACKUP_DIR_LOCAL/$BACKUP_NAME"


if [ $? -ne 0 ]; then
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
echo "Limpando backups locais antigos (+$RETENTION_DAYS dias)..."
find "$BACKUP_DIR_LOCAL" -type f \( -name "mongodb_dump_*.tar" -o -name "mongodb_dump_*.tar.enc" \) -mtime +$RETENTION_DAYS -print -delete
echo "[OK] Limpeza concluída."
echo "Fim do processo: $(date +'%Y-%m-%d %H:%M:%S')"
echo "----------------------------------------------------"

