# Documentação - Rotina de Backup MongoDB

## Visão Geral

Este documento descreve o funcionamento da rotina de backup automatizada do MongoDB, implementada pelo script `bkp-final.sh`. A rotina realiza backups completos do banco de dados MongoDB, compacta e criptografa os arquivos e os envia para o Amazon S3.

## Arquivos Envolvidos

- **`bkp-final.sh`**: Script principal de backup
- **`.env`**: Arquivo de configuração com credenciais e variáveis sensíveis
- **`.openssl_pass`**: Arquivo com a senha de criptografia

## Arquitetura do Cluster MongoDB

### Nó Dedicado de Backup

Foi adicionado um nó específico ao cluster MongoDB exclusivamente para realizar backups:

- **Hostname**: `mongodb-backup.s4bdigital.net`
- **IP**: `10.250.50.114`
- **Porta**: `37017`
- **Função**: Nó secundário dedicado exclusivamente para backups

### Configuração do Nó no Replica Set

O nó foi adicionado ao cluster com as seguintes características:

```javascript
rs.add({
  host: "mongodb-backup.s4bdigital.net:37017", 
  priority: 0,      // Prioridade zero - nunca será eleito como primário
  hidden: true,     // Nó oculto - não aparece nas queries normais
  votes: 0          // Sem direito a voto - não participa da eleição de primário
})
```

**Características Importantes**:
- **`priority: 0`**: Garante que este nó nunca será promovido a primário, mantendo-o sempre como secundário
- **`hidden: true`**: O nó fica oculto para aplicações cliente, não recebendo tráfego de leitura normal
- **`votes: 0`**: O nó não participa das eleições de primário, evitando impacto na disponibilidade do cluster

Esta configuração garante que o nó de backup não interfira na operação normal do cluster e sempre esteja disponível para realizar backups sem impacto na performance.

## Versões

- **v1** (16/12/2025): Redirecionamento de logs para `/var/log/mongodb_backup.log`
- **v2** (17/12/2025): Criação do arquivo de variável `.env`
- **v3** (18/12/2025): Correção para funcionar via cron (caminho absoluto do `.env`)
- **v4** (18/12/2025): Adicionado verificação de espaço em disco, verificação de integridade do backup e rotação de logs
- **v5** (05/01/2025): Adicionado criptografia AES-256-CBC dos backups antes do upload ao S3

## Configurações

### Variáveis do Script (`bkp-final.sh`)

#### Diretórios
- **`BACKUP_DIR_LOCAL`**: `/backup/mongodb_temp` - Diretório local temporário para armazenar backups
- **`BACKUP_DIR_REMOTO`**: `/mnt/nfs/mongodb/daily/` - Diretório remoto (NFS) para backups diários
- **`REMOTE_HOST`**: `backup-server-ip` - Host do servidor de backup

#### MongoDB
- **`MONGO_HOSTS`**: `10.250.50.114:37017` - Host e porta do MongoDB
- **`MONGODB_URI`**: URI de conexão construída dinamicamente usando variáveis do `.env`

#### Retenção
- **`RETENTION_DAYS`**: `2` - Número de dias para manter backups locais antes de excluir
- **Retenção S3**: `7 dias` - Configurado diretamente no bucket S3 (não configurável via script)

#### Verificações e Logs
- **`MIN_DISK_SPACE_GB`**: `70` - Espaço mínimo em disco necessário (em GB) antes de iniciar o backup
- **`LOG_FILE`**: `/var/log/mongodb_backup.log` - Caminho do arquivo de log
- **`LOG_MAX_SIZE_MB`**: `100` - Tamanho máximo do arquivo de log em MB antes de rotacionar
- **`LOG_BACKUP_COUNT`**: `5` - Número de arquivos de log de backup a manter após rotação

#### Criptografia
- **`PASS_FILE`**: `/.openssl_pass` - Arquivo contendo a senha para criptografia OpenSSL (deve ter permissões restritas: chmod 600)

#### AWS S3
- **`S3_BUCKET_NAME`**: `backup-mongodb-superbid` - Nome do bucket S3
- **`S3_PATH`**: `prd` - Caminho dentro do bucket
- **`S3_TARGET`**: `s3://backup-mongodb-superbid/prd/` - Caminho completo de destino
- **`AWS_PROFILE`**: `backup_mongodb` - Perfil AWS a ser utilizado
- **`AWS_REGION`**: `sa-east-1` - Região AWS (São Paulo)

### Variáveis do Arquivo `.env`

O arquivo `.env` contém as credenciais e configurações sensíveis:

```bash
MONGO_USER="<user_backup>"              # Usuário do MongoDB
MONGO_PASS="<passord>"        # Senha do MongoDB
AUTH_DB="admin"                      # Banco de autenticação
REPLICA_SET_NAME="rsGARR"            # Nome do Replica Set

export AWS_ACCESS_KEY_ID="..."       # Chave de acesso AWS
export AWS_SECRET_ACCESS_KEY="..."   # Chave secreta AWS
```

**⚠️ IMPORTANTE**: O arquivo `.env` contém informações sensíveis e não deve ser versionado ou compartilhado.

## Fluxo de Execução

### 1. Inicialização e Validação

1. O script determina seu próprio diretório para localizar o arquivo `.env`
2. Carrega as variáveis de ambiente do arquivo `.env`
3. Valida se o arquivo `.env` existe
4. Valida se a variável `MONGODB_URI` está definida
5. **Rotaciona logs** se o arquivo de log exceder 100MB (mantém os últimos 5 arquivos)
6. Configura o redirecionamento de logs para `/var/log/mongodb_backup.log`
7. **Verifica espaço em disco disponível** - Aborta se houver menos de 50GB disponíveis

### 2. Execução do Backup (`mongodump`)

O script executa o `mongodump` com as seguintes características:

- **Host**: Conecta ao Replica Set usando o formato `${RS_NAME}/${MONGO_HOSTS}` (nó dedicado: `mongodb-backup.s4bdigital.net:37017`)
- **Autenticação**: Utiliza as credenciais do arquivo `.env`
- **Read Preference**: `secondary` - Lê do nó secundário dedicado para não impactar o primário
- **Compactação**: `--gzip` - Comprime os dados durante o dump
- **Saída**: Salva em `$BACKUP_DIR_LOCAL/$BACKUP_NAME`

**Nome do Backup**: `mongodb_dump_YYYYMMDD_HHMMSS` (timestamp)

**Nota**: O backup é realizado no nó dedicado `mongodb-backup`, que está configurado como secundário oculto e sem prioridade, garantindo que sempre esteja disponível para backups sem interferir na operação do cluster.

### 3. Compactação

Após o dump, o script compacta o diretório de backup em um arquivo tar:

- **Comando**: `tar -cf "$FINAL_FILE" -C "$BACKUP_DIR_LOCAL" "$BACKUP_NAME"`
- **Arquivo final**: `mongodb_dump_YYYYMMDD_HHMMSS.tar`
- **Localização**: `$BACKUP_DIR_LOCAL`

### 4. Criptografia

O backup compactado é criptografado antes do upload:

- **Algoritmo**: AES-256-CBC (Advanced Encryption Standard com chave de 256 bits)
- **Comando**: `openssl enc -aes-256-cbc -salt -in "$FINAL_FILE" -out "$FINAL_FILE.enc" --pass file:"$PASS_FILE"`
- **Arquivo de senha**: `$SCRIPT_DIR/.openssl_pass` - Arquivo contendo a senha de criptografia
- **Arquivo criptografado**: `mongodb_dump_YYYYMMDD_HHMMSS.tar.enc`
- **Validação**: Verifica se o arquivo de senha existe antes de criptografar
- **Limpeza**: Remove o arquivo original `.tar` após criptografia bem-sucedida (mantém apenas o `.enc`)

**⚠️ IMPORTANTE**: O arquivo `$SCRIPT_DIR/.openssl_pass` deve ter permissões restritas (chmod 600) e conter apenas a senha de criptografia.

### 5. Upload para Amazon S3

O backup criptografado é enviado para o S3:

- **Comando**: `aws s3 cp "$ENCRYPTED_FILE" "$S3_TARGET"`
- **Região**: `sa-east-1` (São Paulo)
- **Destino**: `s3://backup-mongodb-superbid/prd/`
- **Perfil AWS**: Utiliza as credenciais exportadas do `.env`
- **Retenção S3**: `7 dias` - Configurado diretamente no bucket S3 através de políticas de lifecycle (não configurável via script)
- **MD5 Local**: Calcula e exibe o MD5 do arquivo criptografado local antes do upload para referência
- **Arquivo enviado**: Apenas o arquivo criptografado `.enc` é enviado ao S3 (o arquivo original `.tar` é removido após criptografia)

### 5.1. Verificação de Integridade do Backup

Após o upload, o script verifica a integridade do backup:

- **Comparação de tamanho**: Compara o tamanho do arquivo local com o arquivo no S3 usando `s3api head-object`
- **Validação**: Se os tamanhos não coincidirem, o script aborta com erro
- **MD5 local**: Calcula e exibe o MD5 do arquivo local para referência
- **Informações S3**: Obtém metadados do arquivo no S3 (tamanho, ETag) para validação
- **Exibição**: Mostra tamanhos formatados em formato legível (KB, MB, GB)

### 6. Limpeza Local

O script remove backups locais antigos:

- **Critério**: Arquivos com mais de `RETENTION_DAYS` (2 dias)
- **Padrão**: `mongodb_dump_*.tar` e `mongodb_dump_*.tar.enc`
- **Comando**: `find "$BACKUP_DIR_LOCAL" -type f \( -name "mongodb_dump_*.tar" -o -name "mongodb_dump_*.tar.enc" \) -mtime +$RETENTION_DAYS -print -delete`

## Logs

Todos os logs são registrados em:
- **Arquivo**: `/var/log/mongodb_backup.log`
- **Formato**: STDOUT e STDERR são redirecionados para o arquivo e console simultaneamente

### Rotação de Logs

O script implementa rotação automática de logs para evitar crescimento excessivo:

- **Tamanho máximo**: Quando o log excede `100MB`, é automaticamente rotacionado
- **Backups mantidos**: Os últimos `5` arquivos de log são mantidos
- **Nomenclatura**: Logs rotacionados são nomeados como `mongodb_backup.log.1`, `mongodb_backup.log.2`, etc.
- **Processo**: A rotação ocorre antes de cada execução do backup, se necessário

### Exemplo de Log

```
----------------------------------------------------
Início do Backup: 2025-12-18 10:00:00
----------------------------------------------------
Verificando espaço em disco disponível...
[OK] Espaço em disco suficiente: 150GB disponível (mínimo: 70GB)
Criando diretório local temporário: /backup/mongodb_temp
Iniciando mongodump no nó Secundário...
[OK] Backup concluído localmente.
Compactando backup...
[OK] Compactação concluída: /backup/mongodb_temp/mongodb_dump_20251218_100000.tar
Criptografando backup...
[OK] Criptografia concluída: /backup/mongodb_temp/mongodb_dump_20251218_100000.tar.enc
[OK] Arquivo original removido após criptografia.
Transferindo para o S3 em s3://backup-mongodb-superbid/prd/...
Tamanho do arquivo local: 2.5GB
MD5 local: a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6
[OK] Upload para o S3 concluído com sucesso.
Verificando integridade do backup no S3...
Tamanho do arquivo no S3: 2.5GB
[OK] Verificação de integridade: Tamanhos coincidem (2684354560 bytes)
Limpando backups locais antigos (+2 dias)...
[OK] Limpeza concluída.
Fim do processo: 2025-12-18 10:15:00
----------------------------------------------------
```

## Tratamento de Erros

O script possui validações e tratamento de erros em pontos críticos:

1. **Arquivo `.env` não encontrado**: Script aborta com código de saída 1
2. **`MONGODB_URI` não definida**: Script aborta com código de saída 1
3. **Espaço em disco insuficiente**: Script aborta com código de saída 1 se houver menos de 70GB disponíveis
4. **Falha no `mongodump`**: Script aborta com código de saída 1
5. **Falha na compactação**: Script aborta com código de saída 1
6. **Arquivo de senha não encontrado**: Script aborta com código de saída 1 se `/.openssl_pass` não existir
7. **Falha na criptografia**: Script aborta com código de saída 1
8. **Falha no upload S3**: Script aborta com código de saída 1
9. **Falha na verificação de integridade**: Script aborta com código de saída 1 se os tamanhos não coincidirem

## Dependências

### Ferramentas Necessárias

- **`mongodump`**: Ferramenta do MongoDB para criação de backups
  - Localização: `/usr/bin/mongodump`
- **`tar`**: Ferramenta de compactação
- **`openssl`**: Ferramenta de criptografia
  - Utilizado para criptografar backups com AES-256-CBC
  - Requer arquivo de senha em `/.openssl_pass`
- **`aws`**: CLI da Amazon Web Services
  - Localização: `/usr/local/bin/aws`
  - Requer configuração de credenciais no `.env`

### Permissões Necessárias

- Leitura/escrita no diretório `/backup/mongodb_temp`
- Escrita no arquivo de log `/var/log/mongodb_backup.log`
- Leitura do arquivo de senha `/.openssl_pass` (deve ter permissões restritas: chmod 600)
- Acesso de leitura ao MongoDB (usuário `backupUser`)
- Permissões de escrita no bucket S3 `backup-mongodb-superbid`

## Descriptografia de Backups

Para restaurar um backup criptografado, é necessário descriptografá-lo primeiro. O processo de descriptografia utiliza o mesmo arquivo de senha usado na criptografia.

### Descriptografar Backup do S3

1. **Baixar o arquivo criptografado do S3**:
   ```bash
   aws s3 cp s3://backup-mongodb-superbid/prd/mongodb_dump_YYYYMMDD_HHMMSS.tar.enc /backup/mongodb_temp/
   ```

2. **Descriptografar o arquivo**:
   ```bash
   openssl enc -d -aes-256-cbc -salt -in /backup/mongodb_temp/mongodb_dump_YYYYMMDD_HHMMSS.tar.enc \
     -out /backup/mongodb_temp/mongodb_dump_YYYYMMDD_HHMMSS.tar \
     --pass file:$SCRIPT_DIR/.openssl_pass
   ```

3. **Extrair o arquivo tar**:
   ```bash
   tar -xf /backup/mongodb_temp/mongodb_dump_YYYYMMDD_HHMMSS.tar -C /backup/mongodb_temp/
   ```

4. **Restaurar o backup no MongoDB**:
   ```bash
   mongorestore --host <host> --username <user> --password <pass> \
     --authenticationDatabase admin \
     /backup/mongodb_temp/mongodb_dump_YYYYMMDD_HHMMSS/
   ```

**⚠️ IMPORTANTE**: 
- O arquivo de senha `/.openssl_pass` deve estar presente e acessível
- Após a descriptografia, o arquivo `.tar` pode ser extraído normalmente
- Certifique-se de ter espaço suficiente em disco antes de descriptografar

## Execução Automatizada (Cron)

O backup é executado automaticamente via cron no seguinte horário:

```bash
# Executar diariamente às 02:17 (horário BRT - Brasília)
17 2 * * * /root/scripts/bkp-final.sh
```

**Configuração Atual**:
- **Horário**: `02:17 BRT` (Brasília Time)
- **Frequência**: Diária
- **Caminho**: `/root/scripts/bkp-final.sh`

**Nota**: É recomendado usar o caminho absoluto do script para garantir que funcione corretamente no ambiente cron.

## Monitoramento

### New Relic

A rotina de backup é monitorada pelo **New Relic** para acompanhamento de:

- **Execução dos backups**: Status de sucesso/falha
- **Tempo de execução**: Duração de cada processo de backup
- **Tamanho dos backups**: Monitoramento do tamanho dos arquivos gerados
- **Espaço em disco**: Alertas quando o espaço disponível está abaixo do mínimo
- **Falhas**: Notificações automáticas em caso de erros críticos

**Configuração**: O monitoramento é realizado através de integração do New Relic com os logs e métricas do sistema. Os logs em `/var/log/mongodb_backup.log` são analisados pelo agente do New Relic para gerar alertas e dashboards.

## Observações Importantes

1. **Nó Dedicado de Backup**: O backup é realizado no nó dedicado `mongodb-backup`, configurado como secundário oculto sem prioridade e sem direito a voto, garantindo que nunca seja promovido a primário
2. **Read Preference Secondary**: O backup é realizado no nó secundário para não impactar a performance do primário
3. **Compactação Gzip**: O `mongodump` já comprime os dados durante o dump, reduzindo o tamanho dos arquivos
4. **Criptografia**: Todos os backups são criptografados com AES-256-CBC antes do upload ao S3, garantindo segurança dos dados sensíveis
5. **Arquivo de Senha**: O arquivo `/.openssl_pass` contém a senha de criptografia e deve ter permissões restritas (chmod 600) e ser mantido em local seguro
6. **Remoção de Arquivo Original**: O arquivo `.tar` original é removido automaticamente após criptografia bem-sucedida, mantendo apenas o arquivo criptografado `.enc`
7. **Retenção Local**: Apenas 2 dias de backups são mantidos localmente para economizar espaço em disco (tanto arquivos `.tar` quanto `.enc`)
8. **Retenção S3**: 7 dias de backups são mantidos no S3 através de políticas de lifecycle do bucket (configuração não gerenciada pelo script)
9. **Verificação de Espaço**: O script verifica automaticamente se há espaço suficiente (mínimo 70GB) antes de iniciar o backup
10. **Verificação de Integridade**: Após o upload, o script valida que o arquivo foi transferido corretamente comparando tamanhos entre local e S3
11. **Rotação de Logs**: Logs são rotacionados automaticamente quando excedem 100MB, mantendo os últimos 5 arquivos
12. **Segurança**: As credenciais estão no arquivo `.env`, que deve ter permissões restritas (chmod 600)
13. **Monitoramento**: A rotina é monitorada pelo New Relic para alertas e acompanhamento de métricas

## Melhorias Implementadas

### v4 (18/12/2025)
1. ✅ **Verificação de Espaço em Disco**: Implementada verificação automática de espaço disponível (mínimo 70GB) antes de iniciar o backup
2. ✅ **Verificação de Integridade**: Implementada validação do backup após upload ao S3, comparando tamanhos dos arquivos
3. ✅ **Rotação de Logs**: Implementada rotação automática de logs quando excedem 100MB, mantendo os últimos 5 arquivos
4. ✅ **Correção na Limpeza**: Padrão de busca corrigido para `*.tar` (corresponde ao formato real dos arquivos)

### v5 (05/01/2025)
1. ✅ **Criptografia AES-256-CBC**: Implementada criptografia de todos os backups antes do upload ao S3
2. ✅ **Validação de Arquivo de Senha**: Verificação automática da existência do arquivo de senha antes da criptografia
3. ✅ **Remoção Automática**: Remoção do arquivo original não criptografado após criptografia bem-sucedida
4. ✅ **Limpeza Atualizada**: Limpeza de arquivos antigos agora inclui tanto arquivos `.tar` quanto `.enc`

## Melhorias Futuras Sugeridas

1. Implementar notificações (email/Slack) em caso de falha (além do monitoramento New Relic)
2. Adicionar verificação de checksum MD5 completo entre arquivo local e S3 (atualmente apenas tamanho)
3. Implementar métricas customizadas no New Relic para acompanhamento detalhado
4. Adicionar opção de backup incremental para reduzir tempo e espaço
5. Implementar rotação de senhas de criptografia com suporte a múltiplas versões
6. Adicionar script de descriptografia para facilitar restauração de backups

