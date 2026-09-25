import { createBrowserClient } from "@supabase/ssr";
import type { Database } from "@/types/database.types";

export const DB_SCHEMA = (process.env.NEXT_PUBLIC_SUPABASE_SCHEMA || "quiz") as "quiz";

export function createClient() {
  return createBrowserClient<Database, "quiz">(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      db: {
        schema: DB_SCHEMA,
      },
    },
  );
}
