# Documentação - Rotina de Backup MongoDB

## Visão Geral

Este documento descreve o funcionamento da rotina de backup automatizada do MongoDB, implementada pelo script `bkp-final.sh`. A rotina realiza backups completos do banco de dados MongoDB, compacta e criptografa os arquivos e os envia para o Amazon S3.

## Arquivos Envolvidos

- **`bkp-final.sh`**: Script principal de backup
- **`.env`**: Arquivo de configuração com credenciais e variáveis sensíveis (não versionado)
- **`.env.template`**: Template para criação do arquivo `.env`
- **`.openssl_pass`**: Arquivo com a senha de criptografia (não versionado)
- **`.openssl_pass.template`**: Template para criação do arquivo `.openssl_pass`
- **`.gitignore`**: Arquivo que define quais arquivos devem ser ignorados pelo Git (arquivos sensíveis, logs e backups)

## Arquitetura do Cluster MongoDB

### Nó Dedicado de Backup

Foi adicionado um nó específico ao cluster MongoDB exclusivamente para realizar backups:

- **Hostname**: `mongodb-backup.<dominio>`
- **IP**: `10.250.50.114`
- **Porta**: `37017`
- **Função**: Nó secundário dedicado exclusivamente para backups

### Configuração do Nó no Replica Set

O nó foi adicionado ao cluster com as seguintes características:

```javascript
rs.add({
  host: "mongodb-backup.<dominio>:37017", 
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

**Importante**: o `bkp-final.sh` **roda neste nó** e o `mongodump` lê o `mongod` local (`10.250.50.114:37017`). Não descobre nem usa outros SECONDARY do replica set (diferente do script legado antigo, que escolhia qualquer SECONDARY via `rs.status()`).

## Versões

- **v1** (16/12/2025): Redirecionamento de logs para `/var/log/mongodb_backup.log`
- **v2** (17/12/2025): Criação do arquivo de variável `.env`
- **v3** (18/12/2025): Correção para funcionar via cron (caminho absoluto do `.env`)
- **v4** (18/12/2025): Adicionado verificação de espaço em disco, verificação de integridade do backup e rotação de logs
- **v5** (05/01/2025): Adicionado criptografia AES-256-CBC dos backups antes do upload ao S3
- **v6** (09/06/2026): Retenção local por quantidade — mantém apenas os 2 arquivos `.enc` mais recentes
- **v7** (23/07/2026): `mongodump` com conexão direta no nó de backup (`host:porta`, sem discovery do replica set)
- **v8** (23/07/2026): Tentativa de dump em lotes por ObjectId (**revertido na v10**)
- **v9** (23/07/2026): Tentativa de mais retries/lotes (**revertido na v10**)
- **v10** (23/07/2026): Dump simples neste SECONDARY dedicado (estilo legado: `--host/--port/--db/--gzip`), sem lotes e sem ler outros nós

## Configurações

### Variáveis do Script (`bkp-final.sh`)

#### Diretórios
- **`BACKUP_DIR_LOCAL`**: `/backup/mongodb_temp` - Diretório local temporário para armazenar backups
- **`BACKUP_DIR_REMOTO`**: `/mnt/nfs/mongodb/daily/` - Diretório remoto (NFS) para backups diários
- **`REMOTE_HOST`**: `backup-server-ip` - Host do servidor de backup

#### MongoDB
- **`MONGO_HOSTS`**: `10.250.50.114:37017` - Host/porta do `mongod` **neste** nó de backup (dump local)
- **`MONGO_BIN`**: `/usr/bin/mongo` - Shell (ping/diagnóstico; `--host` e `--port` separados)
- **`MONGODUMP_BIN`**: `/usr/bin/mongodump` - Binário do dump
- **`BACKUP_DB`**: `GARR_MONGO` - Database dumpado (padrão do script legado)

#### Dump
- **`DUMP_MAX_RETRIES`**: `3` - Tentativas do `mongodump` em caso de falha transitória
- **`DUMP_RETRY_SLEEP_SEC`**: `60` - Espera entre retries (segundos)

#### Retenção
- **`RETENTION_ENCRYPTED_COUNT`**: `2` - Quantidade de arquivos `.tar.enc` a manter localmente
- **Retenção S3**: `7 dias` - Configurado diretamente no bucket S3 (não configurável via script)

#### Verificações e Logs
- **`MIN_DISK_SPACE_GB`**: `70` - Espaço mínimo em disco necessário (em GB) antes de iniciar o backup
- **`LOG_FILE`**: `/var/log/mongodb_backup.log` - Caminho do arquivo de log
- **`LOG_MAX_SIZE_MB`**: `100` - Tamanho máximo do arquivo de log em MB antes de rotacionar
- **`LOG_BACKUP_COUNT`**: `5` - Número de arquivos de log de backup a manter após rotação

#### Criptografia
- **`PASS_FILE`**: `/.openssl_pass` - Arquivo contendo a senha para criptografia OpenSSL (deve ter permissões restritas: chmod 600)
  - Um template está disponível em `.openssl_pass.template` para facilitar a configuração inicial

#### AWS S3
- **`S3_BUCKET_NAME`**: `backup-mongodb-superbid` - Nome do bucket S3
- **`S3_PATH`**: `prd` - Caminho dentro do bucket
- **`S3_TARGET`**: `s3://backup-mongodb-superbid/prd/` - Caminho completo de destino
- **`AWS_PROFILE`**: `backup_mongodb` - Perfil AWS a ser utilizado
- **`AWS_REGION`**: `sa-east-1` - Região AWS (São Paulo)

### Variáveis do Arquivo `.env`

O arquivo `.env` contém as credenciais e configurações sensíveis. Um template está disponível em `.env.template` para facilitar a configuração inicial.

**Estrutura do arquivo `.env`**:

```bash
MONGO_USER="<user_backup>"              # Usuário do MongoDB
MONGO_PASS="<password>"                 # Senha do MongoDB
AUTH_DB="<base>"                        # Banco de autenticação
REPLICA_SET_NAME="<replica set>"        # Nome do Replica Set

export AWS_ACCESS_KEY_ID="..."          # Chave de acesso AWS
export AWS_SECRET_ACCESS_KEY="..."      # Chave secreta AWS
```

**⚠️ IMPORTANTE**: 
- O arquivo `.env` contém informações sensíveis e não deve ser versionado ou compartilhado
- Use o template `.env.template` como base para criar seu arquivo `.env`
- Certifique-se de que o arquivo tenha permissões restritas (`chmod 600`)

## Fluxo de Execução

### 1. Inicialização e Validação

1. O script determina seu próprio diretório para localizar o arquivo `.env`
2. Carrega as variáveis de ambiente do arquivo `.env`
3. Valida se o arquivo `.env` existe
4. Valida se a variável `MONGODB_URI` está definida
5. **Rotaciona logs** se o arquivo de log exceder 100MB (mantém os últimos 5 arquivos)
6. Configura o redirecionamento de logs para `/var/log/mongodb_backup.log`
7. **Verifica espaço em disco disponível** - Aborta se houver menos de 70GB disponíveis

### 2. Execução do Backup (`mongodump` neste SECONDARY)

O script **roda no nó dedicado** e faz um dump simples (estilo legado), lendo só o `mongod` local:

```bash
mongodump --host 10.250.50.114 --port 37017 \
  --db GARR_MONGO --username ... --password ... \
  --authenticationDatabase ... \
  --excludeCollection system.users \
  --gzip --out ...
```

- **Não** usa `rs.status()` para escolher outro SECONDARY do cluster
- **Não** faz dump em lotes por ObjectId
- Retry configurável (`DUMP_MAX_RETRIES`) se o dump falhar de forma transitória
- Compactação `--gzip` durante o dump

**Nome do Backup**: `mongodb_dump_YYYYMMDD_HHMMSS` (timestamp)

**Nota**: O nó é `hidden` + `priority: 0` + `votes: 0`, para o backup não impactar o primário nem receber tráfego de aplicação.


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
  - Um template está disponível em `.openssl_pass.template` para facilitar a configuração inicial
- **Arquivo criptografado**: `mongodb_dump_YYYYMMDD_HHMMSS.tar.enc`
- **Validação**: Verifica se o arquivo de senha existe antes de criptografar
- **Limpeza**: Remove o arquivo original `.tar` após criptografia bem-sucedida (mantém apenas o `.enc`)

**⚠️ IMPORTANTE**: 
- O arquivo `$SCRIPT_DIR/.openssl_pass` deve ter permissões restritas (chmod 600) e conter apenas a senha de criptografia
- Use o template `.openssl_pass.template` como base para criar seu arquivo de senha

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

O script remove artefatos locais antigos:

- **Subpastas** `mongodb_dump_*` e arquivos `.tar` órfãos
- **Arquivos `.enc`**: mantém apenas os `RETENTION_ENCRYPTED_COUNT` (2) mais recentes

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
Início do Backup: 2026-07-23 10:00:00
----------------------------------------------------
Verificando espaço em disco disponível...
[OK] Espaço em disco suficiente: 150GB disponível (mínimo: 70GB)
Criando diretório local temporário: /backup/mongodb_temp
Iniciando dump neste nó SECONDARY dedicado (estilo legado)...
Target: 10.250.50.114:37017 db=GARR_MONGO
Nó de backup (SECONDARY dedicado): 10.250.50.114:37017
>>> mongodump --host 10.250.50.114 --port 37017 --db GARR_MONGO --gzip
[OK] Backup concluído localmente.
...
----------------------------------------------------
```

## Tratamento de Erros

O script possui validações e tratamento de erros em pontos críticos:

1. **Arquivo `.env` não encontrado**: Script aborta com código de saída 1
2. **`MONGODB_URI` não definida**: Script aborta com código de saída 1
3. **Espaço em disco insuficiente**: Script aborta com código de saída 1 se houver menos de 70GB disponíveis
4. **Falha no dump** (após retries): Script aborta com código de saída 1
5. **Falha na compactação**: Script aborta com código de saída 1
6. **Arquivo de senha não encontrado**: Script aborta com código de saída 1 se `.openssl_pass` não existir
7. **Falha na criptografia**: Script aborta com código de saída 1
8. **Falha no upload S3**: Script aborta com código de saída 1
9. **Falha na verificação de integridade**: Script aborta com código de saída 1 se os tamanhos não coincidirem

## Dependências

### Ferramentas Necessárias

- **`mongodump`**: Ferramenta do MongoDB para criação de backups (`/usr/bin/mongodump`)
- **`mongo`**: Shell opcional para diagnóstico/ping (`/usr/bin/mongo`; `--host` e `--port` separados)
- **`tar`**: Ferramenta de compactação
- **`openssl`**: Criptografia AES-256-CBC (arquivo de senha em `$SCRIPT_DIR/.openssl_pass`)
- **`aws`**: CLI AWS (`/usr/local/bin/aws`) com credenciais no `.env`

### Permissões Necessárias

- Leitura/escrita no diretório `/backup/mongodb_temp`
- Escrita no arquivo de log `/var/log/mongodb_backup.log`
- Leitura do arquivo de senha `$SCRIPT_DIR/.openssl_pass` (chmod 600)
- Acesso de leitura ao MongoDB **neste** nó de backup (`BACKUP_DB`, padrão `GARR_MONGO`)
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

1. **Nó Dedicado de Backup**: secundário oculto (`hidden: true`, `priority: 0`, `votes: 0`) — nunca vira primário
2. **Script roda neste nó**: o `mongodump` lê o `mongod` local (`MONGO_HOSTS`), sem `rs.status()` e sem outros SECONDARY
3. **Dump simples**: um `mongodump --db GARR_MONGO --gzip` (estilo legado), com retry leve
4. **Compactação Gzip**: aplicada pelo próprio `mongodump` (`--gzip`)
5. **Criptografia**: AES-256-CBC antes do upload ao S3
6. **Arquivo de Senha**: `$SCRIPT_DIR/.openssl_pass` com permissões restritas (chmod 600)
7. **Retenção Local**: mantém apenas `RETENTION_ENCRYPTED_COUNT` (2) arquivos `.enc`
8. **Retenção S3**: 7 dias via lifecycle do bucket
9. **Verificação de Espaço**: mínimo 70GB antes de iniciar
10. **Verificação de Integridade**: compara tamanho local vs S3 após o upload
11. **Rotação de Logs**: acima de 100MB, mantém os últimos 5 arquivos
12. **Monitoramento**: New Relic sobre `/var/log/mongodb_backup.log`
13. **Segurança / Git**: `.env`, `.openssl_pass`, logs e backups no `.gitignore`

## Melhorias Implementadas

### v4 (18/12/2025)
1. ✅ Verificação de espaço em disco (mínimo 70GB)
2. ✅ Verificação de integridade pós-upload S3
3. ✅ Rotação automática de logs
4. ✅ Correção na limpeza de arquivos `*.tar`

### v5 (05/01/2025)
1. ✅ Criptografia AES-256-CBC antes do S3
2. ✅ Validação do arquivo de senha
3. ✅ Remoção do `.tar` após criptografia
4. ✅ Limpeza incluindo `.tar` e `.enc`

### v6 (09/06/2026)
1. ✅ Retenção local por quantidade (2 `.enc` mais recentes)

### v7 / v10 (23/07/2026)
1. ✅ Conexão direta neste nó de backup (`--host` / `--port`)
2. ✅ Dump simples de `GARR_MONGO` com `--gzip` e retry
3. ✅ Documentado que o script não lê outros SECONDARY do cluster

### v8 / v9 (23/07/2026) — revertidas
1. ⚠️ Lotes por ObjectId e retries agressivos foram tentados e **removidos na v10** (não fazem parte do comportamento atual)

## Melhorias Futuras Sugeridas

1. Notificações (email/Slack) em caso de falha (além do New Relic)
2. Checksum MD5 completo entre local e S3 (hoje só tamanho)
3. Métricas customizadas no New Relic
4. Avaliar snapshot de filesystem no secundário para datasets muito grandes
5. Rotação de senhas de criptografia com múltiplas versões
6. Script auxiliar de descriptografia/restauração
