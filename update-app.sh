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
echo -e "${BLUE}[1/3] Puxando alterações do repositório Git...${NC}"
git pull origin main

# 2. Aplicar eventuais novas migrations no Supabase
echo -e "${BLUE}[2/3] Verificando e aplicando migrations do banco...${NC}"
if docker ps --format '{{.Names}}' | grep -q "^supabase-db$"; then
  if [ -d "$PROJECT_DIR/supabase/migrations" ]; then
    for sql_file in $(ls -1 "$PROJECT_DIR"/supabase/migrations/*.sql 2>/dev/null | sort); do
      docker exec -i supabase-db psql -U postgres -d postgres < "$sql_file" > /dev/null 2>&1 || true
    done
    echo -e "${GREEN}  Migrations sincronizadas com sucesso.${NC}"
  fi
fi

# 3. Recompilar e reiniciar o container do Next.js
echo -e "${BLUE}[3/3] Recompilando e reiniciando a aplicação Next.js...${NC}"
docker compose build
docker compose up -d

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}            APLICAÇÃO ATUALIZADA COM SUCESSO!               ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "Verifique o status a qualquer momento rodando: ${CYAN}./check-status.sh${NC}"
echo -e "Veja os logs da aplicação com:                  ${CYAN}docker logs quiz-app -f${NC}"
