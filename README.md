# Quiz Platform

Plataforma SaaS de criação de quizzes interativos para geração de leads, vendas de infoprodutos, funis de conversão e captação de dados para marketing.

Código pensado para ser **clonado e personalizado** (white-label): marca, cores e hero da landing editáveis em `/admin/settings`.

## Stack

| Camada    | Tecnologia                                      |
| --------- | ----------------------------------------------- |
| Frontend  | Next.js 15, TypeScript, Tailwind CSS, Shadcn/UI |
| Forms     | React Hook Form + Zod                           |
| Estado    | TanStack Query, Zustand, Context API            |
| Animações | Framer Motion                                   |
| Backend   | Supabase (Auth, Storage, Edge Functions)        |
| Deploy    | Vercel (ou equivalente)                         |

## Instalação (comprador / nova cópia)

**Migrations sozinhas não bastam.** Siga o runbook:

→ **[SETUP.md](./SETUP.md)**

Resumo:

```bash
npm install
cp .env.example .env.local   # preencha URL/keys do Supabase
npx supabase link --project-ref <REF>
npm run db:push
# Configure Auth Site URL + Redirect URLs no painel Supabase
npm run functions:deploy:webhook   # --no-verify-jwt
npm run dev
# Crie a conta em /register, depois:
npm run setup:promote-admin -- --email=seu@email.com
```

Depois, em `/admin/settings`, configure a **Marca** e os planos/integrações de pagamento.

## Desenvolvimento rápido (já com Supabase configurado)

```bash
npm install
cp .env.local.example .env.local
npm run dev
```

Acesse [http://localhost:3000](http://localhost:3000).

## Scripts

```bash
npm run dev                       # Servidor de desenvolvimento
npm run build                     # Build de produção
npm run lint                      # ESLint
npm run typecheck                 # TypeScript
npm run test                      # Testes unitários
npm run db:push                   # Aplica migrations no projeto linkado
npm run functions:deploy:webhook  # Deploy webhook-in sem JWT
npm run setup:promote-admin       # Promove usuário a admin
```

## Variáveis de ambiente

Veja [`.env.example`](./.env.example). Mínimo:

```env
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
NEXT_PUBLIC_APP_URL=http://localhost:3000
```

Opcional: `VERCEL_*` para domínios custom de quiz.  
Build sem env: `SKIP_ENV_VALIDATION=true npm run build`.

## Arquitetura

Domain Driven Folder Structure — `app/` fino, lógica em `domains/`.

```
src/
├── app/              # Rotas (App Router)
├── domains/          # auth, quiz, workspace, admin, billing, marketing...
├── components/       # UI compartilhada
├── services/         # Clientes Supabase
├── config/           # site, branding defaults, features
└── ...
```

## Personalização white-label

| O quê                            | Onde                      |
| -------------------------------- | ------------------------- |
| Nome, logo, favicon, cores, hero | `/admin/settings` → Marca |
| Planos e checkout                | `/admin/plans`            |
| Webhook de vendas                | `/admin/integrations`     |
| Manutenção / cadastros / trial   | `/admin/settings`         |

## Auth e e-mail

Site URL e Redirect URLs ficam no **painel Supabase**, não no código.

- **Confirm email: OFF** (padrão do produto) — cadastro entra logado sem verificar e-mail. Ver [`SETUP.md`](./SETUP.md).
- SMTP / templates são necessários sobretudo para **reset de senha**; sem isso, forgot-password falha em produção.
- `/auth/callback` permanece necessário mesmo com confirmação desligada.

---

## 🗄️ Arquitetura de Isolamento de Banco (Multi-App / Schemas)

Para permitir que múltiplos projetos (como **Quiz App** e **UaiFlow**) rodem na **mesma VPS** e compartilhem o **mesmo PostgreSQL do Supabase** com máxima economia de memória (sem duplicar containers), este projeto utiliza o schema dedicado `quiz`.

### Como Funciona:
- **`quiz`**: Contém todas as tabelas da aplicação (`quiz.quizzes`, `quiz.workspaces`, `quiz.profiles`, `quiz.workspace_members`, `quiz.quiz_steps`, etc.).
- **`uaiflow`**: Contém as tabelas da automação de Instagram do UaiFlow (`uaiflow.profiles`, `uaiflow.workspaces`, `uaiflow.automations`, etc.).
- **`auth.users`**: Compartilhado com segurança pelo Supabase Auth.
- **`public`**: Permanece limpo para extensões e funções utilitárias públicas.

### Configuração do PostgREST (`PGRST_DB_SCHEMAS`)
O PostgREST do Supabase precisa expor os schemas para a API REST. No arquivo `.env` do Supabase (`/opt/supabase/.env`), os schemas ficam definidos assim:
```env
PGRST_DB_SCHEMAS="public,storage,graphql_public,uaiflow,quiz"
```
O cliente Next.js do Quiz App se comunica automaticamente com o schema `quiz` através da variável de ambiente:
```env
NEXT_PUBLIC_SUPABASE_SCHEMA=quiz
```

---

## 🖥️ Como Instalar em VPS Limpa (Deploy Automático)

O script `deploy-vps.sh` é inteligente: se a VPS estiver limpa, ele instala o Docker, Node.js e o Supabase. Se o Supabase já estiver rodando (instalado pelo UaiFlow, por exemplo), ele **detecta a instância existente**, reutiliza as credenciais e adiciona o schema `quiz` automaticamente sem derrubar o outro app.

### Passo a Passo:
1. Clone o repositório na VPS:
   ```bash
   cd /var/www
   git clone https://github.com/reinaldorocha/quiz_qwl.git
   cd quiz_qwl
   ```
2. Execute o instalador como root:
   ```bash
   sudo ./deploy-vps.sh
   ```
3. Informe seu domínio para a aplicação (ex: `quiz.meudominio.com`) e o subdomínio para a API Supabase (ex: `api.meudominio.com`).
4. Ao final, o script exibirá todas as credenciais salvas e as instruções prontas para o **Nginx Proxy Manager** (porta `3010` para o App e `8800` para a API Supabase).

---

## 🚀 Como Atualizar a Aplicação na VPS (Deploy Contínuo)

Sempre que fizer alterações no GitHub, criar novos recursos ou migrations, basta executar:

### Opção 1: Atualização Automática em 1 Comando (Recomendado)
```bash
cd /var/www/quiz_qwl
./update-app.sh
```
O script executa tudo automaticamente:
1. `git pull origin main`
2. Garante que `quiz` está ativo em `PGRST_DB_SCHEMAS`
3. Aplica novas migrations no PostgreSQL
4. Recarrega o cache do PostgREST (`reload schema`)
5. Recompila o container Next.js e sobe a nova versão

---

### Opção 2: Atualização Manual Passo a Passo
```bash
cd /var/www/quiz_qwl

# 1. Puxe as últimas alterações do GitHub
git pull origin main

# 2. Recompile e reinicie o container do Next.js
docker compose build --build-arg NEXT_PUBLIC_SUPABASE_SCHEMA=quiz
docker compose up -d

# 3. Notifique o schema cache caso tenha rodado migrations
DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E 'supabase.*db|supabase-postgres|postgres:17' | head -n1)
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -c "SELECT pg_notify('pgrst', 'reload schema');"
```

---

### Comandos Úteis de Manutenção

* **Verificar o status de todos os serviços e portas**:
  ```bash
  ./check-status.sh
  ```
* **Ver logs em tempo real do Next.js**:
  ```bash
  docker logs quiz-app -f
  ```
* **Ver logs do PostgREST**:
  ```bash
  docker logs $(docker ps --format '{{.Names}}' | grep -E 'supabase.*rest|postgrest' | head -n1) -f
  ```
* **Reiniciar a aplicação**:
  ```bash
  docker compose restart
  ```

## Licença

Defina a licença comercial adequada antes de distribuir o código.
