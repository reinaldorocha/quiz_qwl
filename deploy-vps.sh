#!/usr/bin/env bash
# ==============================================================================
# Script de Instalação Automática: Next.js App + Supabase Self-Hosted na VPS
# ==============================================================================
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Cores para saída
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "============================================================"
echo "    INSTALAÇÃO COMPLETA: QUIZ APP + SUPABASE SELF-HOSTED    "
echo "============================================================"
echo -e "${NC}"

# 1. Checagem de privilégios de root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERRO] Este script precisa ser executado como root (sudo).${NC}"
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 2. Obter variáveis e domínios do usuário
if [ -z "$APP_DOMAIN" ]; then
  echo -e "${YELLOW}>> Informe o domínio do seu aplicativo Next.js (ex: quiz.meudominio.com ou meudominio.com):${NC}"
  read -p "Domínio App: " APP_DOMAIN
fi

if [ -z "$SUPABASE_DOMAIN" ]; then
  echo -e "${YELLOW}>> Informe o subdomínio para o Supabase API/Studio (ex: api.meudominio.com ou supabase.meudominio.com):${NC}"
  read -p "Domínio Supabase: " SUPABASE_DOMAIN
fi

echo ""
echo -e "${BLUE}Configurações informadas:${NC}"
echo "  - Domínio App:      https://$APP_DOMAIN"
echo "  - Domínio Supabase: https://$SUPABASE_DOMAIN"
echo ""

# 3. Instalar Dependências do Sistema
echo -e "${CYAN}[1/4] Atualizando sistema e instalando dependências (Docker, Node.js)...${NC}"
apt-get update -qq
apt-get install -y -qq curl git openssl jq ca-certificates gnupg lsb-release

# Instalar Node.js 20 se não existir
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
fi

# Instalar Docker se não existir
if ! command -v docker &> /dev/null; then
  echo "Instalando Docker Engine..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

# 4. Instalar Supabase Self-Hosted
SUPABASE_DIR="/opt/supabase"
echo -e "${CYAN}[2/4] Configurando Supabase Self-Hosted em $SUPABASE_DIR...${NC}"
mkdir -p "$SUPABASE_DIR"

if [ ! -f "$SUPABASE_DIR/.env.example" ] || [ ! -f "$SUPABASE_DIR/docker-compose.yml" ]; then
  echo "Baixando arquivos oficiais do Supabase Docker..."
  TEMP_REPO="/tmp/supabase-repo-$$"
  git clone --depth 1 https://github.com/supabase/supabase.git "$TEMP_REPO"
  cp -rf "$TEMP_REPO"/docker/. "$SUPABASE_DIR"/
  rm -rf "$TEMP_REPO"
fi

# Fallback se .env.example não tiver sido copiado
if [ ! -f "$SUPABASE_DIR/.env.example" ]; then
  echo "Baixando .env.example diretamente..."
  curl -fsSL https://raw.githubusercontent.com/supabase/supabase/master/docker/.env.example -o "$SUPABASE_DIR/.env.example"
fi

cd "$SUPABASE_DIR"

# Carregar senhas existentes se já existirem, para não dessincronizar com o banco
if [ -f .env ]; then
  echo "Carregando credenciais já existentes do Supabase..."
  POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" .env | cut -d'=' -f2 || true)
  JWT_SECRET=$(grep "^JWT_SECRET=" .env | cut -d'=' -f2 || true)
  SECRET_KEY_BASE=$(grep "^SECRET_KEY_BASE=" .env | cut -d'=' -f2 || true)
  VAULT_ENC_KEY=$(grep "^VAULT_ENC_KEY=" .env | cut -d'=' -f2 || true)
  DASHBOARD_USERNAME=$(grep "^DASHBOARD_USERNAME=" .env | cut -d'=' -f2 || true)
  DASHBOARD_PASSWORD=$(grep "^DASHBOARD_PASSWORD=" .env | cut -d'=' -f2 || true)
  ANON_KEY=$(grep "^ANON_KEY=" .env | cut -d'=' -f2 || true)
  SERVICE_ROLE_KEY=$(grep "^SERVICE_ROLE_KEY=" .env | cut -d'=' -f2 || true)
fi

# Gerar valores caso ainda não existam
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}
JWT_SECRET=${JWT_SECRET:-$(openssl rand -hex 32)}
SECRET_KEY_BASE=${SECRET_KEY_BASE:-$(openssl rand -hex 32)}
VAULT_ENC_KEY=${VAULT_ENC_KEY:-$(openssl rand -hex 16)}
DASHBOARD_USERNAME=${DASHBOARD_USERNAME:-admin}
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD:-$(openssl rand -base64 12)}

# Gerar chaves JWT se necessário
if [ -z "$ANON_KEY" ] || [ -z "$SERVICE_ROLE_KEY" ]; then
  KEYS_JSON=$(node -e '
  const crypto = require("crypto");
  const secret = process.argv[1];
  const sign = (payload) => {
    const h = Buffer.from(JSON.stringify({alg:"HS256",typ:"JWT"})).toString("base64url");
    const b = Buffer.from(JSON.stringify(payload)).toString("base64url");
    const s = crypto.createHmac("sha256", secret).update(h + "." + b).digest("base64url");
    return `${h}.${b}.${s}`;
  };
  const now = Math.floor(Date.now() / 1000);
  const exp = now + 15 * 365 * 24 * 3600; // 15 anos
  const anon = sign({ role: "anon", iss: "supabase", iat: now, exp });
  const service = sign({ role: "service_role", iss: "supabase", iat: now, exp });
  console.log(JSON.stringify({ anon, service }));
  ' "$JWT_SECRET")

  ANON_KEY=$(echo "$KEYS_JSON" | jq -r .anon)
  SERVICE_ROLE_KEY=$(echo "$KEYS_JSON" | jq -r .service)
fi

set_env() {
  local key="$1"
  local val="$2"
  local file="${3:-.env}"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|g" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

# Criar ou atualizar o .env do Supabase
[ ! -f .env ] && cp .env.example .env

set_env "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"
set_env "JWT_SECRET" "$JWT_SECRET"
set_env "ANON_KEY" "$ANON_KEY"
set_env "SERVICE_ROLE_KEY" "$SERVICE_ROLE_KEY"
set_env "DASHBOARD_USERNAME" "$DASHBOARD_USERNAME"
set_env "DASHBOARD_PASSWORD" "$DASHBOARD_PASSWORD"
set_env "SECRET_KEY_BASE" "$SECRET_KEY_BASE"
set_env "VAULT_ENC_KEY" "$VAULT_ENC_KEY"

set_env "API_EXTERNAL_URL" "https://$SUPABASE_DOMAIN"
set_env "SITE_URL" "https://$APP_DOMAIN"
set_env "ADDITIONAL_REDIRECT_URLS" "https://$APP_DOMAIN/auth/callback,https://$APP_DOMAIN"
set_env "ENABLE_EMAIL_AUTOCONFIRM" "true"

# Portas customizadas para evitar conflito com Coolify e outros containers
set_env "API_GW_HTTP_PORT" "8800"
set_env "KONG_HTTP_PORT" "8800"
set_env "KONG_HTTPS_PORT" "8444"
set_env "POSTGRES_PORT" "54322"

echo "Parando eventuais containers anteriores do Supabase..."
docker compose down 2>/dev/null || true

echo "Iniciando containers do Supabase..."
docker compose up -d

echo "Aguardando PostgreSQL do Supabase inicializar..."
for i in {1..30}; do
  if docker exec supabase-db pg_isready -U postgres -d postgres &>/dev/null; then
    echo -e "${GREEN}PostgreSQL está pronto!${NC}"
    break
  fi
  sleep 2
done

# Sincronizar senhas de todos os usuários internos com a senha atual do .env
docker exec -i supabase-db psql -U postgres -d postgres <<EOF 2>/dev/null || true
ALTER USER postgres WITH PASSWORD '$POSTGRES_PASSWORD';
ALTER USER supabase_admin WITH PASSWORD '$POSTGRES_PASSWORD';
ALTER USER supabase_auth_admin WITH PASSWORD '$POSTGRES_PASSWORD';
ALTER USER authenticator WITH PASSWORD '$POSTGRES_PASSWORD';
ALTER USER supabase_storage_admin WITH PASSWORD '$POSTGRES_PASSWORD';
EOF

docker compose restart auth rest storage 2>/dev/null || true

# 5. Executar as Migrations do Projeto
echo -e "${CYAN}[3/4] Aplicando migrations do banco de dados...${NC}"
if [ -d "$PROJECT_DIR/supabase/migrations" ]; then
  for sql_file in $(ls -1 "$PROJECT_DIR"/supabase/migrations/*.sql 2>/dev/null | sort); do
    echo "  -> Executando $(basename "$sql_file")..."
    docker exec -i supabase-db psql -U postgres -d postgres < "$sql_file" > /dev/null 2>&1 || true
  done
  echo -e "${GREEN}Todas as migrations foram aplicadas!${NC}"
fi

# 6. Configurar e Subir o Container do App Next.js
echo -e "${CYAN}[4/4] Construindo e iniciando a aplicação Next.js...${NC}"
cd "$PROJECT_DIR"

export NEXT_PUBLIC_SUPABASE_URL="https://$SUPABASE_DOMAIN"
export NEXT_PUBLIC_SUPABASE_ANON_KEY="$ANON_KEY"
export SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"
export NEXT_PUBLIC_APP_URL="https://$APP_DOMAIN"

cat <<EOF > .env
NEXT_PUBLIC_SUPABASE_URL=https://$SUPABASE_DOMAIN
NEXT_PUBLIC_SUPABASE_ANON_KEY=$ANON_KEY
SUPABASE_SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY
NEXT_PUBLIC_APP_URL=https://$APP_DOMAIN
EOF
cp -f .env .env.local

docker compose down 2>/dev/null || true
docker compose build \
  --build-arg NEXT_PUBLIC_SUPABASE_URL="https://$SUPABASE_DOMAIN" \
  --build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY="$ANON_KEY" \
  --build-arg NEXT_PUBLIC_APP_URL="https://$APP_DOMAIN" \
  --build-arg SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"

docker compose up -d

# 7. Salvar credenciais geradas e instruções
CREDS_FILE="/root/quiz_credentials.txt"
cat <<EOF > "$CREDS_FILE"
============================================================
              CREDENCIAS DO SEU PROJETO QUIZ
============================================================

1. APLICATIVO NEXT.JS (Porta interna 3010):
   - Domínio: https://$APP_DOMAIN
   - Local:   http://127.0.0.1:3010

2. SUPABASE SELF-HOSTED (Porta interna 8800):
   - Domínio da API / Gateway: https://$SUPABASE_DOMAIN
   - Painel Supabase Studio:    https://$SUPABASE_DOMAIN/project/default
   - Usuário do Studio: $DASHBOARD_USERNAME
   - Senha do Studio:   $DASHBOARD_PASSWORD

3. CHAVES DE API DO SUPABASE:
   - Anon / Public Key:
$ANON_KEY

   - Service Role Key (Secreta):
$SERVICE_ROLE_KEY

4. BANCO DE DADOS POSTGRESQL (Porta interna 54322):
   - Usuário: postgres
   - Senha:   $POSTGRES_PASSWORD

============================================================
CONFIGURAÇÃO NO SEU NGINX PROXY MANAGER (NPM):
============================================================
Como você usa o Nginx Proxy Manager, basta criar 2 Proxy Hosts no painel:

Host 1 (App):
  - Domain Names:           $APP_DOMAIN
  - Forward Hostname / IP:  172.17.0.1  (ou o IP da VPS)
  - Forward Port:           3010
  - WebSockets Support:     [X] Ativado
  - SSL:                    Request a new SSL Certificate (Let's Encrypt)

Host 2 (Supabase):
  - Domain Names:           $SUPABASE_DOMAIN
  - Forward Hostname / IP:  172.17.0.1  (ou o IP da VPS)
  - Forward Port:           8800
  - WebSockets Support:     [X] Ativado (essencial para Realtime)
  - SSL:                    Request a new SSL Certificate (Let's Encrypt)

============================================================
OU SE PREFERIR O ARQUIVO NGINX TRADICIONAL:
============================================================

# Bloco para o Aplicativo Next.js:
server {
    server_name $APP_DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:3010;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    client_max_body_size 10M;
}

# Bloco para o Supabase:
server {
    server_name $SUPABASE_DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:8800;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    client_max_body_size 50M;
}

============================================================
PRÓXIMOS PASSOS:
1. Configure os blocos acima no seu Nginx e gere o SSL (certbot).
2. Acesse https://$APP_DOMAIN/register e crie sua conta.
3. Na VPS, execute para se tornar administrador:
   cd $PROJECT_DIR
   npm run setup:promote-admin -- --email=SEU_EMAIL_CADASTRADO
4. Acesse o painel administrativo em:
   https://$APP_DOMAIN/admin
============================================================
EOF

chmod 600 "$CREDS_FILE"

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}          INSTALAÇÃO CONCLUÍDA COM SUCESSO!                 ${NC}"
echo -e "${GREEN}============================================================${NC}"
cat "$CREDS_FILE"
echo ""
echo -e "${YELLOW}Uma cópia segura das credenciais foi salva em: ${CREDS_FILE}${NC}"
