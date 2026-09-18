#!/usr/bin/env bash
# ==============================================================================
# Script de Diagnóstico e Status: Quiz App + Supabase Self-Hosted
# ==============================================================================

# Cores
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}         STATUS DO SISTEMA: QUIZ APP + SUPABASE            ${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# 1. Checagem do Container do Quiz App (Next.js)
echo -e "${BLUE}1. Aplicativo Next.js (quiz-app):${NC}"
if docker ps --format '{{.Names}}' | grep -q "^quiz-app$"; then
  STATUS=$(docker inspect --format='{{.State.Status}}' quiz-app 2>/dev/null)
  UPTIME=$(docker inspect --format='{{.State.StartedAt}}' quiz-app 2>/dev/null | cut -d'.' -f1)
  echo -e "  Container:      ${GREEN}[RODANDO]${NC} (Status: $STATUS, Iniciado em: $UPTIME)"
  
  # Teste HTTP na porta 3010
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3010 || echo "000")
  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
    echo -e "  Porta 3010:     ${GREEN}[OK]${NC} Respondendo HTTP $HTTP_CODE"
  else
    echo -e "  Porta 3010:     ${YELLOW}[AVISO]${NC} Código HTTP: $HTTP_CODE"
  fi
else
  echo -e "  Container:      ${RED}[PARADO OU INEXISTENTE]${NC}"
fi

echo ""

# 2. Checagem do Supabase (Banco de Dados PostgreSQL)
echo -e "${BLUE}2. Supabase PostgreSQL (supabase-db):${NC}"
if docker ps --format '{{.Names}}' | grep -q "^supabase-db$"; then
  if docker exec supabase-db pg_isready -U postgres -d postgres &>/dev/null; then
    echo -e "  PostgreSQL:     ${GREEN}[ONLINE / PRONTO]${NC} Aceitando conexões na porta 54322"
    # Checar se as tabelas principais existem
    TABLES_COUNT=$(docker exec -i supabase-db psql -U postgres -d postgres -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ')
    echo -e "  Tabelas public: ${GREEN}[OK]${NC} $TABLES_COUNT tabelas encontradas"
  else
    echo -e "  PostgreSQL:     ${RED}[FALHA]${NC} O banco não está respondendo a pg_isready"
  fi
else
  echo -e "  PostgreSQL:     ${RED}[CONTAINER PARADO]${NC}"
fi

echo ""

# 3. Checagem do Gateway / API do Supabase (Porta 8800)
echo -e "${BLUE}3. Supabase API Gateway & Studio (Porta 8800):${NC}"
GATEWAY_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "^(supabase-envoy|supabase-kong)$" | head -n 1)
if [ -n "$GATEWAY_CONTAINER" ]; then
  echo -e "  Gateway ($GATEWAY_CONTAINER): ${GREEN}[RODANDO]${NC}"
  
  # Teste HTTP na porta 8800
  HTTP_GATEWAY=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8800/ || echo "000")
  if [ "$HTTP_GATEWAY" -ge 200 ] && [ "$HTTP_GATEWAY" -lt 500 ]; then
    echo -e "  Porta 8800:     ${GREEN}[OK]${NC} Gateway respondendo HTTP $HTTP_GATEWAY"
  else
    echo -e "  Porta 8800:     ${RED}[FALHA]${NC} Não respondeu na porta 8800 (Código: $HTTP_GATEWAY)"
  fi
else
  echo -e "  Gateway:        ${RED}[CONTAINER DE GATEWAY PARADO]${NC}"
fi

echo ""

# 4. Lista dos Containers do Supabase Ativos
echo -e "${BLUE}4. Todos os Containers do Supabase Ativos:${NC}"
SUPABASE_CONTAINERS=$(docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(supabase|realtime)")
if [ -n "$SUPABASE_CONTAINERS" ]; then
  echo "$SUPABASE_CONTAINERS" | while read -r line; do
    echo -e "  ${GREEN}✔${NC} $line"
  done
else
  echo -e "  ${RED}Nenhum container do Supabase foi encontrado em execução.${NC}"
fi

echo ""

# 5. Uso de Memória dos Containers
echo -e "${BLUE}5. Consumo de Recursos (Memória / CPU):${NC}"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" | grep -E "(quiz|supabase|realtime|NAME)" | head -n 15

echo ""

# 6. Teste de Acesso aos Domínios Externos (Se já configurados no NPM)
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$PROJECT_DIR/.env" ]; then
  APP_URL=$(grep "^NEXT_PUBLIC_APP_URL=" "$PROJECT_DIR/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
  SUPABASE_URL=$(grep "^NEXT_PUBLIC_SUPABASE_URL=" "$PROJECT_DIR/.env" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
  
  echo -e "${BLUE}6. Teste de Acesso Externo (HTTPS / Domínios):${NC}"
  if [ -n "$APP_URL" ]; then
    EXT_APP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "$APP_URL" 2>/dev/null || echo "Erro")
    if [ "$EXT_APP_CODE" -ge 200 ] && [ "$EXT_APP_CODE" -lt 400 ]; then
      echo -e "  $APP_URL:      ${GREEN}[ONLINE - HTTP $EXT_APP_CODE]${NC}"
    else
      echo -e "  $APP_URL:      ${YELLOW}[AVISO - HTTP $EXT_APP_CODE]${NC} (Verifique se o Nginx Proxy Manager já foi configurado)"
    fi
  fi

  if [ -n "$SUPABASE_URL" ]; then
    EXT_SB_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "$SUPABASE_URL" 2>/dev/null || echo "Erro")
    if [ "$EXT_SB_CODE" -ge 200 ] && [ "$EXT_SB_CODE" -lt 500 ]; then
      echo -e "  $SUPABASE_URL: ${GREEN}[ONLINE - HTTP $EXT_SB_CODE]${NC}"
    else
      echo -e "  $SUPABASE_URL: ${YELLOW}[AVISO - HTTP $EXT_SB_CODE]${NC} (Verifique se o Nginx Proxy Manager já foi configurado)"
    fi
  fi
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
