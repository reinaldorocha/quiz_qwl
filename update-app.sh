#!/usr/bin/env bash
# ==============================================================================
# Script de Atualização Contínua: Quiz App
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}             ATUALIZANDO QUIZ APP NA VPS                    ${NC}"
echo -e "${CYAN}============================================================${NC}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# 1. Puxar alterações do Git
echo -e "${BLUE}[1/4] Puxando alterações do repositório Git...${NC}"
git pull origin main

# 2. Garantir que o schema 'quiz' esteja ativo no PostgREST
echo -e "${BLUE}[2/4] Verificando configuração do PostgREST...${NC}"
REST_NAME=$(docker ps --format '{{.Names}}' | grep -E 'supabase.*rest|postgrest' | head -n1)
if [ -n "$REST_NAME" ]; then
  ACTIVE_SCHEMAS=$(docker inspect "$REST_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep "^PGRST_DB_SCHEMAS=" || true)
  if [[ ! "$ACTIVE_SCHEMAS" =~ "quiz" ]]; then
    SUPABASE_DIR=$(docker inspect "$REST_NAME" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
    [ -z "$SUPABASE_DIR" ] && SUPABASE_DIR="/opt/supabase"
    if [ -f "$SUPABASE_DIR/.env" ]; then
      CURRENT_SCHEMAS=$(grep "^PGRST_DB_SCHEMAS=" "$SUPABASE_DIR/.env" | cut -d '=' -f2- | tr -d '"' | tr -d "'" || true)
      [ -z "$CURRENT_SCHEMAS" ] && CURRENT_SCHEMAS="public,storage,graphql_public"
      [[ ! "$CURRENT_SCHEMAS" =~ "quiz" ]] && CURRENT_SCHEMAS="${CURRENT_SCHEMAS},quiz"
      sed -i -E "s|^PGRST_DB_SCHEMAS=.*|PGRST_DB_SCHEMAS=\"${CURRENT_SCHEMAS}\"|" "$SUPABASE_DIR/.env"
      cd "$SUPABASE_DIR"
      docker compose up -d --force-recreate $(docker compose config --services 2>/dev/null | grep -E 'rest|meta') 2>/dev/null || docker compose up -d
      cd "$PROJECT_DIR"
    fi
  fi
fi

# 3. Aplicar migrations no Supabase
echo -e "${BLUE}[3/4] Sincronizando migrations do schema quiz...${NC}"
DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E 'supabase.*db|supabase-postgres|postgres:17' | head -n1)
if [ -n "$DB_CONTAINER" ]; then
  if [ -d "$PROJECT_DIR/supabase/migrations" ]; then
    for sql_file in $(ls -1 "$PROJECT_DIR"/supabase/migrations/*.sql 2>/dev/null | sort); do
      docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres < "$sql_file" > /dev/null 2>&1 || true
    done
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -c "SELECT pg_notify('pgrst', 'reload schema');" > /dev/null 2>&1 || true
    echo -e "${GREEN}  Migrations sincronizadas com sucesso.${NC}"
  fi
fi

# 4. Recompilar e reiniciar o container do Next.js
echo -e "${BLUE}[4/4] Recompilando e reiniciando a aplicação Next.js...${NC}"
docker compose build --build-arg NEXT_PUBLIC_SUPABASE_SCHEMA=quiz
docker compose up -d

# Conectar na rede do Supabase se existir
if [ -n "$DB_CONTAINER" ]; then
  SUPABASE_NET=$(docker inspect "$DB_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' 2>/dev/null | head -n1)
  if [ -n "$SUPABASE_NET" ] && [ "$SUPABASE_NET" != "bridge" ]; then
    docker network connect "$SUPABASE_NET" quiz-app 2>/dev/null || true
  fi
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}            APLICAÇÃO ATUALIZADA COM SUCESSO!               ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "Verifique o status a qualquer momento rodando: ${CYAN}./check-status.sh${NC}"
echo -e "Veja os logs da aplicação com:                  ${CYAN}docker logs quiz-app -f${NC}"
