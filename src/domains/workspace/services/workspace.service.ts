import { assertCanInviteMember } from "@/domains/billing/services/subscription.service";
import type {
  InviteRole,
  UserProfile,
  UserWorkspace,
  Workspace,
  WorkspaceInvitation,
  WorkspaceMemberWithProfile,
  WorkspaceOwnerSummary,
  WorkspaceRole,
} from "@/domains/workspace/types/workspace.types";
import { createClient } from "@/services/supabase/server";
import { createAdminClient } from "@/services/supabase/admin";

export async function getDefaultWorkspaceForUser(
  userId: string,
): Promise<Workspace | null> {
  const workspaces = await listWorkspacesForUser(userId);
  return workspaces[0] ?? null;
}

export async function getWorkspaceBySlug(
  slug: string,
): Promise<Workspace | null> {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from("workspaces")
    .select("*")
    .eq("slug", slug)
    .maybeSingle();

  if (error || !data) {
    return null;
  }

  return data;
}

export async function userHasWorkspaceAccess(
  userId: string,
  workspaceId: string,
): Promise<boolean> {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from("workspace_members")
    .select("id")
    .eq("user_id", userId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();

  return !error && !!data;
}

export async function listWorkspacesForUser(
  userId: string,
): Promise<UserWorkspace[]> {
  const supabase = await createClient();

  const { data: memberships, error } = await supabase
    .from("workspace_members")
    .select("workspace_id, role, created_at")
    .eq("user_id", userId)
    .order("created_at", { ascending: true });

  if (error) {
    console.error("[listWorkspacesForUser] error fetching memberships:", error.message);
    return [];
  }

  if (!memberships?.length) {
    return [];
  }

  const workspaceIds = memberships.map((row) => row.workspace_id);
  const { data: workspaces, error: workspacesError } = await supabase
    .from("workspaces")
    .select("*")
    .in("id", workspaceIds);

  if (workspacesError) {
    console.error("[listWorkspacesForUser] error fetching workspaces:", workspacesError.message);
    return [];
  }

  if (!workspaces || workspaces.length === 0) {
    return [];
  }

  const workspaceById = new Map(workspaces.map((ws) => [ws.id, ws]));

  const ownerIds = [...new Set(workspaces.map((ws) => ws.owner_id))];
  const { data: owners, error: ownersError } = await supabase
    .from("profiles")
    .select("id, email, full_name")
    .in("id", ownerIds);

  if (ownersError) {
    console.warn(
      "[listWorkspacesForUser] Warning fetching workspace owners:",
      ownersError.message,
    );
  }

  const ownerList = owners ?? [];
  const ownerById = new Map<string, WorkspaceOwnerSummary>(
    ownerList.map((owner) => [owner.id, owner]),
  );

  return memberships
    .map((membership) => {
      const workspace = workspaceById.get(membership.workspace_id);
      if (!workspace) return null;
      const owner = ownerById.get(workspace.owner_id) ?? {
        id: workspace.owner_id,
        email: "",
        full_name: null,
      };
      return {
        ...workspace,
        role: membership.role as WorkspaceRole,
        owner,
      };
    })
    .filter((item): item is UserWorkspace => item !== null);
}

export async function ensureDefaultWorkspaceForUser(
  userId: string,
  email: string,
  fullName?: string | null,
): Promise<UserWorkspace[]> {
  try {
    const supabaseWithRpc = supabase as unknown as {
      rpc: (
        fn: string,
        args: Record<string, unknown>,
      ) => Promise<{ data: unknown; error: { message: string } | null }>;
    };
    const { error: rpcError } = await supabaseWithRpc.rpc(
      "create_default_workspace_if_missing",
      {
        p_user_id: userId,
        p_email: email || "",
        p_name: fullName || null,
      },
    );

    if (rpcError) {
      console.warn(
        "[ensureDefaultWorkspaceForUser] RPC fallback to admin:",
        rpcError.message,
      );
      try {
        const admin = createAdminClient();
        await admin.from("profiles").upsert(
          {
            id: userId,
            email: email || "",
            full_name: fullName || null,
          },
          { onConflict: "id" },
        );

        const baseName = fullName?.trim() || "Meu workspace";
        const slug = `workspace-${userId.replace(/-/g, "").slice(0, 8)}`;

        const { data: createdWs } = await admin
          .from("workspaces")
          .upsert(
            {
              name: baseName,
              slug,
              owner_id: userId,
            },
            { onConflict: "slug" },
          )
          .select()
          .maybeSingle();

        const workspaceId = createdWs?.id;
        if (workspaceId) {
          await admin.from("workspace_members").upsert(
            {
              workspace_id: workspaceId,
              user_id: userId,
              role: "owner",
            },
            { onConflict: "workspace_id,user_id" },
          );
        }
      } catch (adminErr) {
        console.error(
          "[ensureDefaultWorkspaceForUser] Admin fallback failed:",
          adminErr,
        );
      }
    }

    return await listWorkspacesForUser(userId);
  } catch (err) {
    console.error(
      "[ensureDefaultWorkspaceForUser] Erro ao provisionar workspace:",
      err,
    );
    return [];
  }
}

export async function getUserRoleInWorkspace(
  userId: string,
  workspaceId: string,
): Promise<WorkspaceRole | null> {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from("workspace_members")
    .select("role")
    .eq("user_id", userId)
    .eq("workspace_id", workspaceId)
    .maybeSingle();

  if (error || !data) return null;
  return data.role as WorkspaceRole;
}

export async function getUserProfile(
  userId: string,
): Promise<UserProfile | null> {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from("profiles")
    .select("id, email, full_name, avatar_url, created_at")
    .eq("id", userId)
    .maybeSingle();

  if (error || !data) return null;
  return data;
}

export async function listWorkspaceMembers(
  workspaceId: string,
): Promise<WorkspaceMemberWithProfile[]> {
  const supabase = await createClient();

  const { data: members, error } = await supabase
    .from("workspace_members")
    .select("id, workspace_id, user_id, role, created_at")
    .eq("workspace_id", workspaceId)
    .order("created_at", { ascending: true });

  if (error || !members?.length) return [];

  const userIds = members.map((member) => member.user_id);
  const { data: profiles, error: profilesError } = await supabase
    .from("profiles")
    .select("id, email, full_name, avatar_url")
    .in("id", userIds);

  if (profilesError || !profiles) return [];

  const profileById = new Map(profiles.map((profile) => [profile.id, profile]));

  return members
    .map((member) => {
      const profile = profileById.get(member.user_id);
      if (!profile) return null;
      return {
        id: member.id,
        workspace_id: member.workspace_id,
        user_id: member.user_id,
        role: member.role,
        created_at: member.created_at,
        profile,
      };
    })
    .filter((item): item is WorkspaceMemberWithProfile => item !== null);
}

export async function listWorkspaceInvitations(
  workspaceId: string,
): Promise<WorkspaceInvitation[]> {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from("workspace_invitations")
    .select("*")
    .eq("workspace_id", workspaceId)
    .eq("status", "pending")
    .order("created_at", { ascending: false });

  if (error || !data) return [];
  return data as WorkspaceInvitation[];
}

export async function inviteWorkspaceMember(params: {
  workspaceId: string;
  email: string;
  role: InviteRole;
  invitedBy: string;
}): Promise<
  | { success: true; invitation: WorkspaceInvitation }
  | { success: false; error: string }
> {
  const supabase = await createClient();
  const email = params.email.trim().toLowerCase();

  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return { success: false, error: "E-mail inválido" };
  }

  try {
    await assertCanInviteMember(params.workspaceId);
  } catch (error) {
    return {
      success: false,
      error:
        error instanceof Error
          ? error.message
          : "Não foi possível convidar membro",
    };
  }

  const { data, error } = await supabase
    .from("workspace_invitations")
    .insert({
      workspace_id: params.workspaceId,
      email,
      role: params.role,
      invited_by: params.invitedBy,
    })
    .select("*")
    .single();

  if (error) {
    if (error.code === "23505") {
      return {
        success: false,
        error: "Já existe um convite pendente para este e-mail",
      };
    }
    return { success: false, error: "Não foi possível criar o convite" };
  }

  return { success: true, invitation: data as WorkspaceInvitation };
}

export async function revokeWorkspaceInvitation(
  invitationId: string,
  workspaceId: string,
): Promise<{ success: boolean; error?: string }> {
  const supabase = await createClient();

  const { error } = await supabase
    .from("workspace_invitations")
    .update({ status: "revoked" })
    .eq("id", invitationId)
    .eq("workspace_id", workspaceId)
    .eq("status", "pending");

  if (error) {
    return { success: false, error: "Não foi possível revogar o convite" };
  }

  return { success: true };
}

export async function acceptWorkspaceInvitation(
  token: string,
): Promise<
  { success: true; workspaceSlug: string } | { success: false; error: string }
> {
  const supabase = await createClient();

  const { data, error } = await supabase.rpc("accept_workspace_invitation", {
    invite_token: token,
  });

  if (error || !data) {
    return {
      success: false,
      error: error?.message ?? "Não foi possível aceitar o convite",
    };
  }

  return { success: true, workspaceSlug: String(data) };
}

export async function getInvitationByToken(
  token: string,
): Promise<WorkspaceInvitation | null> {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from("workspace_invitations")
    .select("*")
    .eq("token", token)
    .eq("status", "pending")
    .maybeSingle();

  if (error || !data) return null;
  return data as WorkspaceInvitation;
}

export async function resolveActiveWorkspaceForUser(params: {
  userId: string;
  querySlug?: string | null;
  cookieSlug?: string | null;
}): Promise<UserWorkspace | null> {
  const workspaces = await listWorkspacesForUser(params.userId);
  if (workspaces.length === 0) return null;

  const fromQuery = params.querySlug
    ? workspaces.find((ws) => ws.slug === params.querySlug)
    : undefined;
  if (fromQuery) return fromQuery;

  const fromCookie = params.cookieSlug
    ? workspaces.find((ws) => ws.slug === params.cookieSlug)
    : undefined;
  if (fromCookie) return fromCookie;

  return workspaces[0];
}

export async function updateWorkspaceName(
  workspaceId: string,
  name: string,
): Promise<{ success: true } | { success: false; error: string }> {
  const supabase = await createClient();

  const { error } = await supabase
    .from("workspaces")
    .update({ name: name.trim() })
    .eq("id", workspaceId);

  if (error) {
    return { success: false, error: "Não foi possível renomear o workspace." };
  }

  return { success: true };
}
